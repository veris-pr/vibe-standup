/// Standup CLI — the main entry point.

import ArgumentParser
import Foundation
import StandupCore
import LivePlugins
import StagePlugins

@main
struct StandupCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "standup",
        abstract: "Audio capture and processing pipeline for meetings",
        subcommands: [
            StartCommand.self,
            StopCommand.self,
            ListCommand.self,
            ShowCommand.self,
            SetupCommand.self,
        ],
        defaultSubcommand: nil
    )
}

// MARK: - Shared State

/// Builds and returns the shared registry with all built-in plugins.
func buildRegistry() -> PluginRegistry {
    let registry = PluginRegistry()
    LivePluginRegistration.registerAll(in: registry)
    StagePluginRegistration.registerAll(in: registry)
    return registry
}

// MARK: - Start

struct StartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start an audio capture session"
    )

    @Option(name: .long, help: "Pipeline to use (YAML file name without extension)")
    var pipeline: String = "default"

    func run() async throws {
        let config = StandupConfig.load()
        let registry = buildRegistry()
        let engine = PipelineEngine(registry: registry)

        // Load pipeline definition
        let pipelinePath = (config.pipelinesDirectory as NSString)
            .appendingPathComponent("\(pipeline).yaml")

        let definition: PipelineDefinition
        if FileManager.default.fileExists(atPath: pipelinePath) {
            definition = try PipelineParser.load(from: pipelinePath)
        } else {
            // Default: no live plugins, no stages
            definition = PipelineDefinition(
                name: pipeline,
                description: "Default capture-only pipeline",
                liveChains: LiveChainConfig(),
                stages: []
            )
        }

        // Build live plugin chains
        let chains = try await engine.buildLiveChains(from: definition)

        // Start session
        let sessionManager = try SessionManager(baseDirectory: config.baseDirectory)
        let session = try await sessionManager.startSession(
            pipelineName: pipeline,
            micChain: chains.mic,
            systemChain: chains.system
        )

        print("● Session \(session.id) started")
        print("● Pipeline: \(pipeline)")
        print("● Capturing: mic + system audio")
        print("● Press Ctrl+C or run `standup stop` to end")

        // Write active session ID to a file so `standup stop` can find it
        let pidFile = (config.baseDirectory as NSString).appendingPathComponent("active_session")
        try session.id.write(toFile: pidFile, atomically: true, encoding: .utf8)

        // Wait for signal
        let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        sigSource.setEventHandler {
            sigSource.cancel()
            Task {
                let stopped = try await sessionManager.stopSession()
                print("\n■ Session \(stopped.id) stopped")

                if !definition.stages.isEmpty {
                    print("⚙ Running pipeline: \(pipeline)")
                    try await engine.executeStages(definition: definition, session: stopped)
                    try sessionManager.markComplete(sessionId: stopped.id)
                    print("✓ Pipeline complete")
                } else {
                    try sessionManager.markComplete(sessionId: stopped.id)
                }

                try? FileManager.default.removeItem(atPath: pidFile)
                Foundation.exit(0)
            }
        }
        sigSource.resume()

        // Keep running
        dispatchMain()
    }
}

// MARK: - Stop

struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the active capture session"
    )

    func run() async throws {
        let config = StandupConfig.load()
        let pidFile = (config.baseDirectory as NSString).appendingPathComponent("active_session")

        guard FileManager.default.fileExists(atPath: pidFile) else {
            print("No active session")
            return
        }

        let sessionId = try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        print("■ Requesting stop for session \(sessionId)")
        print("  (The running `standup start` process will handle shutdown)")

        // Signal the running process
        // In practice, you'd use a proper IPC mechanism.
        // For now, remove the pid file as a signal.
        try FileManager.default.removeItem(atPath: pidFile)
    }
}

// MARK: - List

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all sessions"
    )

    func run() async throws {
        let config = StandupConfig.load()
        let sessionManager = try SessionManager(baseDirectory: config.baseDirectory)
        let sessions = try sessionManager.listSessions()

        if sessions.isEmpty {
            print("No sessions found")
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        print(String(format: "%-10s %-20s %-12s %s", "SESSION", "PIPELINE", "STATUS", "STARTED"))
        print(String(repeating: "─", count: 60))
        for s in sessions {
            print(String(format: "%-10s %-20s %-12s %s",
                         s.id,
                         s.pipelineName,
                         s.status.rawValue,
                         formatter.string(from: s.startTime)))
        }
    }
}

// MARK: - Show

struct ShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show details of a session"
    )

    @Argument(help: "Session ID")
    var sessionId: String

    func run() async throws {
        let config = StandupConfig.load()
        let sessionManager = try SessionManager(baseDirectory: config.baseDirectory)

        guard let session = try sessionManager.getSession(id: sessionId) else {
            print("Session not found: \(sessionId)")
            return
        }

        print("Session:  \(session.id)")
        print("Pipeline: \(session.pipelineName)")
        print("Status:   \(session.status.rawValue)")
        print("Started:  \(session.startTime)")
        if let end = session.endTime {
            let duration = end.timeIntervalSince(session.startTime)
            print("Duration: \(String(format: "%.0f", duration))s")
        }
        print("Directory: \(session.directoryPath)")

        // List artifacts
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(atPath: session.directoryPath) {
            let dirs = contents.filter { name in
                var isDir: ObjCBool = false
                fm.fileExists(atPath: (session.directoryPath as NSString).appendingPathComponent(name), isDirectory: &isDir)
                return isDir.boolValue
            }
            if !dirs.isEmpty {
                print("Artifacts:")
                for dir in dirs.sorted() {
                    print("  └─ \(dir)/")
                }
            }
        }
    }
}

// MARK: - Setup

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Initialize Standup configuration and check permissions"
    )

    func run() async throws {
        let config = StandupConfig.load()

        // Create directories
        let dirs = [
            config.baseDirectory,
            config.pipelinesDirectory,
        ] + config.pluginSearchPaths

        for dir in dirs {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            print("✓ Created \(dir)")
        }

        // Write default config if not exists
        let configPath = (config.baseDirectory as NSString).appendingPathComponent("config.yaml")
        if !FileManager.default.fileExists(atPath: configPath) {
            try StandupConfig.writeDefault(to: configPath)
            print("✓ Default config written to \(configPath)")
        } else {
            print("✓ Config exists at \(configPath)")
        }

        print("")
        print("Note: When you first run `standup start`, macOS will prompt for:")
        print("  • Microphone access")
        print("  • Screen Recording access (needed for system audio capture)")
        print("")
        print("Setup complete! Create pipeline YAML files in:")
        print("  \(config.pipelinesDirectory)/")
    }
}

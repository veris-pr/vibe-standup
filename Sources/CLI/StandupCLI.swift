/// Standup CLI — entry point. Uses application services from StandupCore.

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
        subcommands: [StartCommand.self, StopCommand.self, ListCommand.self, ShowCommand.self, SetupCommand.self]
    )
}

// MARK: - Shared

func buildRegistry() -> PluginRegistry {
    let registry = PluginRegistry()
    LivePluginRegistration.registerAll(in: registry)
    StagePluginRegistration.registerAll(in: registry)
    return registry
}

func buildServices() throws -> (config: StandupConfig, registry: PluginRegistry, sessionService: SessionService, pipelineService: PipelineService) {
    let config = StandupConfig.load()
    let registry = buildRegistry()
    let repo = try SQLiteSessionRepository(dbPath: config.dbPath)
    let sessionService = SessionService(config: config, repository: repo)
    let pipelineService = PipelineService(registry: registry)
    return (config, registry, sessionService, pipelineService)
}

// MARK: - Start

struct StartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start an audio capture session")

    @Option(name: .long, help: "Pipeline to use (YAML file name without extension)")
    var pipeline: String = "default"

    func run() async throws {
        let (config, _, sessionService, pipelineService) = try buildServices()

        let pipelinePath = (config.pipelinesDirectory as NSString).appendingPathComponent("\(pipeline).yaml")
        let definition: PipelineDefinition
        if FileManager.default.fileExists(atPath: pipelinePath) {
            definition = try PipelineService.load(from: pipelinePath)
        } else {
            definition = .captureOnly(name: pipeline)
        }

        let chains = try await pipelineService.buildLiveChains(from: definition)
        let session = try await sessionService.startSession(
            pipelineName: pipeline,
            micChain: chains.mic,
            systemChain: chains.system
        )

        print("● Session \(session.id) started")
        print("● Pipeline: \(pipeline)")
        print("● Capturing: mic + system audio")
        print("● Press Ctrl+C or run `standup stop` to end")

        try session.id.write(toFile: config.activeSessionFile, atomically: true, encoding: .utf8)

        let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        sigSource.setEventHandler {
            sigSource.cancel()
            Task {
                let stopped = try await sessionService.stopSession()
                print("\n■ Session \(stopped.id) stopped")

                if !definition.stages.isEmpty {
                    print("⚙ Running pipeline: \(pipeline)")
                    try await pipelineService.executeStages(definition: definition, session: stopped)
                    try sessionService.markComplete(sessionId: stopped.id)
                    print("✓ Pipeline complete")
                } else {
                    try sessionService.markComplete(sessionId: stopped.id)
                }

                try? FileManager.default.removeItem(atPath: config.activeSessionFile)
                Foundation.exit(0)
            }
        }
        sigSource.resume()
        dispatchMain()
    }
}

// MARK: - Stop

struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop the active capture session")

    func run() async throws {
        let config = StandupConfig.load()
        guard FileManager.default.fileExists(atPath: config.activeSessionFile) else {
            print("No active session")
            return
        }
        let sessionId = try String(contentsOfFile: config.activeSessionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        print("■ Requesting stop for session \(sessionId)")
        try FileManager.default.removeItem(atPath: config.activeSessionFile)
    }
}

// MARK: - List

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List all sessions")

    func run() async throws {
        let (_, _, sessionService, _) = try buildServices()
        let sessions = try sessionService.listSessions()

        if sessions.isEmpty {
            print("No sessions found")
            return
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"

        print(String(format: "%-10s %-20s %-12s %s", "SESSION", "PIPELINE", "STATUS", "STARTED"))
        print(String(repeating: "─", count: 60))
        for s in sessions {
            print(String(format: "%-10s %-20s %-12s %s", s.id, s.pipelineName, s.status.rawValue, fmt.string(from: s.startTime)))
        }
    }
}

// MARK: - Show

struct ShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show session details")

    @Argument(help: "Session ID")
    var sessionId: String

    func run() async throws {
        let (_, _, sessionService, _) = try buildServices()

        guard let session = try sessionService.getSession(id: sessionId) else {
            print("Session not found: \(sessionId)")
            return
        }

        print("Session:   \(session.id)")
        print("Pipeline:  \(session.pipelineName)")
        print("Status:    \(session.status.rawValue)")
        print("Started:   \(session.startTime)")
        if let end = session.endTime {
            print("Duration:  \(String(format: "%.0f", end.timeIntervalSince(session.startTime)))s")
        }
        print("Directory: \(session.directoryPath)")

        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(atPath: session.directoryPath) {
            let dirs = contents.filter { name in
                var isDir: ObjCBool = false
                fm.fileExists(atPath: (session.directoryPath as NSString).appendingPathComponent(name), isDirectory: &isDir)
                return isDir.boolValue
            }
            if !dirs.isEmpty {
                print("Artifacts:")
                for dir in dirs.sorted() { print("  └─ \(dir)/") }
            }
        }
    }
}

// MARK: - Setup

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "setup", abstract: "Initialize Standup configuration")

    func run() async throws {
        let config = StandupConfig.load()

        for dir in [config.baseDirectory, config.pipelinesDirectory, config.sessionsDirectory] + config.pluginSearchPaths {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            print("✓ Created \(dir)")
        }

        let configPath = (config.baseDirectory as NSString).appendingPathComponent("config.yaml")
        if !FileManager.default.fileExists(atPath: configPath) {
            try StandupConfig.writeDefault(to: configPath)
            print("✓ Default config written to \(configPath)")
        } else {
            print("✓ Config exists at \(configPath)")
        }

        let registry = buildRegistry()
        print("\nRegistered plugins:")
        print("  Live:  \(registry.allLivePluginIds.joined(separator: ", "))")
        print("  Stage: \(registry.allStagePluginIds.joined(separator: ", "))")

        print("\nNote: macOS will prompt for Microphone and Screen Recording access on first run.")
        print("Setup complete!")
    }
}

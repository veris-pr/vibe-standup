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
        subcommands: [InitCommand.self, StartCommand.self, StopCommand.self, ListCommand.self, ShowCommand.self, SetupCommand.self]
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

// MARK: - Init

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Initialize Standup: install dependencies, download models, configure permissions"
    )

    @Flag(name: .long, help: "Skip Homebrew dependency installation")
    var skipBrew: Bool = false

    @Flag(name: .long, help: "Skip whisper model download")
    var skipModel: Bool = false

    @Option(name: .long, help: "Whisper model to download (tiny, base, small, medium, large)")
    var model: String = "base.en"

    @Flag(name: .long, help: "Show what would be done without making changes")
    var dryRun: Bool = false

    func run() async throws {
        print("""
        ┌──────────────────────────────────┐
        │   Standup — Initialization       │
        └──────────────────────────────────┘
        """)

        let config = StandupConfig.load()
        var checks = CheckResults()

        // 1. System requirements
        printStep("Checking system requirements")
        try checkSystemRequirements(&checks)

        // 2. Directory structure
        printStep("Creating directory structure")
        try createDirectories(config: config, dryRun: dryRun)

        // 3. Homebrew + whisper-cpp
        if !skipBrew {
            printStep("Checking Homebrew dependencies")
            try await installBrewDependencies(dryRun: dryRun, checks: &checks)
        } else {
            printSkip("Homebrew installation (--skip-brew)")
        }

        // 4. Whisper model
        if !skipModel {
            printStep("Checking whisper model: \(model)")
            try await downloadWhisperModel(modelName: model, config: config, dryRun: dryRun, checks: &checks)
        } else {
            printSkip("Whisper model download (--skip-model)")
        }

        // 5. Copy bundled pipelines
        printStep("Installing pipeline definitions")
        try installPipelines(config: config, dryRun: dryRun)

        // 6. Default config
        printStep("Writing default configuration")
        try writeConfig(config: config, dryRun: dryRun)

        // 7. macOS permissions check
        printStep("Checking macOS permissions")
        checkPermissions(&checks)

        // 8. Validate plugin registry
        printStep("Validating plugin registry")
        let registry = buildRegistry()
        printOK("Live plugins: \(registry.allLivePluginIds.joined(separator: ", "))")
        printOK("Stage plugins: \(registry.allStagePluginIds.joined(separator: ", "))")

        // Summary
        printSummary(checks)
    }

    // MARK: - Steps

    private func checkSystemRequirements(_ checks: inout CheckResults) throws {
        // macOS version
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let versionStr = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        if os.majorVersion >= 14 {
            printOK("macOS \(versionStr) (requires 14+)")
        } else {
            printFail("macOS \(versionStr) — requires macOS 14 (Sonoma) or later")
            checks.errors.append("macOS 14+ required")
        }

        // Swift
        let swiftVersion = try shellOutput("/usr/bin/xcrun", args: ["swift", "--version"])
        if let firstLine = swiftVersion.split(separator: "\n").first {
            printOK("Swift: \(firstLine.trimmingCharacters(in: .whitespaces))")
        } else {
            printFail("Swift not found — install Xcode or Xcode Command Line Tools")
            checks.errors.append("Swift not found")
        }

        // Architecture
        #if arch(arm64)
        printOK("Architecture: Apple Silicon (arm64)")
        #else
        printWarn("Architecture: Intel (x86_64) — Apple Silicon recommended for performance")
        checks.warnings.append("Intel architecture — whisper.cpp will be slower")
        #endif
    }

    private func createDirectories(config: StandupConfig, dryRun: Bool) throws {
        let dirs = [
            config.baseDirectory,
            config.pipelinesDirectory,
            config.sessionsDirectory,
            (config.baseDirectory as NSString).appendingPathComponent("models"),
        ] + config.pluginSearchPaths

        for dir in dirs {
            if dryRun {
                printDry("mkdir -p \(dir)")
            } else {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                printOK("Created \(dir)")
            }
        }
    }

    private func installBrewDependencies(dryRun: Bool, checks: inout CheckResults) async throws {
        // Check Homebrew
        let brewPath = findExecutable("brew")
        guard let brew = brewPath else {
            printFail("Homebrew not found — install from https://brew.sh")
            checks.errors.append("Homebrew not installed")
            return
        }
        printOK("Homebrew found: \(brew)")

        // Check whisper-cpp
        let whisperInstalled = findExecutable("whisper-cpp") != nil
            || FileManager.default.fileExists(atPath: "/opt/homebrew/bin/whisper-cpp")
            || FileManager.default.fileExists(atPath: "/usr/local/bin/whisper-cpp")

        if whisperInstalled {
            printOK("whisper-cpp already installed")
        } else {
            if dryRun {
                printDry("brew install whisper-cpp")
            } else {
                printProgress("Installing whisper-cpp via Homebrew...")
                let (exitCode, output) = try await runProcess(brew, args: ["install", "whisper-cpp"])
                if exitCode == 0 {
                    printOK("whisper-cpp installed successfully")
                } else {
                    printFail("whisper-cpp installation failed")
                    if !output.isEmpty { print("  \(output.prefix(200))") }
                    checks.warnings.append("whisper-cpp install failed — transcription will use placeholder")
                }
            }
        }
    }

    private func downloadWhisperModel(modelName: String, config: StandupConfig, dryRun: Bool, checks: inout CheckResults) async throws {
        let modelsDir = (config.baseDirectory as NSString).appendingPathComponent("models")
        let modelFile = "ggml-\(modelName).bin"
        let modelPath = (modelsDir as NSString).appendingPathComponent(modelFile)

        // Also check Homebrew's model directory
        let brewModelPath = "/opt/homebrew/share/whisper-cpp/models/\(modelFile)"

        if FileManager.default.fileExists(atPath: modelPath) {
            printOK("Model exists: \(modelPath)")
            return
        }
        if FileManager.default.fileExists(atPath: brewModelPath) {
            printOK("Model exists (Homebrew): \(brewModelPath)")
            return
        }

        let url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(modelFile)"

        if dryRun {
            printDry("curl -L \(url) -o \(modelPath)")
            return
        }

        printProgress("Downloading \(modelFile) from Hugging Face...")
        printProgress("URL: \(url)")
        printProgress("Destination: \(modelPath)")

        let (exitCode, _) = try await runProcess("/usr/bin/curl", args: [
            "-L", "--progress-bar", "-o", modelPath, url
        ])

        if exitCode == 0 && FileManager.default.fileExists(atPath: modelPath) {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: modelPath),
               let size = attrs[.size] as? Int {
                let mb = Double(size) / 1_048_576
                printOK("Model downloaded: \(modelFile) (\(String(format: "%.0f", mb)) MB)")
            } else {
                printOK("Model downloaded: \(modelFile)")
            }
        } else {
            printFail("Model download failed — transcription will use placeholder")
            checks.warnings.append("Whisper model download failed")
        }
    }

    private func installPipelines(config: StandupConfig, dryRun: Bool) throws {
        // Find bundled pipelines relative to the executable or CWD
        let candidates = [
            "pipelines",
            (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("pipelines"),
        ]

        let fm = FileManager.default
        var bundledDir: String? = nil
        for candidate in candidates {
            if fm.fileExists(atPath: candidate) {
                bundledDir = candidate
                break
            }
        }

        guard let source = bundledDir else {
            printWarn("No bundled pipelines found — you can add .yaml files to \(config.pipelinesDirectory)")
            return
        }

        let yamlFiles = (try? fm.contentsOfDirectory(atPath: source).filter { $0.hasSuffix(".yaml") }) ?? []
        for file in yamlFiles {
            let srcPath = (source as NSString).appendingPathComponent(file)
            let dstPath = (config.pipelinesDirectory as NSString).appendingPathComponent(file)
            if fm.fileExists(atPath: dstPath) {
                printOK("Pipeline exists: \(file)")
            } else if dryRun {
                printDry("cp \(srcPath) \(dstPath)")
            } else {
                try fm.copyItem(atPath: srcPath, toPath: dstPath)
                printOK("Installed pipeline: \(file)")
            }
        }
    }

    private func writeConfig(config: StandupConfig, dryRun: Bool) throws {
        let configPath = (config.baseDirectory as NSString).appendingPathComponent("config.yaml")
        if FileManager.default.fileExists(atPath: configPath) {
            printOK("Config exists: \(configPath)")
        } else if dryRun {
            printDry("Write default config to \(configPath)")
        } else {
            try StandupConfig.writeDefault(to: configPath)
            printOK("Config written: \(configPath)")
        }
    }

    private func checkPermissions(_ checks: inout CheckResults) {
        // We can't directly check these, but we can tell the user what to expect
        printWarn("Microphone access — macOS will prompt on first capture session")
        printWarn("Screen Recording access — required for system audio capture")
        print("  → System Settings > Privacy & Security > Screen Recording > enable 'standup'")
        print("  → System Settings > Privacy & Security > Microphone > enable 'standup'")
        checks.warnings.append("Grant Microphone + Screen Recording permissions on first run")
    }

    // MARK: - Helpers

    private func findExecutable(_ name: String) -> String? {
        let paths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func shellOutput(_ path: String, args: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func runProcess(_ path: String, args: [String]) async throws -> (Int32, String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    private func printStep(_ msg: String) { print("\n▸ \(msg)") }
    private func printOK(_ msg: String) { print("  ✓ \(msg)") }
    private func printFail(_ msg: String) { print("  ✗ \(msg)") }
    private func printWarn(_ msg: String) { print("  ⚠ \(msg)") }
    private func printProgress(_ msg: String) { print("  … \(msg)") }
    private func printSkip(_ msg: String) { print("  ⊘ Skipped: \(msg)") }
    private func printDry(_ msg: String) { print("  [dry-run] \(msg)") }

    private func printSummary(_ checks: CheckResults) {
        print("\n┌──────────────────────────────────┐")
        print("│   Summary                        │")
        print("└──────────────────────────────────┘")

        if checks.errors.isEmpty && checks.warnings.isEmpty {
            print("  ✓ All checks passed. Ready to go!")
            print("\n  Next: standup start --pipeline standup-comics")
        } else {
            if !checks.errors.isEmpty {
                print("  Errors:")
                for e in checks.errors { print("    ✗ \(e)") }
            }
            if !checks.warnings.isEmpty {
                print("  Warnings:")
                for w in checks.warnings { print("    ⚠ \(w)") }
            }
            if checks.errors.isEmpty {
                print("\n  ✓ Setup complete (with warnings). Ready to go!")
                print("  Next: standup start --pipeline standup-comics")
            } else {
                print("\n  ✗ Fix errors above before running standup.")
            }
        }
        print()
    }
}

private struct CheckResults {
    var errors: [String] = []
    var warnings: [String] = []
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

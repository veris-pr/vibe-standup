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
        subcommands: [InitCommand.self, StartCommand.self, StopCommand.self, ResumeCommand.self, ListCommand.self, ShowCommand.self, SetupCommand.self, DoctorCommand.self]
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
    var model: String = "small"

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

        // 8. Virtual audio device check
        printStep("Checking virtual audio devices")
        checkVirtualDevices(&checks)

        // 9. Install optional dependencies for standup-comics pipeline
        printStep("Installing optional dependencies (standup-comics)")
        try await installOptionalDependencies(dryRun: dryRun, checks: &checks)

        // 10. Validate plugin registry
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
        ]

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

        let registry = buildRegistry()
        let availableStagePlugins = Set(registry.allStagePluginIds)
        let yamlFiles = (try? fm.contentsOfDirectory(atPath: source).filter { $0.hasSuffix(".yaml") }) ?? []
        for file in yamlFiles {
            let srcPath = (source as NSString).appendingPathComponent(file)
            let dstPath = (config.pipelinesDirectory as NSString).appendingPathComponent(file)

            if let definition = try? PipelineService.load(from: srcPath) {
                let missingPlugins = Set(definition.stages.map(\.pluginId))
                    .subtracting(availableStagePlugins)
                    .sorted()
                if !missingPlugins.isEmpty {
                    printWarn("Skipping pipeline \(file) — missing stage plugins: \(missingPlugins.joined(separator: ", "))")
                    continue
                }
            }

            if fm.fileExists(atPath: dstPath) {
                let srcData = fm.contents(atPath: srcPath)
                let dstData = fm.contents(atPath: dstPath)
                if srcData == dstData {
                    printOK("Pipeline up to date: \(file)")
                } else if dryRun {
                    printDry("Update \(file) (bundled version differs)")
                } else {
                    try fm.removeItem(atPath: dstPath)
                    try fm.copyItem(atPath: srcPath, toPath: dstPath)
                    printOK("Updated pipeline: \(file)")
                }
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
        printWarn("Screen Recording access — required for system audio capture (screen-capture mode)")
        print("  → System Settings > Privacy & Security > Screen Recording > enable 'standup'")
        print("  → System Settings > Privacy & Security > Microphone > enable 'standup'")
        checks.warnings.append("Grant Microphone + Screen Recording permissions on first run")
    }

    private func checkVirtualDevices(_ checks: inout CheckResults) {
        let devices = VirtualDeviceCaptureEngine.availableVirtualDevices()
        if devices.isEmpty {
            printWarn("No virtual audio devices found (optional)")
            print("  → To use --capture virtual-device, install: brew install blackhole-2ch")
            print("  → Then set your meeting app's audio output to 'BlackHole 2ch'")
        } else {
            for d in devices { printOK("Found: \(d)") }
            print("  → Use: standup start --capture virtual-device --virtual-device \"\(devices[0])\"")
        }
    }

    private func installOptionalDependencies(dryRun: Bool, checks: inout CheckResults) async throws {
        try await installOllama(dryRun: dryRun, checks: &checks)
        try await installMflux(dryRun: dryRun, checks: &checks)
    }

    private func installOllama(dryRun: Bool, checks: inout CheckResults) async throws {
        if let ollamaPath = findExecutable("ollama") {
            printOK("Ollama found: \(ollamaPath)")
        } else {
            guard let brew = findExecutable("brew") else {
                printWarn("Ollama not found and Homebrew unavailable — comic-script will use heuristic fallback")
                checks.warnings.append("Ollama not installed — comic script uses heuristic fallback")
                return
            }
            if dryRun {
                printDry("brew install ollama")
            } else {
                printProgress("Installing Ollama via Homebrew...")
                let (exitCode, output) = try await runProcess(brew, args: ["install", "ollama"])
                if exitCode == 0 {
                    printOK("Ollama installed")
                } else {
                    printFail("Ollama install failed")
                    if !output.isEmpty { print("  \(output.prefix(200))") }
                    checks.warnings.append("Ollama install failed — comic script uses heuristic fallback")
                    return
                }
            }
        }

        // Start Ollama service if not already running
        if !dryRun {
            if let brew = findExecutable("brew") {
                let (_, _) = try await runProcess(brew, args: ["services", "start", "ollama"])
                // Ignore result — may already be running
            }
        }

        // Pull gemma3:4b model if not present
        guard let ollama = findExecutable("ollama") else { return }
        let (_, listOutput) = try await runProcess(ollama, args: ["list"])
        if listOutput.contains("gemma3:4b") {
            printOK("Ollama model gemma3:4b already pulled")
        } else {
            if dryRun {
                printDry("ollama pull gemma3:4b")
            } else {
                printProgress("Pulling gemma3:4b model (≈3.3 GB)...")
                let (exitCode, output) = try await runProcess(ollama, args: ["pull", "gemma3:4b"])
                if exitCode == 0 {
                    printOK("gemma3:4b model pulled")
                } else {
                    printWarn("Failed to pull gemma3:4b — pull manually: ollama pull gemma3:4b")
                    if !output.isEmpty { print("  \(output.prefix(200))") }
                    checks.warnings.append("Ollama model pull failed")
                }
            }
        }
    }

    private func installMflux(dryRun: Bool, checks: inout CheckResults) async throws {
        if let found = findMflux() {
            printOK("mflux-generate found: \(found)")
            return
        }

        let venvDir = (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent(".standup/venv")
        let venvBin = (venvDir as NSString).appendingPathComponent("bin/mflux-generate")

        if dryRun {
            printDry("python3 -m venv \(venvDir) && \(venvDir)/bin/pip install mflux")
            return
        }

        // Create venv if it doesn't exist
        let venvPython = (venvDir as NSString).appendingPathComponent("bin/python3")
        if !FileManager.default.fileExists(atPath: venvPython) {
            printProgress("Creating Python venv at \(venvDir)...")
            let (exitCode, output) = try await runProcess("/usr/bin/python3", args: ["-m", "venv", venvDir])
            if exitCode != 0 {
                printFail("Failed to create Python venv")
                if !output.isEmpty { print("  \(output.prefix(200))") }
                checks.warnings.append("mflux not installed — image generation uses SVG placeholders")
                return
            }
        }

        // Install mflux into the venv
        let pip = (venvDir as NSString).appendingPathComponent("bin/pip")
        printProgress("Installing mflux into venv (this may take a few minutes)...")
        let (exitCode, output) = try await runProcess(pip, args: ["install", "mflux"])
        if exitCode == 0 && FileManager.default.fileExists(atPath: venvBin) {
            printOK("mflux installed: \(venvBin)")
        } else {
            printFail("mflux installation failed")
            if !output.isEmpty { print("  \(output.prefix(200))") }
            checks.warnings.append("mflux not installed — image generation uses SVG placeholders")
        }
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

    private func findMflux() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/mflux-generate",
            "/usr/local/bin/mflux-generate",
            (home as NSString).appendingPathComponent(".local/bin/mflux-generate"),
            (home as NSString).appendingPathComponent(".standup/venv/bin/mflux-generate"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func shellOutput(_ path: String, args: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func runProcess(_ path: String, args: [String]) async throws -> (Int32, String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
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

    @Option(name: .long, help: "Audio capture source: screen-capture (default) or virtual-device")
    var capture: String?

    @Option(name: .long, help: "Virtual audio device name (default: 'BlackHole 2ch')")
    var virtualDevice: String?

    @Flag(name: .long, help: "List available virtual audio devices and exit")
    var listDevices: Bool = false

    func run() async throws {
        // Handle --list-devices
        if listDevices {
            let devices = VirtualDeviceCaptureEngine.availableVirtualDevices()
            if devices.isEmpty {
                print("No virtual audio devices found.")
                print("Install one with: brew install blackhole-2ch")
            } else {
                print("Available virtual audio devices:")
                for d in devices { print("  • \(d)") }
            }
            return
        }

        let (config, registry, sessionService, pipelineService) = try buildServices()

        // Verify init has been run
        let configPath = (config.baseDirectory as NSString).appendingPathComponent("config.yaml")
        if !FileManager.default.fileExists(atPath: configPath) {
            print("✗ Standup not initialized. Run `standup init` first.")
            Foundation.exit(1)
        }

        let pipelinePath = (config.pipelinesDirectory as NSString).appendingPathComponent("\(pipeline).yaml")
        let definition: PipelineDefinition
        if FileManager.default.fileExists(atPath: pipelinePath) {
            definition = try PipelineService.load(from: pipelinePath)
            print("● Pipeline: \(definition.name) — \(definition.description)")
        } else if pipeline == "default" {
            definition = .captureOnly(name: pipeline)
            print("● Pipeline: capture-only (no post-processing)")
        } else {
            print("✗ Pipeline not found: \(pipelinePath)")
            print("  Available pipelines:")
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(atPath: config.pipelinesDirectory).filter({ $0.hasSuffix(".yaml") }) {
                for f in files.sorted() { print("    - \(f.replacingOccurrences(of: ".yaml", with: ""))") }
            }
            Foundation.exit(1)
        }

        let missingStagePlugins = Set(definition.stages.map(\.pluginId))
            .subtracting(Set(registry.allStagePluginIds))
            .sorted()
        if !missingStagePlugins.isEmpty {
            print("✗ Pipeline '\(definition.name)' references unavailable stage plugins:")
            for pluginId in missingStagePlugins {
                print("  - \(pluginId)")
            }
            Foundation.exit(1)
        }

        print("● Starting audio capture...")

        // Resolve capture source: CLI flag > pipeline YAML > default
        let captureSource: AudioCaptureSource
        if let captureFlag = capture {
            guard let source = AudioCaptureSource(rawValue: captureFlag) else {
                print("✗ Unknown capture source: '\(captureFlag)'")
                print("  Available: \(AudioCaptureSource.allCases.map(\.rawValue).joined(separator: ", "))")
                Foundation.exit(1)
            }
            captureSource = source
        } else if let pipelineSource = definition.captureSource {
            captureSource = pipelineSource
        } else {
            captureSource = .screenCapture
        }

        let deviceName = virtualDevice ?? definition.virtualDeviceName

        do {
            let chains = try await pipelineService.buildLiveChains(from: definition)
            let liveCount = chains.mic.pluginCount + chains.system.pluginCount
            if liveCount > 0 {
                print("● Live plugins: \(chains.mic.pluginCount) mic, \(chains.system.pluginCount) system")
            }

            print("● Capture source: \(captureSource.displayName)")
            if captureSource == .virtualDevice {
                print("● Virtual device: \(deviceName ?? "BlackHole 2ch")")
            }

            let session = try await sessionService.startSession(
                pipelineName: pipeline,
                micChain: chains.mic,
                systemChain: chains.system,
                captureSource: captureSource,
                virtualDeviceName: deviceName
            )

            print("● Session \(session.id) started")
            print("● Directory: \(session.directoryPath)")
            print("● Capturing: mic + \(captureSource == .virtualDevice ? "virtual device" : "system") audio")
            if !definition.stages.isEmpty {
                print("● On stop: will run \(definition.stages.count) pipeline stages")
            }
            print("● Press Ctrl+C or run `standup stop` to end")
            print()

            try session.id.write(toFile: config.activeSessionFile, atomically: true, encoding: .utf8)

            // Write PID so `standup stop` can signal this process
            let pidFile = config.activeSessionFile + ".pid"
            try "\(ProcessInfo.processInfo.processIdentifier)".write(toFile: pidFile, atomically: true, encoding: .utf8)

            // Store continuation so SIGINT handler can resume it (avoids continuation leak warning)
            let exitCode: Int32 = await withCheckedContinuation { continuation in
                let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
                signal(SIGINT, SIG_IGN)
                sigSource.setEventHandler {
                    sigSource.cancel()
                    Task {
                        var sessionId: String? = session.id
                        var code: Int32 = 0
                        do {
                            let stopped = try await sessionService.stopSession()
                            sessionId = stopped.id
                            print("\n■ Session \(stopped.id) stopped")

                            // Count chunks
                            let chunksDir = stopped.chunksPath
                            let chunkCount = (try? FileManager.default.contentsOfDirectory(atPath: chunksDir).filter { $0.hasSuffix(".pcm") }.count) ?? 0
                            print("■ Captured \(chunkCount) audio chunks")

                            if !definition.stages.isEmpty {
                                print("\n⚙ Running pipeline: \(pipeline)")
                                for (i, stage) in definition.stages.enumerated() {
                                    print("  [\(i+1)/\(definition.stages.count)] \(stage.id) (\(stage.pluginId))...")
                                }
                                print()

                                try await pipelineService.executeStages(definition: definition, session: stopped)
                                try sessionService.markComplete(sessionId: stopped.id)

                                // Surface warnings from pipeline output
                                let pipelineWarnings = Self.collectPipelineWarnings(sessionPath: stopped.directoryPath, definition: definition)
                                if pipelineWarnings.isEmpty {
                                    print("✓ Pipeline complete!")
                                } else {
                                    print("⚠ Pipeline complete with warnings:")
                                    for warning in pipelineWarnings {
                                        print("  ⚠ \(warning)")
                                    }
                                }
                                print("✓ Results in: \(stopped.directoryPath)")

                                // Show output artifacts
                                let fm = FileManager.default
                                if let dirs = try? fm.contentsOfDirectory(atPath: stopped.directoryPath).sorted() {
                                    for dir in dirs {
                                        let dirPath = (stopped.directoryPath as NSString).appendingPathComponent(dir)
                                        var isDir: ObjCBool = false
                                        if fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue, dir != "chunks" {
                                            let files = (try? fm.contentsOfDirectory(atPath: dirPath)) ?? []
                                            for file in files.sorted() {
                                                print("  └─ \(dir)/\(file)")
                                            }
                                        }
                                    }
                                }
                            } else {
                                try sessionService.markComplete(sessionId: stopped.id)
                                print("✓ Session complete. Audio in: \(stopped.chunksPath)")
                            }
                        } catch {
                            print("\n✗ Error while stopping session or running pipeline: \(error.localizedDescription)")
                            if let id = sessionId {
                                try? sessionService.markFailed(sessionId: id)
                            }
                            code = 1
                        }

                        try? FileManager.default.removeItem(atPath: config.activeSessionFile)
                        try? FileManager.default.removeItem(atPath: config.activeSessionFile + ".pid")
                        continuation.resume(returning: code)
                    }
                }
                sigSource.resume()
            }

            if exitCode != 0 {
                throw ExitCode(exitCode)
            }
        } catch {
            if let captureError = error as? AudioCaptureError {
                switch captureError {
                case .virtualDeviceNotFound(let name):
                    print("\n✗ Virtual audio device '\(name)' not found.")
                    print("  Install: brew install blackhole-2ch")
                    let available = VirtualDeviceCaptureEngine.availableVirtualDevices()
                    if !available.isEmpty {
                        print("  Available devices: \(available.joined(separator: ", "))")
                    }
                    print("  Or use --capture screen-capture to use system audio instead")
                case .virtualDeviceConfigFailed(let name, _):
                    print("\n✗ Failed to configure virtual device '\(name)'")
                    print("  Try: --capture screen-capture")
                default:
                    print("\n✗ Audio error: \(captureError.localizedDescription)")
                }
            } else if error.localizedDescription.contains("permission") || error.localizedDescription.contains("denied") || error.localizedDescription.contains("Screen") {
                print("\n✗ Permission error: \(error.localizedDescription)")
                print("  Fix: System Settings → Privacy & Security")
                print("  → Enable Microphone for this terminal/app")
                print("  → Enable Screen Recording for this terminal/app")
            } else {
                print("\n✗ Failed to start: \(error.localizedDescription)")
            }
            Foundation.exit(1)
        }
    }

    /// Check pipeline outputs for degraded results (empty transcripts, fallback images, etc.)
    private static func collectPipelineWarnings(sessionPath: String, definition: PipelineDefinition) -> [String] {
        var warnings: [String] = []
        let fm = FileManager.default

        let whisperStageIds = definition.stages.filter { $0.pluginId == "whisper" }.map(\.id)
        for stageId in whisperStageIds {
            let segmentsPath = ((sessionPath as NSString).appendingPathComponent(stageId) as NSString)
                .appendingPathComponent("segments.json")
            guard let data = fm.contents(atPath: segmentsPath),
                  let segments = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                continue
            }

            if segments.isEmpty {
                warnings.append("Transcription produced 0 segments — audio may be silent or whisper unavailable")
                continue
            }

            let hasPlaceholder = segments.contains {
                (($0["text"] as? String) ?? "").contains("requires whisper-cpp")
            }
            if hasPlaceholder {
                warnings.append("Transcription used placeholder output — install whisper-cpp and a model for real transcripts")
            }
        }

        let imageStageIds = definition.stages.filter { $0.pluginId == "image-gen" }.map(\.id)
        for stageId in imageStageIds {
            let manifestPath = ((sessionPath as NSString).appendingPathComponent(stageId) as NSString)
                .appendingPathComponent("manifest.json")
            guard let data = fm.contents(atPath: manifestPath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let manifestWarnings = json["warnings"] as? [String] else {
                continue
            }
            warnings.append(contentsOf: manifestWarnings)
        }

        return warnings
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

        // Send SIGINT to the capture process so it stops gracefully
        let pidFile = config.activeSessionFile + ".pid"
        if let pidStr = try? String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidStr) {
            print("■ Sending stop signal to session \(sessionId) (pid \(pid))")
            kill(pid, SIGINT)
        } else {
            print("✗ Cannot stop session \(sessionId): capture PID file is missing")
            print("  The session may still be recording. Stop the process manually, then remove:")
            print("  \(config.activeSessionFile)")
            Foundation.exit(1)
        }
    }
}

// MARK: - Resume

struct ResumeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resume",
        abstract: "Resume a failed or interrupted pipeline",
        discussion: "Re-runs the pipeline for a session, skipping stages that already completed. Use --reset to start the pipeline from scratch."
    )

    @Argument(help: "Session ID to resume")
    var sessionId: String

    @Option(name: .long, help: "Pipeline name (defaults to session's pipeline)")
    var pipeline: String?

    @Flag(name: .long, help: "Reset pipeline state and re-run all stages from scratch")
    var reset: Bool = false

    func run() async throws {
        let (config, _, sessionService, pipelineService) = try buildServices()

        guard let session = try sessionService.getSession(id: sessionId) else {
            print("✗ Session not found: \(sessionId)")
            throw ExitCode.failure
        }

        let pipelineName = pipeline ?? session.pipelineName
        let pipelinePath = (config.pipelinesDirectory as NSString).appendingPathComponent("\(pipelineName).yaml")
        guard FileManager.default.fileExists(atPath: pipelinePath) else {
            print("✗ Pipeline not found: \(pipelinePath)")
            throw ExitCode.failure
        }

        let definition = try PipelineService.load(from: pipelinePath)
        guard !definition.stages.isEmpty else {
            print("✗ Pipeline '\(pipelineName)' has no stages to run")
            throw ExitCode.failure
        }

        if reset {
            PipelineService.resetPipeline(session: session, definition: definition)
            print("↺ Reset pipeline state for session \(sessionId)")
        } else if let state = PipelineState.load(from: session.directoryPath) {
            let done = state.stages.filter { $0.status == .done }.count
            let total = state.stages.count
            if done == total {
                print("✓ All \(total) stages already complete for session \(sessionId)")
                print("  Use --reset to re-run from scratch")
                return
            }
            print("↻ Resuming pipeline '\(pipelineName)' for session \(sessionId) (\(done)/\(total) stages done)")
        } else {
            print("⚙ Running pipeline '\(pipelineName)' for session \(sessionId)")
        }

        // Transition session to processing state for resume
        try? sessionService.markProcessing(sessionId: session.id)

        print()
        for (i, stage) in definition.stages.enumerated() {
            print("  [\(i+1)/\(definition.stages.count)] \(stage.id) (\(stage.pluginId))")
        }
        print()

        do {
            try await pipelineService.executeStages(
                definition: definition,
                session: session,
                onProgress: { stageId, status in
                    switch status {
                    case .done: print("  ✓ \(stageId)")
                    case .running: print("  ▸ \(stageId)...", terminator: "")
                    case .failed: print(" ✗")
                    case .pending: break
                    }
                }
            )

            try sessionService.markComplete(sessionId: session.id)
            print("\n✓ Pipeline complete!")
            print("✓ Results in: \(session.directoryPath)")
        } catch {
            try? sessionService.markFailed(sessionId: session.id)
            print("\n✗ Pipeline failed: \(error.localizedDescription)")
            print("  Run `standup resume \(sessionId)` to retry from the failed stage")
            throw ExitCode.failure
        }
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
        print("Capture:   \(session.captureSource.displayName)")
        print("Status:    \(session.status.rawValue)")
        print("Started:   \(session.startTime)")
        if let end = session.endTime {
            print("Duration:  \(String(format: "%.0f", end.timeIntervalSince(session.startTime)))s")
        }
        print("Directory: \(session.directoryPath)")

        let fm = FileManager.default

        // Show pipeline state if available
        if let state = PipelineState.load(from: session.directoryPath) {
            print("Pipeline stages:")
            for s in state.stages {
                let icon: String
                switch s.status {
                case .done: icon = "✓"
                case .failed: icon = "✗"
                case .running: icon = "▸"
                case .pending: icon = "○"
                }
                var line = "  \(icon) \(s.id) (\(s.status.rawValue))"
                if let err = s.error { line += " — \(err)" }
                print(line)
            }
        }

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

        for dir in [config.baseDirectory, config.pipelinesDirectory, config.sessionsDirectory] {
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

// MARK: - Doctor

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check health of all dependencies without installing anything"
    )

    func run() async throws {
        print("""
        ┌──────────────────────────────────┐
        │   Standup — Health Check          │
        └──────────────────────────────────┘
        """)

        var issues: [String] = []

        // System
        printStep("System")
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let versionStr = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        if os.majorVersion >= 14 {
            printOK("macOS \(versionStr)")
        } else {
            printFail("macOS \(versionStr) — requires 14+")
            issues.append("macOS 14+ required")
        }

        #if arch(arm64)
        printOK("Apple Silicon (arm64)")
        #else
        printWarn("Intel (x86_64) — some features may be slower")
        #endif

        // Directories
        printStep("Standup directories")
        let config = StandupConfig.load()
        let fm = FileManager.default
        for (label, path) in [("Base", config.baseDirectory), ("Pipelines", config.pipelinesDirectory), ("Sessions", config.sessionsDirectory)] {
            if fm.fileExists(atPath: path) {
                printOK("\(label): \(path)")
            } else {
                printFail("\(label): \(path) — missing")
                issues.append("\(label) directory missing — run `standup init`")
            }
        }

        let configPath = (config.baseDirectory as NSString).appendingPathComponent("config.yaml")
        if fm.fileExists(atPath: configPath) {
            printOK("Config: \(configPath)")
        } else {
            printFail("Config missing — run `standup init`")
            issues.append("Config file missing")
        }

        // whisper-cpp
        printStep("Transcription (whisper-cpp)")
        let whisperBin = findExecutable("whisper-cli") ?? findExecutable("whisper-cpp")
        if let path = whisperBin {
            printOK("whisper binary: \(path)")
        } else {
            printFail("whisper-cpp not found")
            issues.append("whisper-cpp not installed — run `standup init` or `brew install whisper-cpp`")
        }

        let modelsDir = (config.baseDirectory as NSString).appendingPathComponent("models")
        let brewModelsDir = "/opt/homebrew/share/whisper-cpp/models"
        let modelFiles = ((try? fm.contentsOfDirectory(atPath: modelsDir)) ?? [])
            + ((try? fm.contentsOfDirectory(atPath: brewModelsDir)) ?? [])
        let ggmlModels = modelFiles.filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }
        if ggmlModels.isEmpty {
            printFail("No whisper models found")
            issues.append("No whisper models — run `standup init`")
        } else {
            for m in Set(ggmlModels).sorted() { printOK("Model: \(m)") }
        }

        // Ollama
        printStep("LLM (Ollama)")
        if let ollamaPath = findExecutable("ollama") {
            printOK("Ollama: \(ollamaPath)")

            // Check if service is running
            let reachable = try? await checkOllamaReachable()
            if reachable == true {
                printOK("Ollama service is running")

                let (_, listOut) = try runProcess(ollamaPath, args: ["list"])
                if listOut.contains("gemma3:4b") {
                    printOK("Model: gemma3:4b")
                } else {
                    printFail("Model gemma3:4b not pulled")
                    issues.append("Run `ollama pull gemma3:4b`")
                }
            } else {
                printFail("Ollama service not running")
                issues.append("Start Ollama: `brew services start ollama`")
            }
        } else {
            printFail("Ollama not installed")
            issues.append("Ollama not installed — run `standup init`")
        }

        // mflux
        printStep("Image generation (mflux)")
        if let mfluxPath = findMflux() {
            printOK("mflux-generate: \(mfluxPath)")
        } else {
            printFail("mflux-generate not found")
            issues.append("mflux not installed — run `standup init`")
        }

        // Pipelines
        printStep("Pipelines")
        let yamlFiles = ((try? fm.contentsOfDirectory(atPath: config.pipelinesDirectory)) ?? [])
            .filter { $0.hasSuffix(".yaml") }
        if yamlFiles.isEmpty {
            printFail("No pipelines installed")
            issues.append("No pipelines — run `standup init`")
        } else {
            for f in yamlFiles.sorted() { printOK(f) }
        }

        // Plugins
        printStep("Plugin registry")
        let registry = buildRegistry()
        printOK("Live:  \(registry.allLivePluginIds.joined(separator: ", "))")
        printOK("Stage: \(registry.allStagePluginIds.joined(separator: ", "))")

        // Summary
        print("\n┌──────────────────────────────────┐")
        print("│   Summary                        │")
        print("└──────────────────────────────────┘")
        if issues.isEmpty {
            print("  ✓ All checks passed. Ready to go!")
        } else {
            print("  Issues found:")
            for issue in issues { print("    ✗ \(issue)") }
            print("\n  Run `standup init` to fix missing dependencies.")
        }
        print()
    }

    // MARK: - Helpers

    private func findExecutable(_ name: String) -> String? {
        let paths = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func findMflux() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/mflux-generate",
            "/usr/local/bin/mflux-generate",
            (home as NSString).appendingPathComponent(".local/bin/mflux-generate"),
            (home as NSString).appendingPathComponent(".standup/venv/bin/mflux-generate"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func runProcess(_ path: String, args: [String]) throws -> (Int32, String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func checkOllamaReachable() async throws -> Bool {
        let url = URL(string: "http://localhost:11434/api/tags")!
        let (_, response) = try await URLSession.shared.data(from: url)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func printStep(_ msg: String) { print("\n▸ \(msg)") }
    private func printOK(_ msg: String) { print("  ✓ \(msg)") }
    private func printFail(_ msg: String) { print("  ✗ \(msg)") }
    private func printWarn(_ msg: String) { print("  ⚠ \(msg)") }
}

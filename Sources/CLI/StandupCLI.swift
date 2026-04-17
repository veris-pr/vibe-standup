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
        subcommands: [InitCommand.self, StartCommand.self, StopCommand.self, ResumeCommand.self, SessionCommand.self, CleanupCommand.self, SetupCommand.self, DoctorCommand.self]
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
    EnvLoader.loadIfPresent()
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

    @Flag(name: .long, help: "Skip Python/mlx-whisper setup")
    var skipModel: Bool = false

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

        // 3. Python + mlx-whisper
        if !skipModel {
            printStep("Checking Python and mlx-whisper")
            try await setupMlxWhisper(dryRun: dryRun, checks: &checks)
        } else {
            printSkip("mlx-whisper setup (--skip-model)")
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
        checks.warnings.append("Intel architecture — mlx-whisper requires Apple Silicon")
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

    private func setupMlxWhisper(dryRun: Bool, checks: inout CheckResults) async throws {
        // Check for uv
        let uvPath = findExecutable("uv")
        guard let uv = uvPath else {
            printFail("uv not found — install from https://docs.astral.sh/uv/getting-started/installation/")
            checks.errors.append("uv not installed — required for mlx-whisper Python environment")
            return
        }
        printOK("uv found: \(uv)")

        // Check for .venv
        let projectRoot = FileManager.default.currentDirectoryPath
        let venvPython = (projectRoot as NSString).appendingPathComponent(".venv/bin/python3")
        if FileManager.default.fileExists(atPath: venvPython) {
            printOK("Python venv: \(venvPython)")
        } else {
            if dryRun {
                printDry("uv venv && uv add mlx-whisper")
            } else {
                printProgress("Creating Python venv and installing mlx-whisper...")
                let (venvExit, _) = try await runProcess(uv, args: ["venv"])
                guard venvExit == 0 else {
                    printFail("Failed to create venv")
                    checks.errors.append("uv venv failed")
                    return
                }
                let (addExit, addOut) = try await runProcess(uv, args: ["add", "mlx-whisper"])
                if addExit == 0 {
                    printOK("mlx-whisper installed in .venv/")
                } else {
                    printFail("mlx-whisper installation failed")
                    if !addOut.isEmpty { print("  \(addOut.prefix(200))") }
                    checks.errors.append("mlx-whisper install failed")
                    return
                }
            }
        }

        // Check script exists
        let scriptPath = (projectRoot as NSString).appendingPathComponent("scripts/mlx_whisper_infer.py")
        if FileManager.default.fileExists(atPath: scriptPath) {
            printOK("Inference script: \(scriptPath)")
        } else {
            printFail("scripts/mlx_whisper_infer.py not found")
            checks.warnings.append("mlx-whisper inference script missing")
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
            printOK("mflux found: \(found)")
            return
        }

        let venvDir = (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent(".standup/venv")
        let venvBin = (venvDir as NSString).appendingPathComponent("bin/mflux-generate-flux2")

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
        let binaries = ["mflux-generate-flux2", "mflux-generate"]
        let searchDirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            (home as NSString).appendingPathComponent(".local/bin"),
            (home as NSString).appendingPathComponent(".standup/venv/bin"),
        ]
        for binary in binaries {
            for dir in searchDirs {
                let path = (dir as NSString).appendingPathComponent(binary)
                if FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
        }
        return nil
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

        let transcribeStageIds = definition.stages.filter {
            $0.pluginId == "mlx-whisper"
        }.map(\.id)
        for stageId in transcribeStageIds {
            let segmentsPath = ((sessionPath as NSString).appendingPathComponent(stageId) as NSString)
                .appendingPathComponent("segments.json")
            guard let data = fm.contents(atPath: segmentsPath),
                  let segments = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                continue
            }

            if segments.isEmpty {
                warnings.append("Transcription produced 0 segments — audio may be silent or mlx-whisper unavailable")
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

// MARK: - Session

struct SessionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "List sessions or show session details",
        discussion: "Without arguments, lists all sessions. With a session ID, shows details. Use --open to open generated outputs."
    )

    @Argument(help: "Session ID to show details for (optional)")
    var sessionId: String?

    @Flag(name: .long, help: "Open the session output directory or generated comic")
    var open: Bool = false

    func run() async throws {
        let (_, _, sessionService, _) = try buildServices()

        if let sessionId {
            try showSession(sessionId: sessionId, sessionService: sessionService)
        } else {
            try listSessions(sessionService: sessionService)
        }
    }

    private func listSessions(sessionService: SessionService) throws {
        let sessions = try sessionService.listSessions()

        if sessions.isEmpty {
            print("No sessions found")
            return
        }

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd HH:mm"

        let header = "SESSION".padding(toLength: 10, withPad: " ", startingAt: 0)
            + "STATUS".padding(toLength: 12, withPad: " ", startingAt: 0)
            + "DURATION".padding(toLength: 10, withPad: " ", startingAt: 0)
            + "STARTED".padding(toLength: 18, withPad: " ", startingAt: 0)
            + "PIPELINE"
        print(header)
        print(String(repeating: "─", count: 72))
        for s in sessions {
            let duration = formatDuration(s)
            let diskSize = directorySize(s.directoryPath)
            let line = "\(s.id.padding(toLength: 10, withPad: " ", startingAt: 0))"
                + "\(s.status.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0))"
                + "\(duration.padding(toLength: 10, withPad: " ", startingAt: 0))"
                + "\(dateFmt.string(from: s.startTime).padding(toLength: 18, withPad: " ", startingAt: 0))"
                + "\(s.pipelineName) (\(formatBytes(diskSize)))"
            print(line)
        }
    }

    private func showSession(sessionId: String, sessionService: SessionService) throws {
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
            let secs = end.timeIntervalSince(session.startTime)
            print("Duration:  \(formatSeconds(secs))")
        }
        print("Disk:      \(formatBytes(directorySize(session.directoryPath)))")
        print("Directory: \(session.directoryPath)")

        let fm = FileManager.default

        // Show pipeline state if available
        if let state = PipelineState.load(from: session.directoryPath) {
            print("\nPipeline stages:")
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
            }.sorted()
            if !dirs.isEmpty {
                print("\nArtifacts:")
                for dir in dirs { print("  └─ \(dir)/") }
            }
        }

        if open {
            openSessionOutput(session: session)
        }
    }

    private func openSessionOutput(session: Session) {
        // Try to open comic HTML first, then fall back to directory
        let comicPath = (session.directoryPath as NSString).appendingPathComponent("comic-assemble/comic.html")
        let fm = FileManager.default

        if fm.fileExists(atPath: comicPath) {
            print("\n⬗ Opening comic: \(comicPath)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [comicPath]
            try? process.run()
        } else {
            print("\n⬗ Opening session directory: \(session.directoryPath)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [session.directoryPath]
            try? process.run()
        }
    }

    private func formatDuration(_ session: Session) -> String {
        guard let end = session.endTime else {
            return session.status == .active ? "recording…" : "—"
        }
        return formatSeconds(end.timeIntervalSince(session.startTime))
    }

    private func formatSeconds(_ secs: Double) -> String {
        let totalSeconds = Int(secs)
        if totalSeconds < 60 { return "\(totalSeconds)s" }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes < 60 { return "\(minutes)m \(seconds)s" }
        let hours = minutes / 60
        return "\(hours)h \(minutes % 60)m"
    }
}

// MARK: - Cleanup

struct CleanupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Remove old session data",
        discussion: "Delete session data based on age, status, and what to clean (inputs, outputs, or everything)."
    )

    @Option(name: .long, help: "Remove sessions older than: day, week, month")
    var olderThan: AgePeriod = .week

    @Option(name: .long, help: "Filter by status: active, processing, complete, failed, all")
    var status: StatusFilter = .all

    @Option(name: .long, help: "What to clean: inputs (audio chunks), outputs (pipeline results), all (entire session)")
    var target: CleanTarget = .all

    @Flag(name: .long, help: "Skip confirmation prompt")
    var force: Bool = false

    enum AgePeriod: String, ExpressibleByArgument, CaseIterable {
        case day, week, month
        var cutoffInterval: TimeInterval {
            switch self {
            case .day: return 86_400
            case .week: return 604_800
            case .month: return 2_592_000
            }
        }
    }

    enum StatusFilter: String, ExpressibleByArgument, CaseIterable {
        case active, processing, complete, failed, all
        func matches(_ status: SessionStatus) -> Bool {
            switch self {
            case .active: return status == .active
            case .processing: return status == .processing
            case .complete: return status == .complete
            case .failed: return status == .failed
            case .all: return true
            }
        }
    }

    enum CleanTarget: String, ExpressibleByArgument, CaseIterable {
        case inputs, outputs, all
    }

    func run() async throws {
        let (config, _, sessionService, _) = try buildServices()
        let sessions = try sessionService.listSessions()
        let cutoff = Date().addingTimeInterval(-olderThan.cutoffInterval)

        let matching = sessions.filter { session in
            session.startTime < cutoff && status.matches(session.status)
        }

        if matching.isEmpty {
            print("No sessions match the filter (older than \(olderThan.rawValue), status: \(status.rawValue))")
            return
        }

        let totalSize = matching.reduce(0) { $0 + directorySize($1.directoryPath) }
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd HH:mm"

        print("Sessions matching filter (older than 1 \(olderThan.rawValue), status: \(status.rawValue), target: \(target.rawValue)):")
        print()
        for s in matching {
            let size = directorySize(s.directoryPath)
            print("  \(s.id)  \(s.status.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))  \(dateFmt.string(from: s.startTime))  \(formatBytes(size))")
        }
        print()
        print("Total: \(matching.count) session(s), \(formatBytes(totalSize))")

        if !force {
            print()
            print("Proceed? [y/N] ", terminator: "")
            guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
                print("Aborted")
                return
            }
        }

        // Resolve stage IDs for output-only cleanup
        let pipelineDir = config.pipelinesDirectory

        var cleaned = 0
        for session in matching {
            switch target {
            case .all:
                try sessionService.deleteSession(id: session.id)
            case .inputs:
                try sessionService.cleanInputs(session: session)
            case .outputs:
                let stageIds = stageIdsForSession(session, pipelineDir: pipelineDir)
                try sessionService.cleanOutputs(session: session, stageIds: stageIds)
            }
            cleaned += 1
        }

        let verb: String
        switch target {
        case .all: verb = "Deleted"
        case .inputs: verb = "Cleaned inputs for"
        case .outputs: verb = "Cleaned outputs for"
        }
        print("✓ \(verb) \(cleaned) session(s)")
    }

    /// Resolve stage IDs from the pipeline YAML so we know which dirs are outputs.
    private func stageIdsForSession(_ session: Session, pipelineDir: String) -> [String] {
        let yamlPath = (pipelineDir as NSString).appendingPathComponent("\(session.pipelineName).yaml")
        guard let definition = try? PipelineService.load(from: yamlPath) else {
            // Fallback: list all subdirectories except "chunks"
            let fm = FileManager.default
            return (try? fm.contentsOfDirectory(atPath: session.directoryPath))?
                .filter { name in
                    guard name != "chunks" else { return false }
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: (session.directoryPath as NSString).appendingPathComponent(name), isDirectory: &isDir)
                    return isDir.boolValue
                } ?? []
        }
        return definition.stages.map(\.id)
    }
}

// MARK: - Shared helpers

private func directorySize(_ path: String) -> Int64 {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
    var total: Int64 = 0
    while let file = enumerator.nextObject() as? String {
        let fullPath = (path as NSString).appendingPathComponent(file)
        if let attrs = try? fm.attributesOfItem(atPath: fullPath),
           let size = attrs[.size] as? Int64 {
            total += size
        }
    }
    return total
}

private func formatBytes(_ bytes: Int64) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024) }
    if bytes < 1_073_741_824 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
    return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
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

        // mlx-whisper
        printStep("Transcription (mlx-whisper)")
        let projectRoot = FileManager.default.currentDirectoryPath
        let venvPython = (projectRoot as NSString).appendingPathComponent(".venv/bin/python3")
        let inferScript = (projectRoot as NSString).appendingPathComponent("scripts/mlx_whisper_infer.py")

        if fm.fileExists(atPath: venvPython) {
            printOK("Python venv: \(venvPython)")
        } else {
            printFail("Python venv not found — run `uv venv && uv add mlx-whisper`")
            issues.append("mlx-whisper venv missing — run `standup init`")
        }

        if fm.fileExists(atPath: inferScript) {
            printOK("Inference script: \(inferScript)")
        } else {
            printFail("scripts/mlx_whisper_infer.py not found")
            issues.append("mlx-whisper inference script missing")
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
                if listOut.contains("gemma4") {
                    printOK("Model: gemma4")
                } else {
                    printFail("Model gemma4 not pulled")
                    issues.append("Run `ollama pull gemma4`")
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
            printOK("mflux: \(mfluxPath)")
        } else {
            printFail("mflux-generate-flux2 not found")
            issues.append("mflux not installed — run `standup init`")
        }

        // AWS (optional — for Bedrock cloud plugins)
        printStep("AWS Bedrock (optional)")
        if let awsPath = AWSCLIRunner.findAWSCLI() {
            printOK("AWS CLI: \(awsPath)")
            let aws = AWSCLIRunner()
            if await aws.checkCredentials() {
                printOK("AWS credentials configured")
            } else {
                printWarn("AWS credentials not configured — cloud plugins will not work")
            }
        } else {
            printInfo("AWS CLI not installed — cloud plugins unavailable (local-only is fine)")
        }

        // .env file
        let envPath = (config.baseDirectory as NSString).appendingPathComponent(".env")
        if fm.fileExists(atPath: envPath) {
            printOK(".env: \(envPath)")
        } else {
            printInfo("No .env file — see .env.example for cloud plugin configuration")
        }

        // Google Cloud (optional)
        printStep("Google Cloud (optional)")
        if let gcloudPath = GoogleCloudRunner.findGCloud() {
            printOK("gcloud CLI: \(gcloudPath)")
            let gcloud = GoogleCloudRunner(project: "check")
            if await gcloud.checkAuth() {
                printOK("Google Cloud authenticated")
            } else {
                printWarn("Google Cloud not authenticated — run `gcloud auth login`")
            }
        } else {
            printInfo("gcloud CLI not installed — Google Cloud plugins unavailable (local-only is fine)")
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
        let binaries = ["mflux-generate-flux2", "mflux-generate"]
        let searchDirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            (home as NSString).appendingPathComponent(".local/bin"),
            (home as NSString).appendingPathComponent(".standup/venv/bin"),
        ]
        for binary in binaries {
            for dir in searchDirs {
                let path = (dir as NSString).appendingPathComponent(binary)
                if FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
        }
        return nil
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
    private func printInfo(_ msg: String) { print("  ℹ \(msg)") }
}

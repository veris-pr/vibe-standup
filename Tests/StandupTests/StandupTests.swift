import Foundation
import Testing
@testable import StandupCore
@testable import LivePlugins
@testable import StagePlugins

// MARK: - Ring Buffer Tests

@Test func ringBufferWriteAndRead() async throws {
    let buffer = RingBuffer(minimumCapacity: 1024)

    let samples: [Float] = [1.0, 2.0, 3.0, 4.0]
    samples.withUnsafeBufferPointer { ptr in
        buffer.write(from: ptr.baseAddress!, count: 4)
    }
    #expect(buffer.availableToRead == 4)

    var output = [Float](repeating: 0, count: 4)
    output.withUnsafeMutableBufferPointer { ptr in
        buffer.read(into: ptr.baseAddress!, count: 4)
    }
    #expect(output == [1.0, 2.0, 3.0, 4.0])
    #expect(buffer.availableToRead == 0)
}

@Test func ringBufferOverflow() async throws {
    let buffer = RingBuffer(minimumCapacity: 4)

    let samples: [Float] = [1, 2, 3, 4, 5, 6]
    let written = samples.withUnsafeBufferPointer { ptr in
        buffer.write(from: ptr.baseAddress!, count: 6)
    }
    #expect(written == 4)
}

// MARK: - Plugin Config Tests

@Test func pluginConfigParsing() async throws {
    let config = PluginConfig(values: [
        "threshold_db": "-40",
        "name": "test",
        "count": "5",
        "enabled": "true",
    ])

    #expect(config.double(for: "threshold_db") == -40.0)
    #expect(config.string(for: "name") == "test")
    #expect(config.int(for: "count") == 5)
    #expect(config.bool(for: "enabled") == true)
    #expect(config.string(for: "missing", default: "fallback") == "fallback")
}

// MARK: - Live Plugin Chain Tests

@Test func livePluginChainPassthrough() async throws {
    let chain = LivePluginChain(channel: .mic)

    var samples: [Float] = [0.5, -0.5, 0.3, -0.3]
    samples.withUnsafeMutableBufferPointer { ptr in
        chain.process(buffer: ptr.baseAddress!, frameCount: 4)
    }
    #expect(samples == [0.5, -0.5, 0.3, -0.3])
}

// MARK: - Base Class Tests

@Test func baseLivePluginLifecycle() async throws {
    let plugin = NoiseGatePlugin()
    #expect(plugin.id == "noise-gate")

    let config = PluginConfig(values: ["threshold_db": "-30", "hold_ms": "50"])
    try await plugin.setup(config: config)
    plugin.prepareBuffers(maxFrameCount: 1024)

    // Test with loud signal
    var loud: [Float] = Array(repeating: 0.5, count: 512)
    let result = loud.withUnsafeMutableBufferPointer { ptr in
        plugin.process(buffer: ptr.baseAddress!, frameCount: 512, channel: .mic)
    }
    #expect(result == .passthrough)

    // Test with silence
    var silent: [Float] = Array(repeating: 0.0001, count: 512)
    // Process many times to exhaust hold counter
    for _ in 0..<100 {
        _ = silent.withUnsafeMutableBufferPointer { ptr in
            plugin.process(buffer: ptr.baseAddress!, frameCount: 512, channel: .mic)
        }
    }

    await plugin.teardown()
}

// MARK: - Factory Tests

@Test func noiseReductionFactoryCreatesGate() async throws {
    let config = PluginConfig(values: ["strategy": "gate"])
    let plugin = try NoiseReductionFactory.create(strategy: .gate, config: config)
    #expect(plugin.id == "noise-gate")
}

@Test func noiseReductionFactoryCreatesSpectral() async throws {
    let config = PluginConfig()
    let plugin = try NoiseReductionFactory.create(strategy: .spectral, config: config)
    #expect(plugin.id == "spectral-noise")
}

@Test func normalizationFactoryCreatesLUFS() async throws {
    let plugin = try NormalizationFactory.create(strategy: .lufs, config: PluginConfig())
    #expect(plugin.id == "lufs-normalize")
}

@Test func normalizationFactoryCreatesPeak() async throws {
    let plugin = try NormalizationFactory.create(strategy: .peak, config: PluginConfig())
    #expect(plugin.id == "peak-normalize")
}

// MARK: - Registry Tests

@Test func registryResolvesFactoryPlugin() async throws {
    let registry = PluginRegistry()
    registry.register(liveFactory: NoiseReductionFactory.self)

    let gateConfig = PluginConfig(values: ["strategy": "gate"])
    let gate = try registry.resolveLivePlugin(id: "noise-reduction", config: gateConfig)
    #expect(gate.id == "noise-gate")

    let spectralConfig = PluginConfig(values: ["strategy": "spectral"])
    let spectral = try registry.resolveLivePlugin(id: "noise-reduction", config: spectralConfig)
    #expect(spectral.id == "spectral-noise")
}

@Test func registryThrowsOnUnknownStrategy() async throws {
    let registry = PluginRegistry()
    registry.register(liveFactory: NoiseReductionFactory.self)

    let badConfig = PluginConfig(values: ["strategy": "nonexistent"])
    #expect(throws: PluginRegistryError.self) {
        try registry.resolveLivePlugin(id: "noise-reduction", config: badConfig)
    }
}

@Test func registryThrowsOnUnknownPlugin() async throws {
    let registry = PluginRegistry()
    #expect(throws: PluginRegistryError.self) {
        try registry.resolveLivePlugin(id: "does-not-exist")
    }
}

// MARK: - Session Value Object Tests

@Test func sessionValueObject() async throws {
    let session = Session(
        id: "test-123",
        pipelineName: "standup-comics",
        directoryPath: "/tmp/test"
    )

    #expect(session.status == .active)
    #expect(session.chunksPath == "/tmp/test/chunks")
    #expect(session.stageOutputPath(for: "transcribe") == "/tmp/test/transcribe")

    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(Session.self, from: data)
    #expect(decoded.id == "test-123")
    #expect(decoded.pipelineName == "standup-comics")
}

// MARK: - Pipeline Definition Tests

@Test func pipelineDefinitionCaptureOnly() async throws {
    let def = PipelineDefinition.captureOnly(name: "test")
    #expect(def.name == "test")
    #expect(def.stages.isEmpty)
    #expect(def.liveChains.mic.isEmpty)
}

// MARK: - RNNoise Plugin Tests

@Test func rnnoisePluginProcesses() async throws {
    let plugin = RNNoiseLivePlugin()
    let config = PluginConfig(values: ["smoothing": "0.95", "profile_frames": "2"])
    try await plugin.setup(config: config)
    plugin.prepareBuffers(maxFrameCount: 1024)

    // Feed a few frames to complete noise profiling
    var noise: [Float] = Array(repeating: 0.001, count: 480)
    for _ in 0..<3 {
        _ = noise.withUnsafeMutableBufferPointer { ptr in
            plugin.process(buffer: ptr.baseAddress!, frameCount: 480, channel: .mic)
        }
    }

    // Now process a louder signal — should be mostly preserved
    var signal: [Float] = Array(repeating: 0.5, count: 480)
    let result = signal.withUnsafeMutableBufferPointer { ptr in
        plugin.process(buffer: ptr.baseAddress!, frameCount: 480, channel: .mic)
    }
    #expect(result == .modified)
    // Signal should still be loud (not silenced)
    let maxSample = signal.max() ?? 0
    #expect(maxSample > 0.1)

    await plugin.teardown()
}

@Test func noiseReductionFactoryCreatesRNNoise() async throws {
    let plugin = try NoiseReductionFactory.create(strategy: .rnnoise, config: PluginConfig())
    #expect(plugin.id == "rnnoise")
}

// MARK: - Whisper Plugin Tests

@Test func whisperPluginRegistered() async throws {
    let registry = PluginRegistry()
    StagePluginRegistration.registerAll(in: registry)
    let plugin = try registry.resolveStagePlugin(id: "whisper")
    #expect(plugin.id == "whisper")
}

// MARK: - Comic Formatter Tests

@Test func comicFormatterRegistered() async throws {
    let registry = PluginRegistry()
    StagePluginRegistration.registerAll(in: registry)
    let plugin = try registry.resolveStagePlugin(id: "comic-formatter")
    #expect(plugin.id == "comic-formatter")
}

// MARK: - Comic Renderer Tests

@Test func comicRendererRegistered() async throws {
    let registry = PluginRegistry()
    StagePluginRegistration.registerAll(in: registry)
    let plugin = try registry.resolveStagePlugin(id: "comic-renderer")
    #expect(plugin.id == "comic-renderer")
}

// MARK: - Full Registry Tests

@Test func fullRegistryHasAllPlugins() async throws {
    let registry = PluginRegistry()
    LivePluginRegistration.registerAll(in: registry)
    StagePluginRegistration.registerAll(in: registry)

    let liveIds = registry.allLivePluginIds
    #expect(liveIds.contains("noise-gate"))
    #expect(liveIds.contains("spectral-noise"))
    #expect(liveIds.contains("rnnoise"))
    #expect(liveIds.contains("lufs-normalize"))
    #expect(liveIds.contains("peak-normalize"))
    #expect(liveIds.contains("noise-reduction"))  // factory
    #expect(liveIds.contains("normalize"))         // factory

    let stageIds = registry.allStagePluginIds
    #expect(stageIds.contains("whisper"))
    #expect(stageIds.contains("channel-diarizer"))
    #expect(stageIds.contains("energy-diarizer"))
    #expect(stageIds.contains("transcript-merger"))
    #expect(stageIds.contains("comic-formatter"))
    #expect(stageIds.contains("comic-renderer"))
    #expect(stageIds.contains("diarizer"))         // factory
}

// MARK: - End-to-End Comic Formatter Test

@Test func comicFormatterProcessesTranscript() async throws {
    // Create a temp directory with a mock transcript
    let tmpDir = NSTemporaryDirectory() + "standup-test-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }

    // Write a mock clean transcript
    let transcript = [
        ["startTime": 0.0, "endTime": 2.0, "speaker": "Alice", "text": "Hey team, let's get started!"],
        ["startTime": 2.5, "endTime": 5.0, "speaker": "Bob", "text": "I fixed the auth bug yesterday, finally shipped it!"],
        ["startTime": 5.5, "endTime": 8.0, "speaker": "Carol", "text": "Nice! I'll review it today."],
        ["startTime": 8.5, "endTime": 12.0, "speaker": "Alice", "text": "I'm blocked on the API integration, need help from Dave."],
    ] as [[String: Any]]

    let transcriptData = try JSONSerialization.data(withJSONObject: transcript, options: .prettyPrinted)
    let transcriptPath = (tmpDir as NSString).appendingPathComponent("transcript.json")
    try transcriptData.write(to: URL(fileURLWithPath: transcriptPath))

    // Run comic formatter
    let plugin = ComicFormatterPlugin()
    try await plugin.setup(config: PluginConfig())

    let context = StageContext(
        sessionId: "test",
        sessionDirectory: tmpDir,
        inputArtifacts: ["clean-transcript": Artifact(stageId: "merger", type: .cleanTranscript, path: transcriptPath)],
        config: PluginConfig()
    )

    let artifacts = try await plugin.execute(context: context)
    #expect(artifacts.count == 1)
    #expect(artifacts[0].type == .comicPanels)

    // Verify panels were created
    let panelsData = try Data(contentsOf: URL(fileURLWithPath: artifacts[0].path))
    let panels = try JSONDecoder().decode([[String: AnyDecodable]].self, from: panelsData)
    #expect(panels.count > 0)
    #expect(panels.count <= 12)
}

// Helper for decoding heterogeneous JSON in tests
private struct AnyDecodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let string = try? container.decode(String.self) { value = string }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else { value = "unknown" }
    }
}

// MARK: - End-to-End Comic Renderer Test

@Test func comicRendererProducesHTML() async throws {
    let tmpDir = NSTemporaryDirectory() + "standup-test-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }

    // Write mock panel data
    let panels = [
        ComicPanel(index: 0, speaker: "Alice", text: "Let's go!", mood: "excited", startTime: 0, duration: 2, importance: 0.8, panelSize: "large"),
        ComicPanel(index: 1, speaker: "Bob", text: "Fixed the bug!", mood: "proud", startTime: 2, duration: 3, importance: 0.7, panelSize: "normal"),
    ]
    let panelsPath = (tmpDir as NSString).appendingPathComponent("panels.json")
    try JSONEncoder().encode(panels).write(to: URL(fileURLWithPath: panelsPath))

    let plugin = ComicRendererPlugin()
    try await plugin.setup(config: PluginConfig(values: ["title": "Test Comic"]))

    let context = StageContext(
        sessionId: "test",
        sessionDirectory: tmpDir,
        inputArtifacts: ["comic-formatter": Artifact(stageId: "formatter", type: .comicPanels, path: panelsPath)],
        config: PluginConfig(values: ["title": "Test Comic"])
    )

    let artifacts = try await plugin.execute(context: context)
    #expect(artifacts.count == 1)
    #expect(artifacts[0].type == .comicOutput)

    let html = try String(contentsOfFile: artifacts[0].path, encoding: .utf8)
    #expect(html.contains("<!DOCTYPE html>"))
    #expect(html.contains("Alice"))
    #expect(html.contains("Bob"))
    #expect(html.contains("Test Comic"))
    #expect(html.contains("Let&#39;s go!") || html.contains("Let's go!") || html.contains("Let&"))
}


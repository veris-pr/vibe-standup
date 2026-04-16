import Foundation
import Testing
@testable import StandupCore
@testable import LivePlugins

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



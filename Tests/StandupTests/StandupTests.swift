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

@Test func directPluginRegistrationsReturnFreshInstances() async throws {
    let registry = PluginRegistry()
    LivePluginRegistration.registerAll(in: registry)
    StagePluginRegistration.registerAll(in: registry)

    let liveA = try registry.resolveLivePlugin(id: "noise-gate")
    let liveB = try registry.resolveLivePlugin(id: "noise-gate")
    #expect(liveA !== liveB)

    let stageA = try registry.resolveStagePlugin(id: "whisper")
    let stageB = try registry.resolveStagePlugin(id: "whisper")
    #expect(stageA !== stageB)
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

// MARK: - Wiener Noise Plugin Tests

@Test func wienerNoisePluginProcesses() async throws {
    let plugin = WienerNoisePlugin()
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

@Test func noiseReductionFactoryCreatesWiener() async throws {
    let plugin = try NoiseReductionFactory.create(strategy: .wiener, config: PluginConfig())
    #expect(plugin.id == "wiener-noise")
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
    #expect(liveIds.contains("wiener-noise"))
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

    // Write mock comic script
    let script = ComicScript(
        title: "Test Comic",
        characters: [
            ComicCharacter(speakerId: "me", heroName: "Captain Sprint", costume: "blue spandex", color: "#4A90D9"),
            ComicCharacter(speakerId: "them", heroName: "The Deployer", costume: "red armor", color: "#D94A4A"),
        ],
        panels: [
            ComicScriptPanel(index: 0, speaker: "me", heroName: "Captain Sprint", dialogue: "Let's go!", sceneDescription: "Hero stands ready", imagePrompt: "comic panel, superhero", mood: .excited),
            ComicScriptPanel(index: 1, speaker: "them", heroName: "The Deployer", dialogue: "Fixed the bug!", sceneDescription: "Hero celebrates", imagePrompt: "comic panel, celebration", mood: .proud),
        ]
    )
    let scriptPath = (tmpDir as NSString).appendingPathComponent("script.json")
    try JSONEncoder().encode(script).write(to: URL(fileURLWithPath: scriptPath))

    let plugin = ComicRendererPlugin()
    try await plugin.setup(config: PluginConfig(values: ["title": "Test Comic"]))

    let context = StageContext(
        sessionId: "test",
        sessionDirectory: tmpDir,
        inputArtifacts: ["comic-script": Artifact(stageId: "script", type: .comicScript, path: scriptPath)],
        config: PluginConfig(values: ["title": "Test Comic"])
    )

    let artifacts = try await plugin.execute(context: context)
    #expect(artifacts.count == 1)
    #expect(artifacts[0].type == .comicOutput)

    let html = try String(contentsOfFile: artifacts[0].path, encoding: .utf8)
    #expect(html.contains("<!DOCTYPE html>"))
    #expect(html.contains("Captain Sprint"))
    #expect(html.contains("The Deployer"))
    #expect(html.contains("Test Comic"))
    #expect(html.contains("Cast"))
}

// MARK: - End-to-End Pipeline Integration Test

@Test func channelDiarizerUsesSystemChunkDuration() async throws {
    let sessionId = "diarizer-\(UUID().uuidString.prefix(6))"
    let sessionDir = NSTemporaryDirectory() + "standup-diarizer-\(sessionId)"
    let chunksDir = (sessionDir as NSString).appendingPathComponent("chunks")
    let fm = FileManager.default
    try fm.createDirectory(atPath: chunksDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: sessionDir) }

    let frameCount = 24_000
    let samples = [Float](repeating: 0.2, count: frameCount)
    let sysPath = (chunksDir as NSString).appendingPathComponent("000001_system.pcm")
    try samples.withUnsafeBufferPointer { ptr in
        try Data(buffer: ptr).write(to: URL(fileURLWithPath: sysPath))
    }

    let plugin = ChannelDiarizerPlugin()
    try await plugin.setup(config: PluginConfig())
    let outputs = try await plugin.execute(context: StageContext(
        sessionId: sessionId,
        sessionDirectory: sessionDir,
        stageId: "diarize",
        inputArtifacts: [
            "audio_chunks": Artifact(stageId: "capture", type: .audioChunks, path: chunksDir)
        ],
        config: PluginConfig()
    ))

    let outputPath = try #require(outputs.first?.path)
    let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
    let segments = try JSONDecoder().decode([TestSpeakerLabel].self, from: data)
    let segment = try #require(segments.first)
    #expect(segment.startTime == 0)
    #expect(abs(segment.endTime - 0.5) < 0.0001)
}

/// Full standup-comics pipeline: synthetic audio → whisper → diarize → merge → format → render
@Test func standupComicsEndToEnd() async throws {
    let sessionId = "e2e-\(UUID().uuidString.prefix(6))"
    let sessionDir = NSTemporaryDirectory() + "standup-e2e-\(sessionId)"
    let chunksDir = (sessionDir as NSString).appendingPathComponent("chunks")
    let fm = FileManager.default
    try fm.createDirectory(atPath: chunksDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: sessionDir) }

    // --- Generate synthetic PCM audio chunks ---
    // Simulate a 4-person standup with distinct speaking patterns per chunk.
    // Each chunk = 1 second of audio at 48kHz mono Float32.
    let sampleRate = 48000
    let chunkSamples = sampleRate  // 1 second
    let silenceThreshold: Float = 0.001

    struct Turn {
        let speaker: String  // "mic" or "system"
        let amplitude: Float
    }

    // 10 chunks simulating: Alice(mic) speaks, Bob(system) responds, etc.
    let turns: [Turn] = [
        Turn(speaker: "mic",    amplitude: 0.4),   // Alice: "Hey team, let's start"
        Turn(speaker: "system", amplitude: 0.3),   // Bob: "I fixed the auth bug"
        Turn(speaker: "system", amplitude: 0.35),  // Bob continues
        Turn(speaker: "mic",    amplitude: 0.45),  // Alice: "That's awesome!"
        Turn(speaker: "system", amplitude: 0.3),   // Carol: "I'll review it"
        Turn(speaker: "mic",    amplitude: 0.4),   // Alice: "I'm blocked on the API"
        Turn(speaker: "system", amplitude: 0.25),  // Dave: "I can help"
        Turn(speaker: "mic",    amplitude: 0.3),   // Alice: "Great, let's sync"
        Turn(speaker: "system", amplitude: 0.2),   // Bob: "I'll deploy later"
        Turn(speaker: "mic",    amplitude: 0.35),  // Alice: "Sounds good, wrap up!"
    ]

    for (i, turn) in turns.enumerated() {
        let index = String(format: "%06d", i + 1)

        // Active channel gets a tone, other channel gets near-silence
        let activeAmp = turn.amplitude
        let inactiveAmp: Float = silenceThreshold * 0.1

        // Generate sine wave for active channel (440Hz tone)
        func generateChunk(amplitude: Float) -> Data {
            var samples = [Float](repeating: 0, count: chunkSamples)
            let freq: Float = 440.0
            for j in 0..<chunkSamples {
                samples[j] = amplitude * sin(2.0 * .pi * freq * Float(j) / Float(sampleRate))
            }
            return samples.withUnsafeBufferPointer { Data(buffer: $0) }
        }

        let micData = generateChunk(amplitude: turn.speaker == "mic" ? activeAmp : inactiveAmp)
        let sysData = generateChunk(amplitude: turn.speaker == "system" ? activeAmp : inactiveAmp)

        try micData.write(to: URL(fileURLWithPath: (chunksDir as NSString).appendingPathComponent("\(index)_mic.pcm")))
        try sysData.write(to: URL(fileURLWithPath: (chunksDir as NSString).appendingPathComponent("\(index)_system.pcm")))
    }

    // --- Build pipeline from YAML ---
    let pipelineYAML = """
    name: standup-comics-test
    description: E2E test pipeline

    stages:
      - id: transcribe
        plugin: whisper
        input: audio_chunks

      - id: diarize
        plugin: channel-diarizer
        input: audio_chunks

      - id: clean-transcript
        plugin: transcript-merger
        inputs:
          - transcribe.output
          - diarize.output

      - id: comic-script
        plugin: comic-script
        input: clean-transcript.output
        config:
          max_panels: "8"

      - id: panel-render
        plugin: image-gen
        input: comic-script.output

      - id: comic-assemble
        plugin: comic-renderer
        inputs:
          - comic-script.output
          - panel-render.output
    """

    let definition = try PipelineService.parse(yaml: pipelineYAML)
    #expect(definition.stages.count == 6)

    // --- Setup registry and pipeline service ---
    let registry = PluginRegistry()
    LivePluginRegistration.registerAll(in: registry)
    StagePluginRegistration.registerAll(in: registry)
    let pipelineService = PipelineService(registry: registry)

    // --- Create Session object ---
    let session = Session(
        id: sessionId,
        pipelineName: "standup-comics-test",
        directoryPath: sessionDir
    )

    // --- Execute the full pipeline ---
    try await pipelineService.executeStages(definition: definition, session: session)

    // --- Verify Stage 1: Transcription ---
    // Output dir is now scoped by stage.id ("transcribe"), not plugin.id ("whisper")
    let transcribeDir = (sessionDir as NSString).appendingPathComponent("transcribe")
    let segmentsPath = (transcribeDir as NSString).appendingPathComponent("segments.json")
    #expect(fm.fileExists(atPath: segmentsPath), "Whisper segments.json should exist")
    let segmentsData = try Data(contentsOf: URL(fileURLWithPath: segmentsPath))
    let segments = try JSONDecoder().decode([TestSegment].self, from: segmentsData)
    // Real whisper may find 0 segments in synthetic sine audio; placeholder produces 1
    let hasTranscription = segments.count >= 1

    // --- Verify Stage 2: Diarization ---
    let diarizeDir = (sessionDir as NSString).appendingPathComponent("diarize")
    let speakersPath = (diarizeDir as NSString).appendingPathComponent("speakers.json")
    #expect(fm.fileExists(atPath: speakersPath), "Diarization speakers.json should exist")
    let speakersData = try Data(contentsOf: URL(fileURLWithPath: speakersPath))
    let speakers = try JSONDecoder().decode([TestSpeakerLabel].self, from: speakersData)
    #expect(speakers.count >= 1, "Should have speaker segments")

    // Verify diarization correctness: should have both "me" and "them" speakers
    let speakerTypes = Set(speakers.map { $0.speaker })
    #expect(speakerTypes.contains("me"), "Should detect 'me' (mic) speaker")
    #expect(speakerTypes.contains("them"), "Should detect 'them' (system) speaker")

    // --- Verify Stage 3: Transcript Merger ---
    let mergerDir = (sessionDir as NSString).appendingPathComponent("clean-transcript")
    let transcriptPath = (mergerDir as NSString).appendingPathComponent("transcript.json")
    #expect(fm.fileExists(atPath: transcriptPath), "Merged transcript.json should exist")
    let transcriptData = try Data(contentsOf: URL(fileURLWithPath: transcriptPath))
    let transcript = try JSONDecoder().decode([TestDialogueLine].self, from: transcriptData)
    // Downstream depends on transcription — if whisper found no speech, merger produces 0 lines
    if hasTranscription {
        #expect(transcript.count >= 1, "Should have merged dialogue lines")
        for line in transcript {
            #expect(!line.speaker.isEmpty, "Speaker should not be empty")
            #expect(!line.text.isEmpty, "Text should not be empty")
        }
    }

    // --- Verify Stage 4: Comic Script ---
    let scriptDir = (sessionDir as NSString).appendingPathComponent("comic-script")
    let scriptPath = (scriptDir as NSString).appendingPathComponent("script.json")
    #expect(fm.fileExists(atPath: scriptPath), "Comic script.json should exist")
    let scriptData = try Data(contentsOf: URL(fileURLWithPath: scriptPath))
    let script = try JSONDecoder().decode(TestComicScript.self, from: scriptData)
    if hasTranscription {
        #expect(script.characters.count >= 1, "Should have at least 1 character")
        #expect(script.panels.count >= 1, "Should have at least 1 panel")
        #expect(script.panels.count <= 8, "Should not exceed max_panels=8")
        for panel in script.panels {
            #expect(!panel.heroName.isEmpty)
            #expect(!panel.dialogue.isEmpty)
            #expect(!panel.imagePrompt.isEmpty)
        }
    }

    // --- Verify Stage 5: Panel Images ---
    let imagesDir = (sessionDir as NSString).appendingPathComponent("panel-render")
    let manifestPath = (imagesDir as NSString).appendingPathComponent("manifest.json")
    #expect(fm.fileExists(atPath: manifestPath), "Panel manifest.json should exist")

    // --- Verify Stage 6: Comic Assembly ---
    let assembleDir = (sessionDir as NSString).appendingPathComponent("comic-assemble")
    let comicPath = (assembleDir as NSString).appendingPathComponent("comic.html")
    #expect(fm.fileExists(atPath: comicPath), "Comic HTML should exist")
    let html = try String(contentsOfFile: comicPath, encoding: .utf8)

    // Structure checks
    #expect(html.contains("<!DOCTYPE html>"))
    #expect(html.contains("comic-grid"))
    #expect(html.contains("Generated by Standup"))
    if hasTranscription {
        #expect(html.contains("Cast"), "Should have character legend")
    }

    print("✓ End-to-end standup-comics pipeline completed successfully")
    print("  Transcription segments: \(segments.count)")
    print("  Speaker segments: \(speakers.count) (\(speakerTypes.sorted().joined(separator: ", ")))")
    print("  Dialogue lines: \(transcript.count)")
    print("  Comic script panels: \(script.panels.count)")
    print("  Characters: \(script.characters.map(\.heroName).joined(separator: ", "))")
    print("  HTML size: \(html.count) chars")
}

// Test-only Codable types (to avoid coupling to internal types)
private struct TestSegment: Codable {
    let startTime: Double
    let endTime: Double
    let text: String
}

private struct TestSpeakerLabel: Codable {
    let startTime: Double
    let endTime: Double
    let speaker: String
}

private struct TestDialogueLine: Codable {
    let startTime: Double
    let endTime: Double
    let speaker: String
    let text: String
}

private struct TestComicScript: Codable {
    let title: String
    let characters: [TestComicCharacter]
    let panels: [TestComicScriptPanel]
}

private struct TestComicCharacter: Codable {
    let speakerId: String
    let heroName: String
    let costume: String
    let color: String
}

private struct TestComicScriptPanel: Codable {
    let index: Int
    let speaker: String
    let heroName: String
    let dialogue: String
    let sceneDescription: String
    let imagePrompt: String
    let mood: String
}

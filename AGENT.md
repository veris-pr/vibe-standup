# AGENT.md — Standup Codebase Guide

## What This Is

macOS CLI app: captures mic + system audio, processes through plugin pipelines. Swift 6, DDD architecture, SPM build system.

## Build & Test

```bash
swift build          # Build all targets
swift test           # 23 tests, includes full E2E pipeline test
swift run standup    # Run CLI
```

## Architecture

```
Sources/
├── StandupCore/              # Core library (no plugins)
│   ├── Domain/               # Contracts, value objects — STABLE, rarely changes
│   │   ├── Audio/            # AudioChannel, AudioFormat, AudioChunk, RingBuffer
│   │   ├── Plugin/           # PluginContracts.swift ← THE key file
│   │   ├── Pipeline/         # PipelineDefinition, StageDefinition, Artifact, ArtifactType
│   │   └── Session/          # Session (aggregate root), SessionRepository port
│   ├── Application/          # Use-case orchestration
│   │   ├── SessionService    # Session lifecycle (start/stop/list)
│   │   └── PipelineService   # YAML parsing, live chain building, stage DAG execution
│   └── Infrastructure/       # Adapters for external systems
│       ├── Audio/            # AudioCaptureEngine (AVAudioEngine + ScreenCaptureKit)
│       ├── Config/           # StandupConfig (YAML loader)
│       ├── Persistence/      # SQLiteSessionRepository
│       └── Subprocess/       # SubprocessBridge (JSON-over-stdio for external plugins)
├── LivePlugins/              # Real-time audio plugins (Swift-only, <10ms budget)
│   ├── NoiseReduction/       # NoiseGate, SpectralNoise, RNNoise + Factory
│   ├── Normalization/        # LUFS, Peak + Factory
│   └── Registration.swift    # Registers all live plugins into PluginRegistry
├── StagePlugins/             # Post-session processing plugins
│   ├── Transcription/        # WhisperPlugin (whisper-cpp subprocess)
│   ├── Diarization/          # ChannelDiarizer, EnergyDiarizer + Factory
│   ├── TranscriptMerger/     # Aligns transcription + diarization
│   ├── Comic/                # ComicFormatter (NLP) + ComicRenderer (HTML/SVG)
│   └── Registration.swift    # Registers all stage plugins into PluginRegistry
├── CLI/                      # StandupCLI.swift — all commands
Tests/
└── StandupTests/             # 23 tests (unit + integration + E2E)
pipelines/                    # YAML pipeline definitions
├── standup-comics.yaml       # 5-stage: whisper → diarize → merge → format → render
└── meeting-todos.yaml        # Transcription + action extraction (partially stubbed)
```

## Key File: PluginContracts.swift

`Sources/StandupCore/Domain/Plugin/PluginContracts.swift` — ~350 lines, defines the entire plugin system:

- `Plugin` protocol — base: id, version, setup, teardown
- `LivePlugin` protocol — `process(buffer:frameCount:channel:)` → `LivePluginResult`
- `StagePlugin` protocol — `execute(context: StageContext)` → `[Artifact]`
- `BaseLivePlugin` class — subclass for live plugins
- `BaseStagePlugin` class — subclass for stage plugins
- `LivePluginFactory` / `StagePluginFactory` — factory pattern for multi-strategy plugins
- `PluginRegistry` — central lookup: direct registrations + factory resolution
- `LivePluginChain` — ordered chain of live plugins per audio channel
- `PluginConfig` — `[String: String]` with typed accessors

## Type System

### Enums
- `AudioChannel`: `.mic`, `.system`
- `LivePluginResult`: `.modified`, `.passthrough`, `.mute`
- `ArtifactType`: `.audioChunks`, `.transcriptionSegments`, `.diarizationLabels`, `.cleanTranscript`, `.comicPanels`, `.comicOutput`, `.custom`
- `SessionStatus`: `.active`, `.processing`, `.complete`, `.failed`

### Value Objects
- `AudioFormat` — sampleRate (48000), channels (1), bitsPerSample (32). Use `AudioFormat.standard`.
- `AudioChunk` — index, channel, format, frameCount, timestamp, path
- `Artifact` — stageId, type (ArtifactType), path (file on disk)
- `Session` — id, status, pipelineName, startTime, endTime, directoryPath
- `PluginConfig` — wraps `[String: String]`, has `.string(for:default:)`, `.int(for:default:)`, `.double(for:default:)`, `.bool(for:default:)`
- `StageContext` — sessionId, sessionDirectory, inputArtifacts (`[String: Artifact]`), config

### Pipeline Types
- `PipelineDefinition` — name, description, liveChains (LiveChainConfig), stages ([StageDefinition])
- `LiveChainConfig` — mic: [PluginRef], system: [PluginRef]
- `StageDefinition` — id, pluginId, inputs: [String], config: [String: String]
- `PluginRef` — pluginId, config: [String: String]

## Plugin Registry IDs

Live plugins: `noise-gate`, `spectral-noise`, `rnnoise`, `lufs-normalize`, `peak-normalize`
Live factories: `noise-reduction` (strategies: gate, spectral, rnnoise), `normalize` (strategies: lufs, peak)
Stage plugins: `whisper`, `channel-diarizer`, `energy-diarizer`, `transcript-merger`, `comic-formatter`, `comic-renderer`
Stage factories: `diarizer` (strategies: channel, energy)

## How to Add a New Live Plugin

1. Create `Sources/LivePlugins/MyCategory/MyPlugin.swift`
2. Subclass `BaseLivePlugin`
3. Override `process(buffer:frameCount:channel:)` — modify buffer in-place, return `.modified`
4. Register in `Sources/LivePlugins/Registration.swift`: `registry.register(live: MyPlugin())`
5. If multi-strategy, create a factory implementing `LivePluginFactory`

```swift
import StandupCore

public final class MyPlugin: BaseLivePlugin, @unchecked Sendable {
    public init() { super.init(id: "my-plugin") }
    override public func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: AudioChannel) -> LivePluginResult {
        // Modify buffer in-place. No allocations. No locks.
        return .modified
    }
}
```

## How to Add a New Stage Plugin

1. Create `Sources/StagePlugins/MyCategory/MyPlugin.swift`
2. Subclass `BaseStagePlugin`
3. Set `inputArtifacts` and `outputArtifacts`
4. Override `execute(context:)` — read from `context.inputArtifacts`, write files, return `[Artifact]`
5. Register in `Sources/StagePlugins/Registration.swift`

```swift
import StandupCore

public final class MyPlugin: BaseStagePlugin, @unchecked Sendable {
    override public var inputArtifacts: [ArtifactType] { [.cleanTranscript] }
    override public var outputArtifacts: [ArtifactType] { [.custom] }
    public init() { super.init(id: "my-plugin") }

    override public func execute(context: StageContext) async throws -> [Artifact] {
        let input = context.inputArtifacts.values.first(where: { $0.type == .cleanTranscript })!
        let data = try Data(contentsOf: URL(fileURLWithPath: input.path))
        let outputDir = try ensureOutputDirectory(context: context)
        let outputPath = (outputDir as NSString).appendingPathComponent("output.json")
        // Process data, write to outputPath
        return [Artifact(stageId: id, type: .custom, path: outputPath)]
    }
}
```

## How to Add a New Factory

```swift
public enum MyStrategy: String, PluginStrategy, CaseIterable {
    case fast, accurate
}

public struct MyFactory: LivePluginFactory {
    public static let pluginId = "my-factory"
    public static let defaultStrategy = MyStrategy.fast
    public static func create(strategy: MyStrategy, config: PluginConfig) throws -> LivePlugin {
        switch strategy {
        case .fast: return FastPlugin()
        case .accurate: return AccuratePlugin()
        }
    }
}
// Register: registry.register(liveFactory: MyFactory.self)
```

## Pipeline YAML → Execution

PipelineService.parse(yaml:) → PipelineDefinition
PipelineService.buildLiveChains(from:) → (mic: LivePluginChain, system: LivePluginChain)
PipelineService.executeStages(definition:session:) → runs DAG via topological sort

Stage wiring: `artifacts[stage.id] = output` after each stage. Next stage looks up `context.inputArtifacts[dependencyStageId]`. Special key `"audio_chunks"` → session chunks directory.

## Conventions

- Swift 6 strict concurrency: classes use `@unchecked Sendable`
- All plugins are `public final class ... : Base{Live,Stage}Plugin, @unchecked Sendable`
- Audio format: 48kHz, mono, Float32 everywhere
- PCM chunk naming: `{index}_{channel}.pcm` (e.g., `000001_mic.pcm`)
- Stage output dirs named by plugin ID (not stage ID from YAML)
- JSON output uses `JSONEncoder.prettyEncoding` (defined in ChannelDiarizerPlugin.swift, shared across StagePlugins target)
- Config values are always strings in YAML/PluginConfig; use typed accessors

## Dependencies

- `swift-argument-parser` 1.3+ (CLI)
- `SQLite.swift` 0.15.3+ (persistence)
- `Yams` 5.1+ (YAML parsing)
- External: `whisper-cpp` via Homebrew (optional; falls back to placeholder)

## File Paths at Runtime

```
~/.standup/
├── config.yaml
├── standup.db
├── active_session          # Transient: contains active session ID
├── models/ggml-base.en.bin
├── pipelines/*.yaml
├── plugins/                # External plugin search path
└── sessions/<id>/
    ├── chunks/             # Raw PCM
    ├── <plugin-id>/        # Stage outputs (one dir per plugin)
```

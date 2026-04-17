# AGENT.md — Standup Codebase Guide

## What This Is

macOS CLI app: captures mic + system audio, processes through plugin pipelines. Swift 6, DDD architecture, SPM build system. Primary demo pipeline: standup-comics (6 stages: whisper → diarize → merge → comic-script → image-gen → comic-renderer).

## Build & Test

```bash
swift build          # Build all targets (debug)
swift build -c release  # Release build
swift test           # 25 tests, includes full E2E pipeline test
swift run standup    # Run CLI
```

## CLI Commands

```bash
standup init                              # Full setup — installs all deps
standup init --dry-run                    # Preview without changes
standup doctor                            # Health check — read-only
standup start --pipeline standup-comics   # Start capture session
standup stop                              # Stop from another terminal
standup list                              # List all sessions
standup show <id>                         # Session details
standup setup                             # Lightweight dir/config only
```

## Architecture

```
Sources/
├── StandupCore/              # Core library (no plugins)
│   ├── Domain/               # Contracts, value objects — STABLE, rarely changes
│   │   ├── Audio/            # AudioChannel, AudioFormat, AudioChunk, RingBuffer
│   │   ├── Plugin/           # PluginContracts.swift ← THE key file
│   │   │                     # PluginRegistryImpl.swift ← registry + factories
│   │   ├── Pipeline/         # PipelineDefinition, StageDefinition, Artifact, ArtifactType
│   │   └── Session/          # Session (aggregate root), SessionRepository port
│   ├── Application/          # Use-case orchestration
│   │   ├── SessionService    # Session lifecycle (start/stop/list), capture failure propagation
│   │   └── PipelineService   # YAML parsing, live chain building, stage DAG execution
│   └── Infrastructure/       # Adapters for external systems
│       ├── Audio/            # AudioCaptureEngine (AVAudioEngine + ScreenCaptureKit)
│       ├── Config/           # StandupConfig (YAML loader)
│       ├── Persistence/      # SQLiteSessionRepository
│       └── Subprocess/       # SubprocessBridge (JSON-over-stdio for external plugins)
├── LivePlugins/              # Real-time audio plugins (Swift-only, <10ms budget)
│   ├── NoiseReduction/       # NoiseGate, SpectralNoise, WienerNoise + Factory
│   ├── Normalization/        # LUFS, Peak + Factory
│   └── Registration.swift    # Factory-based registration of all live plugins
├── StagePlugins/             # Post-session processing plugins
│   ├── Transcription/        # WhisperPlugin (whisper-cpp subprocess)
│   ├── Diarization/          # ChannelDiarizer, EnergyDiarizer + Factory
│   ├── TranscriptMerger/     # Aligns transcription + diarization
│   ├── Comic/                # ComicFormatter, ComicScript (Ollama), ImageGen (mflux), ComicRenderer (HTML)
│   └── Registration.swift    # Factory-based registration of all stage plugins
├── CLI/                      # StandupCLI.swift — all commands (init, doctor, start, stop, list, show, setup)
Tests/
└── StandupTests/             # 25 tests (unit + integration + E2E)
pipelines/                    # YAML pipeline definitions
├── standup-comics.yaml       # 6-stage: whisper → diarize → merge → comic-script → image-gen → comic-renderer
└── meeting-todos.yaml        # Planned pipeline — not installed until action-extractor + todo-pusher plugins ship
```

## Key File: PluginContracts.swift

`Sources/StandupCore/Domain/Plugin/PluginContracts.swift` — defines the entire plugin system:

- `Plugin` protocol — base: id, version, setup, teardown
- `LivePlugin` protocol — `process(buffer:frameCount:channel:)` → `LivePluginResult`
- `StagePlugin` protocol — `execute(context: StageContext)` → `[Artifact]`
- `BaseLivePlugin` class — subclass for live plugins
- `BaseStagePlugin` class — subclass for stage plugins, has `ensureOutputDirectory(context:)`
- `LivePluginFactory` / `StagePluginFactory` — factory pattern for multi-strategy plugins
- `LivePluginChain` — ordered chain of live plugins per audio channel
- `PluginConfig` — `[String: String]` with typed accessors

`Sources/StandupCore/Domain/Plugin/PluginRegistryImpl.swift` — central lookup:

- `register(live:factory:)` / `register(stage:factory:)` — closure-based factories (preferred)
- `register(liveFactory:)` / `register(stageFactory:)` — multi-strategy factory types
- `resolveLivePlugin(id:config:)` / `resolveStagePlugin(id:config:)` — returns fresh instances

## Type System

### Enums
- `AudioChannel`: `.mic`, `.system`
- `LivePluginResult`: `.modified`, `.passthrough`, `.mute`
- `ArtifactType`: `.audioChunks`, `.transcriptionSegments`, `.diarizationLabels`, `.cleanTranscript`, `.comicScript`, `.panelImages`, `.comicOutput`, `.custom`
- `SessionStatus`: `.active`, `.processing`, `.complete`, `.failed`

### Value Objects
- `AudioFormat` — sampleRate (48000), channels (1), bitsPerSample (32). Use `AudioFormat.standard`.
- `AudioChunk` — index, channel, format, frameCount, timestamp, path
- `Artifact` — stageId, type (ArtifactType), path (file on disk)
- `Session` — id, status, pipelineName, captureSource, startTime, endTime, directoryPath
- `PluginConfig` — wraps `[String: String]`, has `.string(for:default:)`, `.int(for:default:)`, `.double(for:default:)`, `.bool(for:default:)`
- `StageContext` — sessionId, stageId, sessionDirectory, inputArtifacts (`[String: Artifact]`), config

### Pipeline Types
- `PipelineDefinition` — name, description, liveChains (LiveChainConfig), stages ([StageDefinition])
- `LiveChainConfig` — mic: [PluginRef], system: [PluginRef]
- `StageDefinition` — id, pluginId, inputs: [String], config: [String: String]
- `PluginRef` — pluginId, config: [String: String]

## Plugin Registry IDs

Live plugins: `noise-gate`, `spectral-noise`, `wiener-noise`, `lufs-normalize`, `peak-normalize`
Live factories: `noise-reduction` (strategies: gate, spectral, wiener), `normalize` (strategies: lufs, peak)
Stage plugins: `whisper`, `channel-diarizer`, `energy-diarizer`, `transcript-merger`, `comic-formatter`, `comic-script`, `image-gen`, `comic-renderer`
Stage factories: `diarizer` (strategies: channel, energy)

## How to Add a New Live Plugin

1. Create `Sources/LivePlugins/MyCategory/MyPlugin.swift`
2. Subclass `BaseLivePlugin`
3. Override `process(buffer:frameCount:channel:)` — modify buffer in-place, return `.modified`
4. Register in `Sources/LivePlugins/Registration.swift` using factory closure

```swift
import StandupCore

public final class MyPlugin: BaseLivePlugin, @unchecked Sendable {
    public init() { super.init(id: "my-plugin") }
    override public func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: AudioChannel) -> LivePluginResult {
        // Modify buffer in-place. No allocations. No locks.
        return .modified
    }
}
// In Registration.swift:
registry.register(live: "my-plugin") { MyPlugin() }
```

## How to Add a New Stage Plugin

1. Create `Sources/StagePlugins/MyCategory/MyPlugin.swift`
2. Subclass `BaseStagePlugin`
3. Set `inputArtifacts` and `outputArtifacts`
4. Override `execute(context:)` — read from `context.inputArtifacts`, write files, return `[Artifact]`
5. Register in `Sources/StagePlugins/Registration.swift` using factory closure

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
        return [Artifact(stageId: context.stageId, type: .custom, path: outputPath)]
    }
}
// In Registration.swift:
registry.register(stage: "my-plugin") { MyPlugin() }
```

**Important:** Use `context.stageId` (not `self.id`) for the Artifact's `stageId` — the stage ID comes from the pipeline YAML, not the plugin.

## How to Add a New Factory

```swift
public enum MyStrategy: String, PluginStrategy, CaseIterable {
    case fast, accurate
}

public struct MyFactory: StagePluginFactory {
    public static let pluginId = "my-factory"
    public static let defaultStrategy = MyStrategy.fast
    public static func create(strategy: MyStrategy, config: PluginConfig) throws -> StagePlugin {
        switch strategy {
        case .fast: return FastPlugin()
        case .accurate: return AccuratePlugin()
        }
    }
}
// Register: registry.register(stageFactory: MyFactory.self)
```

## Pipeline YAML → Execution

```
PipelineService.load(from:) → PipelineDefinition
PipelineService.buildLiveChains(from:registry:) → (mic: LivePluginChain, system: LivePluginChain)
PipelineService.executeStages(definition:session:registry:) → runs DAG via topological sort
```

Stage wiring: `artifacts[stage.id] = output` after each stage. Next stage looks up `context.inputArtifacts[dependencyStageId]`. Special key `"audio_chunks"` → session chunks directory.

## Conventions

- Swift 6 strict concurrency (`swiftLanguageModes: [.v6]`): classes use `@unchecked Sendable`
- All plugins are `public final class ... : Base{Live,Stage}Plugin, @unchecked Sendable`
- Plugin registration uses factory closures — each `resolve` returns a fresh instance with isolated state
- Audio format: 48kHz, mono, Float32 everywhere
- PCM chunk naming: `{index}_{channel}.pcm` (e.g., `000001_mic.pcm`)
- Stage output dirs named by plugin ID (not stage ID from YAML)
- Stage plugins must use `context.stageId` (not `self.id`) for Artifact stageId
- JSON output uses `JSONEncoder.prettyEncoding` (shared across StagePlugins target)
- Config values are always strings in YAML/PluginConfig; use typed accessors
- `String.appendingPathComponent` requires `as NSString` cast at each step

## Dependencies

### Swift Packages
- `swift-argument-parser` 1.3+ (CLI)
- `SQLite.swift` 0.15.3+ (persistence)
- `Yams` 5.1+ (YAML parsing)

### External Tools (installed by `standup init`)
- `whisper-cpp` via Homebrew — transcription (falls back to placeholder segments)
- `ollama` via Homebrew + `gemma3:4b` model — LLM comic script generation (falls back to heuristic)
- `mflux` via Python venv at `~/.standup/venv/` — image generation (falls back to SVG placeholders)

## File Paths at Runtime

```
~/.standup/
├── config.yaml
├── standup.db
├── active_session          # Transient: contains active session ID
├── models/ggml-base.en.bin
├── pipelines/*.yaml
├── plugins/                # External plugin search path
├── venv/                   # Python venv for mflux
│   └── bin/mflux-generate
└── sessions/<id>/
    ├── chunks/             # Raw PCM
    ├── whisper/            # Transcription output
    ├── channel-diarizer/   # Speaker labels
    ├── transcript-merger/  # Clean transcript
    ├── comic-script/       # LLM-generated script
    ├── image-gen/          # Panel images + manifest
    └── comic-renderer/     # Final HTML comic
```

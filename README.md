# Standup

**Local-first meeting audio capture and processing for macOS.** Record mic + system audio, transcribe with mlx-whisper, identify speakers, and generate outputs — all through a plugin pipeline you define in YAML.

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS_14+-blue" />
  <img src="https://img.shields.io/badge/language-Swift_6-orange" />
  <img src="https://img.shields.io/badge/license-MIT-green" />
  <img src="https://img.shields.io/badge/architecture-DDD-purple" />
</p>

## Why Standup?

Most meeting tools are cloud-first black boxes. Standup is the opposite:

- **Local-first** — mlx-whisper, Ollama, and mflux run on your machine. Audio never leaves your computer.
- **Plugin-based** — Every processing step is a swappable plugin with a fixed contract.
- **Pipeline-driven** — Define your workflow in YAML. Stages form a DAG with automatic dependency resolution.
- **Dual-channel audio** — Mic and system audio captured separately, enabling true speaker diarization without ML.
- **Resumable** — If a stage fails, fix the issue and resume from where it left off. No re-processing.
- **Any language** — Stage plugins can be Swift, Python, Go, shell scripts, or HTTP API calls.

---

## 1. Core Concept

Standup's core is an **audio capture loop** with two extension points:

```
                    ┌─────────────────────────────────────┐
  🎤 Mic ──────────→│  Live Plugins (real-time, <10ms)    │──→ PCM chunks to disk
  🔊 System ───────→│  NoiseGate → Normalize → ...        │──→ PCM chunks to disk
                    └─────────────────────────────────────┘
                                     │
                                Session Stop
                                     │
                    ┌─────────────────────────────────────┐
                    │  Stage Plugins (offline pipelines)   │
                    │  Transcribe → Diarize → Clean → ... │──→ Final outputs
                    └─────────────────────────────────────┘
```

**Live Plugins** manipulate the audio stream in real-time — noise gates, normalizers, filters. They run on the audio thread with strict constraints (no allocations, no locks, <10ms).

**Stage Plugins** process the captured data after the session ends. They form pipelines defined in YAML, where each stage reads typed artifacts from previous stages and produces new ones. Stage plugins can be written in **any language** — Swift, Python, Go, shell scripts — because they communicate through JSON files on disk.

A **Session** is the container that scopes everything. Audio capture starts when a session starts, the pipeline triggers when the session stops, and all inputs/outputs live under `~/.standup/sessions/<id>/`.

---

## 2. High-Level Architecture

```
┌──────────────────────────────────────────────────────────┐
│  CLI Layer                    Sources/CLI/                │
│  Argument parsing, user I/O, session lifecycle control    │
├──────────────────────────────────────────────────────────┤
│  Application Layer            Sources/StandupCore/       │
│  SessionService          PipelineService                 │
│  (session lifecycle)     (pipeline parsing & execution)  │
├──────────────────────────────────────────────────────────┤
│  Domain Layer                 Sources/StandupCore/       │
│  Plugin contracts · Session entity · Pipeline types      │
│  Audio types · Ring buffer · Value objects                │
├──────────────────────────────────────────────────────────┤
│  Infrastructure Layer         Sources/StandupCore/       │
│  AVAudioEngine · ScreenCaptureKit · ChunkWriter          │
│  SQLite persistence · YAML parser · Ollama HTTP client   │
├──────────────────────────────────────────────────────────┤
│  Plugins                                                 │
│  Sources/LivePlugins/    (real-time audio processing)    │
│  Sources/StagePlugins/   (offline pipeline stages)       │
└──────────────────────────────────────────────────────────┘
```

Each layer only depends downward. Plugins implement domain contracts but live in separate SPM targets so they can be added/removed without touching core code.

### Module Breakdown

| Module | Location | Responsibility |
|---|---|---|
| **StandupCore** | `Sources/StandupCore/` | Domain contracts, application services, infrastructure adapters. The "engine" — knows nothing about plugins. |
| **LivePlugins** | `Sources/LivePlugins/` | Concrete real-time audio processors (noise gate, normalizer, etc.). Implements `LivePlugin` protocol. |
| **StagePlugins** | `Sources/StagePlugins/` | Concrete offline processors (transcription, diarization, LLM cleanup, comic generation). Implements `StagePlugin` protocol. |
| **CLI** | `Sources/CLI/` | User-facing commands (`start`, `stop`, `resume`, `list`, `cleanup`, etc.). Wires everything together. |

### How Modules Connect

```
CLI
 │
 ├── SessionService ──→ AudioCaptureEngine ──→ LivePluginChain ──→ [LivePlugin, LivePlugin, ...]
 │                           │
 │                           └── ChunkWriter ──→ ~/.standup/sessions/<id>/chunks/
 │
 └── PipelineService ──→ PluginRegistry ──→ [StagePlugin, StagePlugin, ...]
                              │
                              └── Each stage: setup() → execute(context) → teardown()
                                                              │
                                                    Reads input artifacts (JSON files)
                                                    Writes output artifacts (JSON files)
```

**PluginRegistry** is the central lookup. At startup, `Registration.swift` registers all built-in plugins:

```swift
// Sources/StagePlugins/Registration.swift
registry.register(stage: "mlx-whisper") { MlxWhisperPlugin() }
registry.register(stage: "transcript-cleaner") { TranscriptCleanerPlugin() }
registry.register(stage: "comic-script") { ComicScriptPlugin() }

// Sources/LivePlugins/Registration.swift
registry.register(live: "noise-gate") { NoiseGatePlugin() }
registry.register(liveFactory: NormalizationFactory.self)  // multi-strategy
```

Each `resolve` call creates a **fresh instance** — no shared state between sessions or pipeline runs.

---

## 3. Session Lifecycle

A session is the top-level container. Everything is scoped to a session.

### State Machine

```
   start          stop            pipeline done        error
    │               │                  │                 │
    ▼               ▼                  ▼                 ▼
 ┌────────┐   ┌────────────┐    ┌───────────┐    ┌──────────┐
 │ active │──→│ processing │───→│ complete  │    │  failed  │
 └────────┘   └────────────┘    └───────────┘    └──────────┘
                    │                                  ▲
                    └──────────────────────────────────┘
```

| Status | Meaning |
|---|---|
| `active` | Audio capture is running. Chunks being written to disk. |
| `processing` | Capture stopped. Pipeline is executing stages. |
| `complete` | All pipeline stages finished successfully. |
| `failed` | A stage failed. Use `resume` to retry from the failed stage. |

### What Happens When You Run a Session

```
1. standup start --pipeline standup-comics-mlx
   │
   ├── Create session directory: ~/.standup/sessions/<id>/
   ├── Load pipeline YAML → PipelineDefinition
   ├── Build live plugin chains from YAML `live:` section
   ├── Start audio capture:
   │   ├── AVAudioEngine → mic audio → [live chain] → ring buffer
   │   └── ScreenCaptureKit → system audio → [live chain] → ring buffer
   ├── ChunkWriter loop: drain ring buffers → PCM files every 1 second
   │   └── chunks/000001_mic.pcm, 000001_system.pcm, 000002_mic.pcm, ...
   └── Session status: active

2. standup stop (or Ctrl+C)
   │
   ├── Stop audio capture
   ├── Session status: processing
   ├── Execute pipeline stages in topological order:
   │   ├── transcribe: PCM → WAV → mlx-whisper → segments.json
   │   ├── diarize: PCM RMS analysis → speakers.json
   │   ├── clean-transcript: LLM cleanup → transcript.json
   │   ├── comic-script: Ollama → script.json
   │   ├── panel-render: mflux → panel images
   │   └── comic-assemble: HTML assembly → comic.html
   └── Session status: complete

3. standup resume <id> (if a stage failed)
   │
   ├── Load pipeline-state.json → find first non-done stage
   ├── Re-execute from that stage onward
   └── Session status: complete (or failed again)
```

### Session Directory Structure

```
~/.standup/sessions/<id>/
├── chunks/                        # Raw PCM audio (input)
│   ├── 000001_mic.pcm
│   ├── 000001_system.pcm
│   └── ...
├── pipeline-state.json            # Stage progress tracker (resumability)
├── transcribe/                    # Stage output directories
│   ├── merged.wav
│   └── segments.json
├── diarize/
│   └── segments.json
├── clean-transcript/
│   └── transcript.json
├── comic-script/
│   └── script.json
├── image-gen/
│   ├── manifest.json
│   └── panel_*.png
└── comic-assemble/
    └── comic.html                 # Final output
```

Each stage writes to its own directory (`<stage-id>/`). The `pipeline-state.json` tracks which stages completed, enabling resume.

---

## 4. Data Flow — How Stages Connect

Stages communicate through **typed artifacts** — JSON files on disk.

### The Artifact Contract

Every stage plugin declares what it needs and what it produces:

```swift
public protocol StagePlugin: Plugin {
    var inputArtifacts: [ArtifactType] { get }   // What I need
    var outputArtifacts: [ArtifactType] { get }  // What I produce
    func execute(context: StageContext) async throws -> [Artifact]
}
```

An `Artifact` is simply a typed reference to a file:

```swift
public struct Artifact {
    let stageId: String      // Which stage produced this
    let type: ArtifactType   // Semantic type (transcription, diarization, etc.)
    let path: String         // Absolute path to JSON file on disk
}
```

Available artifact types:

| ArtifactType | Description |
|---|---|
| `.audioChunks` | Raw PCM audio chunks (always available from capture) |
| `.transcriptionSegments` | Array of `{startTime, endTime, text}` segments |
| `.diarizationLabels` | Array of `{startTime, endTime, speaker}` segments |
| `.cleanTranscript` | Array of `{startTime, endTime, speaker, text}` dialogue lines |
| `.comicScript` | Comic script with characters and panels |
| `.panelImages` | Generated panel image manifest |
| `.comicOutput` | Final rendered comic (HTML) |
| `.custom` | For your own plugin types |

### How the Pipeline Wires Stages Together

The YAML `inputs` declaration creates the dependency graph:

```yaml
stages:
  - id: transcribe
    plugin: mlx-whisper
    input: audio_chunks            # ← No dependency on other stages

  - id: diarize
    plugin: channel-diarizer
    input: audio_chunks            # ← Also no dependency — runs in parallel with transcribe

  - id: clean-transcript
    plugin: transcript-cleaner
    inputs:                        # ← Depends on BOTH transcribe and diarize
      - transcribe.output
      - diarize.output

  - id: comic-script
    plugin: comic-script
    input: clean-transcript.output # ← Depends on clean-transcript
```

The `PipelineService` performs topological sort on the stages, then executes them in order. Stages with no unresolved dependencies could run in parallel (currently sequential for simplicity).

### Execution Flow Inside PipelineService

For each stage, the pipeline service:

```
1. Check pipeline-state.json — skip if already done (resume support)
2. Mark stage as "running" in state file
3. Resolve plugin from registry: registry.resolveStagePlugin(id: "mlx-whisper")
4. Build input map: collect Artifact references from completed upstream stages
5. Create StageContext with: sessionId, sessionDirectory, stageId, inputArtifacts, config
6. Call: plugin.setup(config) → plugin.execute(context) → plugin.teardown()
7. Collect output artifacts, store in state file
8. Mark stage as "done" — or "failed" if execute() threw
9. On failure: save error to state file, stop pipeline, throw
```

The state is persisted after **every stage transition**, so if the process crashes, `resume` picks up exactly where it left off.

---

## 5. Plugin System Deep Dive

### Live Plugins (Real-Time Audio)

Live plugins sit in the audio capture loop and process raw `Float*` buffers on the audio thread. They're **Swift-only** — the latency budget (~10ms) doesn't allow shelling out.

**Constraints:**
- No heap allocations in `process()`
- No locks, no syscalls, no async
- Must return within the latency budget
- Configure in `onSetup()`, which runs before audio starts

**Contract:**

```swift
public protocol LivePlugin: Plugin {
    func prepareBuffers(maxFrameCount: Int)
    func process(buffer: UnsafeMutablePointer<Float>,
                 frameCount: Int,
                 channel: AudioChannel) -> LivePluginResult
}
```

Returns `.modified` (buffer changed), `.passthrough` (no change), or `.mute` (silence the buffer).

**How the live chain works:**

```swift
// One chain per audio channel (mic, system)
public final class LivePluginChain {
    func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        for plugin in plugins {
            let result = plugin.process(buffer: buffer, frameCount: frameCount, channel: channel)
            if case .mute = result {
                buffer.update(repeating: 0, count: frameCount)
                return  // Short-circuit: remaining plugins don't see this buffer
            }
        }
    }
}
```

Plugins run in order. If any plugin returns `.mute`, the buffer is zeroed and remaining plugins are skipped. `.modified` and `.passthrough` continue to the next plugin.

**Base class lifecycle:**

```swift
open class BaseLivePlugin: LivePlugin {
    // Override these:
    open func validate(config: PluginConfig) throws {}   // Validate config values
    open func onSetup() async throws {}                  // Read config, initialize state
    open func process(buffer:frameCount:channel:) -> LivePluginResult  // Process audio
    open func onTeardown() async {}                      // Clean up

    // Called automatically:
    func setup(config:)   // validate → store config → onSetup
    func teardown()       // onTeardown
}
```

**Example — noise gate with config:**

```swift
public final class NoiseGatePlugin: BaseLivePlugin, @unchecked Sendable {
    private var thresholdLinear: Float = 0.001
    private var holdFrames: Int = 4800
    private var holdCounter: Int = 0

    public init() { super.init(id: "noise-gate") }

    override public func onSetup() async throws {
        let thresholdDB = config.double(for: "threshold_db", default: -60)
        thresholdLinear = Float(pow(10.0, thresholdDB / 20.0))
        let holdMs = config.double(for: "hold_ms", default: 100)
        holdFrames = Int(AudioFormat.standard.sampleRate * holdMs / 1000)
    }

    override public func process(buffer: UnsafeMutablePointer<Float>,
                                 frameCount: Int,
                                 channel: AudioChannel) -> LivePluginResult {
        var sumSquares: Float = 0
        for i in 0..<frameCount { let s = buffer[i]; sumSquares += s * s }
        let rms = (sumSquares / Float(frameCount)).squareRoot()

        if rms >= thresholdLinear { holdCounter = holdFrames; return .passthrough }
        if holdCounter > 0 { holdCounter -= frameCount; return .passthrough }
        return .mute
    }
}
```

**Built-in live plugins:**

| Plugin | What It Does | Key Config |
|---|---|---|
| `noise-gate` | Silence gate with hold time | `threshold_db`, `hold_ms` |
| `spectral-noise` | Spectral subtraction denoiser | `reduction_db` |
| `wiener-noise` | Wiener-filter noise reduction | `noise_floor_db` |
| `lufs-normalize` | LUFS-targeted loudness | `target_lufs` |
| `peak-normalize` | Peak normalization | `target_db` |

**Factories** (select strategy in YAML config):
- `noise-reduction` → strategies: `gate`, `spectral`, `wiener`
- `normalize` → strategies: `lufs`, `peak`

### Stage Plugins (Post-Session Pipelines)

Stage plugins run after capture ends. They're **not restricted to Swift** — the Swift plugin class is just an adapter. Processing can happen in any language:

| Pattern | Example | How It Works |
|---|---|---|
| **Shell out to Python** | `MlxWhisperPlugin` | Calls `.venv/bin/python3 scripts/mlx_whisper_infer.py` |
| **HTTP API call** | `TranscriptCleanerPlugin` | Calls Ollama's REST API at `localhost:11434` |
| **External binary** | `ImageGenPlugin` | Invokes mflux for image generation |
| **Pure Swift** | `ChannelDiarizerPlugin` | Reads PCM files, computes RMS directly |

**Base class lifecycle:**

```swift
open class BaseStagePlugin: StagePlugin {
    // Override these:
    open var inputArtifacts: [ArtifactType]               // Declare what you need
    open var outputArtifacts: [ArtifactType]              // Declare what you produce
    open func validate(config: PluginConfig) throws {}    // Validate config
    open func onSetup() async throws {}                   // Read config
    open func execute(context: StageContext) async throws -> [Artifact]  // Do the work
    open func onTeardown() async {}                       // Clean up

    // Provided by base class:
    func ensureOutputDirectory(context:) -> String        // Creates <session>/<stageId>/
}
```

**`StageContext` — what your plugin receives:**

```swift
public struct StageContext {
    let sessionId: String                    // e.g., "5d2df320"
    let sessionDirectory: String             // e.g., "~/.standup/sessions/5d2df320"
    let stageId: String                      // e.g., "clean-transcript" (from YAML)
    let inputArtifacts: [String: Artifact]   // Resolved upstream artifacts
    let config: PluginConfig                 // Key-value config from YAML
}
```

**`PluginConfig` — reading YAML config values:**

```swift
let model = config.string(for: "model", default: "gemma4")
let maxPanels = config.int(for: "max_panels", default: 8)
let threshold = config.double(for: "threshold_db", default: -60)
let verbose = config.bool(for: "verbose", default: false)
```

All config values are strings in the YAML, parsed by these typed accessors.

**Built-in stage plugins:**

| Plugin | Input → Output | What It Does |
|---|---|---|
| `mlx-whisper` | audio chunks → transcription segments | Runs mlx-whisper via Python subprocess |
| `channel-diarizer` | audio chunks → speaker labels | Per-channel RMS → me/them labels |
| `energy-diarizer` | audio chunks → speaker labels | Energy pattern analysis (fallback) |
| `transcript-merger` | segments + labels → clean transcript | Programmatic time-aligned merge |
| `transcript-cleaner` | segments + labels → clean transcript | LLM-powered cleanup (strips repetitions, fixes garbled text) |
| `comic-script` | clean transcript → comic script | LLM-generated comic panels via Ollama |
| `image-gen` | comic script → panel images | mflux FLUX generation (SVG fallback) |
| `comic-renderer` | script + images → HTML | Self-contained comic strip page |
| **Cloud (AWS Bedrock)** | | |
| `bedrock-transcribe` | audio chunks → transcription segments | Amazon Transcribe via AWS CLI (batch S3 job) |
| `bedrock-llm` | clean transcript → comic script | Claude Haiku via Bedrock |
| `bedrock-image-gen` | comic script → panel images | Stability AI SDXL via Bedrock |

---

## 6. Failure Handling and Resumability

### What Happens When a Stage Fails

```
Pipeline running:
  ✓ transcribe     (done — artifacts saved)
  ✓ diarize        (done — artifacts saved)
  ✗ clean-transcript (FAILED — Ollama not running)
  · comic-script   (not started)
  · panel-render   (not started)
  · comic-assemble (not started)
```

When a stage throws an error:
1. The error is saved to `pipeline-state.json` with the stage marked as `failed`
2. The pipeline stops immediately — no further stages run
3. The session is marked as `failed`
4. The CLI prints the error and tells you to use `resume`

### Resuming After Failure

```bash
# Fix the issue (e.g., start Ollama)
ollama serve

# Resume from the failed stage
standup resume <session-id>
```

Resume reads `pipeline-state.json`, sees which stages are `done`, and re-executes from the first non-done stage. Previously completed stages are skipped — their artifacts are reused.

### Re-Running from Scratch

```bash
# Delete all stage outputs and re-run the entire pipeline
standup resume <session-id> --reset
```

`--reset` deletes `pipeline-state.json` and all stage output directories, then runs all stages from the beginning.

### Pipeline State File

`pipeline-state.json` in the session directory tracks every stage:

```json
{
  "pipelineName": "standup-comics-mlx",
  "stages": [
    { "id": "transcribe", "status": "done", "artifact": { "stageId": "transcribe", "type": "transcription_segments", "path": "..." } },
    { "id": "diarize", "status": "done", "artifact": { ... } },
    { "id": "clean-transcript", "status": "failed", "error": "Ollama is not running" },
    { "id": "comic-script", "status": "pending" },
    { "id": "panel-render", "status": "pending" },
    { "id": "comic-assemble", "status": "pending" }
  ]
}
```

Status values: `pending` → `running` → `done` or `failed`. Written after every transition.

---

## 7. Defining a Pipeline

A pipeline is a YAML file that declares which live plugins to run during capture and which stages to run after.

### Full Pipeline Example

```yaml
name: standup-comics-mlx
description: Generate superhero comics from standup meetings

# Live plugins — run during audio capture
live:
  mic:
    - plugin: noise-gate
      config:
        threshold_db: "-40"
        hold_ms: "100"
    - plugin: normalize
      config:
        target_lufs: "-16"
  system:
    - plugin: normalize
      config:
        target_lufs: "-16"

# Stage plugins — run after session stops
stages:
  - id: transcribe
    plugin: mlx-whisper
    input: audio_chunks
    config:
      model: mlx-community/whisper-large-v3-turbo
      language: hi

  - id: diarize
    plugin: channel-diarizer
    input: audio_chunks

  - id: clean-transcript
    plugin: transcript-cleaner
    inputs:
      - transcribe.output
      - diarize.output
    config:
      model: gemma4

  - id: comic-script
    plugin: comic-script
    input: clean-transcript.output
    config:
      model: gemma4
      max_panels: "8"

  - id: panel-render
    plugin: image-gen
    input: comic-script.output
    config:
      model: RunPod/FLUX.2-klein-4B-mflux-4bit
      steps: "4"
      width: "512"
      height: "512"

  - id: comic-assemble
    plugin: comic-renderer
    inputs:
      - comic-script.output
      - panel-render.output
```

### YAML Rules

| Field | Description |
|---|---|
| `id` | Unique identifier for this stage. Used in `pipeline-state.json` and as the output directory name. |
| `plugin` | The registered plugin name (must match what's in `Registration.swift`). |
| `input` | Single dependency. `audio_chunks` = raw capture. `<stage-id>.output` = upstream stage. |
| `inputs` | Multiple dependencies (array). Stage waits for all to complete. |
| `config` | Key-value pairs passed to the plugin. All values are strings. |

### Dependency Rules

- `input: audio_chunks` — no dependency on other stages, always available after capture
- `input: <stage-id>.output` — depends on one upstream stage
- `inputs: [a.output, b.output]` — depends on multiple stages (waits for all)
- Stages with resolved dependencies execute in topological order
- Cycles are detected and rejected at load time

### Deploying a Pipeline

```bash
# Option 1: standup init copies all pipelines from pipelines/ to ~/.standup/pipelines/
standup init

# Option 2: Copy manually
cp my-pipeline.yaml ~/.standup/pipelines/

# Run it
standup start --pipeline my-pipeline
```

---

## 8. Contributing a Plugin

### Step 1: Write the Plugin

**Option A — Pure Swift stage plugin:**

```swift
// Sources/StagePlugins/ActionExtractor/ActionExtractorPlugin.swift
import Foundation
import StandupCore

public final class ActionExtractorPlugin: BaseStagePlugin, @unchecked Sendable {
    override public var inputArtifacts: [ArtifactType] { [.cleanTranscript] }
    override public var outputArtifacts: [ArtifactType] { [.custom] }

    public init() { super.init(id: "action-extractor") }

    override public func execute(context: StageContext) async throws -> [Artifact] {
        // 1. Read upstream artifact
        let input = context.inputArtifacts.values.first { $0.type == .cleanTranscript }!
        let lines = try JSONDecoder().decode(
            [DialogueLine].self,
            from: Data(contentsOf: URL(fileURLWithPath: input.path))
        )

        // 2. Process
        let actions = lines.filter { $0.text.contains("TODO") || $0.text.contains("action") }

        // 3. Write output to stage directory
        let outputDir = try ensureOutputDirectory(context: context)
        let outputPath = (outputDir as NSString).appendingPathComponent("actions.json")
        try JSONEncoder.prettyEncoding.encode(actions).write(to: URL(fileURLWithPath: outputPath))

        // 4. Return typed artifact for downstream stages
        return [Artifact(stageId: context.stageId, type: .custom, path: outputPath)]
    }
}
```

**Option B — Swift adapter that calls a Python script:**

```swift
// Sources/StagePlugins/Sentiment/SentimentPlugin.swift
public final class SentimentPlugin: BaseStagePlugin, @unchecked Sendable {
    override public var inputArtifacts: [ArtifactType] { [.cleanTranscript] }
    override public var outputArtifacts: [ArtifactType] { [.custom] }

    public init() { super.init(id: "sentiment") }

    override public func execute(context: StageContext) async throws -> [Artifact] {
        let input = context.inputArtifacts.values.first { $0.type == .cleanTranscript }!
        let outputDir = try ensureOutputDirectory(context: context)
        let outputPath = (outputDir as NSString).appendingPathComponent("sentiment.json")

        // Shell out to Python — the real logic lives in the script
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ".venv/bin/python3")
        process.arguments = ["scripts/sentiment.py", "--input", input.path, "--output", outputPath]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SentimentError.scriptFailed(process.terminationStatus)
        }

        return [Artifact(stageId: context.stageId, type: .custom, path: outputPath)]
    }
}
```

```python
# scripts/sentiment.py
import json, argparse

parser = argparse.ArgumentParser()
parser.add_argument("--input", required=True)
parser.add_argument("--output", required=True)
args = parser.parse_args()

with open(args.input) as f:
    lines = json.load(f)

results = [{"speaker": l["speaker"], "sentiment": analyze(l["text"])} for l in lines]

with open(args.output, "w") as f:
    json.dump(results, f, indent=2)
```

**Option C — Live plugin (audio thread):**

```swift
// Sources/LivePlugins/HighPass/HighPassPlugin.swift
public final class HighPassPlugin: BaseLivePlugin, @unchecked Sendable {
    private var alpha: Float = 0.0
    private var prevSample: Float = 0.0

    public init() { super.init(id: "high-pass") }

    override public func onSetup() async throws {
        let cutoff = Float(config.double(for: "cutoff_hz", default: 300))
        let dt: Float = 1.0 / Float(AudioFormat.standard.sampleRate)
        let rc = 1.0 / (2.0 * .pi * cutoff)
        alpha = rc / (rc + dt)
    }

    override public func process(buffer: UnsafeMutablePointer<Float>,
                                 frameCount: Int,
                                 channel: AudioChannel) -> LivePluginResult {
        for i in 0..<frameCount {
            let x = buffer[i]
            buffer[i] = alpha * (prevSample + x - buffer[i])
            prevSample = buffer[i]
        }
        return .modified
    }
}
```

### Step 2: Register the Plugin

Add one line to the appropriate registration file:

```swift
// Sources/StagePlugins/Registration.swift
registry.register(stage: "action-extractor") { ActionExtractorPlugin() }
registry.register(stage: "sentiment") { SentimentPlugin() }

// Sources/LivePlugins/Registration.swift
registry.register(live: "high-pass") { HighPassPlugin() }
```

### Step 3: Use in a Pipeline YAML

```yaml
stages:
  - id: extract-actions
    plugin: action-extractor
    input: clean-transcript.output
```

### Step 4: Build and Test

```bash
swift build                    # Verify it compiles
swift test                     # Run 25 tests including E2E
standup resume <id> --reset    # Test with real session data
```

### Plugin Checklist

- [ ] Declares correct `inputArtifacts` and `outputArtifacts`
- [ ] Uses `context.stageId` (not `self.id`) for output directories and artifacts
- [ ] Uses `ensureOutputDirectory(context:)` to create the output directory
- [ ] Writes output as JSON to the stage directory
- [ ] Returns `Artifact` with the correct `ArtifactType` and path
- [ ] Handles errors gracefully (throw, don't crash — pipeline will catch and enable resume)
- [ ] Registered in `Registration.swift` with a factory closure (fresh instance per execution)
- [ ] Works with `resume` — if re-run, produces the same output (idempotent)

### Where to Put Files

```
Sources/
├── StagePlugins/
│   ├── YourPlugin/
│   │   └── YourPlugin.swift        # Plugin implementation
│   └── Registration.swift          # Add your registration here
├── LivePlugins/
│   ├── YourFilter/
│   │   └── YourFilterPlugin.swift
│   └── Registration.swift
scripts/
└── your_script.py                  # External scripts (if using Option B)
```

---

## 9. Use Case: Standup Comics Pipeline

The bundled pipeline captures an engineering standup and turns it into a superhero comic strip:

```
  🎤 Engineering standup call (5-10 minutes)
     │
     ▼
  ┌─ Capture ─────────────────────────┐
  │  Mic: noise-gate → normalize      │
  │  System: normalize                 │
  │  Output: ~7500 PCM chunks         │
  └────────────────────────────────────┘
     │
     ▼
  ┌─ Transcribe (mlx-whisper) ────────┐
  │  Merge PCM → WAV                   │
  │  Run whisper-large-v3-turbo        │
  │  Output: 41 segments (Hindi/English│)
  └────────────────────────────────────┘
     │                    ┌─ Diarize (channel-diarizer) ──┐
     │                    │  Compare mic vs system RMS     │
     │                    │  Output: me/them speaker labels│
     │                    └────────────────────────────────┘
     │                              │
     ▼                              ▼
  ┌─ Clean Transcript (transcript-cleaner) ───────────────┐
  │  Pass 1: Strip whisper hallucination loops             │
  │          (programmatic: 3+ repeated words → 1)         │
  │  Pass 2: LLM (gemma4) cleans garbled text              │
  │  Pass 3: Apply speaker labels, merge same-speaker turns│
  │  Output: 6 clean dialogue lines with speakers          │
  └────────────────────────────────────────────────────────┘
     │
     ▼
  ┌─ Comic Script (comic-script) ─────┐
  │  LLM (gemma3:4b) generates:       │
  │  - Superhero characters per speaker│
  │  - Panel layout with dialogue      │
  │  - Scene descriptions for art      │
  │  Output: ComicScript JSON          │
  └────────────────────────────────────┘
     │
     ▼
  ┌─ Panel Render (image-gen) ─────────┐
  │  mflux FLUX model generates panel  │
  │  images from scene descriptions    │
  │  Fallback: SVG placeholders        │
  │  Output: panel_1.png, panel_2.png  │
  └────────────────────────────────────┘
     │
     ▼
  ┌─ Comic Assemble (comic-renderer) ─┐
  │  HTML template with panels,        │
  │  dialogue bubbles, character names │
  │  Output: comic.html                │
  └────────────────────────────────────┘
     │
     ▼
  open ~/.standup/sessions/<id>/comic-assemble/comic.html 🎉
```

### Other Possible Pipelines

The same architecture supports entirely different use cases:

**Meeting action items:**
```yaml
stages:
  - id: transcribe
    plugin: mlx-whisper
    input: audio_chunks
  - id: diarize
    plugin: channel-diarizer
    input: audio_chunks
  - id: clean
    plugin: transcript-cleaner
    inputs: [transcribe.output, diarize.output]
  - id: actions
    plugin: action-extractor     # Your custom plugin
    input: clean.output
```

**Meeting summary with reminders:**
```yaml
stages:
  - id: transcribe
    plugin: mlx-whisper
    input: audio_chunks
  - id: diarize
    plugin: channel-diarizer
    input: audio_chunks
  - id: clean
    plugin: transcript-cleaner
    inputs: [transcribe.output, diarize.output]
  - id: categorize
    plugin: categorizer          # Classify highlights as todo/reminder/decision
    input: clean.output
  - id: notify
    plugin: notifier             # Trigger reminder tools, todo apps
    input: categorize.output
```

The pipeline handles the plumbing — you just write the logic.

---

## Quick Start

```bash
# Build
swift build

# Initialize — installs all dependencies automatically
swift run standup init

# Check everything is healthy
swift run standup doctor

# Start a session with the standup-comics pipeline
swift run standup start --pipeline standup-comics-mlx

# Join your meeting normally...
# When done, press Ctrl+C or from another terminal:
swift run standup stop

# View results
swift run standup show <session-id>
open ~/.standup/sessions/<id>/comic-assemble/comic.html
```

## Installation

### Prerequisites

| Requirement | Minimum | Notes |
|---|---|---|
| macOS | 14 (Sonoma) | ScreenCaptureKit for system audio |
| Swift | 5.9+ | Xcode 15+ or CLI tools |
| Homebrew | Any | For dependency installation |
| Python 3 | Any | For mlx-whisper and mflux venvs |
| ffmpeg | Any | Required by mlx-whisper for audio loading (`brew install ffmpeg`) |

### Setup

```bash
git clone https://github.com/veris-pr/vibe-standup.git
cd vibe-standup
swift build
swift run standup init
```

`standup init` handles everything automatically:

1. Sets up Python venv with `mlx-whisper` for Apple Silicon–native transcription
2. Installs `ollama` via Homebrew, starts the service, and pulls LLM models
3. Creates a Python venv at `~/.standup/venv/` and installs `mflux`
4. Creates `~/.standup/` directory structure, copies pipelines, writes config

All steps are idempotent — safe to re-run. Use `--dry-run` to preview.

```bash
standup init --dry-run           # Preview without changes
standup init --skip-model        # Skip mlx-whisper model download
```

### macOS Permissions

On first capture, macOS prompts for:
- **Microphone** — your voice
- **Screen Recording** — system audio (other participants via ScreenCaptureKit)

## CLI Commands

| Command | Description |
|---|---|
| `standup init` | Full setup — installs all dependencies, models, directories |
| `standup doctor` | Health check — verifies all dependencies without installing |
| `standup start --pipeline <name>` | Start capture session with a pipeline |
| `standup stop` | Stop the active session from another terminal |
| `standup resume <id> [--reset]` | Resume a failed pipeline, or re-run from scratch |
| `standup list` | List all sessions with status and duration |
| `standup show <id>` | Session details and artifacts |
| `standup cleanup --older-than <period>` | Clean session data (day/week/month), filter by status/io |
| `standup setup` | Lightweight directory/config setup only |

See [CLI.md](CLI.md) for the full command reference.

## Tech Stack

| Component | Technology | Why |
|---|---|---|
| Language | Swift 6 (strict concurrency) | Native macOS performance, type safety |
| Audio capture | AVAudioEngine + ScreenCaptureKit | macOS native, dual-channel |
| Transcription | mlx-whisper (MLX framework) | Local, open-source, fast on Apple Silicon |
| LLM | Ollama (gemma4) | Local inference, no API keys |
| Image gen | mflux (FLUX.2-klein-4B) | Apache 2.0, MLX-optimized, pre-quantized |
| Persistence | SQLite (via SQLite.swift) | Lightweight, zero-config |
| Config/Pipeline | YAML (via Yams) | Human-readable, git-friendly |
| CLI | swift-argument-parser | Apple's official CLI framework |

### Model Discipline — One Model Per Task

> **Rule: Keep exactly one downloaded model per capability. Prefer MLX-optimized, pre-quantized weights. Remove models you're not using.**

This project runs on consumer hardware (M2 16GB). Downloading multiple large models eats disk and RAM fast. Every model choice should be deliberate:

| Task | Model | Size | Source |
|---|---|---|---|
| Speech-to-text | `mlx-community/whisper-large-v3-turbo` | 1.5 GB | HuggingFace (MLX) |
| LLM (cleanup + scripts) | `gemma4` | 9.6 GB | Ollama |
| Image generation | `RunPod/FLUX.2-klein-4B-mflux-4bit` | 4.3 GB | HuggingFace (pre-quantized MLX) |
| **Total** | | **~15.4 GB** | |

**When switching models:**
1. Update the pipeline YAML config
2. Remove the old model (`ollama rm <old>`, or delete from `~/.cache/huggingface/hub/`)
3. Test the pipeline end-to-end
4. Update this table

**Why not multiple models?** We previously had `whisper-turbo` AND `whisper-large-v3-turbo`, `gemma3:4b` AND `gemma4`, etc. The duplicates consumed 12+ GB of extra disk for marginal benefit. One model per task, tested and validated.

## Configuration

`~/.standup/config.yaml`:

```yaml
performance:
  max_live_plugin_latency_ms: 10   # Budget per live plugin chain
  stage_max_parallel: 2            # Concurrent stage execution
  stage_max_rss_mb: 512            # Memory limit for subprocesses
  # mlx-whisper model (HuggingFace repo)
  whisper_model: mlx-community/whisper-large-v3-turbo
```

## Cloud Plugins (AWS Bedrock)

Every local plugin has a cloud-backed alternative using AWS Bedrock. Swap plugins in your YAML — the pipeline contract stays the same.

| Local Plugin | Cloud Plugin | AWS Service |
|---|---|---|
| `mlx-whisper` | `bedrock-transcribe` | Amazon Transcribe |
| `transcript-cleaner` / `comic-script` | `bedrock-llm` | Claude Haiku via Bedrock |
| `image-gen` | `bedrock-image-gen` | Stability AI SDXL via Bedrock |

### Setup

1. Install and configure AWS CLI:
   ```bash
   brew install awscli
   aws configure    # or set up a named profile
   ```

2. Create `~/.standup/.env` from the template:
   ```bash
   cp .env.example ~/.standup/.env
   # Edit with your AWS profile/region/bucket
   ```

3. Enable Bedrock model access in your AWS console (Bedrock → Model access)

4. Deploy the cloud pipeline:
   ```bash
   cp pipelines/standup-comics-bedrock.yaml ~/.standup/pipelines/
   standup start --pipeline standup-comics-bedrock
   ```

### Credential Security

- Credentials are loaded from `~/.standup/.env` (never committed — `.env` is in `.gitignore`)
- Existing environment variables take precedence over `.env` values
- AWS named profiles (`AWS_PROFILE`) are recommended over raw keys
- `standup doctor` checks AWS CLI and credential status

See `.env.example` for all supported variables.

## Testing

```bash
swift test    # 25 tests including full E2E pipeline
```

The E2E test generates synthetic dual-channel audio, runs the complete 6-stage standup-comics pipeline, and verifies every intermediate artifact through to the final HTML comic.

## License

MIT

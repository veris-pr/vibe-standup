# Standup

**Local-first meeting audio capture and processing for macOS.** Record mic + system audio, transcribe with Whisper, identify speakers, and generate outputs — all through a plugin pipeline you define in YAML.

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS_14+-blue" />
  <img src="https://img.shields.io/badge/language-Swift_6-orange" />
  <img src="https://img.shields.io/badge/license-MIT-green" />
  <img src="https://img.shields.io/badge/architecture-DDD-purple" />
</p>

## Why Standup?

Most meeting tools are cloud-first black boxes. Standup is the opposite:

- **Local-first** — Whisper.cpp, Ollama, and mflux run on your machine. Audio never leaves your computer.
- **Plugin-based** — Every processing step is a swappable plugin with a fixed contract.
- **Pipeline-driven** — Define your workflow in YAML. Stages form a DAG with automatic dependency resolution.
- **Dual-channel audio** — Mic and system audio captured separately, enabling true speaker diarization without ML.
- **Graceful degradation** — Missing a dependency? Each stage falls back to placeholders so the pipeline always completes.

## How It Works

```
┌──────────────────── Session ─────────────────────┐
│                                                   │
│  🎤 Mic ───→ [NoiseGate → Normalize] ──→ Chunks  │
│                                                   │
│  🔊 System ─→ [Normalize] ─────────────→ Chunks  │
│                                                   │
│  ─── Live Plugins (real-time, <10ms) ──────────  │
└───────────────────────────────────────────────────┘
                         │
                    Session Stop
                         │
                         ▼
┌────────────── Stage Pipeline (DAG) ──────────────┐
│                                                   │
│  audio_chunks ──→ Whisper (transcribe)            │
│               ──→ ChannelDiarizer (who spoke)     │
│                         │          │              │
│                         ▼          ▼              │
│              TranscriptMerger (align speakers)    │
│                         │                         │
│                         ▼                         │
│              ComicScript (LLM via Ollama)         │
│                         │                         │
│                         ▼                         │
│              ImageGen (mflux panel art)           │
│                         │                         │
│                         ▼                         │
│              ComicRenderer (HTML assembly)        │
│                                                   │
└───────────────────────────────────────────────────┘
                         │
                         ▼
              ~/.standup/sessions/<id>/
              └── comic-renderer/comic.html
```

## Quick Start

```bash
# Build
swift build

# Initialize — installs all dependencies automatically
swift run standup init

# Check everything is healthy
swift run standup doctor

# Start a session with the standup-comics pipeline
swift run standup start --pipeline standup-comics

# Join your meeting normally...
# When done, press Ctrl+C or from another terminal:
swift run standup stop

# View results
swift run standup show <session-id>
open ~/.standup/sessions/<id>/comic-renderer/comic.html
```

## Installation

### Prerequisites

| Requirement | Minimum | Notes |
|---|---|---|
| macOS | 14 (Sonoma) | ScreenCaptureKit for system audio |
| Swift | 5.9+ | Xcode 15+ or CLI tools |
| Homebrew | Any | For dependency installation |
| Python 3 | Any | For mflux venv (image generation) |

### Setup

```bash
git clone https://github.com/veris-pr/vibe-standup.git
cd vibe-standup
swift build
swift run standup init
```

`standup init` handles everything automatically:

1. Installs `whisper-cpp` via Homebrew and downloads the GGML model
2. Installs `ollama` via Homebrew, starts the service, and pulls `gemma3:4b`
3. Creates a Python venv at `~/.standup/venv/` and installs `mflux`
4. Creates `~/.standup/` directory structure, copies pipelines, writes config

All steps are idempotent — safe to re-run. Use `--dry-run` to preview.

```bash
standup init --dry-run           # Preview without changes
standup init --model small.en    # Larger whisper model (better accuracy, slower)
standup init --skip-brew         # Skip Homebrew installs
standup init --skip-model        # Skip whisper model download
```

### macOS Permissions

On first capture, macOS prompts for:
- **Microphone** — your voice
- **Screen Recording** — system audio (other participants via ScreenCaptureKit)

## Architecture

Standup uses **Domain-Driven Design** with clean layer separation:

```
┌──────────────────────────────────────────────────┐
│  CLI Layer              Sources/CLI/             │
│  Argument parsing, user I/O, process management  │
├──────────────────────────────────────────────────┤
│  Application Layer      Sources/StandupCore/     │
│  SessionService · PipelineService                │
├──────────────────────────────────────────────────┤
│  Domain Layer           Sources/StandupCore/     │
│  Contracts · Value Objects · Ring Buffer          │
├──────────────────────────────────────────────────┤
│  Infrastructure Layer   Sources/StandupCore/     │
│  AVAudioEngine · ScreenCaptureKit · SQLite       │
├──────────────────────────────────────────────────┤
│  Plugins                Sources/LivePlugins/     │
│                         Sources/StagePlugins/    │
│  Concrete implementations of domain contracts    │
└──────────────────────────────────────────────────┘
```

### Key Design Decisions

| Decision | Rationale |
|---|---|
| **DDD with ports/adapters** | Domain contracts are stable; infrastructure is swappable |
| **Two plugin types (Live/Stage)** | Real-time audio needs different constraints than batch processing |
| **Factory registration** | Each `resolve` returns a fresh plugin instance — no shared mutable state between sessions |
| **Factory pattern for strategies** | Plugins like noise-reduction have multiple algorithms (gate, spectral, wiener) |
| **YAML pipelines** | Non-developers can define workflows; pipelines are version-controllable |
| **Lock-free ring buffer** | Audio thread can't block — SPSC buffer with power-of-2 masking |
| **Subprocess bridge** | Stage plugins can be any language (Python, Go, etc.) via JSON-over-stdio |
| **Session isolation** | Each session gets its own directory tree; no cross-contamination |

### Data Flow (Per Session)

```
1. standup start --pipeline standup-comics
2. Session created → ~/.standup/sessions/<id>/
3. Audio capture starts:
   - AVAudioEngine → mic PCM → [live chain] → ring buffer → disk
   - ScreenCaptureKit → system PCM → [live chain] → ring buffer → disk
4. Chunks written: chunks/000001_mic.pcm, chunks/000001_system.pcm, ...
5. User stops session (Ctrl+C or standup stop)
6. Pipeline stages execute as DAG:
   a. transcribe: PCM → WAV → whisper-cpp → segments.json
   b. diarize: PCM RMS analysis → speakers.json (me/them from separate channels)
   c. clean-transcript: merge segments + speakers → transcript.json
   d. comic-script: transcript → Ollama (gemma3:4b) → script.json with panels
   e. panel-render: script → mflux image generation → panel PNGs (or SVG fallback)
   f. comic-assemble: script + images → comic.html
7. Session marked complete
```

## Plugin System

### Live Plugins (Real-Time Audio)

Run in the audio callback thread. Strict constraints: no heap allocs, no locks, <10ms budget.

| Plugin | What It Does |
|---|---|
| `noise-gate` | RMS-based silence gate with configurable threshold and hold time |
| `spectral-noise` | Spectral subtraction denoiser |
| `wiener-noise` | Wiener-filter noise reduction |
| `lufs-normalize` | LUFS-targeted loudness normalization |
| `peak-normalize` | Peak normalization |

**Factories** (select strategy in YAML config):
- `noise-reduction` → strategies: `gate`, `spectral`, `wiener`
- `normalize` → strategies: `lufs`, `peak`

### Stage Plugins (Post-Session)

Run after capture stops. Can be Swift or any executable via the subprocess bridge.

| Plugin | Input | Output | What It Does |
|---|---|---|---|
| `whisper` | audio chunks | transcription segments | Runs whisper.cpp as subprocess |
| `channel-diarizer` | audio chunks | speaker labels | Per-channel RMS → me/them labels |
| `energy-diarizer` | audio chunks | speaker labels | Energy pattern analysis (fallback) |
| `transcript-merger` | segments + labels | clean transcript | Time-aligned speaker dialogue |
| `comic-script` | clean transcript | comic script JSON | LLM-generated panels via Ollama |
| `image-gen` | comic script | panel images | mflux FLUX generation (SVG fallback) |
| `comic-renderer` | script + images | HTML file | Self-contained comic strip page |

**Factory:** `diarizer` → strategies: `channel`, `energy`

## Pipeline: standup-comics

The bundled pipeline captures your standup and turns it into a comic strip:

```yaml
name: standup-comics

live:
  mic:
    - plugin: noise-gate
      config: { threshold_db: "-40", hold_ms: "100" }
    - plugin: normalize
      config: { target_lufs: "-16" }
  system:
    - plugin: normalize
      config: { target_lufs: "-16" }

stages:
  - id: transcribe
    plugin: whisper
    input: audio_chunks

  - id: diarize
    plugin: channel-diarizer
    input: audio_chunks

  - id: clean-transcript
    plugin: transcript-merger
    inputs: [transcribe.output, diarize.output]

  - id: comic-script
    plugin: comic-script
    input: clean-transcript.output
    config: { model: "gemma3:4b", max_panels: "8" }

  - id: panel-render
    plugin: image-gen
    input: comic-script.output
    config: { model: "schnell", steps: "4", width: "512", height: "512" }

  - id: comic-assemble
    plugin: comic-renderer
    inputs: [comic-script.output, panel-render.output]
```

Stages form a DAG — `transcribe` and `diarize` run in parallel, then each subsequent stage runs when its inputs are ready.

## Creating Your Own Plugins

### Swift Live Plugin

```swift
public final class MyFilter: BaseLivePlugin, @unchecked Sendable {
    public init() { super.init(id: "my-filter") }

    override public func process(buffer: UnsafeMutablePointer<Float>,
                                 frameCount: Int,
                                 channel: AudioChannel) -> LivePluginResult {
        for i in 0..<frameCount { buffer[i] *= 0.5 }
        return .modified
    }
}
// Register: registry.register(live: "my-filter") { MyFilter() }
```

### Swift Stage Plugin

```swift
public final class MyProcessor: BaseStagePlugin, @unchecked Sendable {
    override public var inputArtifacts: [ArtifactType] { [.cleanTranscript] }
    override public var outputArtifacts: [ArtifactType] { [.custom] }
    public init() { super.init(id: "my-processor") }

    override public func execute(context: StageContext) async throws -> [Artifact] {
        let input = context.inputArtifacts.values.first { $0.type == .cleanTranscript }!
        let outputDir = try ensureOutputDirectory(context: context)
        let outputPath = (outputDir as NSString).appendingPathComponent("output.json")
        // Read input.path, process, write to outputPath
        return [Artifact(stageId: context.stageId, type: .custom, path: outputPath)]
    }
}
// Register: registry.register(stage: "my-processor") { MyProcessor() }
```

### External Plugin (Any Language)

Any executable that speaks JSON over stdio:

```python
#!/usr/bin/env python3
import json, sys
request = json.loads(sys.stdin.readline())
# request has: inputs, config, session_id, output_path
result = {"status": "ok", "artifacts": [{"type": "custom", "path": "..."}]}
print(json.dumps(result))
```

## Creating Custom Pipelines

Create a YAML file in `~/.standup/pipelines/` and reference built-in or custom plugins:

```yaml
name: my-meeting
description: Extract action items from meetings

stages:
  - id: transcribe
    plugin: whisper
    input: audio_chunks

  - id: diarize
    plugin: channel-diarizer
    input: audio_chunks

  - id: merge
    plugin: transcript-merger
    inputs: [transcribe.output, diarize.output]

  - id: actions
    plugin: my-custom-extractor
    input: merge.output
```

Run with: `standup start --pipeline my-meeting`

**Stage DAG rules:**
- Stages with no dependencies run in parallel (up to `stage_max_parallel`)
- `input: audio_chunks` — raw capture data (always available)
- `input: <stage-id>.output` — depends on another stage
- `inputs: [a.output, b.output]` — depends on multiple stages
- Cycles are detected and rejected at load time

## Tech Stack

| Component | Technology | Why |
|---|---|---|
| Language | Swift 6 (strict concurrency) | Native macOS performance, type safety |
| Audio capture | AVAudioEngine + ScreenCaptureKit | macOS native, dual-channel |
| Transcription | whisper.cpp | Local, open-source, fast on Apple Silicon |
| LLM | Ollama (gemma3:4b) | Local inference, no API keys |
| Image gen | mflux (FLUX on MLX) | Apple Silicon optimized diffusion |
| Persistence | SQLite (via SQLite.swift) | Lightweight, zero-config |
| Config/Pipeline | YAML (via Yams) | Human-readable, git-friendly |
| CLI | swift-argument-parser | Apple's official CLI framework |

## Configuration

`~/.standup/config.yaml`:

```yaml
performance:
  max_live_plugin_latency_ms: 10   # Budget per live plugin chain
  stage_max_parallel: 2            # Concurrent stage execution
  stage_max_rss_mb: 512            # Memory limit for subprocesses
  whisper_threads: 4               # CPU threads for whisper.cpp
  whisper_model: base.en           # tiny.en | base.en | small.en | medium.en | large
```

## CLI Commands

| Command | Description |
|---|---|
| `standup init` | Full setup — installs all dependencies, models, directories |
| `standup doctor` | Health check — verifies all dependencies without installing |
| `standup start --pipeline <name>` | Start capture session with a pipeline |
| `standup stop` | Stop the active session from another terminal |
| `standup list` | List all sessions |
| `standup show <id>` | Session details and artifacts |
| `standup setup` | Lightweight directory/config setup only |

See [CLI.md](CLI.md) for the full command reference.

## Session Directory Structure

```
~/.standup/sessions/<id>/
├── chunks/                    # Raw PCM audio
│   ├── 000001_mic.pcm
│   ├── 000001_system.pcm
│   └── ...
├── whisper/
│   └── segments.json          # Transcription segments
├── channel-diarizer/
│   └── segments.json          # Speaker labels (me/them)
├── transcript-merger/
│   └── transcript.json        # Merged speaker dialogue
├── comic-script/
│   └── script.json            # LLM-generated comic panels
├── image-gen/
│   ├── manifest.json          # Panel image paths
│   └── panel_*.png            # Generated panel art (or .svg fallback)
└── comic-renderer/
    └── comic.html             # Final output — open in browser
```

## Testing

```bash
swift test    # 25 tests including full E2E pipeline
```

The E2E test generates synthetic dual-channel audio, runs the complete 6-stage standup-comics pipeline, and verifies every intermediate artifact through to the final HTML comic.

## License

MIT

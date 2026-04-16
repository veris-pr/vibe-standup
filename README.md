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

- **Local-first** — Whisper.cpp runs on your machine. Audio never leaves your computer.
- **Plugin-based** — Every processing step is a swappable plugin with a fixed contract.
- **Pipeline-driven** — Define your workflow in YAML. Stages form a DAG with automatic dependency resolution.
- **Dual-channel audio** — Mic and system audio captured separately, enabling true speaker diarization without ML.
- **Performance-conscious** — Lock-free ring buffer, zero-allocation audio path, <10ms live plugin budget.

## How It Works

```
┌─────────────────── Session ────────────────────┐
│                                                 │
│  🎤 Mic ──→ [NoiseGate → Normalize] ──→ Ring   │
│                                         Buffer  │──→ PCM Chunks
│  🔊 System ──→ [Normalize] ──────────→ Ring    │     on Disk
│                                         Buffer  │
│                                                 │
│  ─── Live Plugins (real-time, <10ms) ────────  │
└─────────────────────────────────────────────────┘
                        │
                   Session Stop
                        │
                        ▼
┌─────────────── Stage Pipeline (DAG) ───────────┐
│                                                 │
│  audio_chunks ──→ Whisper (transcribe)          │
│              ──→ ChannelDiarizer (who spoke)     │
│                        │         │              │
│                        ▼         ▼              │
│              TranscriptMerger (align)           │
│                        │                        │
│                        ▼                        │
│              ComicFormatter (NLP panels)        │
│                        │                        │
│                        ▼                        │
│              ComicRenderer (HTML/SVG)           │
│                                                 │
└─────────────────────────────────────────────────┘
                        │
                        ▼
              ~/.standup/sessions/<id>/
              └── comic-renderer/comic.html
```

## Quick Start

```bash
# Build
swift build

# Initialize (installs whisper-cpp, downloads model, creates directories)
swift run standup init

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
| Swift | 5.9 | Xcode 15+ or CLI tools |
| Homebrew | Any | For whisper-cpp install |

### Setup

```bash
git clone https://github.com/veris-pr/vibe-standup.git
cd vibe-standup
swift build
swift run standup init
```

`standup init` handles everything: dependency installation, model download, directory creation, config writing. Use `--dry-run` to preview.

```bash
standup init --dry-run           # Preview without changes
standup init --model small.en    # Larger model (better accuracy, slower)
standup init --skip-brew         # Skip Homebrew installs
```

### macOS Permissions

On first capture, macOS prompts for:
- **Microphone** — your voice
- **Screen Recording** — system audio (other participants)

## Architecture

Standup uses **Domain-Driven Design** with clean layer separation:

```
┌──────────────────────────────────────────────────┐
│  CLI Layer              Sources/CLI/             │
│  Argument parsing, user I/O                      │
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
| **Factory pattern** | Plugins like noise-reduction have multiple algorithms (gate, spectral, rnnoise) |
| **YAML pipelines** | Non-developers can define workflows; pipelines are version-controllable |
| **Lock-free ring buffer** | Audio thread can't block — SPSC buffer with power-of-2 masking |
| **Subprocess bridge** | Stage plugins can be any language (Python, Go, etc.) via JSON-over-stdio |
| **Session isolation** | Each session gets its own directory tree; no cross-contamination |

### Data Flow (Per Session)

```
1. User runs: standup start --pipeline standup-comics
2. Session created → ~/.standup/sessions/<id>/
3. Audio capture starts:
   - AVAudioEngine → mic PCM → [live chain] → ring buffer → disk
   - ScreenCaptureKit → system PCM → [live chain] → ring buffer → disk
4. Chunks written: chunks/000001_mic.pcm, chunks/000001_system.pcm, ...
5. User stops session (Ctrl+C or standup stop)
6. Pipeline stages execute as DAG:
   - transcribe: PCM → WAV → whisper-cpp → segments.json
   - diarize: PCM RMS analysis → speakers.json (me/them)
   - clean-transcript: merge segments + speakers → transcript.json
   - comic-formatter: NLP scoring → panels.json
   - comic-renderer: panels → comic.html
7. Session marked complete
```

## Plugin System

### Live Plugins (Real-Time Audio)

Run in the audio callback thread. Strict constraints: no heap allocs, no locks, <10ms budget.

| Plugin | Strategy | What It Does |
|---|---|---|
| `noise-gate` | — | RMS-based silence gate |
| `spectral-noise` | — | Spectral subtraction denoiser |
| `rnnoise` | — | Wiener-filter noise reduction |
| `lufs-normalize` | — | LUFS-targeted loudness normalization |
| `peak-normalize` | — | Peak normalization |

**Factories** (select strategy in YAML):
- `noise-reduction` → strategies: `gate`, `spectral`, `rnnoise`
- `normalize` → strategies: `lufs`, `peak`

### Stage Plugins (Post-Session)

Run after capture stops. Can be Swift or any executable.

| Plugin | Input | Output | What It Does |
|---|---|---|---|
| `whisper` | audio chunks | transcription segments | whisper.cpp subprocess |
| `channel-diarizer` | audio chunks | speaker labels | RMS per channel |
| `energy-diarizer` | audio chunks | speaker labels | Energy patterns (fallback) |
| `transcript-merger` | segments + labels | clean transcript | Time-aligned dialogue |
| `comic-formatter` | clean transcript | comic panels | NLP: importance, mood, condensing |
| `comic-renderer` | comic panels | HTML file | Self-contained comic strip |

**Factory:** `diarizer` → strategies: `channel`, `energy`

## Pipeline Definitions

Pipelines are YAML files in `~/.standup/pipelines/`:

```yaml
name: standup-comics
description: Generate comics from standup meetings

live:
  mic:
    - plugin: noise-reduction
      config:
        strategy: gate
        threshold_db: "-40"
    - plugin: normalize
      config:
        target_lufs: "-16"
  system:
    - plugin: normalize

stages:
  - id: transcribe
    plugin: whisper
    input: audio_chunks
    config:
      model: base.en

  - id: diarize
    plugin: channel-diarizer
    input: audio_chunks

  - id: clean-transcript
    plugin: transcript-merger
    inputs:
      - transcribe.output
      - diarize.output

  - id: comic-formatter
    plugin: comic-formatter
    input: clean-transcript.output

  - id: comic-renderer
    plugin: comic-renderer
    input: comic-formatter.output
    config:
      title: "Daily Standup"
```

Stages form a DAG — independent stages run in parallel (up to `stage_max_parallel`).

## Creating Your Own Plugins

### Swift Live Plugin

```swift
final class MyFilter: BaseLivePlugin {
    init() { super.init(id: "my-filter") }

    override func process(buffer: UnsafeMutablePointer<Float>,
                          frameCount: Int,
                          channel: AudioChannel) -> LivePluginResult {
        for i in 0..<frameCount { buffer[i] *= 0.5 }  // Example: halve volume
        return .modified
    }
}
```

### Swift Stage Plugin

```swift
final class MyProcessor: BaseStagePlugin {
    override var inputArtifacts: [ArtifactType] { [.cleanTranscript] }
    init() { super.init(id: "my-processor") }

    override func execute(context: StageContext) async throws -> [Artifact] {
        let outputDir = try ensureOutputDirectory(context: context)
        // Read inputs from context.inputArtifacts, write outputs to outputDir
        return [Artifact(stageId: id, type: .custom, path: outputPath)]
    }
}
```

### External Plugin (Any Language)

Any executable that speaks JSON over stdio:

```python
#!/usr/bin/env python3
import json, sys
request = json.loads(sys.stdin.readline())
# request.inputs, request.config, request.session_id, request.output_path
result = {"status": "ok", "artifacts": [{"type": "custom", "path": "..."}]}
print(json.dumps(result))
```

## Tech Stack

| Component | Technology | Why |
|---|---|---|
| Language | Swift 6 (strict concurrency) | Native macOS performance, type safety |
| Audio capture | AVAudioEngine + ScreenCaptureKit | macOS native, dual-channel |
| Transcription | whisper.cpp (subprocess) | Local-first, open-source, fast on Apple Silicon |
| Persistence | SQLite (via SQLite.swift) | Lightweight, zero-config |
| Config/Pipeline | YAML (via Yams) | Human-readable, git-friendly |
| CLI | swift-argument-parser | Apple's official CLI framework |
| Ring buffer | Custom SPSC | Lock-free, power-of-2 masking |

## Configuration

`~/.standup/config.yaml`:

```yaml
performance:
  max_live_plugin_latency_ms: 10   # Budget per live chain
  stage_max_parallel: 2            # Concurrent stage execution
  stage_max_rss_mb: 512            # Memory limit for subprocesses
  whisper_threads: 4               # CPU threads for whisper
  whisper_model: base.en           # Model: tiny, base, small, medium, large
```

## CLI Commands

| Command | Description |
|---|---|
| `standup init` | First-time setup (dependencies, models, directories) |
| `standup start --pipeline <name>` | Start capture session |
| `standup stop` | Stop active session |
| `standup list` | List all sessions |
| `standup show <id>` | Session details and artifacts |
| `standup setup` | Lightweight directory/config setup |

See [CLI.md](CLI.md) for the full command reference.

## Session Directory Structure

```
~/.standup/sessions/<id>/
├── chunks/
│   ├── 000001_mic.pcm
│   ├── 000001_system.pcm
│   └── ...
├── whisper/
│   └── segments.json
├── channel-diarizer/
│   └── speakers.json
├── transcript-merger/
│   └── transcript.json
├── comic-formatter/
│   └── panels.json
└── comic-renderer/
    └── comic.html          ← Final output
```

## Testing

```bash
swift test    # 23 tests including full E2E pipeline
```

The E2E test generates synthetic dual-channel audio, runs the complete 5-stage standup-comics pipeline, and verifies every intermediate artifact through to the final HTML comic.

## License

MIT

# Standup

A macOS CLI application with a plugin-based architecture for capturing and processing meeting audio. Built with DDD (Domain-Driven Design), pluggable modules with fixed contracts, and factory pattern for multi-strategy plugins.

## Quick Start

```bash
# Build from source
swift build

# Initialize — installs dependencies, downloads models, configures directories
swift run standup init

# Start a capture session
swift run standup start --pipeline standup-comics

# Stop and process (Ctrl+C, or from another terminal)
swift run standup stop

# List past sessions
swift run standup list

# Inspect a session
swift run standup show <session-id>
```

## Installation

### Prerequisites

| Requirement | Version | Why |
|---|---|---|
| macOS | 14+ (Sonoma) | ScreenCaptureKit API for system audio |
| Swift | 5.9+ | Language runtime |
| Homebrew | Any | Dependency management |

### One-Command Setup

```bash
swift build && swift run standup init
```

This will:
1. Verify system requirements (macOS version, Swift, architecture)
2. Create `~/.standup/` directory structure
3. Install `whisper-cpp` via Homebrew (for transcription)
4. Download the whisper model (`base.en` by default, ~142 MB)
5. Install bundled pipeline definitions
6. Write default configuration
7. Check macOS permissions status

### Init Options

```bash
standup init --help
standup init --dry-run          # Preview without changes
standup init --model small.en   # Use a different whisper model
standup init --skip-brew        # Skip Homebrew installs
standup init --skip-model       # Skip model download
```

### macOS Permissions

On first capture session, macOS will prompt for:
- **Microphone** — captures your voice
- **Screen Recording** — captures system audio (other participants)

Grant these in: System Settings → Privacy & Security.

## CLI Reference

See [CLI.md](CLI.md) for the full command reference and usage guide.

## Architecture

Standup uses Domain-Driven Design with three layers:

```
┌─────────────────────────────────────────┐
│  CLI (Sources/CLI)                      │  Argument parsing, user interaction
├─────────────────────────────────────────┤
│  Application (Sources/StandupCore)      │  SessionService, PipelineService
├─────────────────────────────────────────┤
│  Domain (Sources/StandupCore)           │  Contracts, types, ring buffer
├─────────────────────────────────────────┤
│  Infrastructure (Sources/StandupCore)   │  Audio engine, SQLite, subprocess
├─────────────────────────────────────────┤
│  Plugins (Sources/LivePlugins,          │  Concrete implementations
│           Sources/StagePlugins)         │
└─────────────────────────────────────────┘
```

### Plugin System

Two categories of plugins with fixed contracts:

**Live Plugins** — Run in the real-time audio callback during capture.
- Form a filter chain per channel (mic and system audio)
- Must be Swift-only (no subprocess latency)
- Budget: <10ms per chain at 48kHz/1024 frames
- No heap allocations in the audio path

**Stage Plugins** — Run post-session as a DAG pipeline.
- Can be Swift or any executable (via subprocess bridge)
- Process stored artifacts: audio chunks → transcription → diarization → output

### Factory Pattern

Plugins with multiple strategies use the factory pattern:

```yaml
# Pipeline YAML selects strategy via config
- plugin: noise-reduction
  config:
    strategy: rnnoise    # or: gate, spectral
```

Built-in factories:
- `noise-reduction` → gate, spectral, rnnoise
- `normalize` → lufs, peak
- `diarizer` → channel, energy

### Built-in Plugins

| Plugin | Type | Description |
|---|---|---|
| `noise-gate` | Live | RMS-based noise gate |
| `spectral-noise` | Live | Spectral subtraction denoiser |
| `rnnoise` | Live | Wiener-filter noise reduction |
| `lufs-normalize` | Live | LUFS-targeted normalization |
| `peak-normalize` | Live | Peak normalization |
| `whisper` | Stage | whisper.cpp transcription |
| `channel-diarizer` | Stage | Channel-based speaker labeling |
| `energy-diarizer` | Stage | Energy-based speaker labeling |
| `transcript-merger` | Stage | Merges transcription + diarization |
| `comic-formatter` | Stage | NLP panel generation |
| `comic-renderer` | Stage | HTML/SVG comic output |

## Pipeline Definitions

Pipelines are YAML files defining live chains and stage DAGs.

```yaml
name: standup-comics
description: Generate comics from standup meetings

live:
  mic:
    - plugin: noise-gate
      config: { threshold_db: "-40" }
    - plugin: normalize
      config: { target_lufs: "-16" }
  system:
    - plugin: normalize

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
  - id: comic-formatter
    plugin: comic-formatter
    input: clean-transcript.output
  - id: comic-renderer
    plugin: comic-renderer
    input: comic-formatter.output
```

See `pipelines/` for more examples.

## Creating Plugins

### Swift Live Plugin

```swift
import StandupCore

final class MyFilter: BaseLivePlugin {
    init() { super.init(id: "my-filter") }

    override func onSetup() async throws {
        // Read config values
    }

    override func process(buffer: UnsafeMutablePointer<Float>,
                          frameCount: Int,
                          channel: AudioChannel) -> LivePluginResult {
        // Modify buffer in-place, return .modified or .passthrough
        return .modified
    }
}
```

### Swift Stage Plugin

```swift
import StandupCore

final class MyProcessor: BaseStagePlugin {
    override var inputArtifacts: [ArtifactType] { [.cleanTranscript] }
    override var outputArtifacts: [ArtifactType] { [.custom] }

    init() { super.init(id: "my-processor") }

    override func execute(context: StageContext) async throws -> [Artifact] {
        let outputDir = try ensureOutputDirectory(context: context)
        // Process inputs, write output files
        return [Artifact(stageId: id, type: .custom, path: outputPath)]
    }
}
```

### Subprocess Stage Plugin

Any executable reading JSON from stdin and writing JSON to stdout:

```python
#!/usr/bin/env python3
import json, sys

msg = json.loads(sys.stdin.readline())
# msg = {"command": "execute", "session_id": "...", "inputs": {...}, "config": {...}}

result = {"status": "ok", "artifacts": [{"type": "custom", "path": "/path/to/output"}]}
print(json.dumps(result))
```

## Audio Capture

- **Microphone**: AVAudioEngine (your voice)
- **System Audio**: ScreenCaptureKit (all system audio — cannot isolate apps)
- Both channels captured separately for diarization
- Lock-free SPSC ring buffer between audio thread and disk writer
- Format: 48kHz, mono, Float32

## Configuration

`~/.standup/config.yaml`:

```yaml
performance:
  max_live_plugin_latency_ms: 10
  stage_max_parallel: 2
  stage_max_rss_mb: 512
  whisper_threads: 4
  whisper_model: base.en
```

## License

MIT

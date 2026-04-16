# Standup CLI Reference

Complete command reference for the Standup audio processing CLI.

## Commands

### `standup init`

First-time setup. Run this once after building.

```bash
standup init                    # Full setup
standup init --dry-run          # Preview without making changes
standup init --model small.en   # Use a larger whisper model
standup init --skip-brew        # Skip Homebrew dependency install
standup init --skip-model       # Skip whisper model download
```

**What it does:**
1. Verifies macOS 14+, Swift, and architecture
2. Creates `~/.standup/` with subdirectories (sessions, pipelines, plugins, models)
3. Installs `whisper-cpp` via Homebrew
4. Downloads the whisper GGML model from Hugging Face
5. Copies bundled pipeline YAML files to `~/.standup/pipelines/`
6. Writes default `~/.standup/config.yaml`
7. Reports macOS permission requirements

**Whisper model sizes:**

| Model | Size | Speed | Accuracy |
|---|---|---|---|
| `tiny.en` | ~75 MB | Fastest | Lower |
| `base.en` | ~142 MB | Fast | Good (default) |
| `small.en` | ~466 MB | Medium | Better |
| `medium.en` | ~1.5 GB | Slow | High |
| `large` | ~2.9 GB | Slowest | Highest |

### `standup start`

Start an audio capture session.

```bash
standup start                              # Capture only (no pipeline)
standup start --pipeline standup-comics    # Capture + run pipeline on stop
standup start --pipeline meeting-todos     # Different pipeline
```

**Options:**
- `--pipeline <name>` — Pipeline YAML file name (without `.yaml`). Looked up from `~/.standup/pipelines/`. Default: `default` (capture only).

**Behavior:**
- Creates a new session with a unique ID
- Starts dual-channel audio capture (mic via AVAudioEngine, system via ScreenCaptureKit)
- Applies live plugin chains (noise reduction, normalization) in real-time
- Writes PCM audio chunks to `~/.standup/sessions/<id>/chunks/`
- Writes active session ID to `~/.standup/active_session`
- On Ctrl+C: stops capture, runs stage pipeline, cleans up

**During capture:**
- Audio chunks are written continuously to disk
- Live plugins process audio in the callback thread
- The session file locks prevent concurrent sessions

### `standup stop`

Stop the active capture session from another terminal.

```bash
standup stop
```

Reads the active session ID from `~/.standup/active_session` and signals the running session to stop. The `start` command will then run the stage pipeline (if configured) before exiting.

### `standup list`

List all recorded sessions.

```bash
standup list
```

**Output:**
```
SESSION    PIPELINE             STATUS       STARTED
────────────────────────────────────────────────────────────
abc123     standup-comics       complete     2024-03-15 10:30
def456     meeting-todos        complete     2024-03-15 14:00
```

**Status values:**
- `active` — Session is currently capturing
- `stopped` — Capture stopped, pipeline may be running
- `complete` — Pipeline finished, artifacts available
- `failed` — Pipeline encountered an error

### `standup show`

Show details for a specific session.

```bash
standup show <session-id>
```

**Output:**
```
Session:   abc123
Pipeline:  standup-comics
Status:    complete
Started:   2024-03-15 10:30:00 +0000
Duration:  900s
Directory: /Users/you/.standup/sessions/abc123
Artifacts:
  └─ chunks/
  └─ transcribe/
  └─ diarize/
  └─ clean-transcript/
  └─ comic-formatter/
  └─ comic-renderer/
```

### `standup setup`

Lightweight setup — creates directories and writes default config only. Use `standup init` for full initialization including dependency installation.

```bash
standup setup
```

## Session Workflow

A typical session lifecycle:

```
Terminal 1                          Terminal 2
──────────                          ──────────
$ standup start --pipeline comics
● Session abc123 started
● Pipeline: comics
● Capturing: mic + system audio     $ standup stop
● Press Ctrl+C or run standup stop   ■ Requesting stop for abc123

■ Session abc123 stopped
⚙ Running pipeline: comics
  → transcribe (whisper)
  → diarize (channel-diarizer)
  → clean-transcript (transcript-merger)
  → comic-formatter
  → comic-renderer
✓ Pipeline complete
```

## Directory Structure

```
~/.standup/
├── config.yaml          # Global configuration
├── standup.db           # SQLite session database
├── active_session       # File containing active session ID (transient)
├── models/
│   └── ggml-base.en.bin # Whisper GGML model
├── pipelines/
│   ├── standup-comics.yaml
│   └── meeting-todos.yaml
├── plugins/             # External plugin search path
└── sessions/
    └── <session-id>/
        ├── chunks/      # Raw PCM audio (mic + system channels)
        │   ├── 000001_mic.pcm
        │   ├── 000001_system.pcm
        │   └── ...
        ├── transcribe/  # Whisper output
        │   └── segments.json
        ├── diarize/     # Diarization output
        │   └── segments.json
        └── ...          # One directory per pipeline stage
```

## Configuration

`~/.standup/config.yaml`:

```yaml
# Override base directory (default: ~/.standup)
# base_directory: /custom/path

# Override pipelines directory
# pipelines_directory: /custom/pipelines

# External plugin search paths
# plugin_search_paths:
#   - /path/to/my/plugins

performance:
  # Max latency for live plugin chain (ms)
  max_live_plugin_latency_ms: 10

  # Max concurrent stage plugin executions
  stage_max_parallel: 2

  # Max RSS for stage subprocesses (MB)
  stage_max_rss_mb: 512

  # Threads for whisper.cpp
  whisper_threads: 4

  # Whisper model name
  whisper_model: base.en
```

## Pipeline YAML Format

```yaml
name: my-pipeline
description: What this pipeline does

# Live plugins — active during audio capture
live:
  mic:                          # Mic channel chain
    - plugin: noise-gate
      config:
        threshold_db: "-40"
        hold_ms: "100"
    - plugin: normalize
      config:
        strategy: lufs          # Factory strategy selection
        target_lufs: "-16"
  system:                       # System audio channel chain
    - plugin: normalize

# Stage plugins — run as DAG after capture stops
stages:
  - id: transcribe              # Unique stage ID
    plugin: whisper             # Plugin to run
    input: audio_chunks         # Special: raw audio chunks
    config:
      model: base.en
      language: en

  - id: diarize
    plugin: channel-diarizer
    input: audio_chunks

  - id: merge
    plugin: transcript-merger
    inputs:                     # Multiple inputs → DAG edges
      - transcribe.output
      - diarize.output

  - id: format
    plugin: my-custom-plugin    # Your plugin
    input: merge.output
```

**Stage DAG rules:**
- Stages with no dependencies run in parallel (up to `stage_max_parallel`)
- `input: audio_chunks` — depends on raw capture data (always available)
- `input: <stage-id>.output` — depends on another stage completing
- `inputs: [a.output, b.output]` — depends on multiple stages
- Cycles are detected and rejected at load time

## Creating Custom Pipelines

1. Create a YAML file in `~/.standup/pipelines/`:

```bash
vim ~/.standup/pipelines/my-meeting.yaml
```

2. Reference built-in plugins or create your own (see README.md for plugin authoring).

3. Run with:

```bash
standup start --pipeline my-meeting
```

## Troubleshooting

### "No audio captured"
- Grant Microphone permission: System Settings → Privacy & Security → Microphone
- Grant Screen Recording permission for system audio capture
- Check that your audio input device is active

### "Transcription requires whisper-cpp"
- Run `standup init` to install whisper-cpp and download the model
- Or manually: `brew install whisper-cpp`

### "Session not found"
- Run `standup list` to see available sessions
- Sessions are stored in `~/.standup/sessions/`

### High CPU during capture
- Reduce live plugin chain complexity
- Use `noise-gate` instead of `spectral-noise` or `rnnoise` (lighter)
- Check `max_live_plugin_latency_ms` in config

### Pipeline stage failed
- Check the stage output directory for error logs
- Run `standup show <session-id>` to see which stages completed
- Ensure external plugin executables are on your PATH

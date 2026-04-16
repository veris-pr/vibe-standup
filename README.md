# Standup

A macOS CLI application with a plugin-based architecture for capturing and processing meeting audio.

## Quick Start

```bash
# Build
swift build

# Initial setup
swift run standup setup

# Start a capture session
swift run standup start --pipeline standup-comics

# Stop and process
# Press Ctrl+C, or from another terminal:
swift run standup stop

# List sessions
swift run standup list

# Show session details
swift run standup show <session-id>
```

## Architecture

Standup has two categories of plugins:

### Live Plugins
Run in the real-time audio loop during capture. They form a filter chain per audio channel (mic and system audio).

- **noise-gate** — Silences audio below a dB threshold
- **normalize** — LUFS-targeted audio normalization

Constraints: Swift-only, no heap allocations, <10ms latency budget.

### Stage Plugins
Run post-session as a DAG pipeline. Can be Swift or any executable via the subprocess bridge (JSON over stdin/stdout).

- **channel-diarizer** — Labels segments as "me" (mic) or "them" (system audio)
- **transcript-merger** — Merges transcription + diarization into clean dialogue

## Audio Capture

- **Microphone**: AVAudioEngine (your voice)
- **System Audio**: ScreenCaptureKit (their voices)
- Both channels captured separately for diarization
- Lock-free ring buffer between audio thread and disk writer

## Pipeline Definitions

Pipelines are defined in YAML files in `~/.standup/pipelines/` (or the `pipelines/` directory in this repo).

See `pipelines/standup-comics.yaml` and `pipelines/meeting-todos.yaml` for examples.

## Creating Plugins

### Swift Live Plugin

```swift
import StandupCore

final class MyPlugin: LivePlugin {
    let id = "my-plugin"
    let version = "1.0.0"

    func setup(config: PluginConfig) async throws {}
    func teardown() async {}
    func prepareBuffers(maxFrameCount: Int) {}

    func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: AudioChannel) -> LivePluginResult {
        // Modify buffer in-place
        return .modified
    }
}
```

### Subprocess Stage Plugin

Any executable that reads JSON from stdin and writes JSON to stdout:

```python
#!/usr/bin/env python3
import json, sys

msg = json.loads(sys.stdin.readline())
# msg = {"command": "execute", "session_id": "...", "session_path": "...", "output_path": "...", "inputs": {...}, "config": {...}}

# Do your processing...

result = {"status": "ok", "artifacts": [{"type": "custom", "path": "/path/to/output"}]}
print(json.dumps(result))
```

## Requirements

- macOS 14+ (Sonoma)
- Swift 5.9+
- Microphone permission
- Screen Recording permission (for system audio capture)

## License

MIT

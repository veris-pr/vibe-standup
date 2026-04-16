/// Plugin protocols for the Standup audio pipeline.
///
/// Two categories:
/// - LivePlugin: runs in the real-time audio loop, processes frames in-place
/// - StagePlugin: runs post-session, processes stored artifacts

import Foundation

// MARK: - Base Protocol

/// Common interface for all plugins.
public protocol Plugin: AnyObject, Sendable {
    /// Unique identifier for this plugin (e.g., "noise-gate", "whisper").
    var id: String { get }

    /// Semantic version string.
    var version: String { get }

    /// Called once before the plugin is used. Load models, allocate buffers, etc.
    func setup(config: PluginConfig) async throws

    /// Called when the session/pipeline is done. Release resources.
    func teardown() async
}

// MARK: - Live Plugin

/// Result of processing a buffer in a live plugin.
public enum LivePluginResult: Sendable {
    /// The buffer was modified in-place.
    case modified
    /// The buffer was not touched — skip any copy.
    case passthrough
    /// Zero out the buffer (e.g., noise gate closed).
    case mute
}

/// A plugin that processes audio frames in real-time within the capture loop.
///
/// **Constraints:**
/// - Called on the audio thread — must return within ~10ms
/// - No heap allocations in `process`
/// - No locks, no syscalls, no async
/// - Pre-allocate everything in `prepareBuffers`
public protocol LivePlugin: Plugin {
    /// Pre-allocate any scratch buffers needed for processing.
    /// Called once before audio capture starts, NOT on the audio thread.
    func prepareBuffers(maxFrameCount: Int)

    /// Process audio frames in-place.
    /// Called on the real-time audio thread for every buffer.
    func process(
        buffer: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channel: AudioChannel
    ) -> LivePluginResult
}

// MARK: - Live Plugin Chain

/// Runs a sequence of live plugins on an audio buffer.
/// One chain per audio channel (mic, system).
public final class LivePluginChain: @unchecked Sendable {
    public let channel: AudioChannel
    private var plugins: [LivePlugin] = []

    public init(channel: AudioChannel) {
        self.channel = channel
    }

    public func add(_ plugin: LivePlugin) {
        plugins.append(plugin)
    }

    /// Prepare all plugins in the chain.
    public func prepareAll(maxFrameCount: Int) {
        for plugin in plugins {
            plugin.prepareBuffers(maxFrameCount: maxFrameCount)
        }
    }

    /// Run the full chain on a buffer. Called from the audio thread.
    public func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        for plugin in plugins {
            let result = plugin.process(buffer: buffer, frameCount: frameCount, channel: channel)
            switch result {
            case .modified, .passthrough:
                continue
            case .mute:
                // Zero out and stop chain — no point processing silence
                buffer.update(repeating: 0, count: frameCount)
                return
            }
        }
    }
}

// MARK: - Stage Plugin

/// Context passed to a stage plugin during execution.
public struct SessionContext: Sendable {
    public let sessionId: String
    public let sessionDirectory: String
    public let inputArtifacts: [String: ArtifactRef]
    public let config: PluginConfig

    public init(sessionId: String, sessionDirectory: String, inputArtifacts: [String: ArtifactRef], config: PluginConfig) {
        self.sessionId = sessionId
        self.sessionDirectory = sessionDirectory
        self.inputArtifacts = inputArtifacts
        self.config = config
    }

    /// Convenience to get the full path for a stage's output directory.
    public func outputDirectory(for stageId: String) -> String {
        (sessionDirectory as NSString).appendingPathComponent(stageId)
    }
}

/// A plugin that processes stored artifacts after a session ends.
///
/// No real-time constraints — can take as long as needed.
/// Can be implemented in Swift or as a subprocess (see SubprocessStagePlugin).
public protocol StagePlugin: Plugin {
    /// Artifact types this plugin needs as input.
    var inputArtifacts: [ArtifactType] { get }

    /// Artifact types this plugin produces.
    var outputArtifacts: [ArtifactType] { get }

    /// Execute the plugin's processing on the session's data.
    func execute(context: SessionContext) async throws -> [ArtifactRef]
}

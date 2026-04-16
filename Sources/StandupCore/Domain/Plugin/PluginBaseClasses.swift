/// Base classes for live and stage plugins.
///
/// Provides common lifecycle (config storage, setup/teardown hooks, output directory).
/// Subclass instead of implementing LivePlugin/StagePlugin from scratch.

import Foundation

// MARK: - Base Live Plugin

/// Base class for live plugins. Provides common config storage and lifecycle.
open class BaseLivePlugin: LivePlugin, @unchecked Sendable {
    // SAFETY: @unchecked Sendable — config is set once during setup() before
    // audio thread calls process(). process() is called from a single audio thread.
    // Subclass mutable state follows the same pattern: written during setup, read in process.
    public let id: String
    public let version: String
    public private(set) var config: PluginConfig = PluginConfig()

    public init(id: String, version: String = "1.0.0") {
        self.id = id
        self.version = version
    }

    /// Override to validate config. Called by `setup`. Throw on invalid config.
    open func validate(config: PluginConfig) throws {}

    /// Override to do custom setup after config is stored.
    open func onSetup() async throws {}

    /// Override to do custom teardown.
    open func onTeardown() async {}

    // MARK: Plugin protocol

    public func setup(config: PluginConfig) async throws {
        try validate(config: config)
        self.config = config
        try await onSetup()
    }

    public func teardown() async {
        await onTeardown()
    }

    // MARK: LivePlugin protocol

    /// Override to pre-allocate scratch buffers.
    open func prepareBuffers(maxFrameCount: Int) {}

    /// Override to process audio. Base implementation is passthrough.
    open func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: AudioChannel) -> LivePluginResult {
        .passthrough
    }
}

// MARK: - Base Stage Plugin

/// Base class for stage plugins. Provides common config storage, output directory creation, and lifecycle.
open class BaseStagePlugin: StagePlugin, @unchecked Sendable {
    // SAFETY: @unchecked Sendable — stage plugins run sequentially in pipeline.
    // Config set once during setup(), mutable state accessed only during execute().
    public let id: String
    public let version: String
    open var inputArtifacts: [ArtifactType] { [.custom] }
    open var outputArtifacts: [ArtifactType] { [.custom] }
    public private(set) var config: PluginConfig = PluginConfig()

    public init(id: String, version: String = "1.0.0") {
        self.id = id
        self.version = version
    }

    /// Override to validate config.
    open func validate(config: PluginConfig) throws {}

    /// Override to do custom setup.
    open func onSetup() async throws {}

    /// Override to do custom teardown.
    open func onTeardown() async {}

    // MARK: Plugin protocol

    public func setup(config: PluginConfig) async throws {
        try validate(config: config)
        self.config = config
        try await onSetup()
    }

    public func teardown() async {
        await onTeardown()
    }

    // MARK: StagePlugin protocol

    /// Override to implement processing. Base implementation returns empty artifacts.
    open func execute(context: StageContext) async throws -> [Artifact] {
        []
    }

    /// Helper: ensures the output directory exists and returns its path.
    /// Uses stageId from context (scoped per-stage) so two stages with the same
    /// plugin don't collide. Falls back to plugin id when stageId isn't set.
    public func ensureOutputDirectory(context: StageContext) throws -> String {
        let dir = context.outputDirectory(for: id)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Live Plugin Chain

/// Runs a sequence of live plugins on an audio buffer.
/// One chain per audio channel.
public final class LivePluginChain: @unchecked Sendable {
    // SAFETY: @unchecked Sendable — plugins added during setup phase only,
    // then process() called from a single audio thread. No concurrent mutation.
    public let channel: AudioChannel
    private var plugins: [LivePlugin] = []

    public init(channel: AudioChannel) {
        self.channel = channel
    }

    public var pluginCount: Int { plugins.count }

    public func add(_ plugin: LivePlugin) {
        plugins.append(plugin)
    }

    public func prepareAll(maxFrameCount: Int) {
        for plugin in plugins {
            plugin.prepareBuffers(maxFrameCount: maxFrameCount)
        }
    }

    /// Run the full chain on a buffer. Called from the audio thread.
    public func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        for plugin in plugins {
            let result = plugin.process(buffer: buffer, frameCount: frameCount, channel: channel)
            if case .mute = result {
                buffer.update(repeating: 0, count: frameCount)
                return
            }
        }
    }
}

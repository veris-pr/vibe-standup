/// Plugin contracts and base classes for the Plugin bounded context.
///
/// This file defines:
/// - Fixed contracts (protocols) that all plugins must satisfy
/// - Base classes with common lifecycle management
/// - The factory protocol for multi-strategy plugins
///
/// Contracts are STABLE. Infrastructure and plugin implementations change;
/// these interfaces do not.

import Foundation

// MARK: - Plugin Configuration (Value Object)

/// Configuration passed to a plugin at setup time.
public struct PluginConfig: Sendable, Equatable {
    public let values: [String: String]

    public init(values: [String: String] = [:]) {
        self.values = values
    }

    public func string(for key: String, default defaultValue: String = "") -> String {
        values[key] ?? defaultValue
    }

    public func double(for key: String, default defaultValue: Double = 0) -> Double {
        values[key].flatMap(Double.init) ?? defaultValue
    }

    public func int(for key: String, default defaultValue: Int = 0) -> Int {
        values[key].flatMap(Int.init) ?? defaultValue
    }

    public func bool(for key: String, default defaultValue: Bool = false) -> Bool {
        guard let str = values[key] else { return defaultValue }
        return ["true", "1", "yes"].contains(str.lowercased())
    }
}

// MARK: - Plugin Contract (Fixed Interface)

/// Base contract that every plugin must satisfy.
public protocol Plugin: AnyObject, Sendable {
    var id: String { get }
    var version: String { get }
    func setup(config: PluginConfig) async throws
    func teardown() async
}

// MARK: - Live Plugin Contract

/// Result of processing a buffer in a live plugin.
public enum LivePluginResult: Sendable {
    case modified
    case passthrough
    case mute
}

/// Contract for plugins that process audio in real-time.
///
/// **Hard constraints:**
/// - Called on the audio thread
/// - Must return within latency budget (~10ms)
/// - No heap allocations in `process`
/// - No locks, no syscalls, no async
public protocol LivePlugin: Plugin {
    func prepareBuffers(maxFrameCount: Int)
    func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: AudioChannel) -> LivePluginResult
}

// MARK: - Stage Plugin Contract

/// Context provided to a stage plugin during execution.
public struct StageContext: Sendable {
    public let sessionId: String
    public let sessionDirectory: String
    public let inputArtifacts: [String: Artifact]
    public let config: PluginConfig

    public init(sessionId: String, sessionDirectory: String, inputArtifacts: [String: Artifact], config: PluginConfig) {
        self.sessionId = sessionId
        self.sessionDirectory = sessionDirectory
        self.inputArtifacts = inputArtifacts
        self.config = config
    }

    public func outputDirectory(for stageId: String) -> String {
        (sessionDirectory as NSString).appendingPathComponent(stageId)
    }
}

/// Contract for plugins that process stored artifacts post-session.
public protocol StagePlugin: Plugin {
    var inputArtifacts: [ArtifactType] { get }
    var outputArtifacts: [ArtifactType] { get }
    func execute(context: StageContext) async throws -> [Artifact]
}

// MARK: - Base Classes

/// Base class for live plugins. Provides common config storage and lifecycle.
/// Subclass this instead of implementing LivePlugin from scratch.
open class BaseLivePlugin: LivePlugin, @unchecked Sendable {
    public let id: String
    public let version: String
    public private(set) var config: PluginConfig = PluginConfig()
    private var _isPrepared = false

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
        _isPrepared = false
    }

    // MARK: LivePlugin protocol

    /// Override to pre-allocate scratch buffers.
    open func prepareBuffers(maxFrameCount: Int) {
        _isPrepared = true
    }

    /// Override to process audio. Base implementation is passthrough.
    open func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: AudioChannel) -> LivePluginResult {
        .passthrough
    }
}

/// Base class for stage plugins. Provides common config storage, output directory creation, and lifecycle.
open class BaseStagePlugin: StagePlugin, @unchecked Sendable {
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

// MARK: - Plugin Factory Contract

/// Strategy identifier for plugins that support multiple algorithms.
public protocol PluginStrategy: RawRepresentable, CaseIterable, Sendable where RawValue == String {}

/// Factory contract for creating plugin instances by strategy.
///
/// Example: `NoiseReductionFactory.create(strategy: .gate)` returns a NoiseGateLivePlugin.
/// This allows the pipeline YAML to specify which strategy to use:
///
/// ```yaml
/// - plugin: noise-reduction
///   config:
///     strategy: gate
/// ```
public protocol LivePluginFactory: Sendable {
    associatedtype Strategy: PluginStrategy
    static var pluginId: String { get }
    static var defaultStrategy: Strategy { get }
    static func create(strategy: Strategy, config: PluginConfig) throws -> LivePlugin
}

/// Factory for stage plugins with multiple strategy options.
public protocol StagePluginFactory: Sendable {
    associatedtype Strategy: PluginStrategy
    static var pluginId: String { get }
    static var defaultStrategy: Strategy { get }
    static func create(strategy: Strategy, config: PluginConfig) throws -> StagePlugin
}

// MARK: - Plugin Registry

/// Central registry for looking up plugins and factories.
public final class PluginRegistry: @unchecked Sendable {
    private var livePlugins: [String: LivePlugin] = [:]
    private var stagePlugins: [String: StagePlugin] = [:]
    private var liveFactories: [String: (PluginConfig) throws -> LivePlugin] = [:]
    private var stageFactories: [String: (PluginConfig) throws -> StagePlugin] = [:]

    public init() {}

    // MARK: Direct registration

    public func register(live plugin: LivePlugin) {
        livePlugins[plugin.id] = plugin
    }

    public func register(stage plugin: StagePlugin) {
        stagePlugins[plugin.id] = plugin
    }

    // MARK: Factory registration

    /// Register a factory that can create live plugins by strategy.
    public func register<F: LivePluginFactory>(liveFactory: F.Type) {
        liveFactories[F.pluginId] = { config in
            let strategyName = config.string(for: "strategy", default: F.defaultStrategy.rawValue)
            guard let strategy = F.Strategy(rawValue: strategyName) else {
                throw PluginRegistryError.unknownStrategy(strategyName, pluginId: F.pluginId, available: F.Strategy.allCases.map(\.rawValue))
            }
            return try F.create(strategy: strategy, config: config)
        }
    }

    /// Register a factory that can create stage plugins by strategy.
    public func register<F: StagePluginFactory>(stageFactory: F.Type) {
        stageFactories[F.pluginId] = { config in
            let strategyName = config.string(for: "strategy", default: F.defaultStrategy.rawValue)
            guard let strategy = F.Strategy(rawValue: strategyName) else {
                throw PluginRegistryError.unknownStrategy(strategyName, pluginId: F.pluginId, available: F.Strategy.allCases.map(\.rawValue))
            }
            return try F.create(strategy: strategy, config: config)
        }
    }

    // MARK: Lookup

    /// Resolve a live plugin by ID. Checks direct registrations first, then factories.
    public func resolveLivePlugin(id: String, config: PluginConfig = PluginConfig()) throws -> LivePlugin {
        if let plugin = livePlugins[id] { return plugin }
        if let factory = liveFactories[id] { return try factory(config) }
        throw PluginRegistryError.notFound(id)
    }

    /// Resolve a stage plugin by ID. Checks direct registrations first, then factories.
    public func resolveStagePlugin(id: String, config: PluginConfig = PluginConfig()) throws -> StagePlugin {
        if let plugin = stagePlugins[id] { return plugin }
        if let factory = stageFactories[id] { return try factory(config) }
        throw PluginRegistryError.notFound(id)
    }

    public var allLivePluginIds: [String] {
        Array(Set(livePlugins.keys).union(liveFactories.keys)).sorted()
    }

    public var allStagePluginIds: [String] {
        Array(Set(stagePlugins.keys).union(stageFactories.keys)).sorted()
    }
}

public enum PluginRegistryError: Error, LocalizedError, Sendable {
    case notFound(String)
    case unknownStrategy(String, pluginId: String, available: [String])

    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            "Plugin not found: \(id)"
        case .unknownStrategy(let name, let pluginId, let available):
            "Unknown strategy '\(name)' for plugin '\(pluginId)'. Available: \(available.joined(separator: ", "))"
        }
    }
}

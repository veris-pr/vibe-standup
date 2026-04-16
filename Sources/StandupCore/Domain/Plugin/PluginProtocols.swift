/// Core plugin protocols — the stable contracts that all plugins implement.
///
/// These interfaces define WHAT plugins must do. They change rarely.
/// Base classes (PluginBaseClasses.swift) provide HOW via common lifecycle.

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

// MARK: - Plugin Factory Contracts

/// Strategy identifier for plugins that support multiple algorithms.
public protocol PluginStrategy: RawRepresentable, CaseIterable, Sendable where RawValue == String {}

/// Factory contract for creating live plugin instances by strategy.
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

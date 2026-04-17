/// Plugin registry — central lookup for plugin instances and factories.

import Foundation

/// Central registry for looking up plugins and factories.
public final class PluginRegistry: @unchecked Sendable {
    // SAFETY: @unchecked Sendable — populated during app startup before any
    // concurrent access. resolve methods called sequentially from pipeline execution.
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

    /// Register a factory for a single concrete live plugin type.
    /// Prefer this over direct instance registration for plugins with mutable state.
    public func register(live id: String, factory: @escaping @Sendable () -> LivePlugin) {
        liveFactories[id] = { _ in factory() }
    }

    /// Register a factory for a single concrete stage plugin type.
    /// Prefer this over direct instance registration so each stage gets a fresh instance.
    public func register(stage id: String, factory: @escaping @Sendable () -> StagePlugin) {
        stageFactories[id] = { _ in factory() }
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

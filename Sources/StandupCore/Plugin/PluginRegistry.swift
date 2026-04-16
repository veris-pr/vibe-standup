/// Plugin registry — discovers, stores, and retrieves plugins by ID.

import Foundation

public final class PluginRegistry: @unchecked Sendable {
    private var livePlugins: [String: LivePlugin] = [:]
    private var stagePlugins: [String: StagePlugin] = [:]

    public init() {}

    // MARK: - Registration

    public func register(live plugin: LivePlugin) {
        livePlugins[plugin.id] = plugin
    }

    public func register(stage plugin: StagePlugin) {
        stagePlugins[plugin.id] = plugin
    }

    // MARK: - Lookup

    public func livePlugin(id: String) -> LivePlugin? {
        livePlugins[id]
    }

    public func stagePlugin(id: String) -> StagePlugin? {
        stagePlugins[id]
    }

    public var allLivePluginIds: [String] {
        Array(livePlugins.keys).sorted()
    }

    public var allStagePluginIds: [String] {
        Array(stagePlugins.keys).sorted()
    }
}

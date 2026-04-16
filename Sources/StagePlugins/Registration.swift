/// Registers all built-in stage plugins with the plugin registry.

import StandupCore

public enum StagePluginRegistration {
    public static func registerAll(in registry: PluginRegistry) {
        registry.register(stage: ChannelDiarizerPlugin())
        registry.register(stage: TranscriptMergerPlugin())
    }
}

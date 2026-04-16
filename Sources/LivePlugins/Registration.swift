/// Registers all built-in live plugins with the plugin registry.

import StandupCore

public enum LivePluginRegistration {
    public static func registerAll(in registry: PluginRegistry) {
        registry.register(live: NoiseGateLivePlugin())
        registry.register(live: NormalizeLivePlugin())
    }
}

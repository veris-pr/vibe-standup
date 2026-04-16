/// Registers all built-in live plugins and factories with the registry.

import Foundation
import StandupCore

public enum LivePluginRegistration {
    public static func registerAll(in registry: PluginRegistry) {
        // Factories (multi-strategy)
        registry.register(liveFactory: NoiseReductionFactory.self)
        registry.register(liveFactory: NormalizationFactory.self)

        // Also register individual strategies directly for convenience
        registry.register(live: NoiseGatePlugin())
        registry.register(live: SpectralNoisePlugin())
        registry.register(live: LUFSNormalizePlugin())
        registry.register(live: PeakNormalizePlugin())
    }
}

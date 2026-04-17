/// Registers all built-in live plugins and factories with the registry.

import Foundation
import StandupCore

public enum LivePluginRegistration {
    public static func registerAll(in registry: PluginRegistry) {
        // Factories (multi-strategy)
        registry.register(liveFactory: NoiseReductionFactory.self)
        registry.register(liveFactory: NormalizationFactory.self)

        // Also register individual strategies directly for convenience.
        // Use factories so each chain gets a fresh plugin instance and isolated state.
        registry.register(live: "noise-gate") { NoiseGatePlugin() }
        registry.register(live: "spectral-noise") { SpectralNoisePlugin() }
        registry.register(live: "wiener-noise") { WienerNoisePlugin() }
        registry.register(live: "lufs-normalize") { LUFSNormalizePlugin() }
        registry.register(live: "peak-normalize") { PeakNormalizePlugin() }
    }
}

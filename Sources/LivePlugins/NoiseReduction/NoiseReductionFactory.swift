/// Noise Reduction factory — selects which noise reduction strategy to use.
///
/// Strategies:
/// - gate: Simple noise gate (silences below threshold)
/// - spectral: Spectral subtraction (placeholder for more advanced approach)
///
/// Usage in pipeline YAML:
/// ```yaml
/// - plugin: noise-reduction
///   config:
///     strategy: gate        # or "spectral"
///     threshold_db: "-40"
/// ```

import Foundation
import StandupCore

// MARK: - Strategy Enum

public enum NoiseReductionStrategy: String, PluginStrategy, CaseIterable, Sendable {
    case gate
    case spectral
}

// MARK: - Factory

public enum NoiseReductionFactory: LivePluginFactory {
    public static let pluginId = "noise-reduction"
    public static let defaultStrategy = NoiseReductionStrategy.gate

    public static func create(strategy: NoiseReductionStrategy, config: PluginConfig) throws -> LivePlugin {
        switch strategy {
        case .gate:
            return NoiseGatePlugin()
        case .spectral:
            return SpectralNoisePlugin()
        }
    }
}

/// Normalization factory — selects which normalization strategy to use.
///
/// Strategies:
/// - lufs: Target LUFS-based normalization with smooth gain adjustment
/// - peak: Simple peak normalization to a target level

import Foundation
import StandupCore

public enum NormalizationStrategy: String, PluginStrategy, CaseIterable, Sendable {
    case lufs
    case peak
}

public enum NormalizationFactory: LivePluginFactory {
    public static let pluginId = "normalize"
    public static let defaultStrategy = NormalizationStrategy.lufs

    public static func create(strategy: NormalizationStrategy, config: PluginConfig) throws -> LivePlugin {
        switch strategy {
        case .lufs:
            return LUFSNormalizePlugin()
        case .peak:
            return PeakNormalizePlugin()
        }
    }
}

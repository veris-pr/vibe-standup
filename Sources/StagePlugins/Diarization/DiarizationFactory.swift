/// Diarization factory — selects which diarization strategy to use.
///
/// Strategies:
/// - channel: Labels "me"/"them" based on mic vs system audio channel energy
/// - energy: More granular energy-based detection within a single channel

import Foundation
import StandupCore

public enum DiarizationStrategy: String, PluginStrategy, CaseIterable, Sendable {
    case channel
    case energy
}

public enum DiarizationFactory: StagePluginFactory {
    public static let pluginId = "diarizer"
    public static let defaultStrategy = DiarizationStrategy.channel

    public static func create(strategy: DiarizationStrategy, config: PluginConfig) throws -> StagePlugin {
        switch strategy {
        case .channel:
            return ChannelDiarizerPlugin()
        case .energy:
            return EnergyDiarizerPlugin()
        }
    }
}

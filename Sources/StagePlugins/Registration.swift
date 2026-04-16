/// Registers all built-in stage plugins and factories with the registry.

import Foundation
import StandupCore

public enum StagePluginRegistration {
    public static func registerAll(in registry: PluginRegistry) {
        // Factories (multi-strategy)
        registry.register(stageFactory: DiarizationFactory.self)

        // Direct registrations
        registry.register(stage: ChannelDiarizerPlugin())
        registry.register(stage: EnergyDiarizerPlugin())
        registry.register(stage: TranscriptMergerPlugin())
        registry.register(stage: WhisperPlugin())
        registry.register(stage: ComicFormatterPlugin())
        registry.register(stage: ComicRendererPlugin())
    }
}

/// Registers all built-in stage plugins and factories with the registry.

import Foundation
import StandupCore

public enum StagePluginRegistration {
    public static func registerAll(in registry: PluginRegistry) {
        // Factories (multi-strategy)
        registry.register(stageFactory: DiarizationFactory.self)

        // Direct registrations use factories so each stage execution gets a fresh instance.
        registry.register(stage: "channel-diarizer") { ChannelDiarizerPlugin() }
        registry.register(stage: "energy-diarizer") { EnergyDiarizerPlugin() }
        registry.register(stage: "transcript-merger") { TranscriptMergerPlugin() }
        registry.register(stage: "mlx-whisper") { MlxWhisperPlugin() }
        registry.register(stage: "comic-formatter") { ComicFormatterPlugin() }
        registry.register(stage: "comic-script") { ComicScriptPlugin() }
        registry.register(stage: "image-gen") { ImageGenPlugin() }
        registry.register(stage: "comic-renderer") { ComicRendererPlugin() }
    }
}

/// Infrastructure: Configuration loading from YAML.

import Foundation
import Yams

public struct StandupConfig: Sendable {
    public let baseDirectory: String
    public let pipelinesDirectory: String
    public let pluginSearchPaths: [String]
    public let sampleRate: Double
    public let bufferFrameSize: Int
    public let maxLivePluginLatencyMs: Double
    public let stageMaxParallel: Int
    public let stageMaxRSSMB: Int
    public let whisperThreads: Int
    public let whisperModel: String

    public init(
        baseDirectory: String? = nil,
        pipelinesDirectory: String? = nil,
        pluginSearchPaths: [String]? = nil,
        sampleRate: Double = 48000,
        bufferFrameSize: Int = 1024,
        maxLivePluginLatencyMs: Double = 10,
        stageMaxParallel: Int = 2,
        stageMaxRSSMB: Int = 512,
        whisperThreads: Int = 4,
        whisperModel: String = "base.en"
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let base = baseDirectory ?? (home as NSString).appendingPathComponent(".standup")
        self.baseDirectory = base
        self.pipelinesDirectory = pipelinesDirectory ?? (base as NSString).appendingPathComponent("pipelines")
        self.pluginSearchPaths = pluginSearchPaths ?? [(base as NSString).appendingPathComponent("plugins")]
        self.sampleRate = sampleRate
        self.bufferFrameSize = bufferFrameSize
        self.maxLivePluginLatencyMs = maxLivePluginLatencyMs
        self.stageMaxParallel = stageMaxParallel
        self.stageMaxRSSMB = stageMaxRSSMB
        self.whisperThreads = whisperThreads
        self.whisperModel = whisperModel
    }

    public var dbPath: String {
        (baseDirectory as NSString).appendingPathComponent("standup.db")
    }

    public var activeSessionFile: String {
        (baseDirectory as NSString).appendingPathComponent("active_session")
    }

    public var sessionsDirectory: String {
        (baseDirectory as NSString).appendingPathComponent("sessions")
    }

    public static func load() -> StandupConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configPath = (home as NSString)
            .appendingPathComponent(".standup/config.yaml")

        guard FileManager.default.fileExists(atPath: configPath),
              let yaml = try? String(contentsOfFile: configPath, encoding: .utf8),
              let doc = try? Yams.load(yaml: yaml) as? [String: Any] else {
            return StandupConfig()
        }

        let perf = doc["performance"] as? [String: Any] ?? [:]
        return StandupConfig(
            baseDirectory: doc["base_directory"] as? String,
            pipelinesDirectory: doc["pipelines_directory"] as? String,
            pluginSearchPaths: doc["plugin_search_paths"] as? [String],
            sampleRate: doc["sample_rate"] as? Double ?? 48000,
            bufferFrameSize: doc["buffer_frame_size"] as? Int ?? 1024,
            maxLivePluginLatencyMs: perf["max_live_plugin_latency_ms"] as? Double ?? 10,
            stageMaxParallel: perf["stage_max_parallel"] as? Int ?? 2,
            stageMaxRSSMB: perf["stage_max_rss_mb"] as? Int ?? 512,
            whisperThreads: perf["whisper_threads"] as? Int ?? 4,
            whisperModel: perf["whisper_model"] as? String ?? "base.en"
        )
    }

    public static func writeDefault(to path: String? = nil) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configPath = path ?? (home as NSString).appendingPathComponent(".standup/config.yaml")
        let dir = (configPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let yaml = """
        # Standup configuration
        # base_directory: ~/.standup
        # pipelines_directory: ~/.standup/pipelines

        performance:
          max_live_plugin_latency_ms: 10
          stage_max_parallel: 2
          stage_max_rss_mb: 512
          whisper_threads: 4
          whisper_model: base.en
        """
        try yaml.write(toFile: configPath, atomically: true, encoding: .utf8)
    }
}

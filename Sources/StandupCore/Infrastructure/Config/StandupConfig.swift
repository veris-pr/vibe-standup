/// Infrastructure: Configuration loading from YAML.

import Foundation
import Yams

public struct StandupConfig: Sendable {
    public let baseDirectory: String
    public let pipelinesDirectory: String
    public let sampleRate: Double
    public let bufferFrameSize: Int
    public let whisperThreads: Int
    public let whisperModel: String

    public init(
        baseDirectory: String? = nil,
        pipelinesDirectory: String? = nil,
        sampleRate: Double = 48000,
        bufferFrameSize: Int = 1024,
        whisperThreads: Int = 4,
        whisperModel: String = "base.en"
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let base = baseDirectory ?? (home as NSString).appendingPathComponent(".standup")
        self.baseDirectory = base
        self.pipelinesDirectory = pipelinesDirectory ?? (base as NSString).appendingPathComponent("pipelines")
        self.sampleRate = sampleRate
        self.bufferFrameSize = bufferFrameSize
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

        return StandupConfig(
            baseDirectory: doc["base_directory"] as? String,
            pipelinesDirectory: doc["pipelines_directory"] as? String,
            sampleRate: doc["sample_rate"] as? Double ?? 48000,
            bufferFrameSize: doc["buffer_frame_size"] as? Int ?? 1024,
            whisperThreads: doc["whisper_threads"] as? Int ?? 4,
            whisperModel: doc["whisper_model"] as? String ?? "base.en"
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

        # sample_rate: 48000
        # buffer_frame_size: 1024
        whisper_threads: 4
        whisper_model: base.en
        """
        try yaml.write(toFile: configPath, atomically: true, encoding: .utf8)
    }
}

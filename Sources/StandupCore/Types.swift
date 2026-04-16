/// Core types shared across the Standup audio pipeline.

import Foundation

// MARK: - Audio Types

/// Identifies which audio channel a buffer belongs to.
public enum AudioChannel: String, Sendable, Codable {
    case mic
    case system
}

/// Metadata for an audio chunk written to disk.
public struct AudioChunkInfo: Sendable, Codable {
    public let index: Int
    public let channel: AudioChannel
    public let sampleRate: Double
    public let frameCount: Int
    public let timestamp: TimeInterval
    public let path: String

    public init(index: Int, channel: AudioChannel, sampleRate: Double, frameCount: Int, timestamp: TimeInterval, path: String) {
        self.index = index
        self.channel = channel
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.timestamp = timestamp
        self.path = path
    }
}

// MARK: - Session Types

/// States a session moves through during its lifecycle.
public enum SessionStatus: String, Sendable, Codable {
    case active
    case processing
    case complete
    case failed
}

/// Describes a session and its metadata.
public struct SessionInfo: Sendable, Codable {
    public let id: String
    public var status: SessionStatus
    public let pipelineName: String
    public let startTime: Date
    public var endTime: Date?
    public let directoryPath: String

    public init(id: String, status: SessionStatus, pipelineName: String, startTime: Date, endTime: Date? = nil, directoryPath: String) {
        self.id = id
        self.status = status
        self.pipelineName = pipelineName
        self.startTime = startTime
        self.endTime = endTime
        self.directoryPath = directoryPath
    }
}

// MARK: - Artifact Types

/// Types of artifacts that stage plugins produce and consume.
public enum ArtifactType: String, Sendable, Codable {
    case audioChunks = "audio_chunks"
    case transcriptionSegments = "transcription_segments"
    case diarizationLabels = "diarization_labels"
    case cleanTranscript = "clean_transcript"
    case comicPanels = "comic_panels"
    case comicOutput = "comic_output"
    case custom = "custom"
}

/// Reference to an artifact produced by a pipeline stage.
public struct ArtifactRef: Sendable, Codable {
    public let stageId: String
    public let type: ArtifactType
    public let path: String

    public init(stageId: String, type: ArtifactType, path: String) {
        self.stageId = stageId
        self.type = type
        self.path = path
    }
}

// MARK: - Plugin Configuration

/// Configuration passed to a plugin at setup time.
public struct PluginConfig: Sendable {
    public let values: [String: String]

    public init(values: [String: String] = [:]) {
        self.values = values
    }

    public func string(for key: String, default defaultValue: String = "") -> String {
        values[key] ?? defaultValue
    }

    public func double(for key: String, default defaultValue: Double = 0) -> Double {
        if let str = values[key], let val = Double(str) { return val }
        return defaultValue
    }

    public func int(for key: String, default defaultValue: Int = 0) -> Int {
        if let str = values[key], let val = Int(str) { return val }
        return defaultValue
    }
}

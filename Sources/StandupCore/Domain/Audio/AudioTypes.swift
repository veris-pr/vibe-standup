/// Domain value objects for the Audio bounded context.
///
/// These types form the ubiquitous language of the audio domain.
/// They are pure value objects with no infrastructure dependencies.

import Foundation

// MARK: - Audio Channel

/// Identifies which audio channel a buffer belongs to.
public enum AudioChannel: String, Sendable, Codable, CaseIterable {
    case mic
    case system
}

// MARK: - Audio Format

/// Describes the format of audio data in the pipeline.
public struct AudioFormat: Sendable, Equatable {
    public let sampleRate: Double
    public let channels: Int
    public let bitsPerSample: Int

    public init(sampleRate: Double = 48000, channels: Int = 1, bitsPerSample: Int = 32) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
    }

    /// Bytes per frame (one sample per channel).
    public var bytesPerFrame: Int {
        (bitsPerSample / 8) * channels
    }

    /// Standard format used throughout the pipeline.
    public static let standard = AudioFormat()
}

// MARK: - Audio Chunk

/// Metadata for a chunk of audio written to disk during a session.
/// This is a value object — immutable once created.
public struct AudioChunk: Sendable, Codable, Equatable {
    public let index: Int
    public let channel: AudioChannel
    public let format: CodableAudioFormat
    public let frameCount: Int
    public let timestamp: TimeInterval
    public let path: String

    public init(index: Int, channel: AudioChannel, format: AudioFormat, frameCount: Int, timestamp: TimeInterval, path: String) {
        self.index = index
        self.channel = channel
        self.format = CodableAudioFormat(format)
        self.frameCount = frameCount
        self.timestamp = timestamp
        self.path = path
    }

    public var duration: TimeInterval {
        Double(frameCount) / format.sampleRate
    }
}

/// Codable wrapper for AudioFormat.
public struct CodableAudioFormat: Sendable, Codable, Equatable {
    public let sampleRate: Double
    public let channels: Int
    public let bitsPerSample: Int

    public init(_ format: AudioFormat) {
        self.sampleRate = format.sampleRate
        self.channels = format.channels
        self.bitsPerSample = format.bitsPerSample
    }
}

// MARK: - Audio Capture Port (contract)

/// Port defining the contract for audio capture implementations.
/// Infrastructure provides the adapter (e.g., AVAudioEngine + ScreenCaptureKit).
public protocol AudioCapturePort: AnyObject, Sendable {
    var delegate: AudioCaptureDelegate? { get set }
    func start() async throws
    func stop() async
}

/// Delegate notified when audio chunks are captured.
public protocol AudioCaptureDelegate: AnyObject, Sendable {
    func didCaptureChunk(_ chunk: AudioChunk)
    func didEncounterError(_ error: Error)
}

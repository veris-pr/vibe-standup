/// Audio capture engine — captures mic and system audio into separate channels.
///
/// Uses AVAudioEngine for microphone input and ScreenCaptureKit for system audio.
/// Each channel runs through its live plugin chain before being written to the ring buffer.

import AVFAudio
import Foundation
import ScreenCaptureKit

/// Delegate that receives audio chunks as they are captured.
public protocol AudioCaptureDelegate: AnyObject, Sendable {
    func audioCaptureDidWriteChunk(_ chunk: AudioChunkInfo)
    func audioCaptureDidEncounterError(_ error: Error)
}

public final class AudioCaptureEngine: @unchecked Sendable {
    // Audio format: mono Float32 at 48kHz
    public static let sampleRate: Double = 48000
    public static let bufferFrameSize: AVAudioFrameCount = 1024

    private let sessionDirectory: String
    private let micChain: LivePluginChain
    private let systemChain: LivePluginChain

    // Ring buffers — one per channel
    private let micRingBuffer: RingBuffer
    private let systemRingBuffer: RingBuffer

    // AVAudioEngine for mic input
    private var audioEngine: AVAudioEngine?

    // ScreenCaptureKit for system audio
    private var scStream: SCStream?
    private var streamDelegate: SystemAudioStreamDelegate?

    // Writer state
    private var writerTask: Task<Void, Never>?
    private var isRunning = false
    private var chunkIndex = 0
    private let startTimestamp: TimeInterval

    public weak var delegate: AudioCaptureDelegate?

    public init(sessionDirectory: String, micChain: LivePluginChain, systemChain: LivePluginChain) {
        // ~2 seconds of buffer at 48kHz
        let bufferCapacity = Int(Self.sampleRate * 2)
        self.sessionDirectory = sessionDirectory
        self.micChain = micChain
        self.systemChain = systemChain
        self.micRingBuffer = RingBuffer(minimumCapacity: bufferCapacity)
        self.systemRingBuffer = RingBuffer(minimumCapacity: bufferCapacity)
        self.startTimestamp = ProcessInfo.processInfo.systemUptime
    }

    // MARK: - Start / Stop

    public func start() async throws {
        guard !isRunning else { return }
        isRunning = true

        // Prepare live plugin chains
        let maxFrames = Int(Self.bufferFrameSize)
        micChain.prepareAll(maxFrameCount: maxFrames)
        systemChain.prepareAll(maxFrameCount: maxFrames)

        // Create chunks directory
        let chunksDir = (sessionDirectory as NSString).appendingPathComponent("chunks")
        try FileManager.default.createDirectory(atPath: chunksDir, withIntermediateDirectories: true)

        // Start mic capture
        try startMicCapture()

        // Start system audio capture
        try await startSystemAudioCapture()

        // Start writer thread
        writerTask = Task.detached(priority: .utility) { [weak self] in
            await self?.writerLoop()
        }
    }

    public func stop() async {
        isRunning = false

        // Stop mic
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        // Stop system audio
        if let stream = scStream {
            try? await stream.stopCapture()
            scStream = nil
        }

        // Wait for writer to flush
        writerTask?.cancel()
        writerTask = nil
    }

    // MARK: - Microphone Capture (AVAudioEngine)

    private func startMicCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        )!

        inputNode.installTap(onBus: 0, bufferSize: Self.bufferFrameSize, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self, self.isRunning else { return }
            guard let floatData = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)

            // Run live plugin chain on mic audio
            self.micChain.process(buffer: floatData, frameCount: frameCount)

            // Write to ring buffer
            self.micRingBuffer.write(from: floatData, count: frameCount)
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
    }

    // MARK: - System Audio Capture (ScreenCaptureKit)

    private func startSystemAudioCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(Self.sampleRate)
        config.channelCount = 1

        // We don't need video — just audio
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        // Use a display filter — we just want audio, but need a valid filter
        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayFound
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let delegate = SystemAudioStreamDelegate { [weak self] buffer, frameCount in
            guard let self, self.isRunning else { return }
            // Run live plugin chain on system audio
            self.systemChain.process(buffer: buffer, frameCount: frameCount)
            // Write to ring buffer
            self.systemRingBuffer.write(from: buffer, count: frameCount)
        }
        self.streamDelegate = delegate

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()
        self.scStream = stream
    }

    // MARK: - Writer Loop

    /// Drains ring buffers to disk in 1-second chunks.
    private func writerLoop() async {
        let chunkFrames = Int(Self.sampleRate) // 1 second per chunk
        let micTemp = UnsafeMutablePointer<Float>.allocate(capacity: chunkFrames)
        let sysTemp = UnsafeMutablePointer<Float>.allocate(capacity: chunkFrames)
        defer {
            micTemp.deallocate()
            sysTemp.deallocate()
        }

        while isRunning || micRingBuffer.availableToRead > 0 || systemRingBuffer.availableToRead > 0 {
            // Drain mic ring buffer
            let micRead = micRingBuffer.read(into: micTemp, count: chunkFrames)
            if micRead > 0 {
                writeChunk(from: micTemp, frameCount: micRead, channel: .mic)
            }

            // Drain system ring buffer
            let sysRead = systemRingBuffer.read(into: sysTemp, count: chunkFrames)
            if sysRead > 0 {
                writeChunk(from: sysTemp, frameCount: sysRead, channel: .system)
            }

            // Sleep briefly to batch writes (~100ms)
            if micRead == 0 && sysRead == 0 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func writeChunk(from buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: AudioChannel) {
        let chunksDir = (sessionDirectory as NSString).appendingPathComponent("chunks")
        let index = chunkIndex
        chunkIndex += 1

        let filename = String(format: "%04d_%@.pcm", index, channel.rawValue)
        let path = (chunksDir as NSString).appendingPathComponent(filename)

        let data = Data(bytes: buffer, count: frameCount * MemoryLayout<Float>.size)
        try? data.write(to: URL(fileURLWithPath: path))

        let elapsed = ProcessInfo.processInfo.systemUptime - startTimestamp
        let info = AudioChunkInfo(
            index: index,
            channel: channel,
            sampleRate: Self.sampleRate,
            frameCount: frameCount,
            timestamp: elapsed,
            path: path
        )
        delegate?.audioCaptureDidWriteChunk(info)
    }
}

// MARK: - System Audio Stream Delegate

private final class SystemAudioStreamDelegate: NSObject, SCStreamOutput, @unchecked Sendable {
    let handler: (UnsafeMutablePointer<Float>, Int) -> Void

    init(handler: @escaping (UnsafeMutablePointer<Float>, Int) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let blockBuffer = sampleBuffer.dataBuffer else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        let frameCount = length / MemoryLayout<Float>.size
        guard frameCount > 0 else { return }

        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let ptr = dataPointer else { return }

        ptr.withMemoryRebound(to: Float.self, capacity: frameCount) { floatPtr in
            // Make a mutable copy for live plugins to process in-place
            let mutable = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            mutable.update(from: floatPtr, count: frameCount)
            handler(mutable, frameCount)
            mutable.deallocate()
        }
    }
}

// MARK: - Errors

public enum AudioCaptureError: Error, LocalizedError {
    case noDisplayFound
    case micPermissionDenied
    case screenCapturePermissionDenied

    public var errorDescription: String? {
        switch self {
        case .noDisplayFound: "No display found for system audio capture"
        case .micPermissionDenied: "Microphone permission denied"
        case .screenCapturePermissionDenied: "Screen capture permission denied (needed for system audio)"
        }
    }
}

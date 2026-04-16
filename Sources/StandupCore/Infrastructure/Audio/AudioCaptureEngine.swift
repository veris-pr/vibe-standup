/// Infrastructure: Audio capture using AVAudioEngine (mic) + ScreenCaptureKit (system).
///
/// This is the adapter that implements the AudioCapturePort contract.

import AVFAudio
import Foundation
import ScreenCaptureKit

public final class AudioCaptureEngine: AudioCapturePort, @unchecked Sendable {
    public static let defaultFormat = AudioFormat.standard

    private let sessionDirectory: String
    private let micChain: LivePluginChain
    private let systemChain: LivePluginChain
    private let micRingBuffer: RingBuffer
    private let systemRingBuffer: RingBuffer

    private var audioEngine: AVAudioEngine?
    private var scStream: SCStream?
    private var streamDelegate: SystemAudioStreamDelegate?
    private var writerTask: Task<Void, Never>?
    private var isRunning = false
    private var chunkIndex = 0
    private let startTimestamp: TimeInterval

    public weak var delegate: AudioCaptureDelegate?

    public init(sessionDirectory: String, micChain: LivePluginChain, systemChain: LivePluginChain) {
        let bufferCapacity = Int(Self.defaultFormat.sampleRate * 2)
        self.sessionDirectory = sessionDirectory
        self.micChain = micChain
        self.systemChain = systemChain
        self.micRingBuffer = RingBuffer(minimumCapacity: bufferCapacity)
        self.systemRingBuffer = RingBuffer(minimumCapacity: bufferCapacity)
        self.startTimestamp = ProcessInfo.processInfo.systemUptime
    }

    public func start() async throws {
        guard !isRunning else { return }
        isRunning = true

        let maxFrames = 1024
        micChain.prepareAll(maxFrameCount: maxFrames)
        systemChain.prepareAll(maxFrameCount: maxFrames)

        let chunksDir = (sessionDirectory as NSString).appendingPathComponent("chunks")
        try FileManager.default.createDirectory(atPath: chunksDir, withIntermediateDirectories: true)

        try startMicCapture()
        try await startSystemAudioCapture()

        writerTask = Task.detached(priority: .utility) { [weak self] in
            await self?.writerLoop()
        }
    }

    public func stop() async {
        isRunning = false
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        if let stream = scStream {
            try? await stream.stopCapture()
            scStream = nil
        }

        writerTask?.cancel()
        writerTask = nil
    }

    // MARK: - Mic (AVAudioEngine)

    private func startMicCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.defaultFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, self.isRunning else { return }
            guard let floatData = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)
            self.micChain.process(buffer: floatData, frameCount: frameCount)
            self.micRingBuffer.write(from: floatData, count: frameCount)
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
    }

    // MARK: - System Audio (ScreenCaptureKit)

    private func startSystemAudioCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(Self.defaultFormat.sampleRate)
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayFound
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let delegate = SystemAudioStreamDelegate { [weak self] buffer, frameCount in
            guard let self, self.isRunning else { return }
            self.systemChain.process(buffer: buffer, frameCount: frameCount)
            self.systemRingBuffer.write(from: buffer, count: frameCount)
        }
        self.streamDelegate = delegate

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()
        self.scStream = stream
    }

    // MARK: - Writer Loop

    private func writerLoop() async {
        let chunkFrames = Int(Self.defaultFormat.sampleRate) // 1 second
        let micTemp = UnsafeMutablePointer<Float>.allocate(capacity: chunkFrames)
        let sysTemp = UnsafeMutablePointer<Float>.allocate(capacity: chunkFrames)
        defer {
            micTemp.deallocate()
            sysTemp.deallocate()
        }

        while isRunning || micRingBuffer.availableToRead > 0 || systemRingBuffer.availableToRead > 0 {
            let micRead = micRingBuffer.read(into: micTemp, count: chunkFrames)
            if micRead > 0 { writeChunk(from: micTemp, frameCount: micRead, channel: .mic) }

            let sysRead = systemRingBuffer.read(into: sysTemp, count: chunkFrames)
            if sysRead > 0 { writeChunk(from: sysTemp, frameCount: sysRead, channel: .system) }

            if micRead == 0 && sysRead == 0 {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
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
        let chunk = AudioChunk(
            index: index,
            channel: channel,
            format: Self.defaultFormat,
            frameCount: frameCount,
            timestamp: elapsed,
            path: path
        )
        delegate?.didCaptureChunk(chunk)
    }
}

// MARK: - ScreenCaptureKit Stream Output

private final class SystemAudioStreamDelegate: NSObject, SCStreamOutput, @unchecked Sendable {
    let handler: (UnsafeMutablePointer<Float>, Int) -> Void

    init(handler: @escaping (UnsafeMutablePointer<Float>, Int) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let blockBuffer = sampleBuffer.dataBuffer else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        let frameCount = length / MemoryLayout<Float>.size
        guard frameCount > 0 else { return }

        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let ptr = dataPointer else { return }

        ptr.withMemoryRebound(to: Float.self, capacity: frameCount) { floatPtr in
            let mutable = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            mutable.update(from: floatPtr, count: frameCount)
            handler(mutable, frameCount)
            mutable.deallocate()
        }
    }
}

// MARK: - Errors

public enum AudioCaptureError: Error, LocalizedError, Sendable {
    case noDisplayFound
    case micPermissionDenied
    case screenCapturePermissionDenied

    public var errorDescription: String? {
        switch self {
        case .noDisplayFound: "No display found for system audio capture"
        case .micPermissionDenied: "Microphone permission denied"
        case .screenCapturePermissionDenied: "Screen capture permission denied"
        }
    }
}

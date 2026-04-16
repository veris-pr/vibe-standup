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

        // Use the input node's native format — specifying a custom format causes crashes
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        // Target format for our pipeline: mono Float32 at our sample rate
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.defaultFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!

        // If native format matches, tap directly. Otherwise, use a converter.
        let needsConversion = nativeFormat.sampleRate != targetFormat.sampleRate
            || nativeFormat.channelCount != targetFormat.channelCount

        if needsConversion, let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) {
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
                guard let self, self.isRunning else { return }

                let frameCapacity = AVAudioFrameCount(
                    Double(buffer.frameLength) * targetFormat.sampleRate / nativeFormat.sampleRate
                )
                guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }

                var error: NSError?
                converter.convert(to: converted, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                guard error == nil, converted.frameLength > 0 else { return }
                guard let floatData = converted.floatChannelData?[0] else { return }
                let frameCount = Int(converted.frameLength)
                self.micChain.process(buffer: floatData, frameCount: frameCount)
                self.micRingBuffer.write(from: floatData, count: frameCount)
            }
        } else {
            // Native format is compatible — tap directly
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
                guard let self, self.isRunning else { return }
                guard let floatData = buffer.floatChannelData?[0] else { return }
                let frameCount = Int(buffer.frameLength)
                self.micChain.process(buffer: floatData, frameCount: frameCount)
                self.micRingBuffer.write(from: floatData, count: frameCount)
            }
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
            let sysRead = systemRingBuffer.read(into: sysTemp, count: chunkFrames)

            // Write paired chunks with the same index for diarization alignment
            if micRead > 0 || sysRead > 0 {
                let index = chunkIndex
                chunkIndex += 1

                if micRead > 0 {
                    writeChunk(from: micTemp, frameCount: micRead, channel: .mic, index: index)
                }
                if sysRead > 0 {
                    writeChunk(from: sysTemp, frameCount: sysRead, channel: .system, index: index)
                }
            } else {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }
    }

    private func writeChunk(from buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: AudioChannel, index: Int) {
        let chunksDir = (sessionDirectory as NSString).appendingPathComponent("chunks")

        let filename = String(format: "%06d_%@.pcm", index, channel.rawValue)
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
        guard type == .audio else { return }
        guard sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        guard let blockBuffer = sampleBuffer.dataBuffer else { return }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return }

        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let ptr = dataPointer else { return }

        // Detect channel count from format description
        let channelCount: Int
        if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
            channelCount = Int(asbd.pointee.mChannelsPerFrame)
        } else {
            channelCount = 1
        }

        let totalSamples = length / MemoryLayout<Float>.size
        let frameCount = totalSamples / channelCount
        guard frameCount > 0 else { return }

        ptr.withMemoryRebound(to: Float.self, capacity: totalSamples) { floatPtr in
            let mutable = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            defer { mutable.deallocate() }

            if channelCount == 1 {
                mutable.update(from: floatPtr, count: frameCount)
            } else {
                // Downmix to mono by averaging channels
                for i in 0..<frameCount {
                    var sum: Float = 0
                    for ch in 0..<channelCount {
                        sum += floatPtr[i * channelCount + ch]
                    }
                    mutable[i] = sum / Float(channelCount)
                }
            }
            handler(mutable, frameCount)
        }
    }
}

// MARK: - Errors

public enum AudioCaptureError: Error, LocalizedError, Sendable {
    case noDisplayFound
    case micPermissionDenied
    case screenCapturePermissionDenied
    case virtualDeviceNotFound(String)
    case virtualDeviceConfigFailed(String, OSStatus)

    public var errorDescription: String? {
        switch self {
        case .noDisplayFound: "No display found for system audio capture"
        case .micPermissionDenied: "Microphone permission denied"
        case .screenCapturePermissionDenied: "Screen capture permission denied"
        case .virtualDeviceNotFound(let name):
            "Virtual audio device '\(name)' not found. Install it with: brew install blackhole-2ch"
        case .virtualDeviceConfigFailed(let name, let status):
            "Failed to configure virtual device '\(name)' (OSStatus: \(status))"
        }
    }
}

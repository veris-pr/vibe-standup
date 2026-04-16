/// Infrastructure: Audio capture using AVAudioEngine (mic) + ScreenCaptureKit (system).
///
/// This is the adapter that implements the AudioCapturePort contract.

import AVFAudio
import Foundation
import ScreenCaptureKit

public final class AudioCaptureEngine: AudioCapturePort, @unchecked Sendable {
    // SAFETY: @unchecked Sendable — start/stop called from main actor,
    // audio callbacks run on audio thread, writer on utility thread.

    private let sessionDirectory: String
    private let micChain: LivePluginChain
    private let systemChain: LivePluginChain
    private let micRingBuffer: RingBuffer
    private let systemRingBuffer: RingBuffer
    private let chunkWriter: ChunkWriter

    private var audioEngine: AVAudioEngine?
    private var scStream: SCStream?
    private var streamDelegate: SystemAudioStreamDelegate?
    private var writerTask: Task<Void, Never>?

    public weak var delegate: AudioCaptureDelegate? {
        didSet { chunkWriter.delegate = delegate }
    }

    public init(sessionDirectory: String, micChain: LivePluginChain, systemChain: LivePluginChain) {
        let bufferSeconds = 2
        let bufferCapacity = Int(AudioFormat.standard.sampleRate) * bufferSeconds
        self.sessionDirectory = sessionDirectory
        self.micChain = micChain
        self.systemChain = systemChain
        self.micRingBuffer = RingBuffer(minimumCapacity: bufferCapacity)
        self.systemRingBuffer = RingBuffer(minimumCapacity: bufferCapacity)
        self.chunkWriter = ChunkWriter(
            sessionDirectory: sessionDirectory,
            micRingBuffer: micRingBuffer,
            systemRingBuffer: systemRingBuffer,
            startTimestamp: ProcessInfo.processInfo.systemUptime
        )
    }

    public func start() async throws {
        guard !chunkWriter.isRunning else { return }
        chunkWriter.isRunning = true

        let maxFrames = 1024
        micChain.prepareAll(maxFrameCount: maxFrames)
        systemChain.prepareAll(maxFrameCount: maxFrames)

        let chunksDir = (sessionDirectory as NSString).appendingPathComponent("chunks")
        try FileManager.default.createDirectory(atPath: chunksDir, withIntermediateDirectories: true)

        try startMicCapture()
        try await startSystemAudioCapture()

        writerTask = Task.detached(priority: .utility) { [chunkWriter] in
            await chunkWriter.writerLoop()
        }
    }

    public func stop() async {
        chunkWriter.isRunning = false
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        if let stream = scStream {
            try? await stream.stopCapture()
            scStream = nil
        }

        await writerTask?.value
        writerTask = nil
    }

    // MARK: - Mic (AVAudioEngine)

    private func startMicCapture() throws {
        let engine = AVAudioEngine()
        MicTapInstaller.install(
            on: engine,
            chain: micChain,
            ringBuffer: micRingBuffer,
            isRunning: { [chunkWriter] in chunkWriter.isRunning }
        )
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
        config.sampleRate = Int(AudioFormat.standard.sampleRate)
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayFound
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let delegate = SystemAudioStreamDelegate { [weak self, chunkWriter] buffer, frameCount in
            guard let self, chunkWriter.isRunning else { return }
            self.systemChain.process(buffer: buffer, frameCount: frameCount)
            self.systemRingBuffer.write(from: buffer, count: frameCount)
        }
        self.streamDelegate = delegate

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()
        self.scStream = stream
    }
}

// MARK: - ScreenCaptureKit Stream Output

private final class SystemAudioStreamDelegate: NSObject, SCStreamOutput, @unchecked Sendable {
    // SAFETY: @unchecked Sendable — handler closure captures only Sendable references.
    // scratchBuffer is accessed only from the SCStreamOutput callback queue (serial).
    let handler: (UnsafeMutablePointer<Float>, Int) -> Void
    private var scratchBuffer: UnsafeMutablePointer<Float>
    private var scratchCapacity: Int

    init(handler: @escaping (UnsafeMutablePointer<Float>, Int) -> Void) {
        self.handler = handler
        let initial = 4096
        self.scratchBuffer = .allocate(capacity: initial)
        self.scratchCapacity = initial
    }

    deinit { scratchBuffer.deallocate() }

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

        // Grow scratch buffer if needed (rare — only on first large callback)
        if frameCount > scratchCapacity {
            scratchBuffer.deallocate()
            scratchBuffer = .allocate(capacity: frameCount)
            scratchCapacity = frameCount
        }

        ptr.withMemoryRebound(to: Float.self, capacity: totalSamples) { floatPtr in
            if channelCount == 1 {
                scratchBuffer.update(from: floatPtr, count: frameCount)
            } else {
                // Downmix to mono by averaging channels
                for i in 0..<frameCount {
                    var sum: Float = 0
                    for ch in 0..<channelCount {
                        sum += floatPtr[i * channelCount + ch]
                    }
                    scratchBuffer[i] = sum / Float(channelCount)
                }
            }
            handler(scratchBuffer, frameCount)
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

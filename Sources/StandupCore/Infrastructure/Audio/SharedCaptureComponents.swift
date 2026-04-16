/// Shared audio capture infrastructure used by both capture engine implementations.
///
/// Extracts the common mic tap installation, writer loop, and chunk writing
/// logic to eliminate duplication between AudioCaptureEngine and VirtualDeviceCaptureEngine.

import AVFAudio
import Foundation
import os

// MARK: - Chunk Writer

/// Writes audio from ring buffers to PCM chunk files on disk.
/// Used by both ScreenCaptureKit and VirtualDevice capture engines.
final class ChunkWriter: @unchecked Sendable {
    // SAFETY: @unchecked Sendable — accessed from a single writer Task only,
    // except `isRunning` which uses atomic access via OSAllocatedUnfairLock.

    private let sessionDirectory: String
    private let micRingBuffer: RingBuffer
    private let systemRingBuffer: RingBuffer
    private let startTimestamp: TimeInterval
    private var chunkIndex = 0
    private let _isRunning = OSAllocatedUnfairLock(initialState: false)

    weak var delegate: AudioCaptureDelegate?

    private static let writerSleepNanoseconds: UInt64 = 100_000_000 // 100ms

    var isRunning: Bool {
        get { _isRunning.withLock { $0 } }
        set { _isRunning.withLock { $0 = newValue } }
    }

    init(sessionDirectory: String, micRingBuffer: RingBuffer, systemRingBuffer: RingBuffer, startTimestamp: TimeInterval) {
        self.sessionDirectory = sessionDirectory
        self.micRingBuffer = micRingBuffer
        self.systemRingBuffer = systemRingBuffer
        self.startTimestamp = startTimestamp
    }

    /// Run the writer loop, draining ring buffers into chunk files.
    /// Call from a detached Task. Exits when `isRunning` becomes false
    /// and both buffers are drained.
    func writerLoop() async {
        let chunkFrames = Int(AudioFormat.standard.sampleRate)
        let micTemp = UnsafeMutablePointer<Float>.allocate(capacity: chunkFrames)
        let sysTemp = UnsafeMutablePointer<Float>.allocate(capacity: chunkFrames)
        defer {
            micTemp.deallocate()
            sysTemp.deallocate()
        }

        while isRunning || micRingBuffer.availableToRead > 0 || systemRingBuffer.availableToRead > 0 {
            let micRead = micRingBuffer.read(into: micTemp, count: chunkFrames)
            let sysRead = systemRingBuffer.read(into: sysTemp, count: chunkFrames)

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
                try? await Task.sleep(nanoseconds: Self.writerSleepNanoseconds)
            }
        }
    }

    private func writeChunk(from buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: AudioChannel, index: Int) {
        let chunksDir = (sessionDirectory as NSString).appendingPathComponent("chunks")
        let filename = String(format: "%06d_%@.pcm", index, channel.rawValue)
        let path = (chunksDir as NSString).appendingPathComponent(filename)
        let data = Data(bytes: buffer, count: frameCount * MemoryLayout<Float>.size)
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            delegate?.didEncounterError(error)
            return
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - startTimestamp
        let chunk = AudioChunk(
            index: index,
            channel: channel,
            format: AudioFormat.standard,
            frameCount: frameCount,
            timestamp: elapsed,
            path: path
        )
        delegate?.didCaptureChunk(chunk)
    }
}

// MARK: - Mic Tap Installer

/// Installs an audio tap on an AVAudioEngine's input node, handling format
/// conversion and writing to a ring buffer through a live plugin chain.
enum MicTapInstaller {
    /// Install a tap on the engine's input node that processes audio through
    /// the chain and writes to the ring buffer.
    static func install(
        on engine: AVAudioEngine,
        chain: LivePluginChain,
        ringBuffer: RingBuffer,
        isRunning: @escaping @Sendable () -> Bool
    ) {
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormat.standard.sampleRate,
            channels: 1,
            interleaved: false
        )!

        let needsConversion = nativeFormat.sampleRate != targetFormat.sampleRate
            || nativeFormat.channelCount != targetFormat.channelCount

        if needsConversion, let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) {
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { buffer, _ in
                guard isRunning() else { return }

                let frameCapacity = AVAudioFrameCount(
                    Double(buffer.frameLength) * targetFormat.sampleRate / nativeFormat.sampleRate
                )
                guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }

                var error: NSError?
                var provided = false
                converter.convert(to: converted, error: &error) { _, outStatus in
                    if provided { outStatus.pointee = .noDataNow; return nil }
                    provided = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                guard error == nil, converted.frameLength > 0 else { return }
                guard let floatData = converted.floatChannelData?[0] else { return }
                let frameCount = Int(converted.frameLength)
                chain.process(buffer: floatData, frameCount: frameCount)
                ringBuffer.write(from: floatData, count: frameCount)
            }
        } else {
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                guard isRunning() else { return }
                guard let floatData = buffer.floatChannelData?[0] else { return }
                let frameCount = Int(buffer.frameLength)
                chain.process(buffer: floatData, frameCount: frameCount)
                ringBuffer.write(from: floatData, count: frameCount)
            }
        }
    }
}

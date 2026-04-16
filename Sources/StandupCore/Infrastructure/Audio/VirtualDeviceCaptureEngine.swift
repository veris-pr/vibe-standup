/// Infrastructure: Audio capture using a virtual audio device for system audio.
///
/// Uses AVAudioEngine to capture from a named virtual device (e.g., BlackHole)
/// for system audio, plus the default mic for the user's voice.
/// This avoids ScreenCaptureKit entirely — no Screen Recording permission needed.
///
/// Advantages over ScreenCaptureKit:
/// - Per-app audio routing (user chooses which app routes to virtual device)
/// - No monthly permission re-auth on macOS Sequoia
/// - "Set once, forget" — once configured, sessions auto-capture
///
/// Requires: A virtual audio device like BlackHole (`brew install blackhole-2ch`)

@preconcurrency import AVFAudio
import CoreAudio
import Foundation

public final class VirtualDeviceCaptureEngine: AudioCapturePort, @unchecked Sendable {
    public static let defaultFormat = AudioFormat.standard

    private let sessionDirectory: String
    private let micChain: LivePluginChain
    private let systemChain: LivePluginChain
    private let micRingBuffer: RingBuffer
    private let systemRingBuffer: RingBuffer
    private let virtualDeviceName: String

    private var micEngine: AVAudioEngine?
    private var systemEngine: AVAudioEngine?
    private var writerTask: Task<Void, Never>?
    private var isRunning = false
    private var chunkIndex = 0
    private let startTimestamp: TimeInterval

    public weak var delegate: AudioCaptureDelegate?

    public init(
        sessionDirectory: String,
        micChain: LivePluginChain,
        systemChain: LivePluginChain,
        virtualDeviceName: String = "BlackHole 2ch"
    ) {
        let bufferCapacity = Int(Self.defaultFormat.sampleRate * 2)
        self.sessionDirectory = sessionDirectory
        self.micChain = micChain
        self.systemChain = systemChain
        self.micRingBuffer = RingBuffer(minimumCapacity: bufferCapacity)
        self.systemRingBuffer = RingBuffer(minimumCapacity: bufferCapacity)
        self.virtualDeviceName = virtualDeviceName
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
        try startVirtualDeviceCapture()

        writerTask = Task.detached(priority: .utility) { [weak self] in
            await self?.writerLoop()
        }
    }

    public func stop() async {
        isRunning = false

        micEngine?.stop()
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine = nil

        systemEngine?.stop()
        systemEngine?.inputNode.removeTap(onBus: 0)
        systemEngine = nil

        writerTask?.cancel()
        writerTask = nil
    }

    // MARK: - Mic (Default Input Device)

    private func startMicCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.defaultFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!

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
        self.micEngine = engine
    }

    // MARK: - Virtual Device (System Audio)

    private func startVirtualDeviceCapture() throws {
        guard let deviceID = findAudioDevice(named: virtualDeviceName) else {
            throw AudioCaptureError.virtualDeviceNotFound(virtualDeviceName)
        }

        let engine = AVAudioEngine()

        // Set the virtual device as this engine's input
        var deviceIDVar = deviceID
        let status = AudioUnitSetProperty(
            engine.inputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceIDVar,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioCaptureError.virtualDeviceConfigFailed(virtualDeviceName, status)
        }

        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.defaultFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!

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
                self.systemChain.process(buffer: floatData, frameCount: frameCount)
                self.systemRingBuffer.write(from: floatData, count: frameCount)
            }
        } else {
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
                guard let self, self.isRunning else { return }
                guard let floatData = buffer.floatChannelData?[0] else { return }
                let frameCount = Int(buffer.frameLength)
                self.systemChain.process(buffer: floatData, frameCount: frameCount)
                self.systemRingBuffer.write(from: floatData, count: frameCount)
            }
        }

        engine.prepare()
        try engine.start()
        self.systemEngine = engine
    }

    // MARK: - Core Audio Device Lookup

    private func findAudioDevice(named name: String) -> AudioDeviceID? {
        var propAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddress, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return nil }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddress, 0, nil, &dataSize, &devices
        )
        guard status == noErr else { return nil }

        for deviceID in devices {
            if let deviceName = getDeviceName(deviceID), deviceName == name {
                return deviceID
            }
        }
        return nil
    }

    private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        var nameRef: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &nameRef) { ptr in
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &dataSize, ptr)
        }
        guard status == noErr, let ref = nameRef else { return nil }
        return ref.takeUnretainedValue() as String
    }

    // MARK: - Writer Loop (shared with AudioCaptureEngine)

    private func writerLoop() async {
        let chunkFrames = Int(Self.defaultFormat.sampleRate)
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
                try? await Task.sleep(nanoseconds: 100_000_000)
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

    // MARK: - Static Helpers

    /// List available virtual audio devices for user selection.
    public static func availableVirtualDevices() -> [String] {
        var propAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddress, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddress, 0, nil, &dataSize, &devices
        )
        guard status == noErr else { return [] }

        // Virtual devices typically have names like "BlackHole", "Loopback", "Soundflower"
        let knownVirtualPrefixes = ["BlackHole", "Loopback", "Soundflower", "VB-Audio", "CABLE"]
        var result: [String] = []

        for deviceID in devices {
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
            var nameRef: Unmanaged<CFString>?
            let s = withUnsafeMutablePointer(to: &nameRef) { ptr in
                AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, ptr)
            }
            if s == noErr, let ref = nameRef {
                let nameStr = ref.takeUnretainedValue() as String
                if knownVirtualPrefixes.contains(where: { nameStr.hasPrefix($0) }) {
                    result.append(nameStr)
                }
            }
        }
        return result
    }
}

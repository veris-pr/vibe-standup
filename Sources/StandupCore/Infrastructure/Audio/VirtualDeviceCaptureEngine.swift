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
    // SAFETY: @unchecked Sendable — start/stop called from main actor,
    // audio callbacks run on audio thread, writer on utility thread.

    private let sessionDirectory: String
    private let micChain: LivePluginChain
    private let systemChain: LivePluginChain
    private let micRingBuffer: RingBuffer
    private let systemRingBuffer: RingBuffer
    private let virtualDeviceName: String
    private let chunkWriter: ChunkWriter

    private var micEngine: AVAudioEngine?
    private var systemEngine: AVAudioEngine?
    private var writerTask: Task<Void, Never>?

    public weak var delegate: AudioCaptureDelegate? {
        didSet { chunkWriter.delegate = delegate }
    }

    public init(
        sessionDirectory: String,
        micChain: LivePluginChain,
        systemChain: LivePluginChain,
        virtualDeviceName: String = "BlackHole 2ch"
    ) {
        let bufferSeconds = 2
        let bufferCapacity = Int(AudioFormat.standard.sampleRate) * bufferSeconds
        self.sessionDirectory = sessionDirectory
        self.micChain = micChain
        self.systemChain = systemChain
        self.micRingBuffer = RingBuffer(minimumCapacity: bufferCapacity)
        self.systemRingBuffer = RingBuffer(minimumCapacity: bufferCapacity)
        self.virtualDeviceName = virtualDeviceName
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
        try startVirtualDeviceCapture()

        writerTask = Task.detached(priority: .utility) { [chunkWriter] in
            await chunkWriter.writerLoop()
        }
    }

    public func stop() async {
        chunkWriter.isRunning = false

        micEngine?.stop()
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine = nil

        systemEngine?.stop()
        systemEngine?.inputNode.removeTap(onBus: 0)
        systemEngine = nil

        await writerTask?.value
        writerTask = nil
    }

    // MARK: - Mic (Default Input Device)

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
        self.micEngine = engine
    }

    // MARK: - Virtual Device (System Audio)

    private func startVirtualDeviceCapture() throws {
        guard let deviceID = CoreAudioDeviceLookup.findDevice(named: virtualDeviceName) else {
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

        MicTapInstaller.install(
            on: engine,
            chain: systemChain,
            ringBuffer: systemRingBuffer,
            isRunning: { [chunkWriter] in chunkWriter.isRunning }
        )
        engine.prepare()
        try engine.start()
        self.systemEngine = engine
    }

    // MARK: - Static Helpers

    /// List available virtual audio devices for user selection.
    public static func availableVirtualDevices() -> [String] {
        CoreAudioDeviceLookup.availableVirtualDevices()
    }
}

// MARK: - Core Audio Device Lookup

enum CoreAudioDeviceLookup {
    /// Find an audio device by exact name.
    static func findDevice(named name: String) -> AudioDeviceID? {
        for (id, deviceName) in allDevices() {
            if deviceName == name { return id }
        }
        return nil
    }

    /// List virtual audio devices (BlackHole, Loopback, Soundflower, etc.).
    static func availableVirtualDevices() -> [String] {
        let knownVirtualPrefixes = ["BlackHole", "Loopback", "Soundflower", "VB-Audio", "CABLE"]
        return allDevices()
            .map(\.name)
            .filter { name in knownVirtualPrefixes.contains(where: { name.hasPrefix($0) }) }
    }

    /// Enumerate all audio devices on the system.
    private static func allDevices() -> [(id: AudioDeviceID, name: String)] {
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

        return devices.compactMap { deviceID -> (AudioDeviceID, String)? in
            guard let name = deviceName(for: deviceID) else { return nil }
            return (deviceID, name)
        }
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
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
}

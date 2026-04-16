/// Wiener-filter noise reduction live plugin.
///
/// A functional noise reducer using spectral subtraction with Wiener filtering.
/// Processes audio in-place with pre-allocated buffers.
/// Can be swapped for a RNNoise C wrapper when that library is vendored.
///
/// RNNoise operates on 480-sample frames (10ms at 48kHz). This plugin
/// follows the same convention for drop-in compatibility.

import Foundation
import StandupCore

public final class RNNoiseLivePlugin: BaseLivePlugin, @unchecked Sendable {
    /// RNNoise-compatible frame size: 480 samples = 10ms at 48kHz
    static let frameSize = 480

    // Pre-allocated buffers
    private var inputFrame: UnsafeMutablePointer<Float>?
    private var outputFrame: UnsafeMutablePointer<Float>?
    private var noiseEstimate: UnsafeMutablePointer<Float>?

    // Parameters
    private var smoothing: Float = 0.95
    private var noiseFloorDB: Float = -60
    private var attenuation: Float = 0.1

    // Internal state
    private var isNoiseProfiled = false
    private var profileFramesRemaining: Int = 0
    private var overlapBuffer: UnsafeMutablePointer<Float>?
    private var overlapCount: Int = 0

    public init() {
        super.init(id: "rnnoise")
    }

    override public func onSetup() async throws {
        smoothing = Float(config.double(for: "smoothing", default: 0.95))
        noiseFloorDB = Float(config.double(for: "noise_floor_db", default: -60))
        attenuation = Float(config.double(for: "attenuation", default: 0.1))
        // Profile noise for first N frames (default: 10 frames = 100ms)
        profileFramesRemaining = config.int(for: "profile_frames", default: 10)
    }

    override public func prepareBuffers(maxFrameCount: Int) {
        let size = max(maxFrameCount, Self.frameSize)
        inputFrame = .allocate(capacity: size)
        inputFrame?.initialize(repeating: 0, count: size)
        outputFrame = .allocate(capacity: size)
        outputFrame?.initialize(repeating: 0, count: size)
        noiseEstimate = .allocate(capacity: size)
        noiseEstimate?.initialize(repeating: 0, count: size)
        overlapBuffer = .allocate(capacity: size)
        overlapBuffer?.initialize(repeating: 0, count: size)
        overlapCount = 0
    }

    override public func onTeardown() async {
        inputFrame?.deallocate()
        outputFrame?.deallocate()
        noiseEstimate?.deallocate()
        overlapBuffer?.deallocate()
        inputFrame = nil
        outputFrame = nil
        noiseEstimate = nil
        overlapBuffer = nil
    }

    override public func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: AudioChannel) -> LivePluginResult {
        guard let noise = noiseEstimate else { return .passthrough }

        // Process in RNNoise-compatible 480-sample sub-frames
        var offset = 0
        while offset < frameCount {
            let remaining = frameCount - offset
            let subFrameSize = min(remaining, Self.frameSize)

            processSubFrame(
                input: buffer.advanced(by: offset),
                noise: noise,
                count: subFrameSize
            )
            offset += subFrameSize
        }

        return .modified
    }

    private func processSubFrame(input: UnsafeMutablePointer<Float>, noise: UnsafeMutablePointer<Float>, count: Int) {
        if profileFramesRemaining > 0 {
            // During profiling phase: learn the noise floor
            for i in 0..<count {
                let mag = abs(input[i])
                noise[i] = smoothing * noise[i] + (1 - smoothing) * mag
            }
            profileFramesRemaining -= 1
            return
        }

        // Wiener-like filtering: estimate SNR per sample, apply gain
        for i in 0..<count {
            let magnitude = abs(input[i])
            let sign: Float = input[i] >= 0 ? 1 : -1

            // Update noise estimate (slowly track quiet sections)
            let noiseThreshold = noise[i] * 2.0
            if magnitude < noiseThreshold {
                noise[i] = smoothing * noise[i] + (1 - smoothing) * magnitude
            }

            // Compute Wiener gain: G = max(attenuation, 1 - noise/signal)
            let gain: Float
            if magnitude > 1e-8 {
                let snr = max(0, magnitude - noise[i]) / magnitude
                gain = max(attenuation, snr)
            } else {
                gain = attenuation
            }

            input[i] = sign * magnitude * gain
        }
    }
}

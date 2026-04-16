/// Audio normalization live plugin — applies gain to reach a target loudness.
///
/// Uses a simple moving-average RMS tracker and adjusts gain smoothly
/// to avoid clipping and sudden volume changes.

import Foundation
import StandupCore

public final class NormalizeLivePlugin: LivePlugin, @unchecked Sendable {
    public let id = "normalize"
    public let version = "1.0.0"

    // Target RMS level (linear)
    private var targetRMS: Float = 0.1 // ~-20 dBFS default
    // Current smoothed gain
    private var currentGain: Float = 1.0
    // Smoothing factor (0-1, higher = faster response)
    private let smoothing: Float = 0.05
    // Max gain to prevent amplifying silence
    private var maxGain: Float = 10.0
    // Min gain to prevent over-attenuation
    private let minGain: Float = 0.1

    public init() {}

    public func setup(config: PluginConfig) async throws {
        let targetLUFS = config.double(for: "target_lufs", default: -20)
        // Rough LUFS → linear RMS conversion
        targetRMS = Float(pow(10.0, targetLUFS / 20.0))
        maxGain = Float(config.double(for: "max_gain", default: 10))
    }

    public func teardown() async {}

    public func prepareBuffers(maxFrameCount: Int) {
        // No scratch buffers needed
    }

    public func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: AudioChannel) -> LivePluginResult {
        // Compute current RMS
        var sumSquares: Float = 0
        for i in 0..<frameCount {
            let sample = buffer[i]
            sumSquares += sample * sample
        }
        let rms = (sumSquares / Float(frameCount)).squareRoot()

        // Avoid division by near-zero
        guard rms > 1e-6 else { return .passthrough }

        // Compute desired gain
        var desiredGain = targetRMS / rms
        desiredGain = min(desiredGain, maxGain)
        desiredGain = max(desiredGain, minGain)

        // Smooth gain transition to avoid clicks
        currentGain += smoothing * (desiredGain - currentGain)

        // Apply gain
        for i in 0..<frameCount {
            buffer[i] *= currentGain
            // Soft clip at ±1.0 using tanh
            if buffer[i] > 1.0 || buffer[i] < -1.0 {
                buffer[i] = tanhf(buffer[i])
            }
        }

        return .modified
    }
}

// Use C tanhf for performance
@_silgen_name("tanhf")
private func tanhf(_ x: Float) -> Float

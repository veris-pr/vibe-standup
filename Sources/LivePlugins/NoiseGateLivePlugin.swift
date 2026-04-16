/// Noise gate live plugin — silences audio below a dB threshold.
///
/// Computes RMS energy per frame and mutes if below threshold.
/// Zero allocations in the process path.

import Foundation
import StandupCore

public final class NoiseGateLivePlugin: LivePlugin, @unchecked Sendable {
    public let id = "noise-gate"
    public let version = "1.0.0"

    private var thresholdLinear: Float = 0.001 // ~-60 dB default
    private var isOpen = false
    // Hysteresis: gate stays open for this many frames after signal drops
    private var holdFrames: Int = 4800 // 100ms at 48kHz
    private var holdCounter: Int = 0

    public init() {}

    public func setup(config: PluginConfig) async throws {
        let thresholdDB = config.double(for: "threshold_db", default: -60)
        thresholdLinear = Float(pow(10.0, thresholdDB / 20.0))
        let holdMs = config.double(for: "hold_ms", default: 100)
        holdFrames = Int(48000 * holdMs / 1000)
    }

    public func teardown() async {}

    public func prepareBuffers(maxFrameCount: Int) {
        // No scratch buffers needed
    }

    public func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: AudioChannel) -> LivePluginResult {
        // Compute RMS energy
        var sumSquares: Float = 0
        for i in 0..<frameCount {
            let sample = buffer[i]
            sumSquares += sample * sample
        }
        let rms = (sumSquares / Float(frameCount)).squareRoot()

        if rms >= thresholdLinear {
            isOpen = true
            holdCounter = holdFrames
            return .passthrough
        }

        if holdCounter > 0 {
            holdCounter -= frameCount
            return .passthrough
        }

        isOpen = false
        return .mute
    }
}

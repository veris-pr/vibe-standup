/// Noise gate strategy — silences audio below a dB threshold.
///
/// Uses RMS energy detection with a hold time to avoid rapid gate flapping.

import Foundation
import StandupCore

public final class NoiseGatePlugin: BaseLivePlugin, @unchecked Sendable {
    private var thresholdLinear: Float = 0.001
    private var holdFrames: Int = 4800
    private var holdCounter: Int = 0

    public init() {
        super.init(id: "noise-gate")
    }

    override public func validate(config: PluginConfig) throws {
        let db = config.double(for: "threshold_db", default: -60)
        if db > 0 { throw NoiseReductionError.invalidThreshold(db) }
    }

    override public func onSetup() async throws {
        let thresholdDB = config.double(for: "threshold_db", default: -60)
        thresholdLinear = Float(pow(10.0, thresholdDB / 20.0))
        let holdMs = config.double(for: "hold_ms", default: 100)
        holdFrames = Int(48000 * holdMs / 1000)
    }

    override public func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: AudioChannel) -> LivePluginResult {
        var sumSquares: Float = 0
        for i in 0..<frameCount {
            let s = buffer[i]
            sumSquares += s * s
        }
        let rms = (sumSquares / Float(frameCount)).squareRoot()

        if rms >= thresholdLinear {
            holdCounter = holdFrames
            return .passthrough
        }
        if holdCounter > 0 {
            holdCounter -= frameCount
            return .passthrough
        }
        return .mute
    }
}

enum NoiseReductionError: Error {
    case invalidThreshold(Double)
}

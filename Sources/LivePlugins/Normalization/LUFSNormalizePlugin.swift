/// LUFS normalization strategy — targets a specific loudness level with smooth gain.

import Foundation
import StandupCore

public final class LUFSNormalizePlugin: BaseLivePlugin, @unchecked Sendable {
    private var targetRMS: Float = 0.1
    private var currentGain: Float = 1.0
    private let smoothing: Float = 0.05
    private var maxGain: Float = 10.0
    private let minGain: Float = 0.1

    public init() {
        super.init(id: "lufs-normalize")
    }

    override public func onSetup() async throws {
        let targetLUFS = config.double(for: "target_lufs", default: -20)
        targetRMS = Float(pow(10.0, targetLUFS / 20.0))
        maxGain = Float(config.double(for: "max_gain", default: 10))
    }

    override public func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: AudioChannel) -> LivePluginResult {
        var sumSquares: Float = 0
        for i in 0..<frameCount {
            let s = buffer[i]
            sumSquares += s * s
        }
        let rms = (sumSquares / Float(frameCount)).squareRoot()
        guard rms > 1e-6 else { return .passthrough }

        var desired = targetRMS / rms
        desired = min(desired, maxGain)
        desired = max(desired, minGain)
        currentGain += smoothing * (desired - currentGain)

        for i in 0..<frameCount {
            buffer[i] *= currentGain
            if buffer[i] > 1.0 || buffer[i] < -1.0 {
                buffer[i] = tanh(buffer[i])
            }
        }
        return .modified
    }
}

private func tanh(_ x: Float) -> Float {
    Foundation.tanh(Double(x)).isNaN ? 0 : Float(Foundation.tanh(Double(x)))
}

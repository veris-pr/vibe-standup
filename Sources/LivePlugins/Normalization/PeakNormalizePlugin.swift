/// Peak normalization strategy — scales audio so the peak reaches a target level.

import Foundation
import StandupCore

public final class PeakNormalizePlugin: BaseLivePlugin, @unchecked Sendable {
    private var targetPeak: Float = 0.9
    private var currentGain: Float = 1.0
    private let smoothing: Float = 0.1

    public init() {
        super.init(id: "peak-normalize")
    }

    override public func onSetup() async throws {
        targetPeak = Float(config.double(for: "target_peak", default: 0.9))
    }

    override public func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: AudioChannel) -> LivePluginResult {
        var maxSample: Float = 0
        for i in 0..<frameCount {
            maxSample = max(maxSample, abs(buffer[i]))
        }
        guard maxSample > 1e-6 else { return .passthrough }

        let desired = targetPeak / maxSample
        currentGain += smoothing * (desired - currentGain)

        for i in 0..<frameCount {
            buffer[i] *= currentGain
        }
        return .modified
    }
}

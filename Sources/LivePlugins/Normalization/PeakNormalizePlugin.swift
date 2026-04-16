/// Peak normalization strategy — scales audio so the peak reaches a target level.

import Foundation
import StandupCore

public final class PeakNormalizePlugin: BaseLivePlugin, @unchecked Sendable {
    // SAFETY: Inherits Sendable contract from BaseLivePlugin.
    private var targetPeak: Float = 0.9
    private var currentGain: Float = 1.0
    private let smoothing: Float = 0.1
    private let maxGain: Float = 10.0
    private let minGain: Float = 0.1

    public init() {
        super.init(id: "peak-normalize")
    }

    override public func onSetup() async throws {
        targetPeak = Float(config.double(for: "target_peak", default: 0.9))
    }

    override public func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: AudioChannel) -> LivePluginResult {
        guard frameCount > 0 else { return .passthrough }

        var maxSample: Float = 0
        for i in 0..<frameCount {
            maxSample = max(maxSample, abs(buffer[i]))
        }
        guard maxSample > 1e-6 else { return .passthrough }

        let desired = min(max(targetPeak / maxSample, minGain), maxGain)
        currentGain += smoothing * (desired - currentGain)

        for i in 0..<frameCount {
            buffer[i] = min(max(buffer[i] * currentGain, -1.0), 1.0)
        }
        return .modified
    }
}

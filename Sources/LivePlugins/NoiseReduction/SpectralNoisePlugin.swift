/// Spectral noise reduction strategy.
///
/// Uses spectral subtraction to remove stationary noise.
/// This is a simplified implementation — a production version would use
/// a proper noise profile estimation phase.

import StandupCore

public final class SpectralNoisePlugin: BaseLivePlugin, @unchecked Sendable {
    private var smoothingFactor: Float = 0.98
    private var noiseFloor: Float = 0.001

    // Pre-allocated scratch buffer for noise estimation
    private var noiseEstimate: UnsafeMutablePointer<Float>?
    private var maxFrames: Int = 0

    public init() {
        super.init(id: "spectral-noise")
    }

    override public func onSetup() async throws {
        smoothingFactor = Float(config.double(for: "smoothing", default: 0.98))
        noiseFloor = Float(config.double(for: "noise_floor", default: 0.001))
    }

    override public func prepareBuffers(maxFrameCount: Int) {
        maxFrames = maxFrameCount
        noiseEstimate?.deallocate()
        noiseEstimate = .allocate(capacity: maxFrameCount)
        noiseEstimate?.initialize(repeating: 0, count: maxFrameCount)
    }

    override public func onTeardown() async {
        noiseEstimate?.deallocate()
        noiseEstimate = nil
    }

    override public func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: AudioChannel) -> LivePluginResult {
        guard let estimate = noiseEstimate, frameCount <= maxFrames else { return .passthrough }

        // Simple spectral subtraction in time domain (simplified).
        // Update noise estimate with exponential moving average of quiet samples.
        // Subtract estimated noise from signal.
        for i in 0..<frameCount {
            let magnitude = abs(buffer[i])
            if magnitude < noiseFloor {
                // Update noise estimate during quiet sections
                estimate[i] = smoothingFactor * estimate[i] + (1 - smoothingFactor) * magnitude
            }
            // Subtract noise estimate
            let sign: Float = buffer[i] >= 0 ? 1 : -1
            let cleaned = max(0, magnitude - estimate[i])
            buffer[i] = sign * cleaned
        }

        return .modified
    }
}

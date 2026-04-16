/// Infrastructure: Factory for creating audio capture engines by strategy.
///
/// Follows the same factory pattern used for plugins. The capture source
/// is selected at session start — either via CLI flag or pipeline YAML.

import Foundation

public enum AudioCaptureFactory {
    /// Create the appropriate capture engine for the given source strategy.
    public static func create(
        source: AudioCaptureSource,
        sessionDirectory: String,
        micChain: LivePluginChain,
        systemChain: LivePluginChain,
        virtualDeviceName: String? = nil
    ) -> AudioCapturePort {
        switch source {
        case .screenCapture:
            return AudioCaptureEngine(
                sessionDirectory: sessionDirectory,
                micChain: micChain,
                systemChain: systemChain
            )
        case .virtualDevice:
            return VirtualDeviceCaptureEngine(
                sessionDirectory: sessionDirectory,
                micChain: micChain,
                systemChain: systemChain,
                virtualDeviceName: virtualDeviceName ?? "BlackHole 2ch"
            )
        }
    }
}

/// Shared error types for Bedrock plugins.

import Foundation

public enum BedrockError: Error, LocalizedError, Sendable {
    case missingConfig(String)
    case transcriptionFailed(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingConfig(let msg): "Bedrock config error: \(msg)"
        case .transcriptionFailed(let msg): "Bedrock transcription failed: \(msg)"
        case .invalidResponse(let msg): "Bedrock response error: \(msg)"
        }
    }
}

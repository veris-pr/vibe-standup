/// Domain types for the Pipeline bounded context.
///
/// A pipeline defines what happens during and after a capture session:
/// which live plugins run in the audio loop, and which stages run post-session.

import Foundation

// MARK: - Pipeline Definition (Value Object)

public struct PipelineDefinition: Sendable, Equatable {
    public let name: String
    public let description: String
    public let liveChains: LiveChainConfig
    public let stages: [StageDefinition]

    public init(name: String, description: String = "", liveChains: LiveChainConfig = LiveChainConfig(), stages: [StageDefinition] = []) {
        self.name = name
        self.description = description
        self.liveChains = liveChains
        self.stages = stages
    }

    /// A pipeline with no live plugins and no stages — just captures audio.
    public static func captureOnly(name: String) -> PipelineDefinition {
        PipelineDefinition(name: name, description: "Capture-only pipeline")
    }
}

// MARK: - Live Chain Config

public struct LiveChainConfig: Sendable, Equatable {
    public let mic: [PluginRef]
    public let system: [PluginRef]

    public init(mic: [PluginRef] = [], system: [PluginRef] = []) {
        self.mic = mic
        self.system = system
    }
}

// MARK: - Plugin Reference (used in YAML definitions)

/// A reference to a plugin with its configuration. Used in pipeline YAML.
public struct PluginRef: Sendable, Equatable {
    public let pluginId: String
    public let config: [String: String]

    public init(pluginId: String, config: [String: String] = [:]) {
        self.pluginId = pluginId
        self.config = config
    }
}

// MARK: - Stage Definition

public struct StageDefinition: Sendable, Equatable {
    public let id: String
    public let pluginId: String
    public let inputs: [String]
    public let config: [String: String]

    public init(id: String, pluginId: String, inputs: [String] = [], config: [String: String] = [:]) {
        self.id = id
        self.pluginId = pluginId
        self.inputs = inputs
        self.config = config
    }
}

// MARK: - Artifact (Value Object)

/// Types of artifacts that stage plugins produce and consume.
public enum ArtifactType: String, Sendable, Codable {
    case audioChunks = "audio_chunks"
    case transcriptionSegments = "transcription_segments"
    case diarizationLabels = "diarization_labels"
    case cleanTranscript = "clean_transcript"
    case comicPanels = "comic_panels"
    case comicOutput = "comic_output"
    case custom = "custom"
}

/// Reference to an artifact produced by a pipeline stage.
public struct Artifact: Sendable, Codable, Equatable {
    public let stageId: String
    public let type: ArtifactType
    public let path: String

    public init(stageId: String, type: ArtifactType, path: String) {
        self.stageId = stageId
        self.type = type
        self.path = path
    }
}

// MARK: - Pipeline Errors

public enum PipelineError: Error, LocalizedError, Sendable {
    case invalidYAML
    case pluginNotFound(String)
    case cyclicDependency
    case stageExecutionFailed(stageId: String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .invalidYAML: "Invalid pipeline YAML"
        case .pluginNotFound(let id): "Plugin not found: \(id)"
        case .cyclicDependency: "Cyclic dependency in pipeline stages"
        case .stageExecutionFailed(let id, let err): "Stage '\(id)' failed: \(err.localizedDescription)"
        }
    }
}

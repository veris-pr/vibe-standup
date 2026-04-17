/// Domain types for the Pipeline bounded context.
///
/// A pipeline defines what happens during and after a capture session:
/// which live plugins run in the audio loop, and which stages run post-session.

import Foundation

// MARK: - Pipeline Definition (Value Object)

public struct PipelineDefinition: Sendable, Equatable {
    public let name: String
    public let description: String
    public let captureSource: AudioCaptureSource?
    public let virtualDeviceName: String?
    public let liveChains: LiveChainConfig
    public let stages: [StageDefinition]

    public init(name: String, description: String = "", captureSource: AudioCaptureSource? = nil, virtualDeviceName: String? = nil, liveChains: LiveChainConfig = LiveChainConfig(), stages: [StageDefinition] = []) {
        self.name = name
        self.description = description
        self.captureSource = captureSource
        self.virtualDeviceName = virtualDeviceName
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
    case comicScript = "comic_script"
    case panelImages = "panel_images"
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

// MARK: - Shared Stage Plugin Value Types

/// Identifies the speaker in a diarized segment.
public enum Speaker: String, Sendable, Codable, CaseIterable {
    case me
    case them
    case silence
    case unknown
}

/// Mood detected from transcript text, used for comic panel rendering.
public enum Mood: String, Sendable, Codable, CaseIterable {
    case excited
    case proud
    case frustrated
    case thinking
    case asking
    case happy
    case neutral

    public var emoji: String {
        switch self {
        case .excited: "🎉"
        case .proud: "💪"
        case .frustrated: "😤"
        case .thinking: "🤔"
        case .asking: "❓"
        case .happy: "😊"
        case .neutral: "💬"
        }
    }
}

/// Size category for a comic panel.
public enum PanelSize: String, Sendable, Codable {
    case large
    case normal
}

/// A single segment of diarized audio with speaker attribution.
public struct DiarizationSegment: Sendable, Codable {
    public let startTime: Double
    public var endTime: Double
    public let speaker: Speaker

    public init(startTime: Double, endTime: Double, speaker: Speaker) {
        self.startTime = startTime
        self.endTime = endTime
        self.speaker = speaker
    }
}

/// A line of dialogue from the merged transcript.
public struct DialogueLine: Sendable, Codable {
    public let startTime: Double
    public var endTime: Double
    public let speaker: String
    public var text: String

    public init(startTime: Double, endTime: Double, speaker: String, text: String) {
        self.startTime = startTime
        self.endTime = endTime
        self.speaker = speaker
        self.text = text
    }
}

/// A comic panel definition — output of the formatter, input to the renderer.
public struct ComicPanel: Sendable, Codable {
    public let index: Int
    public let speaker: String
    public let text: String
    public let mood: Mood
    public let startTime: Double
    public let duration: Double
    public let importance: Double
    public let panelSize: PanelSize

    public init(index: Int, speaker: String, text: String, mood: Mood, startTime: Double, duration: Double, importance: Double, panelSize: PanelSize) {
        self.index = index
        self.speaker = speaker
        self.text = text
        self.mood = mood
        self.startTime = startTime
        self.duration = duration
        self.importance = importance
        self.panelSize = panelSize
    }
}

// MARK: - Comic Script Types (LLM-generated)

/// A superhero character assigned to a speaker.
public struct ComicCharacter: Sendable, Codable {
    public let speakerId: String
    public let heroName: String
    public let costume: String
    public let color: String

    public init(speakerId: String, heroName: String, costume: String, color: String) {
        self.speakerId = speakerId
        self.heroName = heroName
        self.costume = costume
        self.color = color
    }
}

/// A comic panel with scene description for image generation.
public struct ComicScriptPanel: Sendable, Codable {
    public let index: Int
    public let speaker: String
    public let heroName: String
    public let dialogue: String
    public let sceneDescription: String
    public let imagePrompt: String
    public let mood: Mood

    public init(index: Int, speaker: String, heroName: String, dialogue: String, sceneDescription: String, imagePrompt: String, mood: Mood) {
        self.index = index
        self.speaker = speaker
        self.heroName = heroName
        self.dialogue = dialogue
        self.sceneDescription = sceneDescription
        self.imagePrompt = imagePrompt
        self.mood = mood
    }
}

/// Full comic script output from the LLM.
public struct ComicScript: Sendable, Codable {
    public let title: String
    public let characters: [ComicCharacter]
    public let panels: [ComicScriptPanel]

    public init(title: String, characters: [ComicCharacter], panels: [ComicScriptPanel]) {
        self.title = title
        self.characters = characters
        self.panels = panels
    }
}

// MARK: - Pipeline State (persisted for resumability)

/// Status of a single stage in a pipeline run.
public enum StageStatus: String, Sendable, Codable {
    case pending
    case running
    case done
    case failed
}

/// Tracks per-stage progress so pipelines can resume after failures.
public struct StageState: Sendable, Codable {
    public let id: String
    public var status: StageStatus
    public var artifact: Artifact?
    public var error: String?
}

/// Persisted pipeline progress — written to `pipeline-state.json` in the session directory.
public struct PipelineState: Sendable, Codable {
    public let pipelineName: String
    public var stages: [StageState]

    public init(pipelineName: String, stages: [StageState]) {
        self.pipelineName = pipelineName
        self.stages = stages
    }

    static let fileName = "pipeline-state.json"

    public static func load(from sessionDirectory: String) -> PipelineState? {
        let path = (sessionDirectory as NSString).appendingPathComponent(fileName)
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(PipelineState.self, from: data)
    }

    public func save(to sessionDirectory: String) throws {
        let path = (sessionDirectory as NSString).appendingPathComponent(Self.fileName)
        let data = try JSONEncoder.prettyPipelineState.encode(self)
        try data.write(to: URL(fileURLWithPath: path))
    }

    public static func remove(from sessionDirectory: String) {
        let path = (sessionDirectory as NSString).appendingPathComponent(fileName)
        try? FileManager.default.removeItem(atPath: path)
    }
}

private extension JSONEncoder {
    static let prettyPipelineState: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

// MARK: - Pipeline Errors

public enum PipelineError: Error, LocalizedError, Sendable {
    case invalidYAML
    case missingField(String)
    case pluginNotFound(String)
    case stageExecutionFailed(stageId: String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .invalidYAML: "Invalid pipeline YAML"
        case .missingField(let field): "Missing required field '\(field)' in pipeline YAML"
        case .pluginNotFound(let id): "Plugin not found: \(id)"
        case .stageExecutionFailed(let id, let err): "Stage '\(id)' failed: \(err.localizedDescription)"
        }
    }
}

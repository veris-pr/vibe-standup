/// Transcript merger stage plugin.
///
/// Aligns transcription segments with diarization speaker labels
/// by timestamp to produce a clean, readable dialogue transcript.

import Foundation
import StandupCore

public final class TranscriptMergerPlugin: StagePlugin, @unchecked Sendable {
    public let id = "transcript-merger"
    public let version = "1.0.0"
    public let inputArtifacts: [ArtifactType] = [.transcriptionSegments, .diarizationLabels]
    public let outputArtifacts: [ArtifactType] = [.cleanTranscript]

    public init() {}

    public func setup(config: PluginConfig) async throws {}
    public func teardown() async {}

    public func execute(context: SessionContext) async throws -> [ArtifactRef] {
        let decoder = JSONDecoder()

        // Load transcription segments
        guard let transcriptionRef = context.inputArtifacts.values.first(where: {
            $0.type == .transcriptionSegments
        }) ?? context.inputArtifacts["transcribe"] else {
            throw MergerError.missingInput("transcription segments")
        }
        let transcriptionData = try Data(contentsOf: URL(fileURLWithPath: transcriptionRef.path))
        let segments = try decoder.decode([TranscriptionSegment].self, from: transcriptionData)

        // Load diarization labels
        guard let diarizationRef = context.inputArtifacts.values.first(where: {
            $0.type == .diarizationLabels
        }) ?? context.inputArtifacts["diarize"] else {
            throw MergerError.missingInput("diarization labels")
        }
        let diarizationData = try Data(contentsOf: URL(fileURLWithPath: diarizationRef.path))
        let speakers = try decoder.decode([SpeakerLabel].self, from: diarizationData)

        // Merge: for each transcription segment, find the overlapping speaker label
        var dialogueLines: [DialogueLine] = []
        for segment in segments {
            let midpoint = (segment.startTime + segment.endTime) / 2
            let speaker = speakers.first { midpoint >= $0.startTime && midpoint < $0.endTime }
            dialogueLines.append(DialogueLine(
                startTime: segment.startTime,
                endTime: segment.endTime,
                speaker: speaker?.speaker ?? "unknown",
                text: segment.text
            ))
        }

        // Merge adjacent lines from the same speaker
        var merged: [DialogueLine] = []
        for line in dialogueLines {
            if let last = merged.last, last.speaker == line.speaker {
                merged[merged.count - 1] = DialogueLine(
                    startTime: last.startTime,
                    endTime: line.endTime,
                    speaker: line.speaker,
                    text: last.text + " " + line.text
                )
            } else {
                merged.append(line)
            }
        }

        // Write output
        let outputDir = context.outputDirectory(for: id)
        let outputPath = (outputDir as NSString).appendingPathComponent("transcript.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(merged)
        try data.write(to: URL(fileURLWithPath: outputPath))

        return [ArtifactRef(stageId: id, type: .cleanTranscript, path: outputPath)]
    }
}

// MARK: - Input/Output Types

struct TranscriptionSegment: Codable {
    let startTime: Double
    let endTime: Double
    let text: String
}

struct SpeakerLabel: Codable {
    let startTime: Double
    let endTime: Double
    let speaker: String
}

struct DialogueLine: Codable {
    let startTime: Double
    var endTime: Double
    let speaker: String
    var text: String
}

enum MergerError: Error, LocalizedError {
    case missingInput(String)

    var errorDescription: String? {
        switch self {
        case .missingInput(let what): "Missing input: \(what)"
        }
    }
}

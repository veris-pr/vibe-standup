/// Transcript merger — aligns transcription segments with diarization labels.

import Foundation
import StandupCore

public final class TranscriptMergerPlugin: BaseStagePlugin, @unchecked Sendable {
    // SAFETY: Inherits Sendable contract from BaseStagePlugin.
    override public var inputArtifacts: [ArtifactType] { [.transcriptionSegments, .diarizationLabels] }
    override public var outputArtifacts: [ArtifactType] { [.cleanTranscript] }

    public init() {
        super.init(id: "transcript-merger")
    }

    override public func execute(context: StageContext) async throws -> [Artifact] {
        let decoder = JSONDecoder()

        guard let transcriptionRef = context.inputArtifacts.values.first(where: { $0.type == .transcriptionSegments })
                ?? context.inputArtifacts["transcribe"] else {
            throw MergerError.missingInput("transcription segments")
        }
        let segments = try decoder.decode(
            [TranscriptionSegment].self,
            from: Data(contentsOf: URL(fileURLWithPath: transcriptionRef.path))
        )

        guard let diarizationRef = context.inputArtifacts.values.first(where: { $0.type == .diarizationLabels })
                ?? context.inputArtifacts["diarize"] else {
            throw MergerError.missingInput("diarization labels")
        }
        let speakers = try decoder.decode(
            [DiarizationSegment].self,
            from: Data(contentsOf: URL(fileURLWithPath: diarizationRef.path))
        )

        // Merge: for each segment, find overlapping speaker label
        let lines: [DialogueLine] = segments.map { seg in
            let mid = (seg.startTime + seg.endTime) / 2
            let speaker = speakers.first { mid >= $0.startTime && mid < $0.endTime }
            return DialogueLine(startTime: seg.startTime, endTime: seg.endTime, speaker: speaker?.speaker.rawValue ?? "unknown", text: seg.text)
        }

        // Merge adjacent same-speaker lines
        var merged: [DialogueLine] = []
        for line in lines {
            if let last = merged.last, last.speaker == line.speaker {
                merged[merged.count - 1] = DialogueLine(
                    startTime: last.startTime, endTime: line.endTime,
                    speaker: line.speaker, text: last.text + " " + line.text
                )
            } else {
                merged.append(line)
            }
        }

        let outputDir = try ensureOutputDirectory(context: context)
        let outputPath = (outputDir as NSString).appendingPathComponent("transcript.json")
        try JSONEncoder.prettyEncoding.encode(merged).write(to: URL(fileURLWithPath: outputPath))

        return [Artifact(stageId: id, type: .cleanTranscript, path: outputPath)]
    }
}

// MARK: - Types

struct TranscriptionSegment: Codable {
    let startTime: Double
    let endTime: Double
    let text: String
}

enum MergerError: Error, LocalizedError, Sendable {
    case missingInput(String)
    var errorDescription: String? {
        switch self {
        case .missingInput(let what): "Missing input: \(what)"
        }
    }
}

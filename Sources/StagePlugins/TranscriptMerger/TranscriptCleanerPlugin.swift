/// LLM-powered transcript cleaner.
///
/// Two-pass approach:
/// 1. LLM cleans only the text field of each segment (remove repetitions, fix garbled words)
/// 2. Diarization labels are applied programmatically, then consecutive same-speaker lines merged
///
/// Falls back to programmatic merge if Ollama is unavailable.

import Foundation
import StandupCore

public final class TranscriptCleanerPlugin: BaseStagePlugin, @unchecked Sendable {
    override public var inputArtifacts: [ArtifactType] { [.transcriptionSegments, .diarizationLabels] }
    override public var outputArtifacts: [ArtifactType] { [.cleanTranscript] }

    private var model: String = "gemma4"
    private var ollamaURL: String = "http://localhost:11434"

    public init() {
        super.init(id: "transcript-cleaner")
    }

    override public func onSetup() async throws {
        model = config.string(for: "model", default: "gemma4")
        ollamaURL = config.string(for: "ollama_url", default: "http://localhost:11434")
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

        // Pass 1: Clean text via LLM (structure-preserving)
        let client = OllamaClient(baseURL: ollamaURL)
        let cleanedSegments: [TranscriptionSegment]

        if await client.isAvailable(model: model) {
            cleanedSegments = try await cleanTextWithLLM(client: client, segments: segments)
        } else {
            // Fallback: at least strip repetitions programmatically
            cleanedSegments = segments.map { seg in
                TranscriptionSegment(startTime: seg.startTime, endTime: seg.endTime, text: stripRepetitions(seg.text))
            }
        }

        // Pass 2: Apply diarization labels and merge consecutive same-speaker lines
        let dialogue = labelAndMerge(segments: cleanedSegments, speakers: speakers)

        let outputDir = try ensureOutputDirectory(context: context)
        let outputPath = (outputDir as NSString).appendingPathComponent("transcript.json")
        try JSONEncoder.prettyEncoding.encode(dialogue).write(to: URL(fileURLWithPath: outputPath))

        return [Artifact(stageId: context.stageId, type: .cleanTranscript, path: outputPath)]
    }

    // MARK: - Pass 1: LLM text cleanup (structure-preserving)

    private func cleanTextWithLLM(client: OllamaClient, segments: [TranscriptionSegment]) async throws -> [TranscriptionSegment] {
        // Pre-process: strip obvious repetitions before sending to LLM
        let preprocessed = segments.map { seg in
            TranscriptionSegment(startTime: seg.startTime, endTime: seg.endTime, text: stripRepetitions(seg.text))
        }

        let inputJSON = try JSONEncoder.prettyEncoding.encode(preprocessed)

        let system = """
        You are given a JSON array of transcription segments. Each object contains:
        - "startTime"
        - "endTime"
        - "text"

        Your task is to clean ONLY the "text" field.

        STRICT CONSTRAINTS:
        - Return valid JSON only. No explanations, no comments.
        - Do not change the JSON structure.
        - Do not add, remove, or reorder objects.
        - Do not modify "startTime" or "endTime".
        - Preserve the exact same number of objects.

        TEXT CLEANUP RULES:
        - Remove repeated words (e.g., "अगर अगर अगर" → "अगर").
        - Fix obvious spelling/phonetic errors only when highly confident.
        - Remove filler or noise words.
        - If a segment is too corrupted to fix, replace its "text" value with "(अस्पष्ट)".
        - Do not summarize.
        - Do not add new meaning.
        - Keep the original language (Hindi/Hinglish).
        """

        let response = try await client.generate(
            model: model,
            prompt: String(data: inputJSON, encoding: .utf8) ?? "[]",
            system: system
        )
        let jsonString = extractJSON(from: response)

        do {
            let cleaned = try JSONDecoder().decode([TranscriptionSegment].self, from: Data(jsonString.utf8))
            // Accept LLM output as long as it's valid — even if count differs slightly
            return cleaned.isEmpty ? preprocessed : cleaned
        } catch {
            return preprocessed
        }
    }

    // MARK: - Pass 2: Apply diarization + merge consecutive same-speaker lines

    private func labelAndMerge(segments: [TranscriptionSegment], speakers: [DiarizationSegment]) -> [DialogueLine] {
        let labeled = segments.map { seg -> DialogueLine in
            let mid = (seg.startTime + seg.endTime) / 2
            let speaker = speakers.first { mid >= $0.startTime && mid < $0.endTime }
            return DialogueLine(
                startTime: seg.startTime, endTime: seg.endTime,
                speaker: speaker?.speaker.rawValue ?? "unknown", text: seg.text
            )
        }

        var merged: [DialogueLine] = []
        for line in labeled {
            if let last = merged.last, last.speaker == line.speaker {
                merged[merged.count - 1] = DialogueLine(
                    startTime: last.startTime, endTime: line.endTime,
                    speaker: line.speaker, text: last.text + " " + line.text
                )
            } else {
                merged.append(line)
            }
        }
        return merged
    }

    // MARK: - Helpers

    /// Strip consecutive repeated words/phrases from whisper hallucination loops.
    /// "ख ल ख ल ख ल ख ल" → "ख ल"
    /// "Top Top Top Top" → "Top"
    private func stripRepetitions(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > 2 else { return text }

        // Try phrase lengths from 1 to 4 words
        for phraseLen in 1...min(4, words.count / 3) {
            var result: [String] = []
            var i = 0
            while i < words.count {
                let end = min(i + phraseLen, words.count)
                let phrase = Array(words[i..<end])

                // Count consecutive repetitions of this phrase
                var reps = 1
                var j = end
                while j + phraseLen <= words.count {
                    let next = Array(words[j..<j + phraseLen])
                    if next == phrase { reps += 1; j += phraseLen } else { break }
                }

                if reps >= 3 {
                    // Repeated 3+ times — keep just one occurrence
                    result.append(contentsOf: phrase)
                    i = j
                } else {
                    result.append(words[i])
                    i += 1
                }
            }

            if result.count < words.count / 2 {
                // Significant reduction — use this result
                return result.joined(separator: " ")
            }
        }
        return text
    }

    private func extractJSON(from text: String) -> String {
        var cleaned = text
        if let start = cleaned.range(of: "```json") {
            cleaned = String(cleaned[start.upperBound...])
        } else if let start = cleaned.range(of: "```") {
            cleaned = String(cleaned[start.upperBound...])
        }
        if let end = cleaned.range(of: "```", options: .backwards) {
            cleaned = String(cleaned[..<end.lowerBound])
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Comic formatter stage plugin.
///
/// Transforms a clean transcript (dialogue lines) into comic panel definitions.
/// Uses heuristics to determine panel layout, speaker mood, and importance.

import Foundation
import StandupCore

public final class ComicFormatterPlugin: BaseStagePlugin, @unchecked Sendable {
    // SAFETY: Inherits Sendable contract from BaseStagePlugin.
    override public var inputArtifacts: [ArtifactType] { [.cleanTranscript] }
    override public var outputArtifacts: [ArtifactType] { [.comicPanels] }

    private var maxPanels: Int = 12
    private var minImportanceScore: Double = 0.3

    public init() {
        super.init(id: "comic-formatter")
    }

    override public func onSetup() async throws {
        maxPanels = config.int(for: "max_panels", default: 12)
        minImportanceScore = config.double(for: "min_importance", default: 0.3)
    }

    override public func execute(context: StageContext) async throws -> [Artifact] {
        // Load clean transcript
        guard let transcriptRef = context.inputArtifacts.values.first(where: { $0.type == .cleanTranscript })
                ?? context.inputArtifacts["clean-transcript"] else {
            throw ComicError.missingInput("clean transcript")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: transcriptRef.path))
        let lines = try JSONDecoder().decode([DialogueLine].self, from: data)

        // Score each line for "comic-worthiness"
        var scoredLines = lines.map { line -> ScoredLine in
            let score = computeImportance(line)
            let mood = detectMood(line.text)
            return ScoredLine(line: line, score: score, mood: mood)
        }

        // Filter and select top panels
        scoredLines = scoredLines.filter { $0.score >= minImportanceScore }
        if scoredLines.count > maxPanels {
            scoredLines.sort { $0.score > $1.score }
            scoredLines = Array(scoredLines.prefix(maxPanels))
            // Re-sort by time
            scoredLines.sort { $0.line.startTime < $1.line.startTime }
        }

        // Convert to comic panels
        let panels = scoredLines.enumerated().map { index, scored -> ComicPanel in
            let condensed = condenseText(scored.line.text)
            return ComicPanel(
                index: index,
                speaker: scored.line.speaker,
                text: condensed,
                mood: scored.mood,
                startTime: scored.line.startTime,
                duration: scored.line.endTime - scored.line.startTime,
                importance: scored.score,
                panelSize: scored.score > 0.7 ? .large : .normal
            )
        }

        let outputDir = try ensureOutputDirectory(context: context)
        let outputPath = (outputDir as NSString).appendingPathComponent("panels.json")
        try JSONEncoder.prettyEncoding.encode(panels).write(to: URL(fileURLWithPath: outputPath))

        return [Artifact(stageId: id, type: .comicPanels, path: outputPath)]
    }

    // MARK: - Importance Scoring

    private func computeImportance(_ line: DialogueLine) -> Double {
        var score = 0.3 // base score

        let text = line.text.lowercased()
        let wordCount = text.split(separator: " ").count

        // Short, punchy statements score higher for comics
        if wordCount <= 15 { score += 0.2 }

        // Action-oriented keywords
        let actionWords = ["done", "finished", "fixed", "shipped", "built", "merged", "deployed",
                           "blocked", "stuck", "help", "need", "todo", "will", "going to",
                           "working on", "started", "completed"]
        for word in actionWords where text.contains(word) {
            score += 0.1
            break
        }

        // Emotional/expressive content
        let expressiveWords = ["awesome", "great", "terrible", "amazing", "wow", "finally",
                               "ugh", "yay", "nice", "cool", "crazy", "love", "hate"]
        for word in expressiveWords where text.contains(word) {
            score += 0.15
            break
        }

        // Questions are interesting in comics
        if text.contains("?") { score += 0.1 }

        // Exclamations
        if text.contains("!") { score += 0.1 }

        // Longer monologues are less comic-worthy
        if wordCount > 30 { score -= 0.2 }

        return min(1.0, max(0.0, score))
    }

    // MARK: - Mood Detection

    private func detectMood(_ text: String) -> Mood {
        let lower = text.lowercased()

        let moods: [(Mood, [String])] = [
            (.excited, ["awesome", "amazing", "great", "shipped", "finally", "yay", "!"]),
            (.proud, ["done", "finished", "fixed", "built", "merged", "deployed", "completed"]),
            (.frustrated, ["blocked", "stuck", "broken", "failed", "ugh", "terrible", "bug"]),
            (.thinking, ["maybe", "wondering", "think", "consider", "hmm", "not sure"]),
            (.asking, ["?", "how", "what", "why", "when", "could", "should"]),
            (.happy, ["nice", "cool", "love", "good", "thanks"]),
        ]

        for (mood, keywords) in moods {
            for keyword in keywords where lower.contains(keyword) {
                return mood
            }
        }
        return .neutral
    }

    // MARK: - Text Condensing

    private func condenseText(_ text: String) -> String {
        // For comics, keep it punchy — trim to ~80 chars if too long
        let maxLen = 80
        if text.count <= maxLen { return text }

        // Try to cut at a sentence boundary
        let sentences = text.components(separatedBy: ". ")
        if let first = sentences.first, first.count <= maxLen {
            return first + (sentences.count > 1 ? "..." : "")
        }

        // Hard truncate at word boundary
        let words = text.split(separator: " ")
        var result = ""
        for word in words {
            if (result + " " + word).count > maxLen - 3 { break }
            result += (result.isEmpty ? "" : " ") + word
        }
        return result + "..."
    }
}

// MARK: - Types

private struct ScoredLine {
    let line: DialogueLine
    let score: Double
    let mood: Mood
}

enum ComicError: Error, LocalizedError, Sendable {
    case missingInput(String)
    var errorDescription: String? {
        switch self {
        case .missingInput(let what): "Comic formatter missing input: \(what)"
        }
    }
}

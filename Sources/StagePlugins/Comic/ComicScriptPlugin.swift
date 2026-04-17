/// Comic script stage plugin.
///
/// Takes a clean transcript and uses a local LLM (via Ollama) to:
/// 1. Assign superhero personas to each speaker
/// 2. Select the best moments for comic panels
/// 3. Write scene descriptions and image generation prompts
///
/// Falls back to heuristic generation if Ollama is not available.

import Foundation
import StandupCore

public final class ComicScriptPlugin: BaseStagePlugin, @unchecked Sendable {
    override public var inputArtifacts: [ArtifactType] { [.cleanTranscript] }
    override public var outputArtifacts: [ArtifactType] { [.comicScript] }

    private var model: String = "gemma3:4b"
    private var maxPanels: Int = 8
    private var ollamaURL: String = "http://localhost:11434"

    public init() {
        super.init(id: "comic-script")
    }

    override public func onSetup() async throws {
        model = config.string(for: "model", default: "gemma3:4b")
        maxPanels = config.int(for: "max_panels", default: 8)
        ollamaURL = config.string(for: "ollama_url", default: "http://localhost:11434")
    }

    override public func execute(context: StageContext) async throws -> [Artifact] {
        guard let transcriptRef = context.inputArtifacts.values.first(where: { $0.type == .cleanTranscript })
                ?? context.inputArtifacts["clean-transcript"] else {
            throw ComicScriptError.missingInput("clean transcript")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: transcriptRef.path))
        let lines = try JSONDecoder().decode([DialogueLine].self, from: data)

        let client = OllamaClient(baseURL: ollamaURL)
        let script: ComicScript

        if await client.isAvailable(model: model) {
            script = try await generateWithLLM(client: client, lines: lines)
        } else {
            script = generateFallback(lines: lines)
        }

        let outputDir = try ensureOutputDirectory(context: context)
        let outputPath = (outputDir as NSString).appendingPathComponent("script.json")
        try JSONEncoder.prettyEncoding.encode(script).write(to: URL(fileURLWithPath: outputPath))

        return [Artifact(stageId: context.stageId, type: .comicScript, path: outputPath)]
    }

    // MARK: - LLM Generation

    private func generateWithLLM(client: OllamaClient, lines: [DialogueLine]) async throws -> ComicScript {
        let transcript = lines.map { "[\($0.speaker)] \($0.text)" }.joined(separator: "\n")

        let system = """
        You are a comic book writer. You transform meeting transcripts into fun superhero comic scripts.
        
        Rules:
        - Assign each speaker a unique superhero persona with a hero name, costume description, and signature color
        - Select the \(maxPanels) most interesting/funny/important moments from the transcript
        - For each panel, write a short dialogue (max 60 chars) and a scene description
        - Write an image prompt suitable for AI image generation (comic book style)
        - Keep it fun, exaggerated, and visual
        
        Respond ONLY with valid JSON in this exact format, no other text:
        {
          "title": "Epic Standup: [creative title]",
          "characters": [
            {"speakerId": "me", "heroName": "Captain Code", "costume": "blue spandex with binary patterns", "color": "#4A90D9"}
          ],
          "panels": [
            {
              "index": 0,
              "speaker": "me",
              "heroName": "Captain Code",
              "dialogue": "I shipped the feature!",
              "sceneDescription": "Captain Code stands triumphantly on a pile of merged PRs",
              "imagePrompt": "comic book panel, superhero in blue spandex standing triumphantly, pile of papers, bold outlines, vibrant colors, halftone dots",
              "mood": "proud"
            }
          ]
        }
        
        Valid moods: excited, proud, frustrated, thinking, asking, happy, neutral
        """

        let response = try await client.generate(model: model, prompt: transcript, system: system)

        // Extract JSON from response (LLM may wrap it in markdown code blocks)
        let jsonString = extractJSON(from: response)

        do {
            let script = try JSONDecoder().decode(ComicScript.self, from: Data(jsonString.utf8))
            return script
        } catch {
            // If LLM output is malformed, fall back to heuristic
            return generateFallback(lines: lines)
        }
    }

    private func extractJSON(from text: String) -> String {
        // Strip markdown code fences if present
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

    // MARK: - Heuristic Fallback

    private func generateFallback(lines: [DialogueLine]) -> ComicScript {
        let speakers = Set(lines.map(\.speaker))
        let heroNames: [String: (name: String, costume: String, color: String)] = assignHeroes(speakers: speakers)

        // Score and select best lines
        var scored = lines.enumerated().map { (i, line) -> (Int, DialogueLine, Double) in
            (i, line, scoreImportance(line))
        }
        scored.sort { $0.2 > $1.2 }
        let selected = Array(scored.prefix(maxPanels)).sorted { $0.0 < $1.0 }

        let panels = selected.enumerated().map { (panelIdx, item) -> ComicScriptPanel in
            let (_, line, _) = item
            let hero = heroNames[line.speaker] ?? (name: "Mystery Hero", costume: "dark cloak", color: "#666666")
            let mood = detectMood(line.text)
            let dialogue = condenseText(line.text, maxLen: 60)

            return ComicScriptPanel(
                index: panelIdx,
                speaker: line.speaker,
                heroName: hero.name,
                dialogue: dialogue,
                sceneDescription: "\(hero.name) at the standup board, looking \(mood.rawValue)",
                imagePrompt: "comic book panel, superhero in \(hero.costume), \(mood.rawValue) expression, standup meeting room, bold outlines, vibrant colors, halftone dots, speech bubble",
                mood: mood
            )
        }

        let characters = heroNames.map { (speaker, hero) in
            ComicCharacter(speakerId: speaker, heroName: hero.name, costume: hero.costume, color: hero.color)
        }

        return ComicScript(
            title: "Epic Standup: The Daily Stand",
            characters: characters,
            panels: panels
        )
    }

    private func assignHeroes(speakers: Set<String>) -> [String: (name: String, costume: String, color: String)] {
        let heroPool: [(name: String, costume: String, color: String)] = [
            ("Captain Sprint", "blue spandex with lightning bolt emblem", "#4A90D9"),
            ("The Deployer", "red armor with rocket boosters", "#D94A4A"),
            ("Shield Debug", "green suit with magnifying glass shield", "#4AD94A"),
            ("Binary Blaze", "orange cape with binary code patterns", "#E67E22"),
            ("Quantum Query", "purple robes with glowing data streams", "#9B59B6"),
            ("Iron Commit", "silver armor with git branch wings", "#95A5A6"),
        ]

        var result: [String: (name: String, costume: String, color: String)] = [:]
        for (i, speaker) in speakers.sorted().enumerated() {
            result[speaker] = heroPool[i % heroPool.count]
        }
        return result
    }

    private func scoreImportance(_ line: DialogueLine) -> Double {
        var score = 0.3
        let text = line.text.lowercased()
        let wordCount = text.split(separator: " ").count

        if wordCount <= 15 { score += 0.2 }

        let actionWords = ["done", "finished", "fixed", "shipped", "built", "merged",
                           "deployed", "blocked", "stuck", "help", "todo", "working on"]
        for word in actionWords where text.contains(word) { score += 0.15; break }

        let expressiveWords = ["awesome", "great", "terrible", "amazing", "finally", "ugh", "nice"]
        for word in expressiveWords where text.contains(word) { score += 0.15; break }

        if text.contains("?") { score += 0.1 }
        if text.contains("!") { score += 0.1 }
        if wordCount > 30 { score -= 0.2 }

        return min(1.0, max(0.0, score))
    }

    private func detectMood(_ text: String) -> Mood {
        let lower = text.lowercased()
        let moods: [(Mood, [String])] = [
            (.excited, ["awesome", "amazing", "shipped", "finally", "!"]),
            (.proud, ["done", "finished", "fixed", "built", "merged", "deployed"]),
            (.frustrated, ["blocked", "stuck", "broken", "failed", "bug"]),
            (.thinking, ["maybe", "wondering", "think", "hmm"]),
            (.asking, ["?", "how", "what", "why"]),
            (.happy, ["nice", "cool", "good", "thanks"]),
        ]
        for (mood, keywords) in moods {
            for keyword in keywords where lower.contains(keyword) { return mood }
        }
        return .neutral
    }

    private func condenseText(_ text: String, maxLen: Int) -> String {
        if text.count <= maxLen { return text }
        let words = text.split(separator: " ")
        var result = ""
        for word in words {
            if (result + " " + word).count > maxLen - 3 { break }
            result += (result.isEmpty ? "" : " ") + word
        }
        return result + "..."
    }
}

enum ComicScriptError: Error, LocalizedError, Sendable {
    case missingInput(String)
    var errorDescription: String? {
        switch self {
        case .missingInput(let what): "Comic script missing input: \(what)"
        }
    }
}

/// Google Cloud LLM plugin using Gemini via Vertex AI.
///
/// Drop-in replacement for Ollama-based plugins.
/// Uses Vertex AI's generateContent endpoint with Gemini models.
///
/// Config:
///   project: GCP project ID (required, or set GOOGLE_CLOUD_PROJECT env var)
///   model: Gemini model name (default: "gemini-2.0-flash")
///   region: GCP region (default: "us-central1")
///   max_tokens: Max output tokens (default: 4096)

import Foundation
import StandupCore

public final class GoogleLLMPlugin: BaseStagePlugin, @unchecked Sendable {
    override public var inputArtifacts: [ArtifactType] { [.cleanTranscript] }
    override public var outputArtifacts: [ArtifactType] { [.comicScript] }

    private var model: String = "gemini-2.0-flash"
    private var maxTokens: Int = 4096
    private var gcloud: GoogleCloudRunner = GoogleCloudRunner(project: "")

    public init() {
        super.init(id: "google-llm")
    }

    override public func onSetup() async throws {
        let project = config.string(for: "project", default: "")
            .nonEmpty ?? ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"] ?? ""
        guard !project.isEmpty else {
            throw GoogleCloudError.missingConfig("project is required (config or GOOGLE_CLOUD_PROJECT env var)")
        }
        model = config.string(for: "model", default: "gemini-2.0-flash")
        maxTokens = config.int(for: "max_tokens", default: 4096)
        let region = config.string(for: "region", default: "us-central1")
        gcloud = GoogleCloudRunner(project: project, region: region)
    }

    /// Generate text from Gemini via Vertex AI.
    public func generate(prompt: String, system: String = "") async throws -> String {
        var contents: [[String: Any]] = [
            ["role": "user", "parts": [["text": prompt]]]
        ]
        if !system.isEmpty {
            contents.insert(["role": "user", "parts": [["text": system]]], at: 0)
            contents.insert(["role": "model", "parts": [["text": "Understood. I will follow these instructions."]]], at: 1)
        }

        let body: [String: Any] = [
            "contents": contents,
            "generationConfig": [
                "maxOutputTokens": maxTokens,
                "temperature": 0.7,
            ]
        ]

        let url = gcloud.vertexAIURL(model: model)
        let json = try await gcloud.callAPI(url: url, body: body)

        return extractText(from: json)
    }

    override public func execute(context: StageContext) async throws -> [Artifact] {
        guard let transcriptRef = context.inputArtifacts.values.first(where: { $0.type == .cleanTranscript })
                ?? context.inputArtifacts["clean-transcript"] else {
            throw GoogleCloudError.missingConfig("clean transcript input not found")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: transcriptRef.path))
        let lines = try JSONDecoder().decode([DialogueLine].self, from: data)
        let transcript = lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")

        let prompt = """
        You are given a meeting transcript. Create a comic script as a JSON object.
        Each panel captures a key moment. Return valid JSON only.

        Format:
        {
          "title": "...",
          "characters": [{"name": "...", "heroName": "...", "color": "#hex"}],
          "panels": [{"index": 1, "heroName": "...", "dialogue": "...", "mood": "excited", "sceneDescription": "...", "imagePrompt": "..."}]
        }

        Moods: excited, proud, frustrated, thinking, asking, happy, neutral
        Max 8 panels.

        Transcript:
        \(transcript)
        """

        let response = try await generate(
            prompt: prompt,
            system: "You generate comic scripts from meeting transcripts. Return valid JSON only."
        )

        let script = try parseComicScript(from: response, lines: lines)
        let outputDir = try ensureOutputDirectory(context: context)
        let outputPath = (outputDir as NSString).appendingPathComponent("script.json")
        try JSONEncoder.prettyEncoding.encode(script).write(to: URL(fileURLWithPath: outputPath))

        return [Artifact(stageId: context.stageId, type: .comicScript, path: outputPath)]
    }

    // MARK: - Response Parsing

    private func extractText(from json: [String: Any]) -> String {
        guard let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseComicScript(from response: String, lines: [DialogueLine]) throws -> ComicScript {
        let jsonString: String
        if let start = response.firstIndex(of: "{"),
           let end = response.lastIndex(of: "}") {
            jsonString = String(response[start...end])
        } else {
            jsonString = response
        }

        guard let data = jsonString.data(using: .utf8) else {
            throw GoogleCloudError.invalidResponse("Cannot encode response as UTF-8")
        }

        return try JSONDecoder().decode(ComicScript.self, from: data)
    }
}

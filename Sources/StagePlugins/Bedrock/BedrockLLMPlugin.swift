/// Bedrock LLM plugin using Claude via AWS Bedrock.
///
/// Drop-in replacement for Ollama-based plugins in pipeline stages.
/// Uses `aws bedrock-runtime invoke-model` with Claude Haiku.
///
/// Config:
///   model_id: Bedrock model ID (default: "anthropic.claude-3-haiku-20240307-v1:0")
///   region: AWS region (default: "us-east-1")
///   profile: AWS CLI profile (optional)
///   max_tokens: Maximum tokens in response (default: 4096)

import Foundation
import StandupCore

public final class BedrockLLMPlugin: BaseStagePlugin, @unchecked Sendable {
    override public var inputArtifacts: [ArtifactType] { [.cleanTranscript] }
    override public var outputArtifacts: [ArtifactType] { [.comicScript] }

    private var modelId: String = "anthropic.claude-3-haiku-20240307-v1:0"
    private var maxTokens: Int = 4096
    private var aws: AWSCLIRunner = AWSCLIRunner()

    public init() {
        super.init(id: "bedrock-llm")
    }

    override public func onSetup() async throws {
        modelId = config.string(for: "model_id", default: "anthropic.claude-3-haiku-20240307-v1:0")
        maxTokens = config.int(for: "max_tokens", default: 4096)
        let region = config.string(for: "region", default: "us-east-1")
        let profile: String? = {
            let p = config.string(for: "profile", default: "")
            return p.isEmpty ? nil : p
        }()
        aws = AWSCLIRunner(region: region, profile: profile)
    }

    /// Send a prompt to Claude via Bedrock and return the response text.
    public func generate(prompt: String, system: String = "") async throws -> String {
        let body = buildRequestBody(prompt: prompt, system: system)
        let bodyJSON = try JSONSerialization.data(withJSONObject: body)

        // Write body to temp file (CLI has arg length limits)
        let tempInput = NSTemporaryDirectory() + "bedrock_input_\(UUID().uuidString).json"
        let tempOutput = NSTemporaryDirectory() + "bedrock_output_\(UUID().uuidString).json"
        defer {
            try? FileManager.default.removeItem(atPath: tempInput)
            try? FileManager.default.removeItem(atPath: tempOutput)
        }
        try bodyJSON.write(to: URL(fileURLWithPath: tempInput))

        _ = try await aws.run(service: "bedrock-runtime", args: [
            "invoke-model",
            "--model-id", modelId,
            "--content-type", "application/json",
            "--accept", "application/json",
            "--body", "fileb://\(tempInput)",
            tempOutput,
        ])

        let outputData = try Data(contentsOf: URL(fileURLWithPath: tempOutput))
        guard let json = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any] else {
            throw BedrockError.invalidResponse("Cannot parse Bedrock response")
        }

        return extractText(from: json)
    }

    override public func execute(context: StageContext) async throws -> [Artifact] {
        guard let transcriptRef = context.inputArtifacts.values.first(where: { $0.type == .cleanTranscript })
                ?? context.inputArtifacts["clean-transcript"] else {
            throw BedrockError.missingConfig("clean transcript input not found")
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

        let response = try await generate(prompt: prompt, system: "You generate comic scripts from meeting transcripts. Return valid JSON only.")

        // Parse the LLM response as comic script
        let script = try parseComicScript(from: response, lines: lines)
        let outputDir = try ensureOutputDirectory(context: context)
        let outputPath = (outputDir as NSString).appendingPathComponent("script.json")
        try JSONEncoder.prettyEncoding.encode(script).write(to: URL(fileURLWithPath: outputPath))

        return [Artifact(stageId: context.stageId, type: .comicScript, path: outputPath)]
    }

    // MARK: - Request Building

    private func buildRequestBody(prompt: String, system: String) -> [String: Any] {
        var body: [String: Any] = [
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": maxTokens,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        if !system.isEmpty {
            body["system"] = system
        }
        return body
    }

    private func extractText(from json: [String: Any]) -> String {
        // Claude Messages API response format
        if let content = json["content"] as? [[String: Any]],
           let first = content.first,
           let text = first["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Fallback for older completion format
        if let completion = json["completion"] as? String {
            return completion.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    // MARK: - Parsing

    private func parseComicScript(from response: String, lines: [DialogueLine]) throws -> ComicScript {
        // Try to extract JSON from the response
        let jsonString: String
        if let start = response.firstIndex(of: "{"),
           let end = response.lastIndex(of: "}") {
            jsonString = String(response[start...end])
        } else {
            jsonString = response
        }

        guard let data = jsonString.data(using: .utf8) else {
            throw BedrockError.invalidResponse("Cannot encode response as UTF-8")
        }

        return try JSONDecoder().decode(ComicScript.self, from: data)
    }
}

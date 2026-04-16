/// Infrastructure: HTTP client for the Ollama local LLM API.
///
/// Calls localhost:11434 to run models like Gemma locally.
/// Used by stage plugins that need LLM capabilities.

import Foundation

public enum OllamaError: Error, LocalizedError, Sendable {
    case notRunning
    case requestFailed(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notRunning: "Ollama is not running. Start it with: ollama serve"
        case .requestFailed(let msg): "Ollama request failed: \(msg)"
        case .invalidResponse: "Invalid response from Ollama"
        }
    }
}

public struct OllamaClient: Sendable {
    private let baseURL: String

    public init(baseURL: String = "http://localhost:11434") {
        self.baseURL = baseURL
    }

    /// Generate a completion from the model. Non-streaming.
    public func generate(model: String, prompt: String, system: String = "") async throws -> String {
        let url = URL(string: "\(baseURL)/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300 // LLM can be slow on device

        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false
        ]
        if !system.isEmpty {
            body["system"] = system
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OllamaError.notRunning
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw OllamaError.requestFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String else {
            throw OllamaError.invalidResponse
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Check if Ollama is running and the model is available.
    public func isAvailable(model: String) async -> Bool {
        let url = URL(string: "\(baseURL)/api/tags")!
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return false
        }
        return models.contains { ($0["name"] as? String)?.hasPrefix(model) == true }
    }
}

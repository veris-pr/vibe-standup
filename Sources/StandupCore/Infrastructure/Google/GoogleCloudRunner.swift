/// Infrastructure: Google Cloud API client.
///
/// Uses `gcloud auth print-access-token` for authentication and URLSession
/// for REST API calls. This avoids depending on the Google Cloud SDK for Swift
/// while still leveraging the user's existing gcloud CLI configuration.
///
/// Requires: gcloud CLI installed and authenticated (`gcloud auth login`).

import Foundation

public enum GoogleCloudError: Error, LocalizedError, Sendable {
    case gcloudNotFound
    case authFailed(String)
    case requestFailed(service: String, status: Int, message: String)
    case invalidResponse(String)
    case missingConfig(String)

    public var errorDescription: String? {
        switch self {
        case .gcloudNotFound:
            "gcloud CLI not found. Install: brew install google-cloud-sdk"
        case .authFailed(let msg):
            "Google Cloud auth failed: \(msg)"
        case .requestFailed(let service, let status, let msg):
            "Google Cloud \(service) failed (HTTP \(status)): \(msg)"
        case .invalidResponse(let msg):
            "Invalid Google Cloud response: \(msg)"
        case .missingConfig(let msg):
            "Google Cloud config error: \(msg)"
        }
    }
}

public struct GoogleCloudRunner: Sendable {
    private let project: String
    private let region: String

    public init(project: String, region: String = "us-central1") {
        self.project = project
        self.region = region
    }

    /// Get an access token from gcloud CLI.
    public func accessToken() async throws -> String {
        guard let gcloudPath = GoogleCloudRunner.findGCloud() else {
            throw GoogleCloudError.gcloudNotFound
        }

        let token = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gcloudPath)
            process.arguments = ["auth", "print-access-token"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice

            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw GoogleCloudError.authFailed("gcloud auth print-access-token failed")
            }

            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }.value

        guard !token.isEmpty else {
            throw GoogleCloudError.authFailed("Empty access token — run `gcloud auth login`")
        }

        return token
    }

    /// Call a Google Cloud REST API endpoint.
    public func callAPI(
        url: String,
        method: String = "POST",
        body: [String: Any]
    ) async throws -> [String: Any] {
        let token = try await accessToken()

        guard let requestURL = URL(string: url) else {
            throw GoogleCloudError.invalidResponse("Invalid URL: \(url)")
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleCloudError.invalidResponse("Not an HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw GoogleCloudError.requestFailed(
                service: "API", status: httpResponse.statusCode, message: String(body.prefix(500))
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleCloudError.invalidResponse("Cannot parse JSON response")
        }

        return json
    }

    // MARK: - API URL Builders

    public func vertexAIURL(model: String, method: String = "generateContent") -> String {
        "https://\(region)-aiplatform.googleapis.com/v1/projects/\(project)/locations/\(region)/publishers/google/models/\(model):\(method)"
    }

    public func speechToTextURL() -> String {
        "https://speech.googleapis.com/v1/speech:longrunningrecognize"
    }

    public func speechOperationURL(name: String) -> String {
        "https://speech.googleapis.com/v1/operations/\(name)"
    }

    /// Check operation status (for async APIs).
    public func pollOperation(name: String) async throws -> [String: Any] {
        let token = try await accessToken()
        let url = URL(string: speechOperationURL(name: name))!

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleCloudError.invalidResponse("Cannot parse operation response")
        }
        return json
    }

    // MARK: - Discovery

    public static func findGCloud() -> String? {
        let candidates = [
            "/opt/homebrew/bin/gcloud",
            "/usr/local/bin/gcloud",
            "/usr/bin/gcloud",
            // Homebrew cask installs to google-cloud-sdk
            "/opt/homebrew/share/google-cloud-sdk/bin/gcloud",
            "/usr/local/share/google-cloud-sdk/bin/gcloud",
        ]
        // Also check HOME-based installs
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let homeCandidates = [
            (home as NSString).appendingPathComponent("google-cloud-sdk/bin/gcloud"),
        ]
        return (candidates + homeCandidates).first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Check if gcloud is installed and authenticated.
    public func checkAuth() async -> Bool {
        guard GoogleCloudRunner.findGCloud() != nil else { return false }
        do {
            let token = try await accessToken()
            return !token.isEmpty
        } catch {
            return false
        }
    }
}

/// Infrastructure: AWS CLI subprocess runner.
///
/// Wraps `aws` CLI calls for Bedrock, Transcribe, and S3 operations.
/// Relies on standard AWS credential chain (env vars, profiles, IAM roles).

import Foundation

public enum AWSError: Error, LocalizedError, Sendable {
    case cliNotFound
    case commandFailed(service: String, exitCode: Int32, message: String)
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "AWS CLI not found. Install: brew install awscli"
        case .commandFailed(let service, let code, let msg):
            "AWS \(service) failed (exit \(code)): \(msg)"
        case .invalidOutput(let msg):
            "Invalid AWS response: \(msg)"
        }
    }
}

public struct AWSCLIRunner: Sendable {
    private let awsPath: String
    private let region: String
    private let profile: String?

    public init(region: String = "us-east-1", profile: String? = nil) {
        self.region = region
        self.profile = profile
        self.awsPath = AWSCLIRunner.findAWSCLI() ?? "/usr/local/bin/aws"
    }

    /// Run an AWS CLI command and return stdout as Data.
    public func run(service: String, args: [String]) async throws -> Data {
        let awsPath = self.awsPath
        let region = self.region
        let profile = self.profile

        guard FileManager.default.fileExists(atPath: awsPath) else {
            throw AWSError.cliNotFound
        }

        var fullArgs = [service] + args + ["--region", region, "--output", "json"]
        if let profile { fullArgs += ["--profile", profile] }

        let (status, stdout, stderr) = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: awsPath)
            process.arguments = fullArgs

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = FileHandle.nullDevice

            try process.run()
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            return (process.terminationStatus, stdoutData, stderrData)
        }.value

        guard status == 0 else {
            let msg = String(data: stderr, encoding: .utf8) ?? "unknown error"
            throw AWSError.commandFailed(service: service, exitCode: status, message: String(msg.prefix(500)))
        }

        return stdout
    }

    /// Run and parse JSON response.
    public func runJSON(service: String, args: [String]) async throws -> [String: Any] {
        let data = try await run(service: service, args: args)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AWSError.invalidOutput("Could not parse JSON response")
        }
        return json
    }

    /// Check if AWS CLI is installed and credentials are configured.
    public func checkCredentials() async -> Bool {
        guard FileManager.default.fileExists(atPath: awsPath) else { return false }
        do {
            _ = try await run(service: "sts", args: ["get-caller-identity"])
            return true
        } catch {
            return false
        }
    }

    public static func findAWSCLI() -> String? {
        let candidates = [
            "/opt/homebrew/bin/aws",
            "/usr/local/bin/aws",
            "/usr/bin/aws",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }
}

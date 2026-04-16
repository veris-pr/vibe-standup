/// Subprocess bridge — runs external programs as stage plugins.
///
/// Communicates via JSON over stdin/stdout. Supports any executable
/// (Python, Node, Go, shell scripts, etc.)

import Foundation

/// A stage plugin that delegates to an external subprocess.
public final class SubprocessStagePlugin: StagePlugin, @unchecked Sendable {
    public let id: String
    public let version: String = "1.0.0"
    public let inputArtifacts: [ArtifactType]
    public let outputArtifacts: [ArtifactType]

    private let executablePath: String
    private let arguments: [String]
    private var config: PluginConfig = PluginConfig()

    public init(
        id: String,
        executablePath: String,
        arguments: [String] = [],
        inputArtifacts: [ArtifactType] = [.custom],
        outputArtifacts: [ArtifactType] = [.custom]
    ) {
        self.id = id
        self.executablePath = executablePath
        self.arguments = arguments
        self.inputArtifacts = inputArtifacts
        self.outputArtifacts = outputArtifacts
    }

    public func setup(config: PluginConfig) async throws {
        self.config = config
    }

    public func teardown() async {}

    public func execute(context: SessionContext) async throws -> [ArtifactRef] {
        let outputDir = context.outputDirectory(for: id)

        // Build the JSON message to send via stdin
        let inputMessage = SubprocessInput(
            command: "execute",
            sessionId: context.sessionId,
            sessionPath: context.sessionDirectory,
            outputPath: outputDir,
            inputs: context.inputArtifacts.mapValues { $0.path },
            config: config.values
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let inputData = try encoder.encode(inputMessage)

        // Spawn the subprocess
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Send input and close stdin
        stdinPipe.fileHandleForWriting.write(inputData)
        stdinPipe.fileHandleForWriting.write(Data("\n".utf8))
        stdinPipe.fileHandleForWriting.closeFile()

        // Wait for completion
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: stderrData, encoding: .utf8) ?? "unknown error"
            throw SubprocessError.nonZeroExit(id, Int(process.terminationStatus), errorMsg)
        }

        // Parse stdout for output message
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let output = try decoder.decode(SubprocessOutput.self, from: stdoutData)

        return output.artifacts.map { art in
            ArtifactRef(
                stageId: id,
                type: ArtifactType(rawValue: art.type) ?? .custom,
                path: art.path
            )
        }
    }
}

// MARK: - Protocol Messages

struct SubprocessInput: Codable {
    let command: String
    let sessionId: String
    let sessionPath: String
    let outputPath: String
    let inputs: [String: String]
    let config: [String: String]
}

struct SubprocessOutput: Codable {
    let status: String
    let artifacts: [SubprocessArtifact]
}

struct SubprocessArtifact: Codable {
    let type: String
    let path: String
}

// MARK: - Errors

public enum SubprocessError: Error, LocalizedError {
    case nonZeroExit(String, Int, String)
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .nonZeroExit(let id, let code, let msg):
            "Subprocess plugin '\(id)' exited with code \(code): \(msg)"
        case .invalidOutput(let id):
            "Subprocess plugin '\(id)' produced invalid output"
        }
    }
}

/// Infrastructure: Subprocess bridge for running external programs as stage plugins.

import Foundation

public final class SubprocessStagePlugin: BaseStagePlugin, @unchecked Sendable {
    // SAFETY: Inherits Sendable contract from BaseStagePlugin.
    private let executablePath: String
    private let arguments: [String]
    private let _inputArtifacts: [ArtifactType]
    private let _outputArtifacts: [ArtifactType]

    override public var inputArtifacts: [ArtifactType] { _inputArtifacts }
    override public var outputArtifacts: [ArtifactType] { _outputArtifacts }

    public init(
        id: String,
        executablePath: String,
        arguments: [String] = [],
        inputArtifacts: [ArtifactType] = [.custom],
        outputArtifacts: [ArtifactType] = [.custom]
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self._inputArtifacts = inputArtifacts
        self._outputArtifacts = outputArtifacts
        super.init(id: id)
    }

    override public func execute(context: StageContext) async throws -> [Artifact] {
        let outputDir = try ensureOutputDirectory(context: context)

        let inputMessage = SubprocessInput(
            command: "execute",
            sessionId: context.sessionId,
            sessionPath: context.sessionDirectory,
            outputPath: outputDir,
            inputs: context.inputArtifacts.mapValues(\.path),
            config: config.values
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let inputData = try encoder.encode(inputMessage)

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

        stdinPipe.fileHandleForWriting.write(inputData)
        stdinPipe.fileHandleForWriting.write(Data("\n".utf8))
        stdinPipe.fileHandleForWriting.closeFile()

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: stderrData, encoding: .utf8) ?? "unknown error"
            throw SubprocessError.nonZeroExit(id, Int(process.terminationStatus), errorMsg)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let output = try decoder.decode(SubprocessOutput.self, from: stdoutData)

        return output.artifacts.map { art in
            Artifact(
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

public enum SubprocessError: Error, LocalizedError, Sendable {
    case nonZeroExit(String, Int, String)

    public var errorDescription: String? {
        switch self {
        case .nonZeroExit(let id, let code, let msg):
            "Subprocess plugin '\(id)' exited with code \(code): \(msg)"
        }
    }
}

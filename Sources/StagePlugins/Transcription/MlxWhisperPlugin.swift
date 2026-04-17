/// mlx-whisper transcription stage plugin.
///
/// Runs mlx-whisper via a Python subprocess for Apple Silicon–native transcription.
/// Requires: `.venv/bin/python3` and `scripts/mlx_whisper_infer.py` in the project root.

import Foundation
import StandupCore

// MARK: - Shared types

public enum TranscriptionError: Error, LocalizedError, Sendable {
    case transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .transcriptionFailed(let msg): "Transcription failed: \(msg)"
        }
    }
}

// TranscriptionSegment is defined in TranscriptMergerPlugin.swift (shared within StagePlugins target)

// MARK: - Data helpers for WAV construction

extension Data {
    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }
    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }
}

// MARK: - Plugin

public final class MlxWhisperPlugin: BaseStagePlugin, @unchecked Sendable {
    override public var inputArtifacts: [ArtifactType] { [.audioChunks] }
    override public var outputArtifacts: [ArtifactType] { [.transcriptionSegments] }

    private var model: String = "mlx-community/whisper-large-v3-turbo"
    private var language: String? = nil
    private var pythonPath: String = ""
    private var scriptPath: String = ""

    public init() {
        super.init(id: "mlx-whisper")
    }

    override public func onSetup() async throws {
        model = config.string(for: "model", default: "mlx-community/whisper-large-v3-turbo")
        let lang = config.string(for: "language", default: "auto")
        language = (lang == "auto") ? nil : lang

        pythonPath = config.string(for: "python_path", default: "")
        if pythonPath.isEmpty {
            pythonPath = findPython()
        }

        scriptPath = config.string(for: "script_path", default: "")
        if scriptPath.isEmpty {
            scriptPath = findScript()
        }
    }

    override public func execute(context: StageContext) async throws -> [Artifact] {
        let chunksDir = context.inputArtifacts["audio_chunks"]?.path
            ?? (context.sessionDirectory as NSString).appendingPathComponent("chunks")
        let outputDir = try ensureOutputDirectory(context: context)

        let mergedWAV = (outputDir as NSString).appendingPathComponent("merged.wav")
        try mergeChunksToWAV(chunksDir: chunksDir, outputPath: mergedWAV)

        guard FileManager.default.fileExists(atPath: pythonPath),
              FileManager.default.fileExists(atPath: scriptPath) else {
            throw TranscriptionError.transcriptionFailed(
                "mlx-whisper not found. Run: cd \(projectRoot()) && uv venv && uv add mlx-whisper"
            )
        }

        let segmentsJSON = (outputDir as NSString).appendingPathComponent("mlx_segments.json")
        try await runMlxWhisper(wavPath: mergedWAV, outputPath: segmentsJSON)

        let rawData = try Data(contentsOf: URL(fileURLWithPath: segmentsJSON))
        var segments = try JSONDecoder().decode([TranscriptionSegment].self, from: rawData)
        segments = deduplicateSegments(segments)

        let outputPath = (outputDir as NSString).appendingPathComponent("segments.json")
        try JSONEncoder.prettyEncoding.encode(segments).write(to: URL(fileURLWithPath: outputPath))

        try? FileManager.default.removeItem(atPath: mergedWAV)
        try? FileManager.default.removeItem(atPath: segmentsJSON)

        return [Artifact(stageId: context.stageId, type: .transcriptionSegments, path: outputPath)]
    }

    // MARK: - Python subprocess

    private func runMlxWhisper(wavPath: String, outputPath: String) async throws {
        let pythonPath = self.pythonPath
        let scriptPath = self.scriptPath
        let model = self.model
        let language = self.language

        let (status, stderrData) = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonPath)

            var args = [scriptPath, "--audio", wavPath, "--model", model, "--output", outputPath]
            if let language { args += ["--language", language] }
            process.arguments = args

            let stderrPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderrPipe

            try process.run()
            let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            return (process.terminationStatus, stderr)
        }.value

        guard status == 0 else {
            let msg = String(data: stderrData, encoding: .utf8) ?? "unknown error"
            throw TranscriptionError.transcriptionFailed("mlx-whisper exited with code \(status): \(msg)")
        }

        guard FileManager.default.fileExists(atPath: outputPath) else {
            throw TranscriptionError.transcriptionFailed("mlx-whisper produced no output")
        }
    }

    // MARK: - Deduplication

    private func deduplicateSegments(_ segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        guard segments.count > 1 else { return segments }
        var result: [TranscriptionSegment] = []
        var lastText = ""
        var repeatCount = 0
        let maxRepeats = 2

        for seg in segments {
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == lastText {
                repeatCount += 1
                if repeatCount >= maxRepeats { continue }
            } else {
                repeatCount = 0
                lastText = trimmed
            }
            if trimmed.count < 3 { continue }
            result.append(seg)
        }
        return result
    }

    // MARK: - Merge PCM chunks → WAV

    private func mergeChunksToWAV(chunksDir: String, outputPath: String) throws {
        let fm = FileManager.default
        let allFiles = try fm.contentsOfDirectory(atPath: chunksDir)
            .filter { $0.hasSuffix(".pcm") }
            .sorted()

        var chunkIndices: [String: (mic: String?, system: String?)] = [:]
        for file in allFiles {
            let name = (file as NSString).deletingPathExtension
            if name.hasSuffix("_mic") {
                let idx = String(name.dropLast(4))
                chunkIndices[idx, default: (nil, nil)].mic = file
            } else if name.hasSuffix("_system") {
                let idx = String(name.dropLast(7))
                chunkIndices[idx, default: (nil, nil)].system = file
            }
        }

        let sorted = chunkIndices.sorted { $0.key < $1.key }
        var allSamples = Data()

        for (_, pair) in sorted {
            let systemData: Data
            if let sys = pair.system {
                systemData = try Data(contentsOf: URL(fileURLWithPath:
                    (chunksDir as NSString).appendingPathComponent(sys)))
            } else {
                let micPath = pair.mic.map {
                    (chunksDir as NSString).appendingPathComponent($0)
                }
                let size = micPath.flatMap {
                    try? Data(contentsOf: URL(fileURLWithPath: $0))
                }?.count ?? 0
                systemData = Data(repeating: 0, count: size)
            }
            allSamples.append(systemData)
        }

        guard !allSamples.isEmpty else {
            throw TranscriptionError.transcriptionFailed("No audio chunks found in \(chunksDir)")
        }

        let sampleRate: UInt32 = 48000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 32
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = UInt32(allSamples.count)

        var wav = Data()
        wav.append(contentsOf: "RIFF".utf8)
        wav.appendLE(36 + dataSize)
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8)
        wav.appendLE(UInt32(16))
        wav.appendLE(UInt16(3)) // IEEE Float
        wav.appendLE(channels)
        wav.appendLE(sampleRate)
        wav.appendLE(byteRate)
        wav.appendLE(blockAlign)
        wav.appendLE(bitsPerSample)
        wav.append(contentsOf: "data".utf8)
        wav.appendLE(dataSize)
        wav.append(allSamples)

        try wav.write(to: URL(fileURLWithPath: outputPath))
    }

    // MARK: - Path resolution

    private func projectRoot() -> String {
        // Walk up from binary location or use known paths
        if let env = ProcessInfo.processInfo.environment["STANDUP_PROJECT_ROOT"] {
            return env
        }
        let candidates = [
            FileManager.default.currentDirectoryPath,
            (NSHomeDirectory() as NSString).appendingPathComponent("WORKSPACE/GH/standup"),
        ]
        for dir in candidates {
            let venv = (dir as NSString).appendingPathComponent(".venv/bin/python3")
            if FileManager.default.fileExists(atPath: venv) { return dir }
        }
        return FileManager.default.currentDirectoryPath
    }

    private func findPython() -> String {
        let root = projectRoot()
        let venvPython = (root as NSString).appendingPathComponent(".venv/bin/python3")
        if FileManager.default.fileExists(atPath: venvPython) { return venvPython }
        return "/usr/bin/python3"
    }

    private func findScript() -> String {
        let root = projectRoot()
        return (root as NSString).appendingPathComponent("scripts/mlx_whisper_infer.py")
    }
}

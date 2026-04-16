/// Whisper transcription stage plugin.
///
/// Runs whisper.cpp CLI as a subprocess to transcribe audio.
/// User must install whisper-cpp: `brew install whisper-cpp`
///
/// Falls back to a placeholder if whisper-cpp is not available.

import Foundation
import StandupCore

public final class WhisperPlugin: BaseStagePlugin, @unchecked Sendable {
    override public var inputArtifacts: [ArtifactType] { [.audioChunks] }
    override public var outputArtifacts: [ArtifactType] { [.transcriptionSegments] }

    private var modelPath: String = ""
    private var language: String = "en"
    private var whisperPath: String = ""
    private var threads: Int = 4

    public init() {
        super.init(id: "whisper")
    }

    override public func onSetup() async throws {
        language = config.string(for: "language", default: "en")
        threads = config.int(for: "threads", default: 4)
        let modelName = config.string(for: "model", default: "base.en")

        whisperPath = config.string(for: "whisper_path", default: "")
        if whisperPath.isEmpty {
            whisperPath = findWhisperBinary() ?? ""
        }

        modelPath = config.string(for: "model_path", default: "")
        if modelPath.isEmpty {
            modelPath = findModelPath(modelName: modelName) ?? ""
        }
    }

    override public func execute(context: StageContext) async throws -> [Artifact] {
        let chunksDir = context.inputArtifacts["audio_chunks"]?.path
            ?? (context.sessionDirectory as NSString).appendingPathComponent("chunks")
        let outputDir = try ensureOutputDirectory(context: context)

        // Merge all audio chunks into a single WAV
        let mergedWAV = (outputDir as NSString).appendingPathComponent("merged.wav")
        try mergeChunksToWAV(chunksDir: chunksDir, outputPath: mergedWAV)

        let segments: [WhisperSegmentOutput]
        if !whisperPath.isEmpty && FileManager.default.fileExists(atPath: whisperPath) && !modelPath.isEmpty {
            segments = try runWhisperCpp(wavPath: mergedWAV, outputDir: outputDir)
        } else {
            // Fallback: detect audio duration and emit placeholder
            segments = try createPlaceholderSegments(wavPath: mergedWAV)
        }

        let outputPath = (outputDir as NSString).appendingPathComponent("segments.json")
        let data = try JSONEncoder.prettyEncoding.encode(segments)
        try data.write(to: URL(fileURLWithPath: outputPath))

        try? FileManager.default.removeItem(atPath: mergedWAV)

        return [Artifact(stageId: id, type: .transcriptionSegments, path: outputPath)]
    }

    // MARK: - Merge PCM chunks → WAV

    private func mergeChunksToWAV(chunksDir: String, outputPath: String) throws {
        let fm = FileManager.default
        // Prefer mic channel for transcription, fall back to system
        var files = try fm.contentsOfDirectory(atPath: chunksDir)
            .filter { $0.hasSuffix(".pcm") && $0.contains("_mic") }
            .sorted()

        if files.isEmpty {
            files = try fm.contentsOfDirectory(atPath: chunksDir)
                .filter { $0.hasSuffix(".pcm") && $0.contains("_system") }
                .sorted()
        }

        var allSamples = Data()
        for file in files {
            let path = (chunksDir as NSString).appendingPathComponent(file)
            if let data = fm.contents(atPath: path) {
                allSamples.append(data)
            }
        }

        let sampleRate: UInt32 = 48000
        let bitsPerSample: UInt16 = 32
        let channels: UInt16 = 1
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(allSamples.count)

        var wav = Data()
        wav.append(contentsOf: "RIFF".utf8)
        wav.appendLE(36 + dataSize)
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8)
        wav.appendLE(UInt32(16))
        wav.appendLE(UInt16(3)) // IEEE float
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

    // MARK: - whisper.cpp CLI

    private func runWhisperCpp(wavPath: String, outputDir: String) throws -> [WhisperSegmentOutput] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = [
            "-m", modelPath,
            "-f", wavPath,
            "-l", language,
            "-t", "\(threads)",
            "-oj",
            "-of", (outputDir as NSString).appendingPathComponent("whisper_out"),
            "--no-prints"
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let jsonPath = (outputDir as NSString).appendingPathComponent("whisper_out.json")
        guard FileManager.default.fileExists(atPath: jsonPath) else { return [] }

        let jsonData = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
        let output = try JSONDecoder().decode(WhisperJSONOutput.self, from: jsonData)

        return output.transcription.map { seg in
            WhisperSegmentOutput(
                startTime: seg.offsets.from / 1000.0,
                endTime: seg.offsets.to / 1000.0,
                text: seg.text.trimmingCharacters(in: .whitespaces)
            )
        }
    }

    // MARK: - Fallback

    private func createPlaceholderSegments(wavPath: String) throws -> [WhisperSegmentOutput] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: wavPath),
              let fileSize = attrs[.size] as? Int else { return [] }

        let headerSize = 44
        let dataSize = fileSize - headerSize
        let duration = Double(dataSize / 4) / 48000.0

        guard duration > 0 else { return [] }
        return [WhisperSegmentOutput(
            startTime: 0,
            endTime: duration,
            text: "[Transcription requires whisper-cpp. Install: brew install whisper-cpp]"
        )]
    }

    // MARK: - Find binaries

    private func findWhisperBinary() -> String? {
        ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli",
         "/opt/homebrew/bin/whisper-cpp", "/usr/local/bin/whisper-cpp",
         "/opt/homebrew/bin/main"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    private func findModelPath(modelName: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            (home as NSString).appendingPathComponent(".standup/models/ggml-\(modelName).bin"),
            "/opt/homebrew/share/whisper-cpp/models/ggml-\(modelName).bin",
        ].first { FileManager.default.fileExists(atPath: $0) }
    }
}

// MARK: - Output types

struct WhisperSegmentOutput: Codable {
    let startTime: Double
    let endTime: Double
    let text: String
}

// MARK: - whisper.cpp JSON format

private struct WhisperJSONOutput: Codable {
    let transcription: [WhisperJSONSegment]
}

private struct WhisperJSONSegment: Codable {
    let offsets: WhisperJSONOffsets
    let text: String
}

private struct WhisperJSONOffsets: Codable {
    let from: Double
    let to: Double
}

// MARK: - Data helpers

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }
    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }
}

// JSONEncoder.prettyEncoding is defined in ChannelDiarizerPlugin.swift

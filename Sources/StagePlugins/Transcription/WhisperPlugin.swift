/// Whisper transcription stage plugin.
///
/// Runs whisper.cpp CLI as a subprocess to transcribe audio.
/// User must install whisper-cpp: `brew install whisper-cpp`
///
/// Falls back to a placeholder if whisper-cpp is not available.

import Foundation
import StandupCore

public enum WhisperError: Error, LocalizedError, Sendable {
    case transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .transcriptionFailed(let msg): "Whisper transcription failed: \(msg)"
        }
    }
}

public final class WhisperPlugin: BaseStagePlugin, @unchecked Sendable {
    // SAFETY: Inherits Sendable contract from BaseStagePlugin.
    override public var inputArtifacts: [ArtifactType] { [.audioChunks] }
    override public var outputArtifacts: [ArtifactType] { [.transcriptionSegments] }

    private var modelPath: String = ""
    private var language: String = "auto"
    private var whisperPath: String = ""
    private var threads: Int = 4
    private var maxSegmentSeconds: Int = 30

    public init() {
        super.init(id: "whisper")
    }

    override public func onSetup() async throws {
        language = config.string(for: "language", default: "auto")
        threads = config.int(for: "threads", default: 4)
        maxSegmentSeconds = config.int(for: "max_segment_seconds", default: 30)
        let modelName = config.string(for: "model", default: "small")

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
        let fm = FileManager.default
        if !whisperPath.isEmpty && fm.fileExists(atPath: whisperPath)
            && !modelPath.isEmpty && fm.fileExists(atPath: modelPath) {
            // Split into shorter clips to prevent whisper hallucination on long audio
            let clipPaths = try splitWAVIntoClips(wavPath: mergedWAV, outputDir: outputDir)
            var allSegments: [WhisperSegmentOutput] = []
            for (clipIndex, clipPath) in clipPaths.enumerated() {
                let clipOutputDir = (outputDir as NSString).appendingPathComponent("clip_\(clipIndex)")
                try fm.createDirectory(atPath: clipOutputDir, withIntermediateDirectories: true)
                let clipSegments = try await runWhisperCpp(wavPath: clipPath, outputDir: clipOutputDir)
                let timeOffset = Double(clipIndex * maxSegmentSeconds)
                allSegments.append(contentsOf: clipSegments.map { seg in
                    WhisperSegmentOutput(
                        startTime: seg.startTime + timeOffset,
                        endTime: seg.endTime + timeOffset,
                        text: seg.text
                    )
                })
                // Clean up clip temp files
                try? fm.removeItem(atPath: clipPath)
                try? fm.removeItem(atPath: clipOutputDir)
            }
            segments = deduplicateSegments(allSegments)
        } else {
            segments = try createPlaceholderSegments(wavPath: mergedWAV)
        }

        let outputPath = (outputDir as NSString).appendingPathComponent("segments.json")
        let data = try JSONEncoder.prettyEncoding.encode(segments)
        try data.write(to: URL(fileURLWithPath: outputPath))

        try? FileManager.default.removeItem(atPath: mergedWAV)

        return [Artifact(stageId: context.stageId, type: .transcriptionSegments, path: outputPath)]
    }

    // MARK: - Merge PCM chunks → WAV

    private func mergeChunksToWAV(chunksDir: String, outputPath: String) throws {
        let fm = FileManager.default
        let allFiles = try fm.contentsOfDirectory(atPath: chunksDir)
            .filter { $0.hasSuffix(".pcm") }
            .sorted()

        // Group by chunk index to mix mic + system together
        var chunkIndices: [String: (mic: String?, system: String?)] = [:]
        for file in allFiles {
            // File format: 000001_mic.pcm or 000001_system.pcm
            let name = (file as NSString).deletingPathExtension
            if name.hasSuffix("_mic") {
                let idx = String(name.dropLast(4))
                chunkIndices[idx, default: (nil, nil)].mic = file
            } else if name.hasSuffix("_system") {
                let idx = String(name.dropLast(7))
                chunkIndices[idx, default: (nil, nil)].system = file
            }
        }

        var allSamples = Data()
        for idx in chunkIndices.keys.sorted() {
            let pair = chunkIndices[idx]!
            let micPath = pair.mic.map { (chunksDir as NSString).appendingPathComponent($0) }
            let sysPath = pair.system.map { (chunksDir as NSString).appendingPathComponent($0) }

            let micData = micPath.flatMap { fm.contents(atPath: $0) }
            let sysData = sysPath.flatMap { fm.contents(atPath: $0) }

            // Mix both channels into one for transcription
            if let mic = micData, let sys = sysData {
                let micSamples = mic.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                let sysSamples = sys.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                let count = min(micSamples.count, sysSamples.count)
                var mixed = [Float](repeating: 0, count: count)
                for i in 0..<count {
                    mixed[i] = (micSamples[i] + sysSamples[i]) * 0.5
                }
                // Append any remaining samples from the longer channel
                if micSamples.count > count {
                    mixed.append(contentsOf: micSamples[count...].map { $0 * 0.5 })
                } else if sysSamples.count > count {
                    mixed.append(contentsOf: sysSamples[count...].map { $0 * 0.5 })
                }
                allSamples.append(mixed.withUnsafeBufferPointer { Data(buffer: $0) })
            } else if let data = micData ?? sysData {
                // Single channel: apply same 0.5 gain as mixed path for consistent volume
                let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                let scaled = samples.map { $0 * 0.5 }
                allSamples.append(scaled.withUnsafeBufferPointer { Data(buffer: $0) })
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

    // MARK: - Split WAV into clips

    /// Splits a long WAV into shorter clips to prevent whisper hallucination.
    /// Returns paths to the clip files.
    private func splitWAVIntoClips(wavPath: String, outputDir: String) throws -> [String] {
        let data = try Data(contentsOf: URL(fileURLWithPath: wavPath))
        guard data.count > 44 else { return [wavPath] }

        let sampleRate: Int = 48000
        let bytesPerSample = 4 // Float32
        let samplesPerClip = sampleRate * maxSegmentSeconds
        let bytesPerClip = samplesPerClip * bytesPerSample
        let audioData = data.dropFirst(44)
        let totalBytes = audioData.count

        // If audio fits in one clip, just return the original
        if totalBytes <= bytesPerClip {
            return [wavPath]
        }

        let header = data.prefix(44)
        var paths: [String] = []
        var offset = 0
        var clipIndex = 0

        while offset < totalBytes {
            let remaining = totalBytes - offset
            let clipBytes = min(bytesPerClip, remaining)
            let clipData = audioData[audioData.startIndex + offset ..< audioData.startIndex + offset + clipBytes]

            // Build WAV with updated data size (fmt chunk is bytes 12-35, skip original data header)
            var wav = Data()
            wav.append(contentsOf: "RIFF".utf8)
            wav.appendLE(UInt32(36 + clipBytes))
            wav.append(contentsOf: "WAVE".utf8)
            wav.append(header[12..<36])
            wav.append(contentsOf: "data".utf8)
            wav.appendLE(UInt32(clipBytes))
            wav.append(clipData)

            let clipPath = (outputDir as NSString).appendingPathComponent("clip_\(clipIndex).wav")
            try wav.write(to: URL(fileURLWithPath: clipPath))
            paths.append(clipPath)

            offset += clipBytes
            clipIndex += 1
        }

        return paths
    }

    /// Filters out hallucinated repeated segments.
    private func deduplicateSegments(_ segments: [WhisperSegmentOutput]) -> [WhisperSegmentOutput] {
        guard segments.count > 1 else { return segments }
        var result: [WhisperSegmentOutput] = []
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
            // Skip obviously garbage segments (very short repeated tokens)
            if trimmed.count < 3 { continue }
            result.append(seg)
        }
        return result
    }

    // MARK: - whisper.cpp CLI

    private func runWhisperCpp(wavPath: String, outputDir: String) async throws -> [WhisperSegmentOutput] {
        let whisperPath = self.whisperPath
        let modelPath = self.modelPath
        let language = self.language
        let threads = self.threads

        // Run blocking Process on a non-cooperative thread to avoid blocking the async pool
        let (terminationStatus, stderrData) = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: whisperPath)
            process.arguments = [
                "-m", modelPath,
                "-f", wavPath,
                "-l", language,
                "-t", "\(threads)",
                "-mc", "0",  // no context carry-over between segments (prevents hallucination)
                "-oj",
                "-of", (outputDir as NSString).appendingPathComponent("whisper_out"),
                "--no-prints"
            ]
            let stderrPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderrPipe

            try process.run()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            return (process.terminationStatus, stderrData)
        }.value

        guard terminationStatus == 0 else {
            let errorMsg = String(data: stderrData, encoding: .utf8) ?? "unknown error"
            throw WhisperError.transcriptionFailed("whisper-cpp exited with code \(terminationStatus): \(errorMsg)")
        }

        let jsonPath = (outputDir as NSString).appendingPathComponent("whisper_out.json")
        guard FileManager.default.fileExists(atPath: jsonPath) else {
            throw WhisperError.transcriptionFailed("whisper-cpp produced no output JSON")
        }

        let rawData = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
        // Whisper may emit invalid UTF-8 for non-Latin scripts; sanitize before decoding
        let sanitized = String(data: rawData, encoding: .utf8)
            ?? String(decoding: rawData, as: UTF8.self)
        let jsonData = Data(sanitized.utf8)
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
        let duration = Double(dataSize) / 4.0 / 48000.0

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

/// Bedrock transcription plugin using Amazon Transcribe.
///
/// Uploads session audio to S3, runs a Transcribe batch job, and downloads results.
/// Produces the same TranscriptionSegment JSON as mlx-whisper for pipeline compatibility.
///
/// Config:
///   s3_bucket: S3 bucket for temporary audio upload (required)
///   language: Language code, e.g. "hi-IN", "en-US" (default: "en-US")
///   region: AWS region (default: "us-east-1")
///   profile: AWS CLI profile (optional)

import Foundation
import StandupCore

public final class BedrockTranscribePlugin: BaseStagePlugin, @unchecked Sendable {
    override public var inputArtifacts: [ArtifactType] { [.audioChunks] }
    override public var outputArtifacts: [ArtifactType] { [.transcriptionSegments] }

    private var s3Bucket: String = ""
    private var language: String = "en-US"
    private var aws: AWSCLIRunner = AWSCLIRunner()

    public init() {
        super.init(id: "bedrock-transcribe")
    }

    override public func validate(config: PluginConfig) throws {
        guard !config.string(for: "s3_bucket", default: "").isEmpty else {
            throw BedrockError.missingConfig("s3_bucket is required for bedrock-transcribe")
        }
    }

    override public func onSetup() async throws {
        s3Bucket = config.string(for: "s3_bucket", default: "")
        language = config.string(for: "language", default: "en-US")
        let region = config.string(for: "region", default: "us-east-1")
        let profile: String? = {
            let p = config.string(for: "profile", default: "")
            return p.isEmpty ? nil : p
        }()
        aws = AWSCLIRunner(region: region, profile: profile)
    }

    override public func execute(context: StageContext) async throws -> [Artifact] {
        let outputDir = try ensureOutputDirectory(context: context)

        // Merge chunks to WAV (reuse the PCM→WAV logic)
        let chunksDir = context.inputArtifacts["audio_chunks"]?.path
            ?? (context.sessionDirectory as NSString).appendingPathComponent("chunks")
        let mergedWAV = (outputDir as NSString).appendingPathComponent("merged.wav")
        try mergeChunksToWAV(chunksDir: chunksDir, outputPath: mergedWAV)

        // Upload to S3
        let s3Key = "standup/\(context.sessionId)/audio.wav"
        let s3URI = "s3://\(s3Bucket)/\(s3Key)"
        _ = try await aws.run(service: "s3", args: ["cp", mergedWAV, s3URI])

        // Start transcription job
        let jobName = "standup-\(context.sessionId)-\(Int(Date().timeIntervalSince1970))"
        _ = try await aws.runJSON(service: "transcribe", args: [
            "start-transcription-job",
            "--transcription-job-name", jobName,
            "--language-code", language,
            "--media", "MediaFileUri=\(s3URI)",
            "--output-bucket-name", s3Bucket,
            "--output-key", "standup/\(context.sessionId)/transcript.json",
        ])

        // Poll for completion
        let result = try await pollForCompletion(jobName: jobName)
        guard let transcriptURI = result else {
            throw BedrockError.transcriptionFailed("Job \(jobName) did not complete")
        }

        // Download result
        let rawPath = (outputDir as NSString).appendingPathComponent("aws_transcript.json")
        _ = try await aws.run(service: "s3", args: ["cp", transcriptURI, rawPath])

        // Convert to our segment format
        let segments = try convertTranscribeOutput(rawPath: rawPath)
        let outputPath = (outputDir as NSString).appendingPathComponent("segments.json")
        try JSONEncoder.prettyEncoding.encode(segments).write(to: URL(fileURLWithPath: outputPath))

        // Clean up S3 and local temp files
        _ = try? await aws.run(service: "s3", args: ["rm", s3URI])
        _ = try? await aws.run(service: "s3", args: ["rm", "s3://\(s3Bucket)/standup/\(context.sessionId)/transcript.json"])
        try? FileManager.default.removeItem(atPath: mergedWAV)
        try? FileManager.default.removeItem(atPath: rawPath)

        return [Artifact(stageId: context.stageId, type: .transcriptionSegments, path: outputPath)]
    }

    // MARK: - Polling

    private func pollForCompletion(jobName: String) async throws -> String? {
        let maxAttempts = 60  // 5 minutes at 5s intervals
        for _ in 0..<maxAttempts {
            let json = try await aws.runJSON(service: "transcribe", args: [
                "get-transcription-job",
                "--transcription-job-name", jobName,
            ])

            guard let job = json["TranscriptionJob"] as? [String: Any],
                  let status = job["TranscriptionJobStatus"] as? String else {
                throw BedrockError.transcriptionFailed("Invalid job response")
            }

            switch status {
            case "COMPLETED":
                if let transcript = job["Transcript"] as? [String: Any],
                   let uri = transcript["TranscriptFileUri"] as? String {
                    return uri
                }
                return nil
            case "FAILED":
                let reason = job["FailureReason"] as? String ?? "unknown"
                throw BedrockError.transcriptionFailed("Job failed: \(reason)")
            default:
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        throw BedrockError.transcriptionFailed("Job timed out after 5 minutes")
    }

    // MARK: - Format Conversion

    private func convertTranscribeOutput(rawPath: String) throws -> [TranscriptionSegment] {
        let data = try Data(contentsOf: URL(fileURLWithPath: rawPath))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [String: Any],
              let items = results["items"] as? [[String: Any]] else {
            throw BedrockError.transcriptionFailed("Cannot parse Transcribe output")
        }

        // Group items into segments by punctuation boundaries
        var segments: [TranscriptionSegment] = []
        var currentText = ""
        var segmentStart: Double = 0
        var segmentEnd: Double = 0

        for item in items {
            let itemType = item["type"] as? String ?? ""
            let alternatives = item["alternatives"] as? [[String: Any]] ?? []
            let content = alternatives.first?["content"] as? String ?? ""

            if itemType == "pronunciation" {
                if let startStr = item["start_time"] as? String, let start = Double(startStr) {
                    if currentText.isEmpty { segmentStart = start }
                }
                if let endStr = item["end_time"] as? String, let end = Double(endStr) {
                    segmentEnd = end
                }
                if !currentText.isEmpty { currentText += " " }
                currentText += content
            } else if itemType == "punctuation" {
                currentText += content
                if !currentText.isEmpty {
                    segments.append(TranscriptionSegment(
                        startTime: segmentStart, endTime: segmentEnd, text: currentText
                    ))
                    currentText = ""
                }
            }
        }

        // Flush remaining text
        if !currentText.isEmpty {
            segments.append(TranscriptionSegment(
                startTime: segmentStart, endTime: segmentEnd, text: currentText
            ))
        }

        return segments
    }

    // MARK: - WAV Merge (same logic as MlxWhisperPlugin)

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

        var allSamples = Data()
        for (_, pair) in chunkIndices.sorted(by: { $0.key < $1.key }) {
            let systemData: Data
            if let sys = pair.system {
                systemData = try Data(contentsOf: URL(fileURLWithPath:
                    (chunksDir as NSString).appendingPathComponent(sys)))
            } else {
                let micSize = pair.mic.flatMap {
                    try? Data(contentsOf: URL(fileURLWithPath:
                        (chunksDir as NSString).appendingPathComponent($0)))
                }?.count ?? 0
                systemData = Data(repeating: 0, count: micSize)
            }
            allSamples.append(systemData)
        }

        guard !allSamples.isEmpty else {
            throw BedrockError.transcriptionFailed("No audio chunks in \(chunksDir)")
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
        wav.appendLE(UInt16(3))
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
}

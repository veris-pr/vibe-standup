/// Google Cloud Speech-to-Text plugin.
///
/// Uses the long-running recognize API for batch transcription.
/// Audio is sent as base64-encoded content (no GCS upload needed for <480 min).
///
/// Config:
///   project: GCP project ID (required, or set GOOGLE_CLOUD_PROJECT env var)
///   language: BCP-47 language code, e.g. "hi-IN", "en-US" (default: "en-US")
///   region: GCP region (default: "us-central1")

import Foundation
import StandupCore

public final class GoogleSTTPlugin: BaseStagePlugin, @unchecked Sendable {
    override public var inputArtifacts: [ArtifactType] { [.audioChunks] }
    override public var outputArtifacts: [ArtifactType] { [.transcriptionSegments] }

    private var language: String = "en-US"
    private var gcloud: GoogleCloudRunner = GoogleCloudRunner(project: "")

    public init() {
        super.init(id: "google-stt")
    }

    override public func onSetup() async throws {
        let project = config.string(for: "project", default: "")
            .nonEmpty ?? ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"] ?? ""
        guard !project.isEmpty else {
            throw GoogleCloudError.missingConfig("project is required (config or GOOGLE_CLOUD_PROJECT env var)")
        }
        language = config.string(for: "language", default: "en-US")
        let region = config.string(for: "region", default: "us-central1")
        gcloud = GoogleCloudRunner(project: project, region: region)
    }

    override public func execute(context: StageContext) async throws -> [Artifact] {
        let outputDir = try ensureOutputDirectory(context: context)

        // Merge chunks to WAV
        let chunksDir = context.inputArtifacts["audio_chunks"]?.path
            ?? (context.sessionDirectory as NSString).appendingPathComponent("chunks")
        let mergedWAV = (outputDir as NSString).appendingPathComponent("merged.wav")
        try mergeChunksToWAV(chunksDir: chunksDir, outputPath: mergedWAV)

        // Encode audio as base64
        let audioData = try Data(contentsOf: URL(fileURLWithPath: mergedWAV))
        let base64Audio = audioData.base64EncodedString()

        // Start long-running recognition
        let requestBody: [String: Any] = [
            "config": [
                "encoding": "LINEAR16",
                "sampleRateHertz": 48000,
                "languageCode": language,
                "enableWordTimeOffsets": true,
                "enableAutomaticPunctuation": true,
                "model": "latest_long",
            ],
            "audio": [
                "content": base64Audio
            ]
        ]

        let result = try await gcloud.callAPI(
            url: gcloud.speechToTextURL(),
            body: requestBody
        )

        // Get operation name and poll
        guard let operationName = result["name"] as? String else {
            throw GoogleCloudError.invalidResponse("No operation name in STT response")
        }

        let transcriptResult = try await pollForSTTCompletion(operationName: operationName)
        let segments = parseSTTResult(transcriptResult)

        let outputPath = (outputDir as NSString).appendingPathComponent("segments.json")
        try JSONEncoder.prettyEncoding.encode(segments).write(to: URL(fileURLWithPath: outputPath))

        try? FileManager.default.removeItem(atPath: mergedWAV)

        return [Artifact(stageId: context.stageId, type: .transcriptionSegments, path: outputPath)]
    }

    // MARK: - Polling

    private func pollForSTTCompletion(operationName: String) async throws -> [String: Any] {
        let maxAttempts = 60
        for _ in 0..<maxAttempts {
            let status = try await gcloud.pollOperation(name: operationName)
            if let done = status["done"] as? Bool, done {
                if let response = status["response"] as? [String: Any] {
                    return response
                }
                if let error = status["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    throw GoogleCloudError.requestFailed(service: "STT", status: 0, message: message)
                }
                return status
            }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        throw GoogleCloudError.requestFailed(service: "STT", status: 0, message: "Timed out after 5 minutes")
    }

    // MARK: - Parsing

    private func parseSTTResult(_ result: [String: Any]) -> [TranscriptionSegment] {
        guard let results = result["results"] as? [[String: Any]] else { return [] }

        var segments: [TranscriptionSegment] = []
        for r in results {
            guard let alternatives = r["alternatives"] as? [[String: Any]],
                  let best = alternatives.first,
                  let transcript = best["transcript"] as? String else { continue }

            var startTime: Double = 0
            var endTime: Double = 0

            if let words = best["words"] as? [[String: Any]], !words.isEmpty {
                if let startStr = words.first?["startTime"] as? String {
                    startTime = parseGoogleDuration(startStr)
                }
                if let endStr = words.last?["endTime"] as? String {
                    endTime = parseGoogleDuration(endStr)
                }
            }

            segments.append(TranscriptionSegment(
                startTime: startTime, endTime: endTime, text: transcript
            ))
        }
        return segments
    }

    /// Parse Google's duration format ("1.500s" → 1.5)
    private func parseGoogleDuration(_ str: String) -> Double {
        let cleaned = str.replacingOccurrences(of: "s", with: "")
        return Double(cleaned) ?? 0
    }

    // MARK: - WAV Merge (same as MlxWhisperPlugin)

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
            throw GoogleCloudError.requestFailed(service: "STT", status: 0, message: "No audio chunks")
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

// MARK: - String Extension

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

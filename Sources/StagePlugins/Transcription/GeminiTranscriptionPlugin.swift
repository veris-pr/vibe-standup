/// Gemini transcription stage plugin.
///
/// Uses Google's Gemini API to transcribe audio with timestamps.
/// Requires GEMINI_API_KEY environment variable or `api_key` in stage config.
///
/// Supports multilingual audio natively — no separate model download needed.

import Foundation
import StandupCore

public enum GeminiTranscriptionError: Error, LocalizedError, Sendable {
    case missingAPIKey
    case uploadFailed(String)
    case transcriptionFailed(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Gemini API key not found. Set GEMINI_API_KEY env var or api_key in stage config."
        case .uploadFailed(let msg): "Gemini file upload failed: \(msg)"
        case .transcriptionFailed(let msg): "Gemini transcription failed: \(msg)"
        case .invalidResponse(let msg): "Gemini returned invalid response: \(msg)"
        }
    }
}

public final class GeminiTranscriptionPlugin: BaseStagePlugin, @unchecked Sendable {
    override public var inputArtifacts: [ArtifactType] { [.audioChunks] }
    override public var outputArtifacts: [ArtifactType] { [.transcriptionSegments] }

    private var apiKey: String = ""
    private var model: String = "gemini-2.5-flash"
    private let baseURL = "https://generativelanguage.googleapis.com"

    public init() {
        super.init(id: "gemini-transcription")
    }

    override public func onSetup() async throws {
        apiKey = config.string(for: "api_key", default: "")
        if apiKey.isEmpty {
            apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ""
        }
        model = config.string(for: "model", default: "gemini-2.5-flash")
    }

    override public func execute(context: StageContext) async throws -> [Artifact] {
        guard !apiKey.isEmpty else { throw GeminiTranscriptionError.missingAPIKey }

        let chunksDir = context.inputArtifacts["audio_chunks"]?.path
            ?? (context.sessionDirectory as NSString).appendingPathComponent("chunks")
        let outputDir = try ensureOutputDirectory(context: context)

        // Merge chunks into WAV
        let mergedWAV = (outputDir as NSString).appendingPathComponent("merged.wav")
        try mergeChunksToWAV(chunksDir: chunksDir, outputPath: mergedWAV)

        // Upload audio via Files API
        let fileURI = try await uploadFile(wavPath: mergedWAV)

        // Request transcription
        let segments = try await transcribe(fileURI: fileURI)

        // Write output
        let outputPath = (outputDir as NSString).appendingPathComponent("segments.json")
        let data = try JSONEncoder.prettyEncoding.encode(segments)
        try data.write(to: URL(fileURLWithPath: outputPath))

        // Clean up merged WAV (keep clips dir small)
        try? FileManager.default.removeItem(atPath: mergedWAV)

        return [Artifact(stageId: context.stageId, type: .transcriptionSegments, path: outputPath)]
    }

    // MARK: - Gemini Files API

    private func uploadFile(wavPath: String) async throws -> String {
        let wavData = try Data(contentsOf: URL(fileURLWithPath: wavPath))
        let fileName = (wavPath as NSString).lastPathComponent

        // Step 1: Start resumable upload
        let startURL = URL(string: "\(baseURL)/upload/v1beta/files?key=\(apiKey)")!
        var startReq = URLRequest(url: startURL)
        startReq.httpMethod = "POST"
        startReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        startReq.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        startReq.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        startReq.setValue("audio/wav", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        startReq.setValue("\(wavData.count)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")

        let metadata = ["file": ["display_name": fileName]]
        startReq.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let (_, startResponse) = try await URLSession.shared.data(for: startReq)
        guard let httpResp = startResponse as? HTTPURLResponse,
              let uploadURL = httpResp.value(forHTTPHeaderField: "X-Goog-Upload-URL") else {
            throw GeminiTranscriptionError.uploadFailed("No upload URL in response")
        }

        // Step 2: Upload the actual bytes
        var uploadReq = URLRequest(url: URL(string: uploadURL)!)
        uploadReq.httpMethod = "PUT"
        uploadReq.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        uploadReq.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        uploadReq.httpBody = wavData

        let (uploadData, uploadResponse) = try await URLSession.shared.data(for: uploadReq)
        guard let uploadHTTP = uploadResponse as? HTTPURLResponse, (200...299).contains(uploadHTTP.statusCode) else {
            let body = String(data: uploadData, encoding: .utf8) ?? ""
            throw GeminiTranscriptionError.uploadFailed("Upload failed: \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: uploadData) as? [String: Any],
              let file = json["file"] as? [String: Any],
              let uri = file["uri"] as? String else {
            throw GeminiTranscriptionError.uploadFailed("No file URI in upload response")
        }

        // Step 3: Wait for file to become ACTIVE
        let name = file["name"] as? String ?? ""
        try await waitForFileActive(name: name)

        return uri
    }

    private func waitForFileActive(name: String) async throws {
        let maxAttempts = 30
        for _ in 0..<maxAttempts {
            let url = URL(string: "\(baseURL)/v1beta/\(name)?key=\(apiKey)")!
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let state = json["state"] as? String {
                if state == "ACTIVE" { return }
                if state == "FAILED" {
                    throw GeminiTranscriptionError.uploadFailed("File processing failed")
                }
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw GeminiTranscriptionError.uploadFailed("File did not become ACTIVE within timeout")
    }

    // MARK: - Transcription

    private func transcribe(fileURI: String) async throws -> [GeminiSegmentOutput] {
        let url = URL(string: "\(baseURL)/v1beta/models/\(model):generateContent?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        let prompt = """
        Transcribe this audio with timestamps. The audio may contain Hindi, English, or mixed Hindi-English (Hinglish).

        Output ONLY a JSON array with this exact format, no markdown fences, no explanation:
        [{"start": 0.0, "end": 5.2, "speaker": "Speaker 1", "text": "transcribed text here"}, ...]

        Rules:
        - Use seconds for start/end timestamps
        - Identify different speakers as "Speaker 1", "Speaker 2", etc.
        - Transcribe Hindi in Devanagari script
        - Transcribe English in Latin script
        - Keep code-switched words in their original script
        - If a segment is unclear, still attempt transcription
        - Do not skip silent gaps, just don't create segments for them
        """

        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["file_data": ["mime_type": "audio/wav", "file_uri": fileURI]],
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.1,
                "maxOutputTokens": 8192
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiTranscriptionError.transcriptionFailed("No HTTP response")
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GeminiTranscriptionError.transcriptionFailed("HTTP \(http.statusCode): \(body.prefix(500))")
        }

        // Parse Gemini response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw GeminiTranscriptionError.invalidResponse("Could not extract text from response")
        }

        return parseTranscriptionResponse(text)
    }

    private func parseTranscriptionResponse(_ text: String) -> [GeminiSegmentOutput] {
        // Extract JSON array from response (may have markdown fences)
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            // Fallback: return the whole text as one segment
            return [GeminiSegmentOutput(startTime: 0, endTime: 0, text: text, speaker: nil)]
        }

        return array.compactMap { item -> GeminiSegmentOutput? in
            guard let start = item["start"] as? Double,
                  let end = item["end"] as? Double,
                  let text = item["text"] as? String else { return nil }
            let speaker = item["speaker"] as? String
            return GeminiSegmentOutput(startTime: start, endTime: end, text: text, speaker: speaker)
        }
    }

    // MARK: - Merge PCM chunks → WAV (shared with WhisperPlugin)

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
        for idx in chunkIndices.keys.sorted() {
            let pair = chunkIndices[idx]!
            let micPath = pair.mic.map { (chunksDir as NSString).appendingPathComponent($0) }
            let sysPath = pair.system.map { (chunksDir as NSString).appendingPathComponent($0) }

            let micData = micPath.flatMap { fm.contents(atPath: $0) }
            let sysData = sysPath.flatMap { fm.contents(atPath: $0) }

            if let mic = micData, let sys = sysData {
                let micSamples = mic.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                let sysSamples = sys.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                let count = min(micSamples.count, sysSamples.count)
                var mixed = [Float](repeating: 0, count: count)
                for i in 0..<count {
                    mixed[i] = (micSamples[i] + sysSamples[i]) * 0.5
                }
                if micSamples.count > count {
                    mixed.append(contentsOf: micSamples[count...].map { $0 * 0.5 })
                } else if sysSamples.count > count {
                    mixed.append(contentsOf: sysSamples[count...].map { $0 * 0.5 })
                }
                allSamples.append(mixed.withUnsafeBufferPointer { Data(buffer: $0) })
            } else if let data = micData ?? sysData {
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
}

// MARK: - Output type (same shape as WhisperSegmentOutput for downstream compatibility)

struct GeminiSegmentOutput: Codable {
    let startTime: Double
    let endTime: Double
    let text: String
    let speaker: String?
}

// Data.appendLE is defined in WhisperPlugin.swift

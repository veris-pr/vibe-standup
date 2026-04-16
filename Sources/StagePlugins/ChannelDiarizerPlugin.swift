/// Channel-based diarization stage plugin.
///
/// Labels transcript segments as "me" (mic channel) or "them" (system channel)
/// by analyzing voice activity per channel using RMS energy detection.

import Foundation
import StandupCore

public final class ChannelDiarizerPlugin: StagePlugin, @unchecked Sendable {
    public let id = "channel-diarizer"
    public let version = "1.0.0"
    public let inputArtifacts: [ArtifactType] = [.audioChunks]
    public let outputArtifacts: [ArtifactType] = [.diarizationLabels]

    private var vadThresholdDB: Double = -40

    public init() {}

    public func setup(config: PluginConfig) async throws {
        vadThresholdDB = config.double(for: "vad_threshold_db", default: -40)
    }

    public func teardown() async {}

    public func execute(context: SessionContext) async throws -> [ArtifactRef] {
        let chunksDir = context.inputArtifacts["audio_chunks"]?.path
            ?? (context.sessionDirectory as NSString).appendingPathComponent("chunks")

        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(atPath: chunksDir).sorted()

        let thresholdLinear = Float(pow(10.0, vadThresholdDB / 20.0))
        var segments: [DiarizationSegment] = []

        // Group chunks by their index to pair mic/system
        var chunksByIndex: [String: (mic: String?, system: String?)] = [:]
        for file in files where file.hasSuffix(".pcm") {
            let parts = file.replacingOccurrences(of: ".pcm", with: "").split(separator: "_")
            guard parts.count == 2 else { continue }
            let index = String(parts[0])
            let channel = String(parts[1])
            if chunksByIndex[index] == nil {
                chunksByIndex[index] = (nil, nil)
            }
            let path = (chunksDir as NSString).appendingPathComponent(file)
            if channel == "mic" {
                chunksByIndex[index]?.mic = path
            } else {
                chunksByIndex[index]?.system = path
            }
        }

        let sampleRate = AudioCaptureEngine.sampleRate
        var timeOffset: Double = 0

        for index in chunksByIndex.keys.sorted() {
            guard let pair = chunksByIndex[index] else { continue }

            let micRMS = pair.mic.flatMap { computeRMS(filePath: $0) } ?? 0
            let sysRMS = pair.system.flatMap { computeRMS(filePath: $0) } ?? 0

            // Determine who is speaking
            let micActive = micRMS > thresholdLinear
            let sysActive = sysRMS > thresholdLinear

            let chunkDuration: Double
            if let micPath = pair.mic {
                let fileSize = (try? fm.attributesOfItem(atPath: micPath)[.size] as? Int) ?? 0
                let frameCount = fileSize / MemoryLayout<Float>.size
                chunkDuration = Double(frameCount) / sampleRate
            } else {
                chunkDuration = 1.0
            }

            let speaker: String
            if micActive && sysActive {
                speaker = micRMS > sysRMS ? "me" : "them"
            } else if micActive {
                speaker = "me"
            } else if sysActive {
                speaker = "them"
            } else {
                speaker = "silence"
            }

            if speaker != "silence" {
                segments.append(DiarizationSegment(
                    startTime: timeOffset,
                    endTime: timeOffset + chunkDuration,
                    speaker: speaker
                ))
            }

            timeOffset += chunkDuration
        }

        // Merge adjacent segments from same speaker
        let merged = mergeAdjacentSegments(segments)

        // Write output
        let outputDir = context.outputDirectory(for: id)
        let outputPath = (outputDir as NSString).appendingPathComponent("speakers.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(merged)
        try data.write(to: URL(fileURLWithPath: outputPath))

        return [ArtifactRef(stageId: id, type: .diarizationLabels, path: outputPath)]
    }

    private func computeRMS(filePath: String) -> Float? {
        guard let data = FileManager.default.contents(atPath: filePath) else { return nil }
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return nil }

        return data.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            var sumSquares: Float = 0
            for i in 0..<count {
                sumSquares += floats[i] * floats[i]
            }
            return (sumSquares / Float(count)).squareRoot()
        }
    }

    private func mergeAdjacentSegments(_ segments: [DiarizationSegment]) -> [DiarizationSegment] {
        guard !segments.isEmpty else { return [] }
        var merged: [DiarizationSegment] = [segments[0]]
        for i in 1..<segments.count {
            if segments[i].speaker == merged.last!.speaker {
                merged[merged.count - 1].endTime = segments[i].endTime
            } else {
                merged.append(segments[i])
            }
        }
        return merged
    }
}

struct DiarizationSegment: Codable {
    let startTime: Double
    var endTime: Double
    let speaker: String
}

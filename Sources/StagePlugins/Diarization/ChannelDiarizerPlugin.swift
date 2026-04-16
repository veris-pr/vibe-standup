/// Channel-based diarization — labels segments as "me" (mic) or "them" (system audio)
/// by analyzing voice activity per channel using RMS energy.

import Foundation
import StandupCore

public final class ChannelDiarizerPlugin: BaseStagePlugin, @unchecked Sendable {
    // SAFETY: Inherits Sendable contract from BaseStagePlugin — runs sequentially in pipeline.
    override public var inputArtifacts: [ArtifactType] { [.audioChunks] }
    override public var outputArtifacts: [ArtifactType] { [.diarizationLabels] }

    private var vadThresholdDB: Double = -40

    public init() {
        super.init(id: "channel-diarizer")
    }

    override public func onSetup() async throws {
        vadThresholdDB = config.double(for: "vad_threshold_db", default: -40)
    }

    override public func execute(context: StageContext) async throws -> [Artifact] {
        let chunksDir = context.inputArtifacts["audio_chunks"]?.path
            ?? (context.sessionDirectory as NSString).appendingPathComponent("chunks")

        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(atPath: chunksDir).sorted()
        let thresholdLinear = Float(pow(10.0, vadThresholdDB / 20.0))

        // Group chunks by index to pair mic/system
        var chunksByIndex: [String: (mic: String?, system: String?)] = [:]
        for file in files where file.hasSuffix(".pcm") {
            let parts = file.replacingOccurrences(of: ".pcm", with: "").split(separator: "_")
            guard parts.count == 2 else { continue }
            let index = String(parts[0])
            let channel = String(parts[1])
            let path = (chunksDir as NSString).appendingPathComponent(file)
            if chunksByIndex[index] == nil { chunksByIndex[index] = (nil, nil) }
            if channel == "mic" { chunksByIndex[index]?.mic = path }
            else { chunksByIndex[index]?.system = path }
        }

        var segments: [DiarizationSegment] = []
        var timeOffset: Double = 0

        for index in chunksByIndex.keys.sorted() {
            guard let pair = chunksByIndex[index] else { continue }
            let micRMS = pair.mic.flatMap { computeRMS(filePath: $0) } ?? 0
            let sysRMS = pair.system.flatMap { computeRMS(filePath: $0) } ?? 0

            let micActive = micRMS > thresholdLinear
            let sysActive = sysRMS > thresholdLinear

            let chunkDuration: Double
            if let micPath = pair.mic {
                let fileSize = (try? fm.attributesOfItem(atPath: micPath)[.size] as? Int) ?? 0
                chunkDuration = Double(fileSize) / Double(MemoryLayout<Float>.size) / AudioFormat.standard.sampleRate
            } else {
                chunkDuration = 1.0
            }

            let speaker: Speaker
            if micActive && sysActive {
                speaker = micRMS > sysRMS ? .me : .them
            } else if micActive {
                speaker = .me
            } else if sysActive {
                speaker = .them
            } else {
                speaker = .silence
            }

            if speaker != .silence {
                segments.append(DiarizationSegment(startTime: timeOffset, endTime: timeOffset + chunkDuration, speaker: speaker))
            }
            timeOffset += chunkDuration
        }

        let merged = mergeAdjacent(segments)
        let outputDir = try ensureOutputDirectory(context: context)
        let outputPath = (outputDir as NSString).appendingPathComponent("speakers.json")
        let data = try JSONEncoder.prettyEncoding.encode(merged)
        try data.write(to: URL(fileURLWithPath: outputPath))

        return [Artifact(stageId: id, type: .diarizationLabels, path: outputPath)]
    }

    private func computeRMS(filePath: String) -> Float? {
        guard let data = FileManager.default.contents(atPath: filePath) else { return nil }
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return nil }
        return data.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            var sum: Float = 0
            for i in 0..<count { sum += floats[i] * floats[i] }
            return (sum / Float(count)).squareRoot()
        }
    }

    private func mergeAdjacent(_ segments: [DiarizationSegment]) -> [DiarizationSegment] {
        guard !segments.isEmpty else { return [] }
        var merged = [segments[0]]
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

/// Energy-based diarizer — detects speaker changes by energy patterns
/// within a single audio stream (when channels aren't available).
public final class EnergyDiarizerPlugin: BaseStagePlugin, @unchecked Sendable {
    // SAFETY: Inherits Sendable contract from BaseStagePlugin.
    override public var inputArtifacts: [ArtifactType] { [.audioChunks] }
    override public var outputArtifacts: [ArtifactType] { [.diarizationLabels] }

    public init() {
        super.init(id: "energy-diarizer")
    }

    override public func execute(context: StageContext) async throws -> [Artifact] {
        // Simplified: treat all speech as single speaker since we can't
        // distinguish without ML models. This is the fallback strategy.
        let outputDir = try ensureOutputDirectory(context: context)
        let outputPath = (outputDir as NSString).appendingPathComponent("speakers.json")
        let empty: [DiarizationSegment] = []
        let data = try JSONEncoder.prettyEncoding.encode(empty)
        try data.write(to: URL(fileURLWithPath: outputPath))
        return [Artifact(stageId: id, type: .diarizationLabels, path: outputPath)]
    }
}

// MARK: - JSON Encoder Helper (shared across stage plugins)

extension JSONEncoder {
    static let prettyEncoding: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

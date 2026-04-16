/// Pipeline engine — parses YAML pipeline definitions and executes stage DAGs.

import Foundation
import Yams

// MARK: - Pipeline Definition (parsed from YAML)

public struct PipelineDefinition: Sendable {
    public let name: String
    public let description: String
    public let liveChains: LiveChainConfig
    public let stages: [StageDefinition]

    public init(name: String, description: String, liveChains: LiveChainConfig, stages: [StageDefinition]) {
        self.name = name
        self.description = description
        self.liveChains = liveChains
        self.stages = stages
    }
}

public struct LiveChainConfig: Sendable {
    public let mic: [LivePluginRef]
    public let system: [LivePluginRef]

    public init(mic: [LivePluginRef] = [], system: [LivePluginRef] = []) {
        self.mic = mic
        self.system = system
    }
}

public struct LivePluginRef: Sendable {
    public let pluginId: String
    public let config: [String: String]

    public init(pluginId: String, config: [String: String] = [:]) {
        self.pluginId = pluginId
        self.config = config
    }
}

public struct StageDefinition: Sendable {
    public let id: String
    public let pluginId: String
    public let inputs: [String]  // stage IDs or "audio_chunks"
    public let config: [String: String]

    public init(id: String, pluginId: String, inputs: [String] = [], config: [String: String] = [:]) {
        self.id = id
        self.pluginId = pluginId
        self.inputs = inputs
        self.config = config
    }
}

// MARK: - YAML Parser

public enum PipelineParser {
    public static func parse(yaml: String) throws -> PipelineDefinition {
        guard let doc = try Yams.load(yaml: yaml) as? [String: Any] else {
            throw PipelineError.invalidYAML
        }

        let name = doc["name"] as? String ?? "unnamed"
        let description = doc["description"] as? String ?? ""

        // Parse live chains
        var micRefs: [LivePluginRef] = []
        var sysRefs: [LivePluginRef] = []
        if let live = doc["live"] as? [String: Any] {
            micRefs = parseLiveRefs(live["mic"])
            sysRefs = parseLiveRefs(live["system"])
        }

        // Parse stages
        var stages: [StageDefinition] = []
        if let stageList = doc["stages"] as? [[String: Any]] {
            for s in stageList {
                let id = s["id"] as? String ?? "unknown"
                let pluginId = s["plugin"] as? String ?? id

                var inputs: [String] = []
                if let inp = s["input"] as? String {
                    inputs = [inp]
                } else if let inps = s["inputs"] as? [String] {
                    inputs = inps
                }

                let config = flattenConfig(s["config"])
                stages.append(StageDefinition(id: id, pluginId: pluginId, inputs: inputs, config: config))
            }
        }

        return PipelineDefinition(
            name: name,
            description: description,
            liveChains: LiveChainConfig(mic: micRefs, system: sysRefs),
            stages: stages
        )
    }

    public static func load(from path: String) throws -> PipelineDefinition {
        let yaml = try String(contentsOfFile: path, encoding: .utf8)
        return try parse(yaml: yaml)
    }

    private static func parseLiveRefs(_ value: Any?) -> [LivePluginRef] {
        guard let list = value as? [[String: Any]] else { return [] }
        return list.map { item in
            let pluginId = item["plugin"] as? String ?? "unknown"
            let config = flattenConfig(item["config"])
            return LivePluginRef(pluginId: pluginId, config: config)
        }
    }

    private static func flattenConfig(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (k, v) in dict {
            result[k] = "\(v)"
        }
        return result
    }
}

// MARK: - Pipeline Engine

public final class PipelineEngine: @unchecked Sendable {
    private let registry: PluginRegistry

    public init(registry: PluginRegistry) {
        self.registry = registry
    }

    /// Build live plugin chains from a pipeline definition.
    public func buildLiveChains(from definition: PipelineDefinition) async throws -> (mic: LivePluginChain, system: LivePluginChain) {
        let micChain = LivePluginChain(channel: .mic)
        for ref in definition.liveChains.mic {
            guard let plugin = registry.livePlugin(id: ref.pluginId) else {
                throw PipelineError.pluginNotFound(ref.pluginId)
            }
            try await plugin.setup(config: PluginConfig(values: ref.config))
            micChain.add(plugin)
        }

        let systemChain = LivePluginChain(channel: .system)
        for ref in definition.liveChains.system {
            guard let plugin = registry.livePlugin(id: ref.pluginId) else {
                throw PipelineError.pluginNotFound(ref.pluginId)
            }
            try await plugin.setup(config: PluginConfig(values: ref.config))
            systemChain.add(plugin)
        }

        return (micChain, systemChain)
    }

    /// Execute the post-session stage pipeline.
    public func executeStages(definition: PipelineDefinition, session: SessionInfo) async throws {
        // Topological sort of stages based on input dependencies
        let ordered = try topologicalSort(definition.stages)
        var artifacts: [String: ArtifactRef] = [:]

        for stage in ordered {
            guard let plugin = registry.stagePlugin(id: stage.pluginId) else {
                throw PipelineError.pluginNotFound(stage.pluginId)
            }

            // Gather input artifacts for this stage
            var stageInputs: [String: ArtifactRef] = [:]
            for input in stage.inputs {
                if input == "audio_chunks" {
                    stageInputs["audio_chunks"] = ArtifactRef(
                        stageId: "capture",
                        type: .audioChunks,
                        path: (session.directoryPath as NSString).appendingPathComponent("chunks")
                    )
                } else {
                    // Input references another stage's output: "stage_id.output" or just "stage_id"
                    let stageId = input.replacingOccurrences(of: ".output", with: "")
                    if let ref = artifacts[stageId] {
                        stageInputs[stageId] = ref
                    }
                }
            }

            let context = SessionContext(
                sessionId: session.id,
                sessionDirectory: session.directoryPath,
                inputArtifacts: stageInputs,
                config: PluginConfig(values: stage.config)
            )

            // Create output directory
            let outputDir = context.outputDirectory(for: stage.id)
            try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

            // Setup, execute, teardown
            try await plugin.setup(config: PluginConfig(values: stage.config))
            let outputs = try await plugin.execute(context: context)
            await plugin.teardown()

            // Store first output artifact for downstream stages
            if let output = outputs.first {
                artifacts[stage.id] = output
            }
        }
    }

    /// Simple topological sort based on input references.
    private func topologicalSort(_ stages: [StageDefinition]) throws -> [StageDefinition] {
        let stageMap = Dictionary(uniqueKeysWithValues: stages.map { ($0.id, $0) })
        var visited = Set<String>()
        var result: [StageDefinition] = []

        func visit(_ id: String) throws {
            guard !visited.contains(id) else { return }
            guard let stage = stageMap[id] else { return }
            visited.insert(id)

            for input in stage.inputs {
                let depId = input.replacingOccurrences(of: ".output", with: "")
                if stageMap[depId] != nil {
                    try visit(depId)
                }
            }
            result.append(stage)
        }

        for stage in stages {
            try visit(stage.id)
        }
        return result
    }
}

// MARK: - Errors

public enum PipelineError: Error, LocalizedError {
    case invalidYAML
    case pluginNotFound(String)
    case cyclicDependency

    public var errorDescription: String? {
        switch self {
        case .invalidYAML: "Invalid pipeline YAML"
        case .pluginNotFound(let id): "Plugin not found: \(id)"
        case .cyclicDependency: "Cyclic dependency detected in pipeline stages"
        }
    }
}

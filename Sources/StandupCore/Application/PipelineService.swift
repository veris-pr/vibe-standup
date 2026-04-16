/// Application service: orchestrates pipeline parsing and execution.

import Foundation
import Yams

public final class PipelineService: @unchecked Sendable {
    private let registry: PluginRegistry

    public init(registry: PluginRegistry) {
        self.registry = registry
    }

    // MARK: - Live Chain Building

    /// Build live plugin chains from a pipeline definition.
    public func buildLiveChains(from definition: PipelineDefinition) async throws -> (mic: LivePluginChain, system: LivePluginChain) {
        let micChain = LivePluginChain(channel: .mic)
        for ref in definition.liveChains.mic {
            let pluginConfig = PluginConfig(values: ref.config)
            let plugin = try registry.resolveLivePlugin(id: ref.pluginId, config: pluginConfig)
            try await plugin.setup(config: pluginConfig)
            micChain.add(plugin)
        }

        let systemChain = LivePluginChain(channel: .system)
        for ref in definition.liveChains.system {
            let pluginConfig = PluginConfig(values: ref.config)
            let plugin = try registry.resolveLivePlugin(id: ref.pluginId, config: pluginConfig)
            try await plugin.setup(config: pluginConfig)
            systemChain.add(plugin)
        }

        return (micChain, systemChain)
    }

    // MARK: - Stage Execution

    /// Execute the post-session stage pipeline.
    public func executeStages(definition: PipelineDefinition, session: Session) async throws {
        let ordered = topologicalSort(definition.stages)
        var artifacts: [String: Artifact] = [:]

        for stage in ordered {
            let pluginConfig = PluginConfig(values: stage.config)
            let plugin = try registry.resolveStagePlugin(id: stage.pluginId, config: pluginConfig)

            var stageInputs: [String: Artifact] = [:]
            for input in stage.inputs {
                if input == "audio_chunks" {
                    stageInputs["audio_chunks"] = Artifact(
                        stageId: "capture",
                        type: .audioChunks,
                        path: session.chunksPath
                    )
                } else {
                    let stageId = input.replacingOccurrences(of: ".output", with: "")
                    if let ref = artifacts[stageId] {
                        stageInputs[stageId] = ref
                    }
                }
            }

            let context = StageContext(
                sessionId: session.id,
                sessionDirectory: session.directoryPath,
                inputArtifacts: stageInputs,
                config: pluginConfig
            )

            let outputDir = context.outputDirectory(for: stage.id)
            try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

            try await plugin.setup(config: pluginConfig)
            let outputs = try await plugin.execute(context: context)
            await plugin.teardown()

            if let output = outputs.first {
                artifacts[stage.id] = output
            }
        }
    }

    // MARK: - Pipeline Parsing

    /// Parse a pipeline definition from YAML string.
    public static func parse(yaml: String) throws -> PipelineDefinition {
        guard let doc = try Yams.load(yaml: yaml) as? [String: Any] else {
            throw PipelineError.invalidYAML
        }

        let name = doc["name"] as? String ?? "unnamed"
        let description = doc["description"] as? String ?? ""

        var micRefs: [PluginRef] = []
        var sysRefs: [PluginRef] = []
        if let live = doc["live"] as? [String: Any] {
            micRefs = parseLiveRefs(live["mic"])
            sysRefs = parseLiveRefs(live["system"])
        }

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

    /// Load a pipeline definition from a YAML file.
    public static func load(from path: String) throws -> PipelineDefinition {
        let yaml = try String(contentsOfFile: path, encoding: .utf8)
        return try parse(yaml: yaml)
    }

    // MARK: - Helpers

    private static func parseLiveRefs(_ value: Any?) -> [PluginRef] {
        guard let list = value as? [[String: Any]] else { return [] }
        return list.map { item in
            let pluginId = item["plugin"] as? String ?? "unknown"
            let config = flattenConfig(item["config"])
            return PluginRef(pluginId: pluginId, config: config)
        }
    }

    private static func flattenConfig(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        return dict.reduce(into: [:]) { $0[$1.key] = "\($1.value)" }
    }

    private func topologicalSort(_ stages: [StageDefinition]) -> [StageDefinition] {
        let stageMap = Dictionary(uniqueKeysWithValues: stages.map { ($0.id, $0) })
        var visited = Set<String>()
        var result: [StageDefinition] = []

        func visit(_ id: String) {
            guard !visited.contains(id), let stage = stageMap[id] else { return }
            visited.insert(id)
            for input in stage.inputs {
                let depId = input.replacingOccurrences(of: ".output", with: "")
                if stageMap[depId] != nil { visit(depId) }
            }
            result.append(stage)
        }

        for stage in stages { visit(stage.id) }
        return result
    }
}

/// Application service: orchestrates pipeline parsing and execution.

import Foundation

public final class PipelineService: @unchecked Sendable {
    // SAFETY: @unchecked Sendable — registry is populated at startup and then read-only.
    // Methods called sequentially from session lifecycle.
    private let registry: PluginRegistry

    public init(registry: PluginRegistry) {
        self.registry = registry
    }

    // MARK: - Pipeline Loading (delegates to Infrastructure)

    /// Parse a pipeline definition from YAML string.
    public static func parse(yaml: String) throws -> PipelineDefinition {
        try PipelineYAMLParser.parse(yaml: yaml)
    }

    /// Load a pipeline definition from a YAML file.
    public static func load(from path: String) throws -> PipelineDefinition {
        try PipelineYAMLParser.load(from: path)
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
                    let stageId = input.hasSuffix(".output")
                        ? String(input.dropLast(7))
                        : input
                    guard let ref = artifacts[stageId] else {
                        throw PipelineError.missingField("Stage '\(stage.id)' references input '\(input)' but stage '\(stageId)' produced no output")
                    }
                    stageInputs[stageId] = ref
                }
            }

            let context = StageContext(
                sessionId: session.id,
                sessionDirectory: session.directoryPath,
                stageId: stage.id,
                inputArtifacts: stageInputs,
                config: pluginConfig
            )

            do {
                try await plugin.setup(config: pluginConfig)
                let outputs = try await plugin.execute(context: context)
                await plugin.teardown()

                // Store all output artifacts, keyed as "stageId" for first, "stageId.N" for subsequent
                for (i, output) in outputs.enumerated() {
                    let key = i == 0 ? stage.id : "\(stage.id).\(i)"
                    artifacts[key] = output
                }
            } catch {
                await plugin.teardown()
                throw PipelineError.stageExecutionFailed(stageId: stage.id, underlying: error)
            }
        }
    }

    // MARK: - Helpers

    private func topologicalSort(_ stages: [StageDefinition]) -> [StageDefinition] {
        let stageMap = Dictionary(uniqueKeysWithValues: stages.map { ($0.id, $0) })
        var visited = Set<String>()
        var result: [StageDefinition] = []

        func visit(_ id: String) {
            guard !visited.contains(id), let stage = stageMap[id] else { return }
            visited.insert(id)
            for input in stage.inputs {
                let depId = input.hasSuffix(".output")
                    ? String(input.dropLast(7))
                    : input
                if stageMap[depId] != nil { visit(depId) }
            }
            result.append(stage)
        }

        for stage in stages { visit(stage.id) }
        return result
    }
}

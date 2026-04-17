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

    /// Callback invoked as each stage transitions.
    public typealias StageProgressCallback = (String, StageStatus) -> Void

    /// Execute the post-session stage pipeline. Automatically resumes from the last
    /// successful stage if a `pipeline-state.json` exists (unless reset).
    public func executeStages(
        definition: PipelineDefinition,
        session: Session,
        onProgress: StageProgressCallback? = nil
    ) async throws {
        let ordered = topologicalSort(definition.stages)

        // Load existing state or create fresh
        var state = PipelineState.load(from: session.directoryPath)
            ?? PipelineState(
                pipelineName: definition.name,
                stages: ordered.map { StageState(id: $0.id, status: .pending) }
            )

        // Build set of completed stage IDs and recover their artifacts
        var artifacts: [String: Artifact] = [:]
        let doneIds = Set(state.stages.filter { $0.status == .done }.map(\.id))
        for stageState in state.stages where stageState.status == .done {
            if let artifact = stageState.artifact {
                artifacts[stageState.id] = artifact
            }
        }

        for stage in ordered {
            // Skip already-completed stages
            if doneIds.contains(stage.id) {
                onProgress?(stage.id, .done)
                continue
            }

            // Mark running
            updateStageStatus(&state, stageId: stage.id, status: .running)
            try? state.save(to: session.directoryPath)
            onProgress?(stage.id, .running)

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

                // Store all output artifacts
                let primaryArtifact = outputs.first
                for (i, output) in outputs.enumerated() {
                    let key = i == 0 ? stage.id : "\(stage.id).\(i)"
                    artifacts[key] = output
                }

                // Persist done state with primary artifact
                updateStageStatus(&state, stageId: stage.id, status: .done, artifact: primaryArtifact)
                try? state.save(to: session.directoryPath)
                onProgress?(stage.id, .done)
            } catch {
                await plugin.teardown()
                updateStageStatus(&state, stageId: stage.id, status: .failed, error: error.localizedDescription)
                try? state.save(to: session.directoryPath)
                onProgress?(stage.id, .failed)
                throw PipelineError.stageExecutionFailed(stageId: stage.id, underlying: error)
            }
        }
    }

    /// Reset pipeline state for a session — deletes state file and stage output directories.
    public static func resetPipeline(session: Session, definition: PipelineDefinition) {
        PipelineState.remove(from: session.directoryPath)
        let fm = FileManager.default
        for stage in definition.stages {
            let stageDir = (session.directoryPath as NSString).appendingPathComponent(stage.id)
            try? fm.removeItem(atPath: stageDir)
        }
    }

    private func updateStageStatus(_ state: inout PipelineState, stageId: String, status: StageStatus, artifact: Artifact? = nil, error: String? = nil) {
        if let idx = state.stages.firstIndex(where: { $0.id == stageId }) {
            state.stages[idx].status = status
            if let artifact { state.stages[idx].artifact = artifact }
            if let error { state.stages[idx].error = error }
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

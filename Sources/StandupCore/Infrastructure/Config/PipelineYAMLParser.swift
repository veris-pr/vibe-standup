/// Infrastructure: YAML parsing for pipeline definitions.
///
/// Lives in Infrastructure because it depends on Yams (a library detail).
/// PipelineService delegates to this for loading pipeline configs.

import Foundation
import Yams

/// Parses pipeline YAML into domain PipelineDefinition values.
public enum PipelineYAMLParser {

    /// Parse a pipeline definition from YAML string.
    public static func parse(yaml: String) throws -> PipelineDefinition {
        guard let doc = try Yams.load(yaml: yaml) as? [String: Any] else {
            throw PipelineError.invalidYAML
        }

        guard let name = doc["name"] as? String else {
            throw PipelineError.missingField("name")
        }
        let description = doc["description"] as? String ?? ""

        // Parse capture source configuration
        var captureSource: AudioCaptureSource? = nil
        var virtualDeviceName: String? = nil
        if let capture = doc["capture"] as? [String: Any] {
            if let sourceStr = capture["source"] as? String {
                captureSource = AudioCaptureSource(rawValue: sourceStr)
            }
            virtualDeviceName = capture["virtual_device"] as? String
        } else if let sourceStr = doc["capture_source"] as? String {
            captureSource = AudioCaptureSource(rawValue: sourceStr)
        }

        var micRefs: [PluginRef] = []
        var systemRefs: [PluginRef] = []
        if let live = doc["live"] as? [String: Any] {
            micRefs = try parseLiveRefs(live["mic"])
            systemRefs = try parseLiveRefs(live["system"])
        }

        var stages: [StageDefinition] = []
        if let stageList = doc["stages"] as? [[String: Any]] {
            for s in stageList {
                guard let id = s["id"] as? String else {
                    throw PipelineError.missingField("stages[].id")
                }
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
            captureSource: captureSource,
            virtualDeviceName: virtualDeviceName,
            liveChains: LiveChainConfig(mic: micRefs, system: systemRefs),
            stages: stages
        )
    }

    /// Load a pipeline definition from a YAML file.
    public static func load(from path: String) throws -> PipelineDefinition {
        let yaml = try String(contentsOfFile: path, encoding: .utf8)
        return try parse(yaml: yaml)
    }

    // MARK: - Helpers

    private static func parseLiveRefs(_ value: Any?) throws -> [PluginRef] {
        guard let list = value as? [[String: Any]] else { return [] }
        return try list.map { item in
            guard let pluginId = item["plugin"] as? String else {
                throw PipelineError.missingField("live[].plugin")
            }
            let config = flattenConfig(item["config"])
            return PluginRef(pluginId: pluginId, config: config)
        }
    }

    private static func flattenConfig(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        return dict.reduce(into: [:]) { $0[$1.key] = "\($1.value)" }
    }
}

/// Bedrock image generation plugin using Stability AI via AWS Bedrock.
///
/// Drop-in replacement for the local mflux-based ImageGenPlugin.
/// Uses `aws bedrock-runtime invoke-model` with Stability AI SDXL.
///
/// Config:
///   model_id: Bedrock model ID (default: "stability.stable-diffusion-xl-v1")
///   region: AWS region (default: "us-east-1")
///   profile: AWS CLI profile (optional)
///   width: Image width (default: 512)
///   height: Image height (default: 512)
///   steps: Inference steps (default: 30)

import Foundation
import StandupCore

public final class BedrockImageGenPlugin: BaseStagePlugin, @unchecked Sendable {
    override public var inputArtifacts: [ArtifactType] { [.comicScript] }
    override public var outputArtifacts: [ArtifactType] { [.panelImages] }

    private var modelId: String = "stability.stable-diffusion-xl-v1"
    private var width: Int = 512
    private var height: Int = 512
    private var steps: Int = 30
    private var aws: AWSCLIRunner = AWSCLIRunner()

    public init() {
        super.init(id: "bedrock-image-gen")
    }

    override public func onSetup() async throws {
        modelId = config.string(for: "model_id", default: "stability.stable-diffusion-xl-v1")
        width = config.int(for: "width", default: 512)
        height = config.int(for: "height", default: 512)
        steps = config.int(for: "steps", default: 30)
        let region = config.string(for: "region", default: "us-east-1")
        let profile: String? = {
            let p = config.string(for: "profile", default: "")
            return p.isEmpty ? nil : p
        }()
        aws = AWSCLIRunner(region: region, profile: profile)
    }

    override public func execute(context: StageContext) async throws -> [Artifact] {
        guard let scriptRef = context.inputArtifacts.values.first(where: { $0.type == .comicScript })
                ?? context.inputArtifacts["comic-script"] else {
            throw BedrockError.missingConfig("comic script input not found")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: scriptRef.path))
        let script = try JSONDecoder().decode(ComicScript.self, from: data)

        let outputDir = try ensureOutputDirectory(context: context)
        var manifest: [PanelImageEntry] = []
        var warnings: [String] = []

        for panel in script.panels {
            let pngPath = (outputDir as NSString).appendingPathComponent("panel_\(panel.index).png")
            do {
                try await generateImage(prompt: panel.imagePrompt, outputPath: pngPath)
                manifest.append(PanelImageEntry(index: panel.index, path: "panel_\(panel.index).png", format: "png"))
            } catch {
                warnings.append("Panel \(panel.index): Bedrock image gen failed (\(error.localizedDescription))")
                // Generate SVG placeholder as fallback
                let color = script.characters.first { $0.heroName == panel.heroName }?.color ?? "#4A90D9"
                let svgPath = (outputDir as NSString).appendingPathComponent("panel_\(panel.index).svg")
                try generateSVGFallback(panel: panel, color: color, outputPath: svgPath)
                manifest.append(PanelImageEntry(index: panel.index, path: "panel_\(panel.index).svg", format: "svg"))
            }
        }

        let manifestData = ImageManifest(panels: manifest, warnings: warnings)
        let manifestPath = (outputDir as NSString).appendingPathComponent("manifest.json")
        try JSONEncoder.prettyEncoding.encode(manifestData).write(to: URL(fileURLWithPath: manifestPath))

        return [Artifact(stageId: context.stageId, type: .panelImages, path: manifestPath)]
    }

    // MARK: - Image Generation

    private func generateImage(prompt: String, outputPath: String) async throws {
        let body: [String: Any] = [
            "text_prompts": [
                ["text": prompt, "weight": 1.0]
            ],
            "cfg_scale": 7,
            "steps": steps,
            "width": width,
            "height": height,
            "seed": Int.random(in: 0...4294967295),
        ]

        let bodyJSON = try JSONSerialization.data(withJSONObject: body)
        let tempInput = NSTemporaryDirectory() + "bedrock_img_in_\(UUID().uuidString).json"
        let tempOutput = NSTemporaryDirectory() + "bedrock_img_out_\(UUID().uuidString).json"
        defer {
            try? FileManager.default.removeItem(atPath: tempInput)
            try? FileManager.default.removeItem(atPath: tempOutput)
        }
        try bodyJSON.write(to: URL(fileURLWithPath: tempInput))

        _ = try await aws.run(service: "bedrock-runtime", args: [
            "invoke-model",
            "--model-id", modelId,
            "--content-type", "application/json",
            "--accept", "application/json",
            "--body", "fileb://\(tempInput)",
            tempOutput,
        ])

        let outputData = try Data(contentsOf: URL(fileURLWithPath: tempOutput))
        guard let json = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any],
              let artifacts = json["artifacts"] as? [[String: Any]],
              let first = artifacts.first,
              let base64Image = first["base64"] as? String,
              let imageData = Data(base64Encoded: base64Image) else {
            throw BedrockError.invalidResponse("Cannot decode image from Bedrock response")
        }

        try imageData.write(to: URL(fileURLWithPath: outputPath))
    }

    // MARK: - SVG Fallback

    private func generateSVGFallback(panel: ComicScriptPanel, color: String, outputPath: String) throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
          <rect width="512" height="512" fill="#FFFDE7"/>
          <rect x="4" y="4" width="504" height="504" rx="8" fill="none" stroke="#333" stroke-width="4"/>
          <circle cx="256" cy="180" r="80" fill="\(color)" stroke="#333" stroke-width="3"/>
          <text x="256" y="200" text-anchor="middle" font-size="60">\(panel.mood.emoji)</text>
          <rect x="56" y="370" width="400" height="80" rx="20" fill="white" stroke="#333" stroke-width="2"/>
          <text x="256" y="418" text-anchor="middle" font-family="sans-serif" font-size="16" fill="#333">"\(escapeXML(panel.dialogue))"</text>
        </svg>
        """
        try svg.write(toFile: outputPath, atomically: true, encoding: .utf8)
    }

    private func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

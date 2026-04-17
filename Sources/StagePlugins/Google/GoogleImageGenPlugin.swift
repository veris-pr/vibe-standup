/// Google Cloud image generation plugin using Imagen via Vertex AI.
///
/// Drop-in replacement for the local mflux-based ImageGenPlugin.
/// Uses Vertex AI's predict endpoint with Imagen models.
///
/// Config:
///   project: GCP project ID (required, or set GOOGLE_CLOUD_PROJECT env var)
///   model: Imagen model name (default: "imagen-3.0-generate-001")
///   region: GCP region (default: "us-central1")
///   width: Image width — not configurable for Imagen, included for pipeline compat
///   height: Image height — not configurable for Imagen, included for pipeline compat

import Foundation
import StandupCore

public final class GoogleImageGenPlugin: BaseStagePlugin, @unchecked Sendable {
    override public var inputArtifacts: [ArtifactType] { [.comicScript] }
    override public var outputArtifacts: [ArtifactType] { [.panelImages] }

    private var model: String = "imagen-3.0-generate-001"
    private var gcloud: GoogleCloudRunner = GoogleCloudRunner(project: "")

    public init() {
        super.init(id: "google-image-gen")
    }

    override public func onSetup() async throws {
        let project = config.string(for: "project", default: "")
            .nonEmpty ?? ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"] ?? ""
        guard !project.isEmpty else {
            throw GoogleCloudError.missingConfig("project is required (config or GOOGLE_CLOUD_PROJECT env var)")
        }
        model = config.string(for: "model", default: "imagen-3.0-generate-001")
        let region = config.string(for: "region", default: "us-central1")
        gcloud = GoogleCloudRunner(project: project, region: region)
    }

    override public func execute(context: StageContext) async throws -> [Artifact] {
        guard let scriptRef = context.inputArtifacts.values.first(where: { $0.type == .comicScript })
                ?? context.inputArtifacts["comic-script"] else {
            throw GoogleCloudError.missingConfig("comic script input not found")
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
                warnings.append("Panel \(panel.index): Imagen failed (\(error.localizedDescription))")
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
            "instances": [
                ["prompt": prompt]
            ],
            "parameters": [
                "sampleCount": 1,
            ]
        ]

        let url = gcloud.vertexAIURL(model: model, method: "predict")
        let json = try await gcloud.callAPI(url: url, body: body)

        guard let predictions = json["predictions"] as? [[String: Any]],
              let first = predictions.first,
              let base64Image = first["bytesBase64Encoded"] as? String,
              let imageData = Data(base64Encoded: base64Image) else {
            throw GoogleCloudError.invalidResponse("Cannot decode image from Imagen response")
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

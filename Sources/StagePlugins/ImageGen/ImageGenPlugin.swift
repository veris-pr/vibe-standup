/// Image generation stage plugin.
///
/// Takes a comic script and generates panel images using a local image model.
/// Uses mflux (MLX-based Stable Diffusion/FLUX) as subprocess.
///
/// Falls back to colored SVG placeholder panels if mflux is not available.

import Foundation
import StandupCore

public final class ImageGenPlugin: BaseStagePlugin, @unchecked Sendable {
    override public var inputArtifacts: [ArtifactType] { [.comicScript] }
    override public var outputArtifacts: [ArtifactType] { [.panelImages] }

    private var model: String = "schnell"
    private var steps: Int = 4
    private var width: Int = 512
    private var height: Int = 512
    private var mfluxPath: String = ""

    public init() {
        super.init(id: "image-gen")
    }

    override public func onSetup() async throws {
        model = config.string(for: "model", default: "schnell")
        steps = config.int(for: "steps", default: 4)
        width = config.int(for: "width", default: 512)
        height = config.int(for: "height", default: 512)
        mfluxPath = config.string(for: "mflux_path", default: "")
        if mfluxPath.isEmpty {
            mfluxPath = findMflux() ?? ""
        }
    }

    override public func execute(context: StageContext) async throws -> [Artifact] {
        guard let scriptRef = context.inputArtifacts.values.first(where: { $0.type == .comicScript })
                ?? context.inputArtifacts["comic-script"] else {
            throw ImageGenError.missingInput("comic script")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: scriptRef.path))
        let script = try JSONDecoder().decode(ComicScript.self, from: data)

        let outputDir = try ensureOutputDirectory(context: context)
        let fm = FileManager.default

        // Build character color map for SVG fallback
        let characterColors = Dictionary(uniqueKeysWithValues: script.characters.map { ($0.heroName, $0.color) })

        for panel in script.panels {
            let imagePath = (outputDir as NSString).appendingPathComponent("panel_\(panel.index).png")

            if !mfluxPath.isEmpty && fm.fileExists(atPath: mfluxPath) {
                try await generateWithMflux(prompt: panel.imagePrompt, outputPath: imagePath)
            } else {
                let color = characterColors[panel.heroName] ?? "#4A90D9"
                try generateSVGPlaceholder(panel: panel, color: color, outputPath: imagePath)
            }
        }

        // Write manifest so the renderer knows which images were generated
        let manifest = script.panels.map { panel in
            PanelImageEntry(index: panel.index, path: "panel_\(panel.index).png")
        }
        let manifestPath = (outputDir as NSString).appendingPathComponent("manifest.json")
        try JSONEncoder.prettyEncoding.encode(manifest).write(to: URL(fileURLWithPath: manifestPath))

        return [Artifact(stageId: id, type: .panelImages, path: manifestPath)]
    }

    // MARK: - mflux Generation

    private func generateWithMflux(prompt: String, outputPath: String) async throws {
        let mflux = self.mfluxPath
        let model = self.model
        let steps = self.steps
        let width = self.width
        let height = self.height

        let (terminationStatus, stderrData) = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: mflux)
            process.arguments = [
                "--model", model,
                "--prompt", prompt,
                "--output", outputPath,
                "--steps", "\(steps)",
                "--width", "\(width)",
                "--height", "\(height)",
                "-q", "4"  // 4-bit quantization for speed on 16GB
            ]
            process.standardOutput = FileHandle.nullDevice
            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            try process.run()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            return (process.terminationStatus, stderrData)
        }.value

        guard terminationStatus == 0 else {
            let msg = String(data: stderrData, encoding: .utf8) ?? "unknown"
            throw ImageGenError.generationFailed("mflux exited with code \(terminationStatus): \(msg)")
        }
    }

    // MARK: - SVG Placeholder Fallback

    private func generateSVGPlaceholder(panel: ComicScriptPanel, color: String, outputPath: String) throws {
        // Generate a simple SVG comic panel as placeholder
        let svg = renderPlaceholderSVG(panel: panel, color: color)

        // Write as SVG (rename to .svg for clarity, but keep .png path for manifest consistency)
        let svgPath = outputPath.replacingOccurrences(of: ".png", with: ".svg")
        try svg.write(toFile: svgPath, atomically: true, encoding: .utf8)

        // Also write the SVG at the png path so manifest works uniformly
        try svg.write(toFile: outputPath, atomically: true, encoding: .utf8)
    }

    private func renderPlaceholderSVG(panel: ComicScriptPanel, color: String) -> String {
        let moodEmoji = panel.mood.emoji
        let bgColor = color
        let textColor = isLightColor(color) ? "#333333" : "#FFFFFF"

        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
          <defs>
            <pattern id="dots" x="0" y="0" width="10" height="10" patternUnits="userSpaceOnUse">
              <circle cx="5" cy="5" r="1.5" fill="\(bgColor)" opacity="0.3"/>
            </pattern>
          </defs>
          <!-- Background -->
          <rect width="512" height="512" fill="#FFFDE7"/>
          <rect width="512" height="512" fill="url(#dots)"/>
          <!-- Panel border -->
          <rect x="4" y="4" width="504" height="504" rx="8" fill="none" stroke="#333" stroke-width="4"/>
          <!-- Character circle -->
          <circle cx="256" cy="180" r="80" fill="\(bgColor)" stroke="#333" stroke-width="3"/>
          <!-- Hero emblem -->
          <text x="256" y="200" text-anchor="middle" font-size="60">\(moodEmoji)</text>
          <!-- Hero name banner -->
          <rect x="126" y="270" width="260" height="36" rx="18" fill="\(bgColor)" stroke="#333" stroke-width="2"/>
          <text x="256" y="295" text-anchor="middle" font-family="'Comic Sans MS', cursive" font-size="18" font-weight="bold" fill="\(textColor)">\(escapeXML(panel.heroName))</text>
          <!-- Scene description -->
          <text x="256" y="340" text-anchor="middle" font-family="'Comic Sans MS', cursive" font-size="12" fill="#666">
            \(escapeXML(String(panel.sceneDescription.prefix(50))))
          </text>
          <!-- Speech bubble -->
          <rect x="56" y="370" width="400" height="80" rx="20" fill="white" stroke="#333" stroke-width="2"/>
          <polygon points="150,370 170,350 190,370" fill="white" stroke="#333" stroke-width="2"/>
          <rect x="56" y="371" width="400" height="5" fill="white"/>
          <text x="256" y="418" text-anchor="middle" font-family="'Comic Sans MS', cursive" font-size="16" font-weight="bold" fill="#333">
            "\(escapeXML(panel.dialogue))"
          </text>
          <!-- Install hint -->
          <text x="256" y="495" text-anchor="middle" font-size="9" fill="#BBB">Install mflux for AI-generated art: pip install mflux</text>
        </svg>
        """
    }

    // MARK: - Helpers

    private func findMflux() -> String? {
        // Check common locations for mflux-generate
        let candidates = [
            "/opt/homebrew/bin/mflux-generate",
            "/usr/local/bin/mflux-generate",
        ]
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return found
        }

        // Check in Python venv paths
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let venvPaths = [
            (home as NSString).appendingPathComponent(".local/bin/mflux-generate"),
            (home as NSString).appendingPathComponent(".standup/venv/bin/mflux-generate"),
        ]
        return venvPaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func isLightColor(_ hex: String) -> Bool {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard clean.count == 6,
              let rgb = UInt32(clean, radix: 16) else { return false }
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.6
    }

    private func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - Types

struct PanelImageEntry: Codable {
    let index: Int
    let path: String
}

enum ImageGenError: Error, LocalizedError, Sendable {
    case missingInput(String)
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingInput(let what): "Image gen missing input: \(what)"
        case .generationFailed(let msg): "Image generation failed: \(msg)"
        }
    }
}

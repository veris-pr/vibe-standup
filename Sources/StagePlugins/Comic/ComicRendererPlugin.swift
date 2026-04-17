/// Comic renderer stage plugin.
///
/// Assembles generated panel images and comic script into a self-contained HTML comic.
/// Embeds images as base64 data URIs (or inline SVG) for portability.
/// Falls back to text-only rendering if panel images aren't available.

import Foundation
import StandupCore

public final class ComicRendererPlugin: BaseStagePlugin, @unchecked Sendable {
    // SAFETY: Inherits Sendable contract from BaseStagePlugin.
    override public var inputArtifacts: [ArtifactType] { [.comicScript] }
    override public var outputArtifacts: [ArtifactType] { [.comicOutput] }

    private var title: String = "Standup Comic"

    public init() {
        super.init(id: "comic-renderer")
    }

    override public func onSetup() async throws {
        title = config.string(for: "title", default: "Standup Comic")
    }

    override public func execute(context: StageContext) async throws -> [Artifact] {
        // Load comic script
        guard let scriptRef = context.inputArtifacts.values.first(where: { $0.type == .comicScript })
                ?? context.inputArtifacts["comic-script"] else {
            throw RenderError.missingInput("comic script")
        }

        let scriptData = try Data(contentsOf: URL(fileURLWithPath: scriptRef.path))
        let script = try JSONDecoder().decode(ComicScript.self, from: scriptData)

        // Load panel manifest if available
        let panelManifest: RendererManifest?
        let imageDir: String?
        if let imagesRef = context.inputArtifacts.values.first(where: { $0.type == .panelImages })
            ?? context.inputArtifacts["panel-render"] {
            let manifestData = try Data(contentsOf: URL(fileURLWithPath: imagesRef.path))
            panelManifest = try JSONDecoder().decode(RendererManifest.self, from: manifestData)
            imageDir = (imagesRef.path as NSString).deletingLastPathComponent
        } else {
            panelManifest = nil
            imageDir = nil
        }

        let html = renderHTML(script: script, imageDir: imageDir, manifest: panelManifest)

        let outputDir = try ensureOutputDirectory(context: context)
        let outputPath = (outputDir as NSString).appendingPathComponent("comic.html")
        try html.write(toFile: outputPath, atomically: true, encoding: String.Encoding.utf8)

        return [Artifact(stageId: context.stageId, type: .comicOutput, path: outputPath)]
    }

    // MARK: - HTML Rendering

    private func renderHTML(script: ComicScript, imageDir: String?, manifest: RendererManifest?) -> String {
        let characterColors = Dictionary(uniqueKeysWithValues: script.characters.map {
            ($0.heroName, $0.color)
        })
        let panelLookup: [Int: RendererPanelEntry] = {
            guard let m = manifest else { return [:] }
            return Dictionary(uniqueKeysWithValues: m.panels.map { ($0.index, $0) })
        }()

        let panelHTML = script.panels.map { panel -> String in
            let color = characterColors[panel.heroName] ?? "#4A90D9"
            let moodEmoji = panel.mood.emoji
            let entry = panelLookup[panel.index]
            let imageContent = loadPanelImage(entry: entry, imageDir: imageDir, fallbackColor: color)

            return """
            <div class="panel">
                <div class="panel-image">
                    \(imageContent)
                </div>
                <div class="panel-overlay">
                    <div class="speech-bubble">
                        <p>"\(escapeHTML(panel.dialogue))"</p>
                    </div>
                    <div class="speaker-badge" style="background: \(color);">
                        \(escapeHTML(panel.heroName)) \(moodEmoji)
                    </div>
                </div>
            </div>
            """
        }.joined(separator: "\n")

        // Character legend
        let legendHTML = script.characters.map { char in
            """
            <div class="legend-item">
                <span class="legend-dot" style="background: \(char.color);"></span>
                <strong>\(escapeHTML(char.heroName))</strong>
                <span class="legend-speaker">(\(escapeHTML(char.speakerId)))</span>
                <span class="legend-costume">\(escapeHTML(char.costume))</span>
            </div>
            """
        }.joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>\(escapeHTML(script.title))</title>
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                body {
                    font-family: 'Comic Sans MS', 'Chalkboard SE', 'Marker Felt', cursive, sans-serif;
                    background: #1a1a2e;
                    color: white;
                    padding: 20px;
                }
                h1 {
                    text-align: center;
                    font-size: 2.2em;
                    margin-bottom: 8px;
                    color: #FFD700;
                    text-shadow: 3px 3px 0 #333;
                    letter-spacing: 2px;
                }
                .subtitle {
                    text-align: center;
                    color: #AAA;
                    margin-bottom: 24px;
                    font-size: 0.9em;
                }
                .comic-grid {
                    display: grid;
                    grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
                    gap: 16px;
                    max-width: 1100px;
                    margin: 0 auto 30px;
                }
                .panel {
                    position: relative;
                    border: 4px solid #333;
                    border-radius: 8px;
                    overflow: hidden;
                    background: white;
                    aspect-ratio: 1;
                    transition: transform 0.2s;
                }
                .panel:hover { transform: scale(1.02); box-shadow: 0 8px 24px rgba(0,0,0,0.4); }
                .panel-image {
                    width: 100%;
                    height: 100%;
                }
                .panel-image img, .panel-image svg {
                    width: 100%;
                    height: 100%;
                    object-fit: cover;
                    display: block;
                }
                .panel-overlay {
                    position: absolute;
                    bottom: 0;
                    left: 0;
                    right: 0;
                    padding: 12px;
                }
                .speech-bubble {
                    background: rgba(255,255,255,0.95);
                    border: 3px solid #333;
                    border-radius: 16px;
                    padding: 10px 14px;
                    margin-bottom: 8px;
                    position: relative;
                }
                .speech-bubble::after {
                    content: '';
                    position: absolute;
                    top: -12px;
                    left: 24px;
                    border-width: 0 8px 12px;
                    border-style: solid;
                    border-color: transparent transparent #333;
                }
                .speech-bubble p {
                    font-size: 1em;
                    color: #333;
                    font-weight: bold;
                    line-height: 1.3;
                }
                .speaker-badge {
                    display: inline-block;
                    padding: 4px 12px;
                    border-radius: 12px;
                    font-size: 0.8em;
                    font-weight: bold;
                    color: white;
                    border: 2px solid #333;
                }
                .legend {
                    max-width: 1100px;
                    margin: 0 auto 20px;
                    background: #16213e;
                    border-radius: 12px;
                    padding: 16px 20px;
                }
                .legend h2 {
                    font-size: 1.1em;
                    color: #FFD700;
                    margin-bottom: 10px;
                }
                .legend-item {
                    display: flex;
                    align-items: center;
                    gap: 8px;
                    margin-bottom: 6px;
                    font-size: 0.9em;
                }
                .legend-dot {
                    width: 14px;
                    height: 14px;
                    border-radius: 50%;
                    border: 2px solid #333;
                    flex-shrink: 0;
                }
                .legend-speaker { color: #888; }
                .legend-costume { color: #AAA; font-style: italic; }
                .footer {
                    text-align: center;
                    margin-top: 20px;
                    color: #555;
                    font-size: 0.8em;
                }
                @media (max-width: 700px) {
                    .comic-grid { grid-template-columns: 1fr; }
                }
            </style>
        </head>
        <body>
            <h1>⚡ \(escapeHTML(script.title))</h1>
            <p class="subtitle">\(script.panels.count) panels · \(script.characters.count) heroes</p>
            <div class="legend">
                <h2>🦸 Cast</h2>
                \(legendHTML)
            </div>
            <div class="comic-grid">
                \(panelHTML)
            </div>
            <div class="footer">
                Generated by Standup · Superhero Comic Edition
            </div>
        </body>
        </html>
        """
    }

    // MARK: - Image Loading

    private func loadPanelImage(entry: RendererPanelEntry?, imageDir: String?, fallbackColor: String) -> String {
        guard let entry, let dir = imageDir else {
            return colorFallback(fallbackColor)
        }

        let filePath = (dir as NSString).appendingPathComponent(entry.path)
        let fm = FileManager.default

        guard fm.fileExists(atPath: filePath) else {
            return colorFallback(fallbackColor)
        }

        if entry.format == "svg" {
            // Inline SVG directly
            if let text = try? String(contentsOfFile: filePath, encoding: .utf8) {
                return text
            }
            return colorFallback(fallbackColor)
        }

        // PNG/other binary — embed as base64
        if let data = fm.contents(atPath: filePath) {
            let base64 = data.base64EncodedString()
            return "<img src=\"data:image/png;base64,\(base64)\" alt=\"Panel \(entry.index)\">"
        }

        return colorFallback(fallbackColor)
    }

    private func colorFallback(_ color: String) -> String {
        "<div style=\"width:100%;height:100%;background:\(color);opacity:0.3;\"></div>"
    }

    // MARK: - Helpers

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Types

private enum RenderError: Error, LocalizedError, Sendable {
    case missingInput(String)
    var errorDescription: String? {
        switch self {
        case .missingInput(let what): "Comic renderer missing input: \(what)"
        }
    }
}

/// Mirrors ImageGen's manifest — kept private to avoid coupling.
private struct RendererManifest: Codable {
    let panels: [RendererPanelEntry]
    let warnings: [String]
}

private struct RendererPanelEntry: Codable {
    let index: Int
    let path: String
    let format: String
}

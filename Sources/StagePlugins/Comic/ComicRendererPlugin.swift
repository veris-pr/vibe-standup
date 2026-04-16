/// Comic renderer stage plugin.
///
/// Transforms comic panel definitions into an HTML/SVG comic strip.
/// Outputs a self-contained HTML file with inline CSS and SVG.

import Foundation
import StandupCore

public final class ComicRendererPlugin: BaseStagePlugin, @unchecked Sendable {
    override public var inputArtifacts: [ArtifactType] { [.comicPanels] }
    override public var outputArtifacts: [ArtifactType] { [.comicOutput] }

    private var title: String = "Standup Comic"

    public init() {
        super.init(id: "comic-renderer")
    }

    override public func onSetup() async throws {
        title = config.string(for: "title", default: "Standup Comic")
    }

    override public func execute(context: StageContext) async throws -> [Artifact] {
        guard let panelsRef = context.inputArtifacts.values.first(where: { $0.type == .comicPanels })
                ?? context.inputArtifacts["comic-formatter"] else {
            throw RenderError.missingInput("comic panels")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: panelsRef.path))
        let panels = try JSONDecoder().decode([ComicPanelInput].self, from: data)

        let html = renderHTML(panels: panels)

        let outputDir = try ensureOutputDirectory(context: context)
        let outputPath = (outputDir as NSString).appendingPathComponent("comic.html")
        try html.write(toFile: outputPath, atomically: true, encoding: .utf8)

        return [Artifact(stageId: id, type: .comicOutput, path: outputPath)]
    }

    // MARK: - HTML Rendering

    private func renderHTML(panels: [ComicPanelInput]) -> String {
        // Assign consistent colors to speakers
        var speakerColors: [String: SpeakerStyle] = [:]
        let palette: [SpeakerStyle] = [
            SpeakerStyle(bg: "#4A90D9", text: "#FFFFFF", bubble: "#E8F0FE"),
            SpeakerStyle(bg: "#D94A4A", text: "#FFFFFF", bubble: "#FEE8E8"),
            SpeakerStyle(bg: "#4AD94A", text: "#FFFFFF", bubble: "#E8FEE8"),
            SpeakerStyle(bg: "#D9D94A", text: "#333333", bubble: "#FEFEE8"),
            SpeakerStyle(bg: "#9B59B6", text: "#FFFFFF", bubble: "#F0E8FE"),
            SpeakerStyle(bg: "#E67E22", text: "#FFFFFF", bubble: "#FEF0E8"),
        ]
        var colorIndex = 0
        for panel in panels {
            if speakerColors[panel.speaker] == nil {
                speakerColors[panel.speaker] = palette[colorIndex % palette.count]
                colorIndex += 1
            }
        }

        let panelHTML = panels.map { panel -> String in
            let style = speakerColors[panel.speaker] ?? palette[0]
            let moodEmoji = moodToEmoji(panel.mood)
            let sizeClass = panel.panelSize == "large" ? "panel-large" : "panel-normal"

            return """
            <div class="panel \(sizeClass)">
                <div class="panel-inner">
                    <div class="speaker-badge" style="background: \(style.bg); color: \(style.text);">
                        \(escapeHTML(panel.speaker)) \(moodEmoji)
                    </div>
                    <div class="speech-bubble" style="background: \(style.bubble);">
                        <p>\(escapeHTML(panel.text))</p>
                    </div>
                    <div class="timestamp">\(formatTime(panel.startTime))</div>
                </div>
            </div>
            """
        }.joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>\(escapeHTML(title))</title>
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                body {
                    font-family: 'Comic Sans MS', 'Chalkboard SE', 'Marker Felt', cursive, sans-serif;
                    background: #F5F5F0;
                    padding: 20px;
                }
                h1 {
                    text-align: center;
                    font-size: 2em;
                    margin-bottom: 20px;
                    color: #333;
                    text-shadow: 2px 2px 0 #DDD;
                }
                .comic-grid {
                    display: grid;
                    grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
                    gap: 12px;
                    max-width: 900px;
                    margin: 0 auto;
                }
                .panel {
                    border: 3px solid #333;
                    border-radius: 8px;
                    background: white;
                    overflow: hidden;
                    transition: transform 0.2s;
                }
                .panel:hover { transform: scale(1.02); }
                .panel-large { grid-column: span 2; }
                .panel-inner { padding: 16px; }
                .speaker-badge {
                    display: inline-block;
                    padding: 4px 12px;
                    border-radius: 12px;
                    font-size: 0.85em;
                    font-weight: bold;
                    margin-bottom: 8px;
                }
                .speech-bubble {
                    border: 2px solid #333;
                    border-radius: 12px;
                    padding: 12px 16px;
                    position: relative;
                    margin-bottom: 8px;
                }
                .speech-bubble::after {
                    content: '';
                    position: absolute;
                    bottom: -10px;
                    left: 20px;
                    border-width: 10px 8px 0;
                    border-style: solid;
                    border-color: #333 transparent transparent;
                }
                .speech-bubble p {
                    font-size: 1.05em;
                    line-height: 1.4;
                    color: #333;
                }
                .timestamp {
                    font-size: 0.7em;
                    color: #999;
                    text-align: right;
                }
                .footer {
                    text-align: center;
                    margin-top: 20px;
                    color: #AAA;
                    font-size: 0.8em;
                }
                @media (max-width: 600px) {
                    .panel-large { grid-column: span 1; }
                    .comic-grid { grid-template-columns: 1fr; }
                }
            </style>
        </head>
        <body>
            <h1>📋 \(escapeHTML(title))</h1>
            <div class="comic-grid">
                \(panelHTML)
            </div>
            <div class="footer">
                Generated by Standup · \(panels.count) panels
            </div>
        </body>
        </html>
        """
    }

    // MARK: - Helpers

    private func moodToEmoji(_ mood: String) -> String {
        switch mood {
        case "excited": return "🎉"
        case "proud": return "💪"
        case "frustrated": return "😤"
        case "thinking": return "🤔"
        case "asking": return "❓"
        case "happy": return "😊"
        default: return "💬"
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Types

private struct ComicPanelInput: Codable {
    let index: Int
    let speaker: String
    let text: String
    let mood: String
    let startTime: Double
    let duration: Double
    let importance: Double
    let panelSize: String
}

private struct SpeakerStyle {
    let bg: String
    let text: String
    let bubble: String
}

private enum RenderError: Error, LocalizedError {
    case missingInput(String)
    var errorDescription: String? {
        switch self {
        case .missingInput(let what): "Comic renderer missing input: \(what)"
        }
    }
}

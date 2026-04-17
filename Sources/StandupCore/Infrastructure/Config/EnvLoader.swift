/// Infrastructure: Loads environment variables from a .env file.
///
/// Reads `~/.standup/.env` and sets any variables not already in the environment.
/// Existing env vars take precedence (so system/shell overrides work).

import Foundation

public enum EnvLoader {
    /// Load .env from the standup base directory. Skips silently if file doesn't exist.
    public static func loadIfPresent(from directory: String? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = directory ?? (home as NSString).appendingPathComponent(".standup")
        let envPath = (dir as NSString).appendingPathComponent(".env")

        guard let contents = try? String(contentsOfFile: envPath, encoding: .utf8) else {
            return
        }

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)

            // Strip surrounding quotes
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }

            guard !key.isEmpty else { continue }

            // Don't override existing environment variables
            if ProcessInfo.processInfo.environment[key] == nil {
                setenv(key, value, 0)
            }
        }
    }
}

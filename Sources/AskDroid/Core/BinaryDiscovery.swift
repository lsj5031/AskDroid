import Foundation

enum BinaryDiscovery {
    static let fallbackCandidates: [String] = [
        "~/.local/bin/droid",
        "~/.local/share/mise/shims/droid",
        "~/.mise/shims/droid",
        "/opt/homebrew/bin/droid",
        "/usr/local/bin/droid",
    ]

    static func resolve(override: String, fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> String? {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return fileExists(expanded) ? expanded : nil
        }

        if let fromPath = firstOnPath(named: "droid", fileExists: fileExists) {
            return fromPath
        }

        for candidate in fallbackCandidates {
            let expanded = (candidate as NSString).expandingTildeInPath
            if fileExists(expanded) {
                return expanded
            }
        }
        return nil
    }

    static func firstOnPath(
        named name: String,
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        fileExists: (String) -> Bool
    ) -> String? {
        let entries = (path ?? "").split(separator: ":").map(String.init)
        for entry in entries where !entry.isEmpty {
            let candidate = (entry as NSString).appendingPathComponent(name)
            if fileExists(candidate) {
                return candidate
            }
        }
        return nil
    }
}

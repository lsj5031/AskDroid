import Foundation

enum BinaryDiscovery {
    static let droidFallbackCandidates: [String] = [
        "~/.local/bin/droid",
        "~/.local/share/mise/shims/droid",
        "~/.mise/shims/droid",
        "/opt/homebrew/bin/droid",
        "/usr/local/bin/droid",
    ]

    static let piFallbackCandidates: [String] = [
        "~/.local/bin/pi",
        "~/.local/share/mise/shims/pi",
        "~/.npm-global/bin/pi",
        "/opt/homebrew/bin/pi",
        "/usr/local/bin/pi",
    ]

    static let fallbackCandidates = droidFallbackCandidates

    static func resolve(
        engine: Engine,
        override: String,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> String? {
        switch engine {
        case .droid:
            resolve(override: override, binaryName: "droid", fallbackCandidates: droidFallbackCandidates, fileExists: fileExists)
        case .pi:
            resolve(override: override, binaryName: "pi", fallbackCandidates: piFallbackCandidates, fileExists: fileExists)
        }
    }

    static func resolve(
        override: String,
        binaryName: String = "droid",
        fallbackCandidates: [String] = droidFallbackCandidates,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> String? {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return fileExists(expanded) ? expanded : nil
        }

        if let fromPath = firstOnPath(named: binaryName, fileExists: fileExists) {
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

    static func resolve(
        binaryName: String,
        override: String,
        fallbackCandidates: [String],
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> String? {
        resolve(override: override, binaryName: binaryName, fallbackCandidates: fallbackCandidates, fileExists: fileExists)
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

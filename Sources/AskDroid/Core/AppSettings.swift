import Foundation

enum AutonomySetting: String, CaseIterable, Identifiable, Sendable {
    case droidDefault = ""
    case off = "off"
    case low = "low"
    case medium = "medium"
    case high = "high"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .droidDefault: "Droid default"
        case .off: "Read-only"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var protocolValue: String? {
        switch self {
        case .droidDefault: nil
        case .off: "off"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        }
    }
}

enum ReasoningSetting: String, CaseIterable, Identifiable, Sendable {
    case droidDefault = ""
    case low = "low"
    case medium = "medium"
    case high = "high"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .droidDefault: "Droid default"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var protocolValue: String? {
        rawValue.isEmpty ? nil : rawValue
    }
}

struct AppSettings: Equatable, Sendable {
    var hotkeyKeyCode: UInt32
    var hotkeyModifiers: UInt32
    var modelOverride: String
    var reasoning: ReasoningSetting
    var autonomy: AutonomySetting
    var workingDirectory: String
    var answersDirectory: String
    var droidPath: String
    var launchAtLogin: Bool

    static let defaultHotkeyKeyCode: UInt32 = 2 // D
    static let defaultHotkeyModifiers: UInt32 = (1 << 8) | (1 << 12) // control + command

    static var defaultWorkingDirectory: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AskDroid/workspace", isDirectory: true)
            .path
            ?? (NSHomeDirectory() as NSString)
                .appendingPathComponent("Library/Application Support/AskDroid/workspace")
    }

    static var defaultAnswersDirectory: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AskDroid/answers", isDirectory: true)
            .path
            ?? (NSHomeDirectory() as NSString)
                .appendingPathComponent("Library/Application Support/AskDroid/answers")
    }

    static var `default`: AppSettings {
        AppSettings(
            hotkeyKeyCode: defaultHotkeyKeyCode,
            hotkeyModifiers: defaultHotkeyModifiers,
            modelOverride: "",
            reasoning: .droidDefault,
            autonomy: .high,
            workingDirectory: defaultWorkingDirectory,
            answersDirectory: defaultAnswersDirectory,
            droidPath: "",
            launchAtLogin: false
        )
    }

    var resolvedWorkingDirectory: String {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = trimmed.isEmpty ? Self.defaultWorkingDirectory : (trimmed as NSString).expandingTildeInPath
        return path
    }

    var resolvedAnswersDirectory: String {
        let trimmed = answersDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = trimmed.isEmpty ? Self.defaultAnswersDirectory : trimmed
        return (path as NSString).expandingTildeInPath
    }

    static func isLegacyHomeWorkingDirectory(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "~" { return true }
        return (trimmed as NSString).expandingTildeInPath == NSHomeDirectory()
    }

    static func isLegacyHomeAnswersDirectory(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let homeAnswers = (NSHomeDirectory() as NSString).appendingPathComponent("Droid-Answers")
        return expanded == homeAnswers || trimmed == "~/Droid-Answers" || trimmed == "Droid-Answers"
    }

    var hotkeyDisplay: String {
        HotkeyCodec.display(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)
    }
}

enum SettingsStore {
    static func load() -> AppSettings {
        let suite = UserDefaults.standard
        var settings = AppSettings.default
        if suite.object(forKey: "hotkeyKeyCode") != nil {
            settings.hotkeyKeyCode = UInt32(suite.integer(forKey: "hotkeyKeyCode"))
        }
        if suite.object(forKey: "hotkeyModifiers") != nil {
            settings.hotkeyModifiers = UInt32(suite.integer(forKey: "hotkeyModifiers"))
        }
        settings.modelOverride = suite.string(forKey: "modelOverride") ?? ""
        if let raw = suite.string(forKey: "reasoning"),
           let value = ReasoningSetting(rawValue: raw)
        {
            settings.reasoning = value
        }
        if let raw = suite.string(forKey: "autonomy"),
           let value = AutonomySetting(rawValue: raw)
        {
            settings.autonomy = value
        }
        // Product default moved from Droid's read-only default to high.
        // Migrate anyone who stored the old implicit default; respect explicit choices.
        if settings.autonomy == .droidDefault {
            settings.autonomy = .high
            suite.set(settings.autonomy.rawValue, forKey: "autonomy")
        }
        if let cwd = suite.string(forKey: "workingDirectory"), !cwd.isEmpty {
            settings.workingDirectory = cwd
        }
        if AppSettings.isLegacyHomeWorkingDirectory(settings.workingDirectory) {
            settings.workingDirectory = AppSettings.defaultWorkingDirectory
            suite.set(settings.workingDirectory, forKey: "workingDirectory")
        }
        if let answers = suite.string(forKey: "answersDirectory"), !answers.isEmpty {
            settings.answersDirectory = answers
        }
        if AppSettings.isLegacyHomeAnswersDirectory(settings.answersDirectory) {
            settings.answersDirectory = AppSettings.defaultAnswersDirectory
            suite.set(settings.answersDirectory, forKey: "answersDirectory")
        }
        settings.droidPath = suite.string(forKey: "droidPath") ?? ""
        settings.launchAtLogin = suite.bool(forKey: "launchAtLogin")
        return settings
    }

    static func save(_ settings: AppSettings) {
        let suite = UserDefaults.standard
        suite.set(Int(settings.hotkeyKeyCode), forKey: "hotkeyKeyCode")
        suite.set(Int(settings.hotkeyModifiers), forKey: "hotkeyModifiers")
        suite.set(settings.modelOverride, forKey: "modelOverride")
        suite.set(settings.reasoning.rawValue, forKey: "reasoning")
        suite.set(settings.autonomy.rawValue, forKey: "autonomy")
        suite.set(settings.workingDirectory, forKey: "workingDirectory")
        suite.set(settings.answersDirectory, forKey: "answersDirectory")
        suite.set(settings.droidPath, forKey: "droidPath")
        suite.set(settings.launchAtLogin, forKey: "launchAtLogin")
    }
}

enum HotkeyCodec {
    static let command: UInt32 = 1 << 8
    static let shift: UInt32 = 1 << 9
    static let option: UInt32 = 1 << 11
    static let control: UInt32 = 1 << 12

    static func display(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & control != 0 { parts.append("⌃") }
        if modifiers & option != 0 { parts.append("⌥") }
        if modifiers & shift != 0 { parts.append("⇧") }
        if modifiers & command != 0 { parts.append("⌘") }
        parts.append(keyName(for: keyCode))
        return parts.joined()
    }

    static func keyName(for keyCode: UInt32) -> String {
        switch keyCode {
        case 0: "A"
        case 1: "S"
        case 2: "D"
        case 3: "F"
        case 4: "H"
        case 5: "G"
        case 6: "Z"
        case 7: "X"
        case 8: "C"
        case 9: "V"
        case 11: "B"
        case 12: "Q"
        case 13: "W"
        case 14: "E"
        case 15: "R"
        case 16: "Y"
        case 17: "T"
        case 31: "O"
        case 32: "U"
        case 34: "I"
        case 35: "P"
        case 37: "L"
        case 38: "J"
        case 40: "K"
        case 45: "N"
        case 46: "M"
        case 18: "1"
        case 19: "2"
        case 20: "3"
        case 21: "4"
        case 23: "5"
        case 22: "6"
        case 26: "7"
        case 28: "8"
        case 25: "9"
        case 29: "0"
        case 49: "Space"
        case 36: "Return"
        default: "Key \(keyCode)"
        }
    }
}

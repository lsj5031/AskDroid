import Foundation

struct ArchivedAnswer: Equatable, Sendable {
    var markdownURL: URL
    var imageURLs: [URL]
    /// The resolved file base name. Pass it back into `write` so the same
    /// conversation keeps rewriting one file instead of colliding with its
    /// own previous output.
    var baseName: String
}

/// One turn of raw conversation content. Images are still unfiled data;
/// `write` assigns their names.
struct ArchivedTurn: Equatable, Sendable {
    var question: String
    var answer: String
    var images: [AttachedImage]
    var durationText: String?
}

/// One turn with image files resolved, ready to render.
struct ArchiveTurnContent: Equatable, Sendable {
    var question: String
    var answer: String
    var imageNames: [String]
    var durationText: String?
}

enum AnswerArchive {
    static func uniqueBaseName(
        date: Date,
        existingNames: [String],
        prefix: String = "droid",
        calendar: Calendar = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        return uniqueBaseName(root: "\(prefix)-\(formatter.string(from: date))", existingNames: existingNames)
    }

    /// Uniquifies a root name against the directory listing with `-2`,
    /// `-3`, … suffixes.
    static func uniqueBaseName(root: String, existingNames: [String]) -> String {
        if !existingNames.contains(where: { $0.hasPrefix(root) }) {
            return root
        }
        var suffix = 2
        while existingNames.contains(where: { $0.hasPrefix("\(root)-\(suffix)") }) {
            suffix += 1
        }
        return "\(root)-\(suffix)"
    }

    /// Reduces a session title to a filename-safe fragment. Empty output
    /// means "no usable title".
    static func sanitizeTitle(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var cleaned = String(title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        while let range = cleaned.range(of: #"[-_]{2,}"#, options: .regularExpression) {
            cleaned.replaceSubrange(range, with: "-")
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        if cleaned.count > 40 {
            cleaned = String(cleaned.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        }
        return cleaned
    }

    static func markdown(
        date: Date = Date(),
        turns: [ArchiveTurnContent],
        model: String?,
        engine: String? = nil,
        title: String? = nil
    ) -> String {
        var lines: [String] = [
            "# AskDroid",
            "",
            "- Asked: \(ISO8601DateFormatter().string(from: date))",
        ]
        if let engine, !engine.isEmpty {
            lines.append("- Engine: \(engine.capitalized)")
        }
        if let model, !model.isEmpty {
            lines.append("- Model: \(model)")
        }
        if let title, !title.isEmpty {
            lines.append("- Title: \(title)")
        }
        for (index, turn) in turns.enumerated() {
            lines.append("")
            lines.append("## Turn \(index + 1)")
            if let duration = turn.durationText, !duration.isEmpty {
                lines.append("")
                lines.append("- Duration: \(duration)")
            }
            lines.append("")
            lines.append("### Question")
            lines.append("")
            lines.append(turn.question.trimmingCharacters(in: .whitespacesAndNewlines))
            if !turn.imageNames.isEmpty {
                lines.append("")
                lines.append("### Images")
                lines.append("")
                for name in turn.imageNames {
                    lines.append("![](\(name))")
                }
            }
            lines.append("")
            lines.append("### Answer")
            lines.append("")
            lines.append(turn.answer.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Writes (or rewrites) the conversation archive. Called after every
    /// completed turn with the whole transcript so a crash mid-conversation
    /// still leaves the turns so far on disk. Image files are rewritten
    /// atomically under stable names: `\(base)-N.ext`, numbered across the
    /// conversation in turn order.
    static func write(
        directory: URL,
        date: Date = Date(),
        turns: [ArchivedTurn],
        model: String?,
        engine: String? = nil,
        title: String? = nil,
        base: String? = nil,
        fileManager: FileManager = .default
    ) throws -> ArchivedAnswer {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        let prefix = engine?.lowercased() ?? "droid"
        let resolvedBase: String
        if let base {
            // A rewrite of a conversation already on disk keeps its name.
            resolvedBase = base
        } else if let title, !sanitizeTitle(title).isEmpty {
            resolvedBase = uniqueBaseName(
                root: "\(prefix)-\(sanitizeTitle(title))",
                existingNames: existing
            )
        } else {
            resolvedBase = uniqueBaseName(date: date, existingNames: existing, prefix: prefix)
        }

        var imageURLs: [URL] = []
        var contents: [ArchiveTurnContent] = []
        var nextImageNumber = 1
        for turn in turns {
            var imageNames: [String] = []
            for image in turn.images {
                let name = "\(resolvedBase)-\(nextImageNumber).\(image.fileExtension)"
                nextImageNumber += 1
                let url = directory.appendingPathComponent(name)
                try image.data.write(to: url, options: .atomic)
                imageURLs.append(url)
                imageNames.append(name)
            }
            contents.append(ArchiveTurnContent(
                question: turn.question,
                answer: turn.answer,
                imageNames: imageNames,
                durationText: turn.durationText
            ))
        }

        let markdownURL = directory.appendingPathComponent("\(resolvedBase).md")
        let body = markdown(
            date: date,
            turns: contents,
            model: model,
            engine: engine,
            title: title
        )
        try Data(body.utf8).write(to: markdownURL, options: .atomic)
        return ArchivedAnswer(markdownURL: markdownURL, imageURLs: imageURLs, baseName: resolvedBase)
    }

    static func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 60 {
            return String(format: "%.1fs", duration)
        }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return "\(minutes)m \(seconds)s"
    }
}

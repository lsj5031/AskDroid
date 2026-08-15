import Foundation

struct ArchivedAnswer: Equatable, Sendable {
    var markdownURL: URL
    var imageURLs: [URL]
}

enum AnswerArchive {
    static func uniqueBaseName(
        date: Date,
        existingNames: [String],
        calendar: Calendar = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let stamp = formatter.string(from: date)
        let root = "droid-\(stamp)"
        if !existingNames.contains(where: { $0.hasPrefix(root) }) {
            return root
        }
        var suffix = 2
        while existingNames.contains(where: { $0.hasPrefix("\(root)-\(suffix)") }) {
            suffix += 1
        }
        return "\(root)-\(suffix)"
    }

    static func markdown(
        question: String,
        answer: String,
        model: String?,
        duration: TimeInterval,
        imageNames: [String]
    ) -> String {
        var lines: [String] = [
            "# AskDroid",
            "",
            "- Asked: \(ISO8601DateFormatter().string(from: Date()))",
        ]
        if let model, !model.isEmpty {
            lines.append("- Model: \(model)")
        }
        lines.append("- Duration: \(formatDuration(duration))")
        lines.append("")
        lines.append("## Question")
        lines.append("")
        lines.append(question.trimmingCharacters(in: .whitespacesAndNewlines))
        if !imageNames.isEmpty {
            lines.append("")
            lines.append("## Images")
            lines.append("")
            for name in imageNames {
                lines.append("![](\(name))")
            }
        }
        lines.append("")
        lines.append("## Answer")
        lines.append("")
        lines.append(answer.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func write(
        directory: URL,
        date: Date = Date(),
        question: String,
        answer: String,
        model: String?,
        duration: TimeInterval,
        images: [AttachedImage],
        fileManager: FileManager = .default
    ) throws -> ArchivedAnswer {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        let base = uniqueBaseName(date: date, existingNames: existing)
        var imageURLs: [URL] = []
        var imageNames: [String] = []

        for (index, image) in images.enumerated() {
            let name = "\(base)-\(index + 1).\(image.fileExtension)"
            let url = directory.appendingPathComponent(name)
            try image.data.write(to: url, options: .atomic)
            imageURLs.append(url)
            imageNames.append(name)
        }

        let markdownURL = directory.appendingPathComponent("\(base).md")
        let body = markdown(
            question: question,
            answer: answer,
            model: model,
            duration: duration,
            imageNames: imageNames
        )
        try Data(body.utf8).write(to: markdownURL, options: .atomic)
        return ArchivedAnswer(markdownURL: markdownURL, imageURLs: imageURLs)
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

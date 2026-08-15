import AppKit
import XCTest
@testable import AskDroidKit

final class JSONRPCTests: XCTestCase {
    func testRequestEnvelopeContainsFactoryVersions() throws {
        let line = try JSONRPC.encodeLine(JSONRPC.request(
            id: "1",
            method: "droid.initialize_session",
            params: ["machineId": "askdroid", "cwd": "/tmp"]
        ))
        let parsed = try JSONRPC.parse(line)
        XCTAssertEqual(parsed["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(parsed["factoryApiVersion"] as? String, "1.0.0")
        XCTAssertEqual(parsed["factoryProtocolVersion"] as? String, "1.1.0")
        XCTAssertEqual(parsed["type"] as? String, "request")
        XCTAssertEqual(parsed["method"] as? String, "droid.initialize_session")
    }

    func testNotificationParserReadsTextDeltaAndToolCall() {
        let delta: [String: Any] = [
            "type": "notification",
            "method": "droid.session_notification",
            "params": ["type": "assistant_text_delta", "textDelta": "Hello"],
        ]
        if case .assistantTextDelta(let text) = DroidNotificationParser.parse(delta) {
            XCTAssertEqual(text, "Hello")
        } else {
            XCTFail("expected text delta")
        }

        let tool: [String: Any] = [
            "params": [
                "type": "tool_call",
                "toolUse": ["name": "Read", "id": "1", "input": [:]],
            ],
        ]
        if case .toolCall(let name) = DroidNotificationParser.parse(tool) {
            XCTAssertEqual(name, "Read")
        } else {
            XCTFail("expected tool call")
        }

        let thinking: [String: Any] = [
            "params": ["type": "thinking_text_delta", "textDelta": "hmm"],
        ]
        if case .thinking(let text) = DroidNotificationParser.parse(thinking) {
            XCTAssertEqual(text, "hmm")
        } else {
            XCTFail("expected thinking")
        }
    }

    func testInitializeParamsOmitInvalidSessionSource() {
        let params = DroidEngine.initializeParams(from: .default)
        XCTAssertEqual(params["machineId"] as? String, "askdroid")
        XCTAssertNil(params["sessionSource"])
        XCTAssertEqual(params["autoRejectPermissionRequests"] as? Bool, true)
    }

    func testUserMessageImagesUseBase64Shape() {
        let image = AttachedImage(
            id: UUID(),
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            mediaType: "image/png",
            filename: "paste.png"
        )
        let request = DroidRunRequest(
            prompt: "explain",
            images: [image],
            settings: .default
        )
        let params = DroidEngine.userMessageParams(from: request)
        let images = params["images"] as? [[String: Any]]
        XCTAssertEqual(images?.count, 1)
        XCTAssertEqual(images?.first?["type"] as? String, "base64")
        XCTAssertEqual(images?.first?["mediaType"] as? String, "image/png")
        XCTAssertNotNil(images?.first?["data"] as? String)
    }

    func testActivityLabels() {
        XCTAssertEqual(DroidEngine.activityLabel(for: "Read"), "Reading files…")
        XCTAssertEqual(DroidEngine.activityLabel(for: "Grep"), "Searching…")
        XCTAssertEqual(DroidEngine.activityLabel(for: "CustomTool"), "Using CustomTool…")
    }
}

final class ArchiveTests: XCTestCase {
    func testUniqueNameAddsSuffixOnCollision() {
        let date = Date(timeIntervalSince1970: 1_787_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let first = AnswerArchive.uniqueBaseName(date: date, existingNames: [], calendar: calendar)
        XCTAssertTrue(first.hasPrefix("droid-"))
        let second = AnswerArchive.uniqueBaseName(date: date, existingNames: ["\(first).md"], calendar: calendar)
        XCTAssertEqual(second, "\(first)-2")
        let third = AnswerArchive.uniqueBaseName(
            date: date,
            existingNames: ["\(first).md", "\(first)-2.png"],
            calendar: calendar
        )
        XCTAssertEqual(third, "\(first)-3")
    }

    func testDefaultWorkingDirectoryIsNotHome() {
        XCTAssertNotEqual(AppSettings.default.resolvedWorkingDirectory, NSHomeDirectory())
        XCTAssertTrue(AppSettings.default.resolvedWorkingDirectory.contains("AskDroid/workspace"))
        XCTAssertTrue(AppSettings.isLegacyHomeWorkingDirectory("~"))
        XCTAssertTrue(AppSettings.isLegacyHomeWorkingDirectory(NSHomeDirectory()))
        XCTAssertFalse(AppSettings.isLegacyHomeWorkingDirectory(AppSettings.defaultWorkingDirectory))
    }

    func testDefaultAnswersDirectoryIsApplicationSupport() {
        XCTAssertTrue(AppSettings.default.resolvedAnswersDirectory.contains("AskDroid/answers"))
        XCTAssertFalse(AppSettings.default.resolvedAnswersDirectory.hasSuffix("/Droid-Answers"))
        XCTAssertTrue(AppSettings.isLegacyHomeAnswersDirectory("~/Droid-Answers"))
        XCTAssertTrue(AppSettings.isLegacyHomeAnswersDirectory(
            (NSHomeDirectory() as NSString).appendingPathComponent("Droid-Answers")
        ))
        XCTAssertFalse(AppSettings.isLegacyHomeAnswersDirectory(AppSettings.defaultAnswersDirectory))
    }

    func testWriteCreatesMissingAnswersDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("askdroid-archive-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("answers", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let archived = try AnswerArchive.write(
            directory: directory,
            question: "What is this?",
            answer: "A square.",
            model: nil,
            duration: 1.2,
            images: []
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.markdownURL.path))
        XCTAssertTrue(archived.markdownURL.path.hasPrefix(directory.path))
    }

    func testMarkdownIncludesQuestionAnswerAndImages() {
        let body = AnswerArchive.markdown(
            question: "What is this?",
            answer: "A square.",
            model: "claude-opus-5",
            duration: 3.2,
            imageNames: ["droid-x-1.png"]
        )
        XCTAssertTrue(body.contains("## Question"))
        XCTAssertTrue(body.contains("What is this?"))
        XCTAssertTrue(body.contains("A square."))
        XCTAssertTrue(body.contains("![](droid-x-1.png)"))
        XCTAssertTrue(body.contains("claude-opus-5"))
    }
}

final class BinaryDiscoveryTests: XCTestCase {
    func testOverrideWinsWhenPresent() {
        let resolved = BinaryDiscovery.resolve(override: "/opt/custom/droid") { $0 == "/opt/custom/droid" }
        XCTAssertEqual(resolved, "/opt/custom/droid")
    }

    func testOverrideMissingReturnsNil() {
        let resolved = BinaryDiscovery.resolve(override: "/missing/droid") { _ in false }
        XCTAssertNil(resolved)
    }

    func testPathThenFallbacks() {
        let resolved = BinaryDiscovery.firstOnPath(
            named: "droid",
            path: "/tmp/bin:/opt/bin",
            fileExists: { $0 == "/opt/bin/droid" }
        )
        XCTAssertEqual(resolved, "/opt/bin/droid")
    }
}

final class AttachedImageTests: XCTestCase {
    func testSniffsPngJpegGifAndWebP() {
        XCTAssertEqual(AttachedImage.sniffMediaType(Data([0x89, 0x50, 0x4E, 0x47])), "image/png")
        XCTAssertEqual(AttachedImage.sniffMediaType(Data([0xFF, 0xD8, 0xFF, 0xE0])), "image/jpeg")
        XCTAssertEqual(AttachedImage.sniffMediaType(Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])), "image/gif")
        let webp = Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])
        XCTAssertEqual(AttachedImage.sniffMediaType(webp), "image/webp")
        XCTAssertNil(AttachedImage.sniffMediaType(Data([0x00, 0x01])))
    }

    func testPasteboardPNGBecomesAttachedImage() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(png, forType: .png))
        let images = AttachedImage.fromPasteboard(pasteboard)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.mediaType, "image/png")
        XCTAssertEqual(images.first?.filename, "paste.png")
    }

    func testTIFFBytesAreSniffed() {
        XCTAssertEqual(AttachedImage.sniffMediaType(Data([0x49, 0x49, 0x2A, 0x00])), "image/tiff")
        XCTAssertEqual(AttachedImage.sniffMediaType(Data([0x4D, 0x4D, 0x00, 0x2A])), "image/tiff")
    }
}

final class LineReaderTests: XCTestCase {
    func testSplitsCompleteLinesAndKeepsRemainder() {
        let reader = LineReader()
        let first = reader.push(Data("hello\nwor".utf8))
        XCTAssertEqual(first, ["hello"])
        let second = reader.push(Data("ld\n".utf8))
        XCTAssertEqual(second, ["world"])
    }
}

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

// MARK: - Engine state machine

private final class MockProcess: DroidProcessIO, @unchecked Sendable {
    let standardOutput: FileHandle
    let standardError: FileHandle
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private(set) var written: [String] = []
    private(set) var terminated = false
    private var exitStatus: Int32 = 0
    private var exitContinuation: CheckedContinuation<Int32, Never>?

    init() {
        standardOutput = stdoutPipe.fileHandleForReading
        standardError = stderrPipe.fileHandleForReading
    }

    func write(_ line: String) throws {
        written.append(line)
    }

    func terminate() {
        terminated = true
    }

    func waitUntilExit() -> Int32 { exitStatus }

    func feedStdout(_ line: String) {
        stdoutPipe.fileHandleForWriting.write(Data((line + "\n").utf8))
    }

    func feedStderr(_ line: String) {
        stderrPipe.fileHandleForWriting.write(Data((line + "\n").utf8))
    }

    func closeStdout() { try? stdoutPipe.fileHandleForWriting.close() }
    func closeStderr() { try? stderrPipe.fileHandleForWriting.close() }
    func setExit(_ status: Int32) { exitStatus = status }
}

private struct MockLauncher: DroidProcessLaunching {
    let process: MockProcess
    func launch(executable: String, arguments: [String], environment: [String: String], cwd: String) throws -> any DroidProcessIO {
        process
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DroidRunEvent] = []

    func record(_ event: DroidRunEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    func snapshot() -> [DroidRunEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private func runEngine(
    _ engine: DroidEngine,
    request: DroidRunRequest,
    box: EventBox
) async {
    await engine.run(request) { event in
        box.record(event)
    }
}

final class EngineStateMachineTests: XCTestCase {
    private static func makeSettings() -> AppSettings {
        var s = AppSettings.default
        s.droidPath = "/tmp/droid"
        return s
    }

    func testErrorFromServerSurfacesNotCancelled() async {
        let process = MockProcess()
        let engine = DroidEngine(launcher: MockLauncher(process: process), fileExists: { _ in true })
        let box = EventBox()

        let driver = Task.detached {
            try? await Task.sleep(for: .milliseconds(150))
            process.feedStdout(#"{"jsonrpc":"2.0","id":"1","error":{"message":"invalid API key"}}"#)
            process.closeStdout()
            process.closeStderr()
            process.setExit(1)
        }

        await runEngine(engine, request: DroidRunRequest(prompt: "hi", images: [], settings: Self.makeSettings()), box: box)
        await driver.value

        let failure = box.snapshot().compactMap { event -> String? in
            if case .failed(_, let message) = event { return message }
            return nil
        }.last
        XCTAssertEqual(failure, "invalid API key")
    }

    func testAuthErrorOnStderrSurfacesNotCancelled() async {
        let process = MockProcess()
        let engine = DroidEngine(launcher: MockLauncher(process: process), fileExists: { _ in true })
        let box = EventBox()

        let driver = Task.detached {
            try? await Task.sleep(for: .milliseconds(150))
            process.feedStderr("Error: not authenticated. Set FACTORY_API_KEY.")
            process.closeStdout()
            process.closeStderr()
            process.setExit(1)
        }

        await runEngine(engine, request: DroidRunRequest(prompt: "hi", images: [], settings: Self.makeSettings()), box: box)
        await driver.value

        let failure = box.snapshot().compactMap { event -> String? in
            if case .failed(_, let message) = event { return message }
            return nil
        }.last
        XCTAssertEqual(failure, DroidEngineError.notAuthenticated.localizedDescription)
    }

    func testCompletedTurnEmitsResult() async {
        let process = MockProcess()
        let engine = DroidEngine(launcher: MockLauncher(process: process), fileExists: { _ in true })
        let box = EventBox()
        let answers = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var settings = Self.makeSettings()
        settings.answersDirectory = answers.path

        let driver = Task.detached {
            try? await Task.sleep(for: .milliseconds(150))
            process.feedStdout(#"{"jsonrpc":"2.0","id":"1","result":{"session":{"settings":{"modelId":"gpt-5"}}}}"#)
            try? await Task.sleep(for: .milliseconds(150))
            process.feedStdout(#"{"jsonrpc":"2.0","method":"droid.session_notification","params":{"type":"assistant_text_delta","textDelta":"Hello"}}"#)
            process.feedStdout(#"{"jsonrpc":"2.0","method":"droid.session_notification","params":{"type":"agent_turn_completed","durationMs":1200,"tokenUsage":{"inputTokens":3,"outputTokens":4}}}"#)
            process.closeStdout()
            process.closeStderr()
            process.setExit(0)
        }

        await runEngine(engine, request: DroidRunRequest(prompt: "hi", images: [], settings: settings), box: box)
        await driver.value

        let result = box.snapshot().compactMap { event -> DroidRunResult? in
            if case .completed(_, let r) = event { return r }
            return nil
        }.last
        XCTAssertEqual(result?.text, "Hello")
        XCTAssertEqual(result?.model, "gpt-5")
        XCTAssertNotNil(result?.archiveURL)
        try? FileManager.default.removeItem(at: answers)
    }

    func testRunIDsAreUniquePerRun() async {
        let process = MockProcess()
        let engine = DroidEngine(launcher: MockLauncher(process: process), fileExists: { _ in true })
        let box = EventBox()

        let driver = Task.detached {
            try? await Task.sleep(for: .milliseconds(150))
            process.closeStdout()
            process.closeStderr()
            process.setExit(0)
        }

        await runEngine(engine, request: DroidRunRequest(prompt: "a", images: [], settings: Self.makeSettings()), box: box)
        await runEngine(engine, request: DroidRunRequest(prompt: "b", images: [], settings: Self.makeSettings()), box: box)
        await driver.value

        let ids = box.snapshot().compactMap { event -> UUID? in
            if case .started(let id) = event { return id }
            return nil
        }
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1])
    }
}

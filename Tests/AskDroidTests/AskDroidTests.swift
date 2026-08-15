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
        if case .toolCall(let name, _) = DroidNotificationParser.parse(tool) {
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

    func testNotificationParserReadsToolResultAndTokenUsage() {
        let result: [String: Any] = [
            "params": [
                "type": "tool_result",
                "content": "Error: Tool execution cancelled by user",
                "isError": true,
            ],
        ]
        if case .toolResult(let text) = DroidNotificationParser.parse(result) {
            XCTAssertTrue(text.contains("cancelled"))
        } else {
            XCTFail("expected tool result")
        }

        let usage: [String: Any] = [
            "params": [
                "type": "session_token_usage_changed",
                "tokenUsage": ["inputTokens": 353, "outputTokens": 479],
            ],
        ]
        if case .tokenUsage(let tokens) = DroidNotificationParser.parse(usage) {
            XCTAssertEqual(tokens.inputTokens, 353)
            XCTAssertEqual(tokens.outputTokens, 479)
        } else {
            XCTFail("expected token usage")
        }
    }

    func testNotificationParserReadsToolCallDetail() {
        let tool: [String: Any] = [
            "params": [
                "type": "tool_call",
                "toolUse": ["name": "Execute", "id": "1", "input": ["command": "ls -la"]],
            ],
        ]
        if case .toolCall(let name, let detail) = DroidNotificationParser.parse(tool) {
            XCTAssertEqual(name, "Execute")
            XCTAssertEqual(detail, "ls -la")
        } else {
            XCTFail("expected tool call with detail")
        }
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

    func testDefaultAutonomyIsHigh() {
        XCTAssertEqual(AppSettings.default.autonomy, .high)
        let params = DroidEngine.initializeParams(from: .default)
        XCTAssertEqual(params["autonomyLevel"] as? String, "high")
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
    private let lock = NSLock()
    private let exitSemaphore = DispatchSemaphore(value: 0)
    private var exitStatus: Int32 = 0
    private var exited = false
    private(set) var written: [String] = []
    private(set) var terminated = false

    init() {
        standardOutput = stdoutPipe.fileHandleForReading
        standardError = stderrPipe.fileHandleForReading
    }

    var didExit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exited
    }

    func write(_ line: String) throws {
        lock.lock()
        written.append(line)
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        terminated = true
        let needsSignal = !exited
        if !exited {
            exited = true
            exitStatus = SIGTERM
        }
        lock.unlock()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        if needsSignal { exitSemaphore.signal() }
    }

    func waitUntilExit() -> Int32 {
        exitSemaphore.wait()
        lock.lock()
        defer { lock.unlock() }
        return exitStatus
    }

    func feedStdout(_ line: String) {
        guard !didExit else { return }
        stdoutPipe.fileHandleForWriting.write(Data((line + "\n").utf8))
    }

    func feedStderr(_ line: String) {
        guard !didExit else { return }
        stderrPipe.fileHandleForWriting.write(Data((line + "\n").utf8))
    }

    func closeStdout() { try? stdoutPipe.fileHandleForWriting.close() }
    func closeStderr() { try? stderrPipe.fileHandleForWriting.close() }

    func setExit(_ status: Int32) {
        lock.lock()
        if !exited {
            exited = true
            exitStatus = status
        }
        lock.unlock()
        exitSemaphore.signal()
    }
}

private final class MockLauncher: DroidProcessLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MockProcess] = []

    var processes: [MockProcess] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    func launch(executable: String, arguments: [String], environment: [String: String], cwd: String) throws -> any DroidProcessIO {
        let process = MockProcess()
        lock.lock()
        storage.append(process)
        lock.unlock()
        return process
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

    func recorder() -> @Sendable (DroidRunEvent) -> Void {
        { event in self.record(event) }
    }

    func snapshot() -> [DroidRunEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private func waitForProcesses(_ launcher: MockLauncher, count: Int) async {
    for _ in 0..<300 {
        if launcher.count >= count { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private func runEngine(
    _ engine: DroidEngine,
    request: DroidRunRequest,
    runID: UUID = UUID(),
    box: EventBox
) async {
    await engine.run(request, runID: runID) { event in
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
        let launcher = MockLauncher()
        let engine = DroidEngine(launcher: launcher, fileExists: { _ in true })
        let box = EventBox()

        let driver = Task.detached {
            await waitForProcesses(launcher, count: 1)
            let process = launcher.processes[0]
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
        let launcher = MockLauncher()
        let engine = DroidEngine(launcher: launcher, fileExists: { _ in true })
        let box = EventBox()

        let driver = Task.detached {
            await waitForProcesses(launcher, count: 1)
            let process = launcher.processes[0]
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
        let launcher = MockLauncher()
        let engine = DroidEngine(launcher: launcher, fileExists: { _ in true })
        let box = EventBox()
        let answers = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var settings = Self.makeSettings()
        settings.answersDirectory = answers.path

        let driver = Task.detached {
            await waitForProcesses(launcher, count: 1)
            let process = launcher.processes[0]
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
        let launcher = MockLauncher()
        let engine = DroidEngine(launcher: launcher, fileExists: { _ in true })
        let box = EventBox()

        let driver = Task.detached {
            for _ in 0..<400 {
                for process in launcher.processes where !process.didExit {
                    process.closeStdout()
                    process.closeStderr()
                    process.setExit(0)
                }
                if launcher.count >= 2 { return }
                try? await Task.sleep(for: .milliseconds(10))
            }
            for process in launcher.processes where !process.didExit {
                process.closeStdout()
                process.closeStderr()
                process.setExit(0)
            }
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

    func testCancelMidRunReportsCancelled() async {
        let launcher = MockLauncher()
        let engine = DroidEngine(launcher: launcher, fileExists: { _ in true })
        let box = EventBox()
        let runID = UUID()

        let driver = Task.detached {
            await waitForProcesses(launcher, count: 1)
            await engine.cancel(runID: runID)
        }

        await runEngine(
            engine,
            request: DroidRunRequest(prompt: "hi", images: [], settings: Self.makeSettings()),
            runID: runID,
            box: box
        )
        await driver.value

        XCTAssertEqual(launcher.processes.count, 1)
        XCTAssertTrue(launcher.processes[0].terminated)
        let failure = box.snapshot().compactMap { event -> String? in
            if case .failed(_, let message) = event { return message }
            return nil
        }.last
        XCTAssertEqual(failure, DroidEngineError.cancelled.localizedDescription)
    }

    func testCancelDoesNotKillNewerRun() async {
        let launcher = MockLauncher()
        let engine = DroidEngine(launcher: launcher, fileExists: { _ in true })
        let boxA = EventBox()
        let boxB = EventBox()
        let idA = UUID()
        let idB = UUID()
        let answers = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var settings = Self.makeSettings()
        settings.answersDirectory = answers.path
        let requestA = DroidRunRequest(prompt: "a", images: [], settings: settings)
        let requestB = DroidRunRequest(prompt: "b", images: [], settings: settings)
        let recordA = boxA.recorder()
        let recordB = boxB.recorder()

        let runA = Task.detached {
            await engine.run(requestA, runID: idA, onEvent: recordA)
        }
        await waitForProcesses(launcher, count: 1)

        let runB = Task.detached {
            await engine.run(requestB, runID: idB, onEvent: recordB)
        }
        await waitForProcesses(launcher, count: 2)

        // Starting B retires A's process; a stray cancel for A must not touch B.
        XCTAssertTrue(launcher.processes[0].terminated)
        await engine.cancel(runID: idA)
        let processB = launcher.processes[1]
        XCTAssertFalse(processB.terminated)

        processB.feedStdout(#"{"jsonrpc":"2.0","id":"1","result":{"session":{"settings":{"modelId":"gpt-5"}}}}"#)
        try? await Task.sleep(for: .milliseconds(150))
        processB.feedStdout(#"{"jsonrpc":"2.0","method":"droid.session_notification","params":{"type":"assistant_text_delta","textDelta":"B answer"}}"#)
        processB.feedStdout(#"{"jsonrpc":"2.0","method":"droid.session_notification","params":{"type":"agent_turn_completed","durationMs":5}}"#)
        processB.closeStdout()
        processB.closeStderr()
        processB.setExit(0)

        await runA.value
        await runB.value

        let failureA = boxA.snapshot().compactMap { event -> String? in
            if case .failed(_, let message) = event { return message }
            return nil
        }.last
        XCTAssertEqual(failureA, DroidEngineError.cancelled.localizedDescription)

        let resultB = boxB.snapshot().compactMap { event -> DroidRunResult? in
            if case .completed(_, let r) = event { return r }
            return nil
        }.last
        XCTAssertEqual(resultB?.text, "B answer")
        try? FileManager.default.removeItem(at: answers)
    }
}

@MainActor
final class AskSessionTests: XCTestCase {
    private func makeSession(launcher: MockLauncher) -> AskSession {
        var settings = AppSettings.default
        settings.droidPath = "/tmp/droid"
        let temp = FileManager.default.temporaryDirectory
        settings.answersDirectory = temp.appendingPathComponent(UUID().uuidString).path
        settings.workingDirectory = temp.appendingPathComponent(UUID().uuidString).path
        return AskSession(
            settings: settings,
            engine: DroidEngine(launcher: launcher, fileExists: { _ in true })
        )
    }

    func testStaleEventsDroppedAfterCancel() async {
        let launcher = MockLauncher()
        let session = makeSession(launcher: launcher)
        session.isExpanded = true
        session.prompt = "hello"
        session.submit()

        for _ in 0..<300 where launcher.count == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(launcher.count, 1)
        let idA = session.currentRunID
        XCTAssertNotNil(idA)
        XCTAssertEqual(session.phase, .running)

        session.cancelRun()
        XCTAssertEqual(session.phase, .failed)
        XCTAssertNil(session.currentRunID)

        // Stale events from the cancelled run must not mutate the UI.
        session.handle(.started(idA!))
        session.handle(.textDelta(idA!, "late text"))
        session.handle(.log(idA!, "late log"))
        session.handle(.activity(idA!, "late activity"))
        session.handle(.failed(idA!, "boom"))
        session.handle(.completed(idA!, DroidRunResult(
            text: "late", model: nil, duration: 1,
            tokenUsage: nil, archiveURL: nil, archiveError: nil
        )))

        XCTAssertEqual(session.answer, "")
        XCTAssertFalse(session.runLog.contains("late log"))
        XCTAssertEqual(session.errorMessage, DroidEngineError.cancelled.localizedDescription)
        XCTAssertEqual(session.phase, .failed)
    }

    func testImagePayloadCapSkipsOversized() {
        let launcher = MockLauncher()
        let session = makeSession(launcher: launcher)
        let big = AttachedImage(
            id: UUID(),
            data: Data(repeating: 0xFF, count: AskSession.maxImageBytes + 1),
            mediaType: "image/png",
            filename: "big.png"
        )
        let small = AttachedImage(
            id: UUID(),
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            mediaType: "image/png",
            filename: "small.png"
        )
        let added = session.attach(images: [big, small])
        XCTAssertTrue(added)
        XCTAssertEqual(session.images.count, 1)
        XCTAssertEqual(session.images.first?.filename, "small.png")
        XCTAssertNotNil(session.notice)
    }
}

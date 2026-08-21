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

    func testNotificationParserMapsSessionMilestones() {
        let mcp: [String: Any] = [
            "method": "droid.session_notification",
            "params": ["notification": [
                "type": "mcp_status_changed",
                "summary": ["total": 0, "connected": 0, "connecting": 0, "failed": 0, "disabled": 0],
            ]],
        ]
        if case .milestone(let text) = DroidNotificationParser.parse(mcp) {
            XCTAssertEqual(text, "No MCP servers configured")
        } else {
            XCTFail("expected mcp milestone")
        }

        let hookStart: [String: Any] = [
            "method": "droid.session_notification",
            "params": ["notification": ["type": "hook_execution_started", "hookEventName": "SessionStart"]],
        ]
        if case .milestone(let text) = DroidNotificationParser.parse(hookStart) {
            XCTAssertEqual(text, "Running SessionStart hook…")
        } else {
            XCTFail("expected hook milestone")
        }

        let hookDone: [String: Any] = [
            "method": "droid.session_notification",
            "params": ["notification": [
                "type": "hook_execution_completed",
                "hookEventName": "SessionStart",
                "hookStatus": "completed",
            ]],
        ]
        if case .milestone(let text) = DroidNotificationParser.parse(hookDone) {
            XCTAssertEqual(text, "SessionStart hook completed")
        } else {
            XCTFail("expected hook completed milestone")
        }

        let settings: [String: Any] = [
            "method": "droid.session_notification",
            "params": ["notification": ["type": "settings_updated", "settings": [:]]],
        ]
        if case .milestone(let text) = DroidNotificationParser.parse(settings) {
            XCTAssertEqual(text, "Session settings loaded")
        } else {
            XCTFail("expected settings milestone")
        }

        let createMessage: [String: Any] = [
            "method": "droid.session_notification",
            "params": ["notification": ["type": "create_message", "message": [:]]],
        ]
        guard case .ignored = DroidNotificationParser.parse(createMessage) else {
            XCTFail("create_message should stay ignored")
            return
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
            turns: [ArchivedTurn(question: "What is this?", answer: "A square.", images: [], durationText: nil)],
            model: nil
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.markdownURL.path))
        XCTAssertTrue(archived.markdownURL.path.hasPrefix(directory.path))
    }

    private static func makeImage() -> AttachedImage {
        AttachedImage(
            id: UUID(),
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            mediaType: "image/png",
            filename: "paste.png"
        )
    }

    func testMarkdownIncludesQuestionAnswerAndImages() {
        let body = AnswerArchive.markdown(
            turns: [ArchiveTurnContent(
                question: "What is this?",
                answer: "A square.",
                imageNames: ["droid-x-1.png"],
                durationText: AnswerArchive.formatDuration(3.2)
            )],
            model: "claude-opus-5"
        )
        XCTAssertTrue(body.contains("## Turn 1"))
        XCTAssertTrue(body.contains("### Question"))
        XCTAssertTrue(body.contains("What is this?"))
        XCTAssertTrue(body.contains("### Answer"))
        XCTAssertTrue(body.contains("A square."))
        XCTAssertTrue(body.contains("![](droid-x-1.png)"))
        XCTAssertTrue(body.contains("claude-opus-5"))
        XCTAssertTrue(body.contains("- Duration: 3.2s"))
    }

    func testMarkdownIncludesEngineAndTitle() {
        let body = AnswerArchive.markdown(
            turns: [ArchiveTurnContent(question: "What is this?", answer: "A square.", imageNames: [], durationText: nil)],
            model: "claude-opus-5",
            engine: "pi",
            title: "fix the login bug"
        )
        XCTAssertTrue(body.contains("- Engine: Pi"))
        XCTAssertTrue(body.contains("- Model: claude-opus-5"))
        XCTAssertTrue(body.contains("- Title: fix the login bug"))
    }

    func testConversationMarkdownGrowsOneSectionPerTurn() {
        let body = AnswerArchive.markdown(
            turns: [
                ArchiveTurnContent(question: "first?", answer: "one", imageNames: [], durationText: nil),
                ArchiveTurnContent(question: "second?", answer: "two", imageNames: [], durationText: nil),
            ],
            model: nil
        )
        XCTAssertTrue(body.contains("## Turn 1"))
        XCTAssertTrue(body.contains("## Turn 2"))
        XCTAssertFalse(body.contains("## Turn 3"))
        // Turn order is preserved.
        let turn1 = body.range(of: "## Turn 1")!.lowerBound
        let turn2 = body.range(of: "## Turn 2")!.lowerBound
        XCTAssertTrue(turn1 < turn2)
        XCTAssertTrue(body.contains("first?"))
        XCTAssertTrue(body.contains("two"))
    }

    func testWriteRewritesSameFilePerTurn() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("askdroid-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try AnswerArchive.write(
            directory: directory,
            turns: [ArchivedTurn(question: "first?", answer: "one", images: [], durationText: nil)],
            model: nil
        )
        XCTAssertTrue(first.markdownURL.lastPathComponent.hasSuffix(".md"))

        // The rewrite passes the resolved base back in and lands on the SAME
        // file, now containing both turns.
        let second = try AnswerArchive.write(
            directory: directory,
            turns: [
                ArchivedTurn(question: "first?", answer: "one", images: [], durationText: nil),
                ArchivedTurn(question: "second?", answer: "two", images: [], durationText: nil),
            ],
            model: nil,
            base: first.baseName
        )
        XCTAssertEqual(second.markdownURL, first.markdownURL)
        let body = try String(contentsOf: second.markdownURL, encoding: .utf8)
        XCTAssertTrue(body.contains("## Turn 1"))
        XCTAssertTrue(body.contains("## Turn 2"))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasSuffix(".md") }.count,
            1,
            "rewriting spawned extra archive files"
        )
    }

    func testImageNamesContinueAcrossTurns() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("askdroid-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let archived = try AnswerArchive.write(
            directory: directory,
            turns: [
                ArchivedTurn(question: "a", answer: "b", images: [Self.makeImage()], durationText: nil),
                ArchivedTurn(question: "c", answer: "d", images: [Self.makeImage(), Self.makeImage()], durationText: nil),
            ],
            model: nil,
            base: "pi-test"
        )
        XCTAssertEqual(archived.imageURLs.map(\.lastPathComponent), ["pi-test-1.png", "pi-test-2.png", "pi-test-3.png"])
        let body = try String(contentsOf: archived.markdownURL, encoding: .utf8)
        XCTAssertTrue(body.contains("![](pi-test-1.png)"))
        XCTAssertTrue(body.contains("![](pi-test-3.png)"))
    }

    func testTitleSanitizesIntoFilename() {
        XCTAssertEqual(AnswerArchive.sanitizeTitle("Fix the login bug!"), "Fix-the-login-bug")
        XCTAssertEqual(AnswerArchive.sanitizeTitle("  ///  "), "")
        XCTAssertEqual(AnswerArchive.sanitizeTitle(String(repeating: "x", count: 100)).count, 40)
        let name = AnswerArchive.uniqueBaseName(
            root: "pi-\(AnswerArchive.sanitizeTitle("my/feature:v2"))",
            existingNames: []
        )
        XCTAssertEqual(name, "pi-my-feature-v2")
        // Collision suffixes still apply to title-derived roots.
        let suffixed = AnswerArchive.uniqueBaseName(root: name, existingNames: ["\(name).md"])
        XCTAssertEqual(suffixed, "\(name)-2")
    }

    func testUniqueNameWithPiPrefix() {
        let date = Date(timeIntervalSince1970: 1_787_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let name = AnswerArchive.uniqueBaseName(date: date, existingNames: [], prefix: "pi", calendar: calendar)
        XCTAssertTrue(name.hasPrefix("pi-"))
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

    func testPiDiscoveryOverrideAndFallbacks() {
        let resolvedOverride = BinaryDiscovery.resolve(
            binaryName: "pi",
            override: "/opt/custom/pi",
            fallbackCandidates: BinaryDiscovery.piFallbackCandidates,
            fileExists: { $0 == "/opt/custom/pi" }
        )
        XCTAssertEqual(resolvedOverride, "/opt/custom/pi")

        let resolvedFallback = BinaryDiscovery.resolve(
            binaryName: "pi",
            override: "",
            fallbackCandidates: ["/home/.local/bin/pi"],
            fileExists: { $0 == "/home/.local/bin/pi" }
        )
        XCTAssertEqual(resolvedFallback, "/home/.local/bin/pi")
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

final class NotchMetricsTests: XCTestCase {
    func testNotchedScreenUsesAuxiliaryAreas() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let metrics = NotchMetrics.from(
            screenFrame: screen,
            visibleFrame: visible,
            auxiliaryTopLeft: 650,
            auxiliaryTopRight: 650,
            safeAreaTop: 32
        )
        XCTAssertTrue(metrics.hasNotch)
        XCTAssertEqual(metrics.notchWidth, 212)
        XCTAssertEqual(metrics.notchHeight, 32)
        XCTAssertEqual(metrics.compactSize.height, metrics.notchHeight)
        XCTAssertEqual(metrics.notchFrame.origin.y, screen.maxY - 32)
        XCTAssertEqual(metrics.notchFrame.midX, screen.midX, accuracy: 0.5)

        let compact = metrics.frame(for: metrics.compactSize, expanded: false)
        XCTAssertEqual(compact.maxY, screen.maxY)
        XCTAssertEqual(compact.minX, screen.midX - metrics.notchWidth / 2 - metrics.compactLeadingWidth, accuracy: 0.5)

        let expanded = metrics.frame(for: metrics.expandedSize(contentHeight: 400), expanded: true)
        XCTAssertEqual(expanded.maxY, screen.maxY)
        XCTAssertEqual(expanded.midX, screen.midX, accuracy: 0.5)
        XCTAssertEqual(expanded.height, 432)
    }

    func testNonNotchedScreenFallsBackToVisibleFrame() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let metrics = NotchMetrics.from(
            screenFrame: screen,
            visibleFrame: visible,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil,
            safeAreaTop: 0
        )
        XCTAssertFalse(metrics.hasNotch)
        let compact = metrics.frame(for: metrics.compactSize, expanded: false)
        XCTAssertLessThan(compact.maxY, visible.maxY + 0.1)
        XCTAssertEqual(compact.midX, visible.midX, accuracy: 0.5)
        XCTAssertEqual(metrics.compactSize.width, Theme.pillWidth)
    }

    func testMarketingMetricsAreNotched() {
        XCTAssertTrue(NotchMetrics.marketing.hasNotch)
        XCTAssertEqual(NotchMetrics.marketing.notchHeight, 32)
        XCTAssertGreaterThan(NotchMetrics.marketing.notchWidth, 100)
    }

    func testNotchFrameUsesMeasuredEdgesNotAssumedCentering() {
        // Asymmetric ears: the lens is not at screen midX, and the frame must
        // be measured from the ear edges instead of centered.
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let metrics = NotchMetrics.from(
            screenFrame: screen,
            visibleFrame: visible,
            auxiliaryTopLeft: 700,
            auxiliaryTopRight: 600,
            safeAreaTop: 32
        )
        XCTAssertTrue(metrics.hasNotch)
        XCTAssertEqual(metrics.notchLeftEdge, 700, accuracy: 0.5)
        XCTAssertEqual(metrics.notchFrame.minX, 700, accuracy: 0.5)
        XCTAssertEqual(metrics.notchFrame.width, 212, accuracy: 0.5)
        XCTAssertEqual(metrics.notchFrame.midX, 806, accuracy: 0.5)
        XCTAssertNotEqual(metrics.notchFrame.midX, screen.midX, accuracy: 0.5)

        let compact = metrics.frame(for: metrics.compactSize, expanded: false)
        XCTAssertEqual(compact.minX, metrics.notchFrame.minX - metrics.compactLeadingWidth, accuracy: 0.5)
    }

    func testMenuBarSafeAreaIsNotANotch() {
        XCTAssertFalse(NotchMetrics.looksLikeHardwareNotch(
            left: 12, right: 12, safeAreaTop: 24, screenWidth: 1920
        ))
        XCTAssertFalse(NotchMetrics.looksLikeHardwareNotch(
            left: 650, right: 650, safeAreaTop: 8, screenWidth: 1512
        ))
        XCTAssertTrue(NotchMetrics.looksLikeHardwareNotch(
            left: 650, right: 650, safeAreaTop: 32, screenWidth: 1512
        ))
    }
}

final class DisplayOccupationTests: XCTestCase {
    func testForeignFullscreenIgnoresOurPID() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertFalse(DisplayOccupation.isForeignFullscreen(
            bounds: screen, screen: screen, layer: 0, ownerPID: 42, ourPID: 42
        ))
        XCTAssertTrue(DisplayOccupation.isForeignFullscreen(
            bounds: screen, screen: screen, layer: 0, ownerPID: 99, ourPID: 42
        ))
        XCTAssertFalse(DisplayOccupation.isForeignFullscreen(
            bounds: CGRect(x: 0, y: 0, width: 400, height: 300),
            screen: screen, layer: 0, ownerPID: 99, ourPID: 42
        ))
    }

    func testSameSizeSecondDisplayIsNotFullscreen() {
        // A fullscreen window on an identical display beside or above the
        // pinned one must not count as covering it (width/height match).
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let beside = CGRect(x: 1512, y: 0, width: 1512, height: 982)
        XCTAssertFalse(DisplayOccupation.isForeignFullscreen(
            bounds: beside, screen: screen, layer: 0, ownerPID: 99, ourPID: 42
        ))
        let above = CGRect(x: 0, y: -982, width: 1512, height: 982)
        XCTAssertFalse(DisplayOccupation.isForeignFullscreen(
            bounds: above, screen: screen, layer: 0, ownerPID: 99, ourPID: 42
        ))
        // The same window positioned over this screen still counts.
        XCTAssertTrue(DisplayOccupation.isForeignFullscreen(
            bounds: screen, screen: screen, layer: 0, ownerPID: 99, ourPID: 42
        ))
    }

    func testTouchingEdgeIsNotFullscreen() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let touching = CGRect(x: 1512 - 1, y: 0, width: 1512, height: 982)
        XCTAssertFalse(DisplayOccupation.isForeignFullscreen(
            bounds: touching, screen: screen, layer: 0, ownerPID: 99, ourPID: 42
        ))
    }
}

final class LaunchContextTests: XCTestCase {
    func testMissingAppleEventIsNotLogin() {
        XCTAssertFalse(LaunchContext.isLoginLaunch(event: nil))
    }
}

final class SurfaceGuardTests: XCTestCase {
    func testScreenshotChords() {
        XCTAssertTrue(SurfaceGuard.isScreenshotChord(keyCode: 20, flags: [.command, .shift]))
        XCTAssertTrue(SurfaceGuard.isScreenshotChord(keyCode: 21, flags: [.command, .shift]))
        XCTAssertTrue(SurfaceGuard.isScreenshotChord(keyCode: 23, flags: [.command, .shift]))
        XCTAssertFalse(SurfaceGuard.isScreenshotChord(keyCode: 20, flags: [.command]))
        XCTAssertFalse(SurfaceGuard.isScreenshotChord(keyCode: 20, flags: [.command, .shift, .option]))
        XCTAssertFalse(SurfaceGuard.isScreenshotChord(keyCode: 0, flags: [.command, .shift]))
    }

    func testOnlyScreenshotAppsHideThePassiveSurface() {
        XCTAssertTrue(SurfaceGuard.shouldHideForBundle("com.apple.screencaptureui"))
        XCTAssertFalse(SurfaceGuard.shouldHideForBundle("us.zoom.xos"))
        XCTAssertFalse(SurfaceGuard.shouldHideForBundle("com.apple.Safari"))
        XCTAssertFalse(SurfaceGuard.shouldHideForBundle("com.apple.ControlCenter"))
        XCTAssertFalse(SurfaceGuard.shouldHideForBundle(nil))
    }

    func testUserSummonBypassesPassiveHide() {
        XCTAssertTrue(SurfaceGuard.shouldHidePassiveSurface(
            captureHidden: true, fullscreenCovered: false, userSummoned: false
        ))
        XCTAssertFalse(SurfaceGuard.shouldHidePassiveSurface(
            captureHidden: true, fullscreenCovered: true, userSummoned: true
        ))
    }

    func testCaptureHideDurations() {
        XCTAssertEqual(SurfaceGuard.captureHideDuration(for: 20), 1.4) // ⌘⇧3
        XCTAssertEqual(SurfaceGuard.captureHideDuration(for: 21), 8)   // ⌘⇧4 region selection
        XCTAssertEqual(SurfaceGuard.captureHideDuration(for: 23), 1.4) // ⌘⇧5
        XCTAssertEqual(SurfaceGuard.captureHideDuration(for: 0), 1.4)  // not a chord
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
    private var readersClosed = false

    init() {
        standardOutput = stdoutPipe.fileHandleForReading
        standardError = stderrPipe.fileHandleForReading
    }

    var readersAreClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return readersClosed
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

    /// Mirrors FoundationProcess: force EOF on our side once the process is
    /// known dead. For the mock, closing the write ends delivers real EOF.
    func closeReaders() {
        lock.lock()
        readersClosed = true
        lock.unlock()
        closeStdout()
        closeStderr()
    }

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
    _ engine: any EngineClient,
    request: EngineRequest,
    runID: UUID = UUID(),
    box: EventBox
) async {
    await engine.run(request, runID: runID) { event in
        box.record(event)
    }
}

// MARK: Multi-turn harness (start session -> drive turns -> close)
// `runEngine` blocks until run() returns, so it cannot drive a session that
// survives its first turn. These helpers keep the process alive between turns.

private func startSession(
    _ engine: any EngineClient,
    settings: AppSettings,
    box: EventBox
) async throws -> SessionHandle {
    try await engine.begin(settings: settings, onEvent: box.recorder())
}

/// Polls `MockProcess.written` for a marker so tests feed protocol lines only
/// after the engine actually wrote the preceding request.
private func waitForWritten(_ process: MockProcess, contains needle: String, timeoutSeconds: Double = 5) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if process.written.joined().contains(needle) { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

private func waitFor(_ condition: @escaping @Sendable () -> Bool, timeoutSeconds: Double = 5) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

private func writtenCount(_ process: MockProcess, containing needle: String) -> Int {
    process.written.filter { $0.contains(needle) }.count
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
        // Archiving is conversation-level since plan 008 Phase 8: engines
        // emit completions without files; AskSession owns the archive.
        XCTAssertNil(result?.archiveURL)
        try? FileManager.default.removeItem(at: answers)
    }

    func testLargeInitResponseLineIsProcessed() async {
        // Regression: the real initialize response is a single ~20 KB line, larger
        // than the old 16 KB read chunk. read(upToCount:) blocked waiting for a full
        // chunk and the run deadlocked; availableData must deliver it in pieces.
        let launcher = MockLauncher()
        let engine = DroidEngine(launcher: launcher, fileExists: { _ in true })
        let box = EventBox()
        let answers = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var settings = Self.makeSettings()
        settings.answersDirectory = answers.path

        let bigModel = String(repeating: "x", count: 20_000)
        let initLine = #"{"jsonrpc":"2.0","id":"1","result":{"session":{"settings":{"modelId":""#
            + bigModel + #""}}}}"#

        let driver = Task.detached {
            await waitForProcesses(launcher, count: 1)
            let process = launcher.processes[0]
            process.feedStdout(initLine)
            try? await Task.sleep(for: .milliseconds(300))
            process.feedStdout(#"{"jsonrpc":"2.0","method":"droid.session_notification","params":{"type":"assistant_text_delta","textDelta":"ok"}}"#)
            process.feedStdout(#"{"jsonrpc":"2.0","method":"droid.session_notification","params":{"type":"agent_turn_completed","durationMs":5}}"#)
            process.closeStdout()
            process.closeStderr()
            process.setExit(0)
        }

        await runEngine(engine, request: DroidRunRequest(prompt: "hi", images: [], settings: settings), box: box)
        await driver.value

        let written = launcher.processes[0].written.joined()
        XCTAssertTrue(written.contains(#""id":"2"#), "engine never answered the large init response")
        let result = box.snapshot().compactMap { event -> DroidRunResult? in
            if case .completed(_, let r) = event { return r }
            return nil
        }.last
        XCTAssertEqual(result?.text, "ok")
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

    // MARK: Multi-turn on one process

    private static func makeMultiTurnSettings() -> AppSettings {
        var settings = AppSettings.default
        settings.droidPath = "/tmp/droid"
        settings.answersDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        return settings
    }

    private static let droidInitResponse =
        #"{"jsonrpc":"2.0","id":"1","result":{"session":{"settings":{"modelId":"gpt-5"}}}}"#

    func testDroidServesTwoTurnsOnOneProcess() async throws {
        let launcher = MockLauncher()
        let engine = DroidEngine(launcher: launcher, fileExists: { _ in true })
        let box = EventBox()
        let settings = Self.makeMultiTurnSettings()

        let handle = try await startSession(engine, settings: settings, box: box)
        let process = launcher.processes[0]
        process.feedStdout(Self.droidInitResponse)

        let turn1 = UUID()
        let send1 = Task.detached {
            await engine.send(DroidRunRequest(prompt: "one", images: [], settings: settings), turnID: turn1, to: handle)
        }
        await waitForWritten(process, contains: "add_user_message")
        process.feedStdout(#"{"jsonrpc":"2.0","method":"droid.session_notification","params":{"type":"assistant_text_delta","textDelta":"Hello"}}"#)
        process.feedStdout(#"{"jsonrpc":"2.0","method":"droid.session_notification","params":{"type":"agent_turn_completed","reason":"completed","durationMs":5}}"#)
        await send1.value

        // Turn 2 rides the same process — no relaunch, no terminate between.
        let turn2 = UUID()
        let send2 = Task.detached {
            await engine.send(DroidRunRequest(prompt: "two", images: [], settings: settings), turnID: turn2, to: handle)
        }
        let sawSecondMessage = await waitFor { writtenCount(process, containing: "add_user_message") >= 2 }
        XCTAssertTrue(sawSecondMessage, "second turn never sent add_user_message")
        process.feedStdout(#"{"jsonrpc":"2.0","method":"droid.session_notification","params":{"type":"assistant_text_delta","textDelta":"World"}}"#)
        process.feedStdout(#"{"jsonrpc":"2.0","method":"droid.session_notification","params":{"type":"agent_turn_completed","reason":"completed","durationMs":5}}"#)
        await send2.value

        XCTAssertEqual(launcher.count, 1, "a second CLI process was launched")
        XCTAssertFalse(process.terminated, "process was killed between turns")

        let completions = box.snapshot().compactMap { event -> (UUID, String)? in
            if case .completed(let id, let result) = event { return (id, result.text) }
            return nil
        }
        XCTAssertEqual(completions.map(\.1), ["Hello", "World"])
        XCTAssertEqual(completions.map(\.0), [turn1, turn2])
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: settings.answersDirectory))
        await engine.close(handle)
    }

    func testDroidErrorReasonFailsTurnButKeepsSessionAlive() async throws {
        let launcher = MockLauncher()
        let engine = DroidEngine(launcher: launcher, fileExists: { _ in true })
        let box = EventBox()
        let settings = Self.makeMultiTurnSettings()

        let handle = try await startSession(engine, settings: settings, box: box)
        let process = launcher.processes[0]
        process.feedStdout(Self.droidInitResponse)

        let turn1 = UUID()
        let send1 = Task.detached {
            await engine.send(DroidRunRequest(prompt: "one", images: [], settings: settings), turnID: turn1, to: handle)
        }
        await waitForWritten(process, contains: "add_user_message")
        // The error notification is captured this turn; agent_turn_completed
        // then reports reason "error" and must fail the turn with that text.
        process.feedStdout(#"{"jsonrpc":"2.0","method":"droid.session_notification","params":{"type":"error","message":"Connection error."}}"#)
        process.feedStdout(#"{"jsonrpc":"2.0","method":"droid.session_notification","params":{"type":"agent_turn_completed","reason":"error","durationMs":5,"tokenUsage":{"inputTokens":0,"outputTokens":0}}}"#)
        await send1.value

        let failure = box.snapshot().compactMap { event -> String? in
            if case .failed(_, let message) = event { return message }
            return nil
        }.last
        XCTAssertEqual(failure, "Connection error.")
        XCTAssertFalse(process.terminated, "an errored turn tore the session down")

        // The session is still usable: a follow-up turn completes in-process.
        let turn2 = UUID()
        let send2 = Task.detached {
            await engine.send(DroidRunRequest(prompt: "two", images: [], settings: settings), turnID: turn2, to: handle)
        }
        _ = await waitFor { writtenCount(process, containing: "add_user_message") >= 2 }
        process.feedStdout(#"{"jsonrpc":"2.0","method":"droid.session_notification","params":{"type":"assistant_text_delta","textDelta":"Recovered"}}"#)
        process.feedStdout(#"{"jsonrpc":"2.0","method":"droid.session_notification","params":{"type":"agent_turn_completed","reason":"completed","durationMs":5}}"#)
        await send2.value

        XCTAssertEqual(launcher.count, 1)
        let recovery = box.snapshot().compactMap { event -> String? in
            if case .completed(_, let result) = event { return result.text }
            return nil
        }.last
        XCTAssertEqual(recovery, "Recovered")
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: settings.answersDirectory))
        await engine.close(handle)
    }

    /// Droid has no wire-steer path: its mid-turn `add_user_message` queue
    /// auto-executes as an engine-initiated turn whose output the handle can
    /// never settle, so `queue` refuses with the typed error and steering is
    /// delivered client-side by AskSession instead.
    func testDroidQueueThrowsTypedUnsupported() async throws {
        let launcher = MockLauncher()
        let engine = DroidEngine(launcher: launcher, fileExists: { _ in true })
        let settings = Self.makeMultiTurnSettings()
        let handle = try await startSession(engine, settings: settings, box: EventBox())
        do {
            try await engine.queue(DroidRunRequest(prompt: "x", images: [], settings: settings), to: handle)
            XCTFail("droid queue must throw")
        } catch let error as EngineError {
            XCTAssertEqual(error, .steeringUnsupported(.droid))
        }
        await engine.close(handle)
    }

    func testDroidInterruptDoesNotTerminateProcess() async throws {
        let launcher = MockLauncher()
        let engine = DroidEngine(launcher: launcher, fileExists: { _ in true })
        let box = EventBox()
        let settings = Self.makeMultiTurnSettings()

        let handle = try await startSession(engine, settings: settings, box: box)
        let process = launcher.processes[0]
        process.feedStdout(Self.droidInitResponse)

        let turn1 = UUID()
        let send1 = Task.detached {
            await engine.send(DroidRunRequest(prompt: "one", images: [], settings: settings), turnID: turn1, to: handle)
        }
        await waitForWritten(process, contains: "add_user_message")

        await engine.interrupt(handle)

        // The interrupt is protocol bytes, not a kill.
        XCTAssertTrue(process.written.joined().contains("droid.interrupt_session"))
        XCTAssertFalse(process.terminated, "interrupt terminated the process")
        await send1.value

        let interruptions = box.snapshot().compactMap { event -> UUID? in
            if case .interrupted(let id) = event { return id }
            return nil
        }
        XCTAssertEqual(interruptions, [turn1])
        XCTAssertEqual(launcher.count, 1)
        await engine.close(handle)
    }

    func testUnexpectedProcessExitFailsTurnAndMarksSessionDead() async throws {
        let launcher = MockLauncher()
        let engine = DroidEngine(launcher: launcher, fileExists: { _ in true })
        let box = EventBox()
        let settings = Self.makeMultiTurnSettings()

        let handle = try await startSession(engine, settings: settings, box: box)
        let process = launcher.processes[0]
        process.feedStdout(Self.droidInitResponse)

        let turn1 = UUID()
        let send1 = Task.detached {
            await engine.send(DroidRunRequest(prompt: "one", images: [], settings: settings), turnID: turn1, to: handle)
        }
        await waitForWritten(process, contains: "add_user_message")
        process.feedStdout(#"{"jsonrpc":"2.0","method":"droid.session_notification","params":{"type":"assistant_text_delta","textDelta":"partial"}}"#)
        // Crash mid-turn.
        process.closeStdout()
        process.closeStderr()
        process.setExit(1)
        await send1.value

        let failure = box.snapshot().compactMap { event -> String? in
            if case .failed(_, let message) = event { return message }
            return nil
        }.last
        XCTAssertEqual(failure, "Droid exited with status 1.")

        // The next send relaunches instead of talking into a dead pipe.
        let turn2 = UUID()
        let send2 = Task.detached {
            await engine.send(DroidRunRequest(prompt: "two", images: [], settings: settings), turnID: turn2, to: handle)
        }
        _ = await waitFor { launcher.count >= 2 }
        let replacement = launcher.processes[1]
        replacement.feedStdout(Self.droidInitResponse)
        _ = await waitForWritten(replacement, contains: "add_user_message")
        replacement.feedStdout(#"{"jsonrpc":"2.0","method":"droid.session_notification","params":{"type":"assistant_text_delta","textDelta":"back"}}"#)
        replacement.feedStdout(#"{"jsonrpc":"2.0","method":"droid.session_notification","params":{"type":"agent_turn_completed","reason":"completed","durationMs":5}}"#)
        await send2.value

        XCTAssertEqual(launcher.count, 2)
        let recovery = box.snapshot().compactMap { event -> String? in
            if case .completed(_, let result) = event { return result.text }
            return nil
        }.last
        XCTAssertEqual(recovery, "back")
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: settings.answersDirectory))
        await engine.close(handle)
    }
}

final class MainMenuTests: XCTestCase {
    /// The composer lives in a borderless window; without a main menu AppKit
    /// never dispatches standard editing key equivalents to the text view.
    func testMainMenuProvidesEditingKeyEquivalents() {
        let menu = MainMenuBuilder.build()
        let edit = menu.items.compactMap(\.submenu).first
        XCTAssertNotNil(edit, "expected an Edit submenu")
        let equivalents = Dictionary(
            edit?.items.compactMap { item -> (String, Selector)? in
                guard let action = item.action else { return nil }
                return (item.keyEquivalent, action)
            }.map { ($0.0, $0.1) } ?? [],
            uniquingKeysWith: { first, _ in first }
        )
        XCTAssertEqual(equivalents["a"], #selector(NSText.selectAll(_:)))
        XCTAssertEqual(equivalents["c"], #selector(NSText.copy(_:)))
        XCTAssertEqual(equivalents["v"], #selector(NSText.paste(_:)))
        XCTAssertEqual(equivalents["x"], #selector(NSText.cut(_:)))
        XCTAssertEqual(equivalents["z"], Selector(("undo:")))
        XCTAssertEqual(equivalents["Z"], Selector(("redo:")))
    }
}

final class RealDroidIntegrationTests: XCTestCase {
    /// Runs the real droid CLI through the production engine and launcher.
    /// Skipped unless ASKDROID_INTEGRATION=1 is set.
    func testRealDroidEndToEnd() async throws {
        guard ProcessInfo.processInfo.environment["ASKDROID_INTEGRATION"] == "1" else {
            throw XCTSkip("Set ASKDROID_INTEGRATION=1 to run against the real droid CLI")
        }
        let engine = DroidEngine()
        let box = EventBox()
        var settings = AppSettings.default
        settings.answersDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path

        await runEngine(
            engine,
            request: DroidRunRequest(prompt: "Reply with exactly: ok", images: [], settings: settings),
            box: box
        )

        let failure = box.snapshot().compactMap { event -> String? in
            if case .failed(_, let message) = event { return message }
            return nil
        }.last
        XCTAssertNil(failure, "run failed: \(failure ?? "")")
        let result = box.snapshot().compactMap { event -> DroidRunResult? in
            if case .completed(_, let r) = event { return r }
            return nil
        }.last
        let logLines = box.snapshot().compactMap { event -> String? in
            if case .log(_, let text) = event { return text }
            return nil
        }
        XCTAssertNotNil(result, "no completion event; log: \(logLines)")
        XCTAssertFalse(result?.text.isEmpty ?? true, "empty answer")
    }
}

@MainActor
final class AskSessionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AskLog.setDirectoryOverrideForTesting(
            FileManager.default.temporaryDirectory.appendingPathComponent("AskDroidTests-logs", isDirectory: true)
        )
    }

    override func tearDown() {
        AskLog.setDirectoryOverrideForTesting(nil)
        super.tearDown()
    }

    private func makeSession(launcher: MockLauncher, engine: Engine = .droid) -> AskSession {
        var settings = AppSettings.default
        settings.engine = engine
        settings.droidPath = "/tmp/droid"
        settings.piPath = "/tmp/pi"
        let temp = FileManager.default.temporaryDirectory
        settings.answersDirectory = temp.appendingPathComponent(UUID().uuidString).path
        settings.workingDirectory = temp.appendingPathComponent(UUID().uuidString).path
        return AskSession(
            settings: settings,
            droidEngine: DroidEngine(launcher: launcher, fileExists: { _ in true }),
            piEngine: PiEngine(launcher: launcher, fileExists: { _ in true })
        )
    }

    func testInjectedPiEngineWinsOverSettings() {
        var settings = AppSettings.default
        settings.engine = .droid
        let injected = PiEngine()
        let session = AskSession(settings: settings, engine: injected)
        XCTAssertEqual(session.settings.engine, .pi)
        XCTAssertIdentical(session.engine as? PiEngine, injected)
    }

    func testInjectedDroidEngineWinsOverSettings() {
        var settings = AppSettings.default
        settings.engine = .pi
        let injected = DroidEngine()
        let session = AskSession(settings: settings, engine: injected)
        XCTAssertEqual(session.settings.engine, .droid)
        XCTAssertIdentical(session.engine as? DroidEngine, injected)
    }

    func testStaleEventsDroppedAfterInterrupt() async {
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
        // Sends gate on droid's initialization handshake.
        feedDroidInit(launcher.processes[0])
        _ = await waitForWritten(launcher.processes[0], contains: "add_user_message")

        session.interruptTurn()
        XCTAssertEqual(session.phase, .interrupted)
        XCTAssertNil(session.errorMessage, "interrupting is not an error")

        // Stale events from the interrupted turn must not mutate the UI.
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
        XCTAssertEqual(session.phase, .interrupted)
        XCTAssertEqual(session.transcript.first?.status, .interrupted)
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

    func testPresentDoesNotResetCompletedPhase() {
        let session = makeSession(launcher: MockLauncher())
        session.phase = .completed
        session.present()
        XCTAssertTrue(session.isExpanded)
        XCTAssertEqual(session.phase, .completed)
        session.dismiss()
        XCTAssertFalse(session.isExpanded)
        XCTAssertEqual(session.phase, .completed)
    }

    func testFailedCompactTitleStaysScannable() {
        let session = makeSession(launcher: MockLauncher())
        session.phase = .failed
        session.errorMessage = "Droid hit a connection error and could not reach the model."
        XCTAssertEqual(session.compactTitle, "Failed")
    }

    // MARK: Multi-turn transcript

    @MainActor
    private func waitForSession(_ condition: @escaping () -> Bool, timeoutSeconds: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func feedDroidInit(_ process: MockProcess) {
        process.feedStdout(#"{"jsonrpc":"2.0","id":"1","result":{"session":{"settings":{"modelId":"gpt-5"}}}}"#)
    }

    private func feedDroidTurn(_ process: MockProcess, delta: String?, reason: String = "completed") {
        if let delta {
            process.feedStdout(
                #"{"jsonrpc":"2.0","method":"droid.session_notification","params":{"type":"assistant_text_delta","textDelta":"\#(delta)"}}"#
            )
        }
        process.feedStdout(
            #"{"jsonrpc":"2.0","method":"droid.session_notification","params":{"type":"agent_turn_completed","reason":"\#(reason)","durationMs":5}}"#
        )
    }

    private func feedPiTurn(_ process: MockProcess, delta: String?) {
        process.feedStdout(#"{"id":"1","type":"response","command":"prompt","success":true}"#)
        if let delta {
            process.feedStdout(
                #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"\#(delta)"}}"#
            )
        }
        process.feedStdout(#"{"type":"agent_settled"}"#)
    }

    func testFollowUpKeepsPriorTurnsInTranscript() async {
        let launcher = MockLauncher()
        let session = makeSession(launcher: launcher)
        session.isExpanded = true
        session.prompt = "first"
        session.submit()

        _ = await waitFor { launcher.count >= 1 }
        let process = launcher.processes[0]
        feedDroidInit(process)
        _ = await waitForWritten(process, contains: "add_user_message")
        feedDroidTurn(process, delta: "Answer one")
        _ = await waitForSession { session.transcript.first?.status == .completed }
        XCTAssertEqual(session.transcript.count, 1)
        XCTAssertEqual(session.transcript[0].answer, "Answer one")

        // A follow-up must not wipe history.
        session.prompt = "second"
        session.submit()
        let sawSecondMessage = await waitForSession { writtenCount(process, containing: "add_user_message") >= 2 }
        XCTAssertTrue(sawSecondMessage)
        feedDroidTurn(process, delta: "Answer two")
        _ = await waitForSession { session.transcript.count == 2 && session.transcript[1].status == .completed }

        XCTAssertEqual(session.transcript.count, 2)
        XCTAssertEqual(session.transcript[0].question, "first")
        XCTAssertEqual(session.transcript[0].answer, "Answer one")
        XCTAssertEqual(session.transcript[1].answer, "Answer two")
        XCTAssertEqual(session.answer, "Answer two", "mirror should show the newest turn")
        XCTAssertEqual(launcher.count, 1, "follow-up relaunched the CLI")
        XCTAssertFalse(process.terminated)
    }

    func testInterruptLeavesSessionUsableForNextTurn() async {
        let launcher = MockLauncher()
        let session = makeSession(launcher: launcher)
        session.isExpanded = true
        session.prompt = "first"
        session.submit()

        _ = await waitFor { launcher.count >= 1 }
        let process = launcher.processes[0]
        feedDroidInit(process)
        _ = await waitForWritten(process, contains: "add_user_message")

        session.interruptTurn()
        XCTAssertEqual(session.phase, .interrupted)
        XCTAssertEqual(session.transcript.first?.status, .interrupted)
        XCTAssertNil(session.errorMessage)

        // The same session serves the next turn.
        session.prompt = "second"
        session.submit()
        let sawSecondMessage = await waitForSession { writtenCount(process, containing: "add_user_message") >= 2 }
        XCTAssertTrue(sawSecondMessage)
        feedDroidTurn(process, delta: "Answer two")
        _ = await waitForSession { session.transcript.count == 2 && session.transcript[1].status == .completed }

        XCTAssertEqual(session.transcript[0].status, .interrupted)
        XCTAssertEqual(session.transcript[1].status, .completed)
        XCTAssertEqual(launcher.count, 1)
        XCTAssertFalse(process.terminated)
    }

    func testStartNewConversationClearsTranscript() async {
        let launcher = MockLauncher()
        let session = makeSession(launcher: launcher, engine: .pi)
        session.isExpanded = true
        session.prompt = "first"
        session.submit()

        _ = await waitFor { launcher.count >= 1 }
        let process = launcher.processes[0]
        _ = await waitForWritten(process, contains: #""type":"prompt""#)
        feedPiTurn(process, delta: "One")
        _ = await waitForSession { session.transcript.first?.status == .completed }
        XCTAssertEqual(session.transcript.count, 1)

        session.startNewConversation()
        _ = await waitForWritten(process, contains: #""type":"new_session""#)
        XCTAssertTrue(session.transcript.isEmpty, "transcript survived a new conversation")
        XCTAssertEqual(session.phase, .composing)
        XCTAssertEqual(launcher.count, 1, "reset relaunched the CLI")
        XCTAssertFalse(process.terminated, "reset killed the process")

        // The conversation is usable again on the same process.
        session.prompt = "second"
        session.submit()
        let sawSecondPrompt = await waitForSession { writtenCount(process, containing: #""type":"prompt""#) >= 2 }
        XCTAssertTrue(sawSecondPrompt)
        feedPiTurn(process, delta: "Two")
        _ = await waitForSession { session.transcript.count == 1 && session.transcript[0].status == .completed }
        XCTAssertEqual(session.transcript[0].answer, "Two")
        XCTAssertEqual(launcher.count, 1)
    }

    func testPerTurnLogDoesNotLeakIntoNextTurnDiagnostics() async {
        let launcher = MockLauncher()
        let session = makeSession(launcher: launcher)
        session.isExpanded = true
        session.prompt = "one"
        session.submit()

        _ = await waitFor { launcher.count >= 1 }
        let process = launcher.processes[0]
        feedDroidInit(process)
        _ = await waitForWritten(process, contains: "add_user_message")
        // Turn 1 hits a connection error: tool noise, error notification,
        // then agent_turn_completed with reason "error".
        process.feedStdout(#"{"jsonrpc":"2.0","method":"droid.session_notification","params":{"type":"tool_call","toolUse":{"name":"Read","id":"9","input":{"path":"x.swift"}}}}"#)
        process.feedStdout(#"{"jsonrpc":"2.0","method":"droid.session_notification","params":{"type":"error","message":"Connection error."}}"#)
        feedDroidTurn(process, delta: nil, reason: "error")
        _ = await waitForSession { session.transcript.first?.status == .failed }
        XCTAssertEqual(session.errorMessage?.lowercased().contains("connection error"), true)

        // Turn 2 completes with no text; its diagnostics must be generic.
        session.prompt = "two"
        session.submit()
        _ = await waitForSession { writtenCount(process, containing: "add_user_message") >= 2 }
        feedDroidTurn(process, delta: nil, reason: "completed")
        _ = await waitForSession { session.transcript.count == 2 && session.transcript[1].status != .running }

        XCTAssertEqual(session.transcript[1].status, .failed)
        XCTAssertNotNil(session.transcript[1].errorMessage, "empty-answer turn should carry an explanation")
        XCTAssertFalse(session.errorMessage?.lowercased().contains("connection error") ?? true,
                       "turn 1's connection error leaked into turn 2's diagnostics")
        XCTAssertTrue(session.errorMessage?.contains("without writing an answer") ?? false)
    }

    func testEngineSwitchClosesSession() async {
        let launcher = MockLauncher()
        let session = makeSession(launcher: launcher, engine: .pi)
        session.isExpanded = true
        session.prompt = "first"
        session.submit()

        _ = await waitFor { launcher.count >= 1 }
        let process = launcher.processes[0]
        _ = await waitForWritten(process, contains: #""type":"prompt""#)
        feedPiTurn(process, delta: "One")
        _ = await waitForSession { session.transcript.first?.status == .completed }

        session.engineDidChange()
        XCTAssertTrue(session.transcript.isEmpty, "transcript should not follow a new engine")
        _ = await waitForSession { process.terminated }
        XCTAssertEqual(launcher.count, 1)

        // The next submit starts a fresh session for the (same) engine.
        session.prompt = "second"
        session.submit()
        _ = await waitForSession { launcher.count >= 2 }
        let fresh = launcher.processes[1]
        _ = await waitForWritten(fresh, contains: #""type":"prompt""#)
        feedPiTurn(fresh, delta: "Two")
        _ = await waitForSession { session.transcript.first?.status == .completed }
        XCTAssertEqual(session.transcript.count, 1)
        XCTAssertEqual(session.transcript[0].answer, "Two")
        XCTAssertEqual(launcher.count, 2)
    }

    // MARK: Transcript surface (plan 008 Phase 6)

    func testContextStatsSurfacesForFooterMeta() {
        let session = makeSession(launcher: MockLauncher())
        XCTAssertNil(session.contextStats)
        session.handle(.contextStats(used: 14_601, limit: 922_000))
        XCTAssertEqual(session.contextStats, ContextStats(used: 14_601, limit: 922_000))
        XCTAssertEqual(session.contextStats?.label, "ctx 14.6k / 922k")
    }

    func testContextStatsReplacementNeverMixesPairs() {
        // Pi can change its reported window mid-conversation (model switch).
        // Each reading replaces the previous one whole — a new turn's tokens
        // must never pair with an older turn's window.
        let session = makeSession(launcher: MockLauncher())
        session.handle(.contextStats(used: 11_400, limit: 922_000))
        session.handle(.contextStats(used: 11_400, limit: 262_144))
        XCTAssertEqual(session.contextStats, ContextStats(used: 11_400, limit: 262_144))
    }

    func testContextStatsLabelHandlesSmallAndHugeFills() {
        XCTAssertEqual(ContextStats(used: 512, limit: 200_000).label, "ctx 512 / 200k")
        XCTAssertEqual(ContextStats(used: 60_000, limit: 200_000).label, "ctx 60.0k / 200k")
    }

    func testToggleExpandedRowTracksPriorTurns() {
        let session = makeSession(launcher: MockLauncher())
        let id = UUID()
        XCTAssertTrue(session.expandedTurnIDs.isEmpty)
        session.toggleExpandedRow(id)
        XCTAssertEqual(session.expandedTurnIDs, [id])
        session.toggleExpandedRow(id)
        XCTAssertTrue(session.expandedTurnIDs.isEmpty)
    }

    // MARK: Header lines (operator fix batch)

    func testHeaderPrimaryLeadsWithNewestQuestion() {
        XCTAssertEqual(
            HeaderLines.primary(isSettingsOpen: true, newestQuestion: "q?", sessionTitle: "title"),
            "Settings"
        )
        // While a conversation is on screen, the visible topic leads even
        // when a session title names an earlier one.
        XCTAssertEqual(
            HeaderLines.primary(isSettingsOpen: false, newestQuestion: "and its wingspan?", sessionTitle: "what is a pelican?"),
            "and its wingspan?"
        )
        XCTAssertEqual(
            HeaderLines.primary(isSettingsOpen: false, newestQuestion: "", sessionTitle: "what is a pelican?"),
            "Look at the attached image(s)."
        )
        // No live turn: the title (or app name) stands.
        XCTAssertEqual(
            HeaderLines.primary(isSettingsOpen: false, newestQuestion: nil, sessionTitle: "what is a pelican?"),
            "what is a pelican?"
        )
        XCTAssertEqual(
            HeaderLines.primary(isSettingsOpen: false, newestQuestion: nil, sessionTitle: nil),
            "AskDroid"
        )
    }

    func testHeaderSecondaryDemotesTitleOnlyWhenItDiffers() {
        // Live activity wins while streaming, even when a title differs.
        XCTAssertEqual(
            HeaderLines.secondary(
                isSettingsOpen: false, phase: .running, activity: "Reading files…",
                newestQuestion: "and its wingspan?", sessionTitle: "what is a pelican?",
                hotkeyDisplay: "⌥Space", engineTitle: "Pi"
            ),
            "Reading files…"
        )
        // Settled: the title drops to the secondary line.
        XCTAssertEqual(
            HeaderLines.secondary(
                isSettingsOpen: false, phase: .completed, activity: "Done",
                newestQuestion: "and its wingspan?", sessionTitle: "what is a pelican?",
                hotkeyDisplay: "⌥Space", engineTitle: "Pi"
            ),
            "what is a pelican?"
        )
        // Title identical to the primary disappears; the hint returns.
        XCTAssertEqual(
            HeaderLines.secondary(
                isSettingsOpen: false, phase: .completed, activity: "",
                newestQuestion: "what is a pelican?", sessionTitle: "what is a pelican?",
                hotkeyDisplay: "⌥Space", engineTitle: "Pi"
            ),
            "⌥Space · ⌘↩ ask · Esc hide"
        )
        // No title at all → hint.
        XCTAssertEqual(
            HeaderLines.secondary(
                isSettingsOpen: false, phase: .idle, activity: "",
                newestQuestion: nil, sessionTitle: nil,
                hotkeyDisplay: "⌥Space", engineTitle: "Pi"
            ),
            "⌥Space · ⌘↩ ask · Esc hide"
        )
    }

    func testThinkingPreviewIsTailOfCollapsedText() {
        XCTAssertEqual(ThinkingPreview.line(from: "short thought"), "short thought")
        XCTAssertEqual(ThinkingPreview.line(from: "a\n b\t\tc"), "a b c")
        let long = String(repeating: "x", count: 200)
        let preview = ThinkingPreview.line(from: long)
        XCTAssertEqual(preview.count, ThinkingPreview.characterLimit + 1, "ellipsis plus the tail")
        XCTAssertTrue(preview.hasPrefix("…"))
        XCTAssertTrue(long.hasSuffix(String(preview.dropFirst())), "preview must come from the end")
    }

    func testRetryFailedTurnResubmitsItsQuestion() async {
        let launcher = MockLauncher()
        let session = makeSession(launcher: launcher)
        session.isExpanded = true
        session.prompt = "find the bug"
        session.submit()

        _ = await waitFor { launcher.count >= 1 }
        let process = launcher.processes[0]
        feedDroidInit(process)
        _ = await waitForWritten(process, contains: "add_user_message")
        feedDroidTurn(process, delta: nil, reason: "error")
        _ = await waitForSession { session.transcript.first?.status == .failed }
        XCTAssertTrue(session.prompt.isEmpty, "composer should have emptied on submit")

        // Try again restores the failed question as a NEW turn.
        session.retryFailedTurn()
        XCTAssertEqual(session.transcript.count, 2, "retry must not wipe the failed turn")
        XCTAssertEqual(session.transcript[0].status, .failed)
        XCTAssertEqual(session.transcript[1].question, "find the bug")
        XCTAssertEqual(session.transcript[1].status, .running)
        let sawSecondMessage = await waitForSession { writtenCount(process, containing: "add_user_message") >= 2 }
        XCTAssertTrue(sawSecondMessage, "retry never sent the question")
        feedDroidTurn(process, delta: "fixed")
        _ = await waitForSession { session.transcript[1].status == .completed }
        XCTAssertEqual(session.transcript[1].answer, "fixed")
    }

    // MARK: Steering (plan 008 Phase 7)

    func testSteeredMessageQueuesWhileTurnIsRunning() async {
        // Pi steers on the wire: the steered prompt must carry
        // streamingBehavior "steer" and mirror the remote queue.
        let launcher = MockLauncher()
        let session = makeSession(launcher: launcher, engine: .pi)
        session.isExpanded = true
        session.prompt = "long running question"
        session.submit()

        _ = await waitFor { launcher.count >= 1 }
        let process = launcher.processes[0]
        _ = await waitForWritten(process, contains: #""type":"prompt""#)
        process.feedStdout(#"{"id":"1","type":"response","command":"prompt","success":true}"#)
        _ = await waitForSession { session.phase == .running && session.transcript[0].status == .running }

        // Type while the turn streams: no new transcript turn, message pends.
        session.prompt = "actually focus on the error path"
        session.submit()
        XCTAssertEqual(session.transcript.count, 1, "steering must not append a turn")
        XCTAssertTrue(session.prompt.isEmpty, "composer should empty once queued")
        XCTAssertEqual(session.pendingMessages, ["actually focus on the error path"])

        let sawSteer = await waitForWritten(process, contains: #""streamingBehavior":"steer""#)
        XCTAssertTrue(sawSteer, "steered prompt was never sent with streamingBehavior")
        let promptsBeforeSettle = writtenCount(process, containing: #""type":"prompt""#)
        XCTAssertEqual(promptsBeforeSettle, 2, "steering must ride the live session, not a new turn")

        // Pi's queue_update is the authoritative pending list.
        session.handle(.queueChanged(["actually focus on the error path", "and also add tests"]))
        XCTAssertEqual(session.pendingMessages, ["actually focus on the error path", "and also add tests"])

        // Settling delivers steered input into the finished turn; the
        // pending mirror clears and no follow-up turn auto-sends.
        process.feedStdout(#"{"type":"agent_settled"}"#)
        _ = await waitForSession { session.transcript[0].status == .completed }
        _ = await waitForSession { session.pendingMessages.isEmpty }
        XCTAssertEqual(session.transcript.count, 1)
        let promptsAfterSettle = writtenCount(process, containing: #""type":"prompt""#)
        XCTAssertEqual(promptsAfterSettle, 2, "settle must not re-send steered messages")
    }

    func testDroidSubmitWhileRunningPendsAndAutoSendsAsNextTurn() async {
        // Droid has no usable wire-steer path (its queued messages run as an
        // unreachable engine-initiated turn), so the session holds the
        // message and sends it through the normal pipeline on settle.
        let launcher = MockLauncher()
        let session = makeSession(launcher: launcher)
        session.isExpanded = true
        session.prompt = "long running question"
        session.submit()

        _ = await waitFor { launcher.count >= 1 }
        let process = launcher.processes[0]
        feedDroidInit(process)
        _ = await waitForWritten(process, contains: "add_user_message")

        session.prompt = "what did you find?"
        session.submit()
        XCTAssertEqual(session.transcript.count, 1, "steering must not append a turn")
        XCTAssertTrue(session.prompt.isEmpty)
        XCTAssertEqual(session.pendingMessages, ["what did you find?"])
        XCTAssertFalse(
            process.written.joined().contains("what did you find?"),
            "droid steering must not write mid-turn bytes the engine cannot answer"
        )

        // Turn 1 settles -> the pending message auto-sends as turn 2.
        feedDroidTurn(process, delta: "answer one")
        let sawSecondMessage = await waitForSession { writtenCount(process, containing: "add_user_message") >= 2 }
        XCTAssertTrue(sawSecondMessage, "pending message never auto-sent")
        XCTAssertTrue(session.transcript.last?.question == "what did you find?")
        XCTAssertEqual(session.transcript.count, 2)
        XCTAssertEqual(session.transcript[0].status, .completed)
        XCTAssertEqual(session.transcript[1].status, .running)

        feedDroidTurn(process, delta: "answer two")
        _ = await waitForSession { session.transcript[1].status == .completed }
        XCTAssertEqual(session.transcript[1].answer, "answer two")
        XCTAssertTrue(session.pendingMessages.isEmpty)
        XCTAssertEqual(launcher.count, 1, "auto-send relaunched the CLI")
    }

    func testInterruptKeepsPendingMessageQueuedUntilSettle() async {
        let launcher = MockLauncher()
        let session = makeSession(launcher: launcher)
        session.isExpanded = true
        session.prompt = "long running question"
        session.submit()

        _ = await waitFor { launcher.count >= 1 }
        let process = launcher.processes[0]
        feedDroidInit(process)
        _ = await waitForWritten(process, contains: "add_user_message")

        session.prompt = "follow-up anyway"
        session.submit()
        XCTAssertEqual(session.pendingMessages, ["follow-up anyway"])

        // The interrupt stops the turn, not the queued intent: settling the
        // interrupted turn auto-sends the pending message as the next one.
        session.interruptTurn()
        XCTAssertEqual(session.transcript[0].status, .interrupted)
        XCTAssertEqual(session.transcript.count, 2)
        XCTAssertEqual(session.transcript[1].question, "follow-up anyway")
        XCTAssertEqual(session.phase, .running)
        let sawSecondMessage = await waitForSession { writtenCount(process, containing: "add_user_message") >= 2 }
        XCTAssertTrue(sawSecondMessage)
        feedDroidTurn(process, delta: "done anyway")
        _ = await waitForSession { session.transcript[1].status == .completed }
        XCTAssertTrue(session.pendingMessages.isEmpty)
    }

    // MARK: Conversation archive and session title (plan 008 Phase 8)

    func testConversationArchiveGrowsAcrossTurns() async {
        let launcher = MockLauncher()
        let session = makeSession(launcher: launcher)
        session.isExpanded = true
        session.prompt = "what is a pelican?"
        session.submit()

        _ = await waitFor { launcher.count >= 1 }
        let process = launcher.processes[0]
        feedDroidInit(process)
        _ = await waitForWritten(process, contains: "add_user_message")
        feedDroidTurn(process, delta: "a big bird")
        _ = await waitForSession { session.transcript.first?.status == .completed }

        // One archive file exists after turn 1 and both the turn and the
        // mirror point at it.
        _ = await waitForSession { session.archiveURL != nil }
        let firstURL = session.archiveURL
        XCTAssertNotNil(firstURL)
        XCTAssertEqual(session.transcript[0].archiveURL, firstURL)

        session.prompt = "and its wingspan?"
        session.submit()
        _ = await waitForSession { writtenCount(process, containing: "add_user_message") >= 2 }
        feedDroidTurn(process, delta: "about three metres")
        _ = await waitForSession { session.transcript.count == 2 && session.transcript[1].status == .completed }

        // The SAME file was rewritten with both turns.
        XCTAssertEqual(session.archiveURL, firstURL, "turn 2 spawned a second archive file")
        XCTAssertEqual(session.transcript[0].archiveURL, firstURL)
        XCTAssertEqual(session.transcript[1].archiveURL, firstURL)
        let body = (try? String(contentsOf: firstURL!, encoding: .utf8)) ?? ""
        XCTAssertTrue(body.contains("## Turn 1"))
        XCTAssertTrue(body.contains("what is a pelican?"))
        XCTAssertTrue(body.contains("a big bird"))
        XCTAssertTrue(body.contains("## Turn 2"))
        XCTAssertTrue(body.contains("about three metres"))
    }

    func testDroidSessionTitleReachesHeaderAndArchiveName() async {
        let launcher = MockLauncher()
        let session = makeSession(launcher: launcher)
        session.isExpanded = true
        session.prompt = "help"
        session.submit()

        _ = await waitFor { launcher.count >= 1 }
        let process = launcher.processes[0]
        feedDroidInit(process)
        _ = await waitForWritten(process, contains: "add_user_message")

        // Droid names the session mid-turn; the raw notification must reach
        // the session even while a turn is live.
        process.feedStdout(#"{"jsonrpc":"2.0","method":"droid.session_notification","params":{"notification":{"type":"session_title_updated","title":"Fix the login bug!"}}}"#)
        _ = await waitForSession { session.sessionTitle == "Fix the login bug!" }
        XCTAssertEqual(session.sessionTitle, "Fix the login bug!")

        feedDroidTurn(process, delta: "ok")
        _ = await waitForSession { session.transcript.first?.status == .completed }
        _ = await waitForSession { session.archiveURL != nil }

        // The archive filename derives from the title.
        let name = session.archiveURL?.lastPathComponent ?? ""
        XCTAssertTrue(name.hasPrefix("droid-Fix-the-login-bug"), "unexpected archive name: \(name)")
        let body = (try? String(contentsOf: session.archiveURL!, encoding: .utf8)) ?? ""
        XCTAssertTrue(body.contains("- Title: Fix the login bug!"))
    }

    func testPiSessionNamedFromFirstQuestion() async {
        let launcher = MockLauncher()
        let session = makeSession(launcher: launcher, engine: .pi)
        session.isExpanded = true
        session.prompt = "explain the visitor pattern please"
        session.submit()

        _ = await waitFor { launcher.count >= 1 }
        let process = launcher.processes[0]
        _ = await waitForWritten(process, contains: #""type":"prompt""#)
        feedPiTurn(process, delta: "sure")
        _ = await waitForSession { session.transcript.first?.status == .completed }

        // Pi doesn't push titles; AskDroid derives one from the first
        // question and pushes it via set_session_name.
        XCTAssertEqual(session.sessionTitle, "explain the visitor pattern please")
        let sawName = await waitForWritten(process, contains: #""type":"set_session_name""#)
        XCTAssertTrue(sawName, "set_session_name never sent")
        XCTAssertTrue(process.written.joined().contains(#""name":"explain the visitor pattern please""#))
    }
}

final class SettingsStoreTests: XCTestCase {
    /// Ephemeral suite so `swift test` never reads or writes the app's real
    /// UserDefaults.
    private func freshSuite() -> UserDefaults {
        let name = "AskDroidTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    func testDefaultEngineIsPi() {
        XCTAssertEqual(AppSettings.default.engine, .pi)
    }

    func testSettingsStoreRoundTrip() {
        let suite = freshSuite()
        var settings = AppSettings.default
        settings.engine = .droid
        settings.droidPath = "/custom/droid"
        settings.piPath = "/custom/pi"
        settings.reasoning = .xhigh
        SettingsStore.save(settings, to: suite)

        let loaded = SettingsStore.load(from: suite)
        XCTAssertEqual(loaded.engine, .droid)
        XCTAssertEqual(loaded.droidPath, "/custom/droid")
        XCTAssertEqual(loaded.piPath, "/custom/pi")
        XCTAssertEqual(loaded.reasoning, .xhigh)
    }

    func testLoadWithoutSavedEngineUsesDefault() {
        let suite = freshSuite()
        let loaded = SettingsStore.load(from: suite)
        XCTAssertEqual(loaded.engine, .pi)
    }

    func testReasoningSupersetMapping() {
        XCTAssertEqual(ReasoningSetting.off.piProtocolValue, "off")
        XCTAssertNil(ReasoningSetting.off.droidProtocolValue)

        XCTAssertEqual(ReasoningSetting.minimal.piProtocolValue, "minimal")
        XCTAssertNil(ReasoningSetting.minimal.droidProtocolValue)

        XCTAssertEqual(ReasoningSetting.low.piProtocolValue, "low")
        XCTAssertEqual(ReasoningSetting.low.droidProtocolValue, "low")

        XCTAssertEqual(ReasoningSetting.medium.piProtocolValue, "medium")
        XCTAssertEqual(ReasoningSetting.medium.droidProtocolValue, "medium")

        XCTAssertEqual(ReasoningSetting.high.piProtocolValue, "high")
        XCTAssertEqual(ReasoningSetting.high.droidProtocolValue, "high")

        XCTAssertEqual(ReasoningSetting.xhigh.piProtocolValue, "xhigh")
        XCTAssertNil(ReasoningSetting.xhigh.droidProtocolValue)

        XCTAssertEqual(ReasoningSetting.max.piProtocolValue, "max")
        XCTAssertNil(ReasoningSetting.max.droidProtocolValue)

        XCTAssertNil(ReasoningSetting.defaultLevel.piProtocolValue)
        XCTAssertNil(ReasoningSetting.defaultLevel.droidProtocolValue)
    }
}

final class PiEngineStateMachineTests: XCTestCase {
    private static func makeSettings() -> AppSettings {
        var s = AppSettings.default
        s.engine = .pi
        s.piPath = "/tmp/pi"
        return s
    }

    func testPromptParamsFormat() {
        let image = AttachedImage(
            id: UUID(),
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            mediaType: "image/png",
            filename: "paste.png"
        )
        let request = EngineRequest(
            prompt: "what is in this?",
            images: [image],
            settings: Self.makeSettings()
        )
        let params = PiEngine.promptParams(id: "7", from: request)
        XCTAssertEqual(params["id"] as? String, "7")
        XCTAssertEqual(params["type"] as? String, "prompt")
        XCTAssertEqual(params["message"] as? String, "what is in this?")
        let images = params["images"] as? [[String: Any]]
        XCTAssertEqual(images?.count, 1)
        XCTAssertEqual(images?.first?["type"] as? String, "image")
        XCTAssertEqual(images?.first?["mimeType"] as? String, "image/png")
        XCTAssertNotNil(images?.first?["data"] as? String)
    }

    func testPiHappyPathStreamingAndSettled() async {
        let launcher = MockLauncher()
        let engine = PiEngine(launcher: launcher, fileExists: { _ in true })
        let box = EventBox()
        let answers = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var settings = Self.makeSettings()
        settings.answersDirectory = answers.path

        let driver = Task.detached {
            await waitForProcesses(launcher, count: 1)
            let process = launcher.processes[0]
            process.feedStdout(#"{"id":"1","type":"response","command":"prompt","success":true}"#)
            process.feedStdout(#"{"type":"agent_start"}"#)
            process.feedStdout(#"{"type":"message_start","message":{"role":"assistant","model":"claude-3-5-sonnet-20241022","provider":"anthropic"}}"#)
            try? await Task.sleep(for: .milliseconds(50))
            process.feedStdout(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Hello "}}"#)
            process.feedStdout(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"from Pi!"}}"#)
            process.feedStdout(#"{"type":"message_update","usage":{"input":12,"output":8}}"#)
            process.feedStdout(#"{"type":"agent_settled"}"#)
            process.closeStdout()
            process.closeStderr()
            process.setExit(0)
        }

        await runEngine(engine, request: EngineRequest(prompt: "hi", images: [], settings: settings), box: box)
        await driver.value

        let textDeltas = box.snapshot().compactMap { event -> String? in
            if case .textDelta(_, let text) = event { return text }
            return nil
        }
        XCTAssertEqual(textDeltas.joined(), "Hello from Pi!")

        let result = box.snapshot().compactMap { event -> EngineResult? in
            if case .completed(_, let r) = event { return r }
            return nil
        }.last
        XCTAssertEqual(result?.text, "Hello from Pi!")
        XCTAssertEqual(result?.model, "claude-3-5-sonnet-20241022")
        XCTAssertEqual(result?.tokenUsage?.inputTokens, 12)
        XCTAssertEqual(result?.tokenUsage?.outputTokens, 8)
        // Archiving is conversation-level since plan 008 Phase 8.
        XCTAssertNil(result?.archiveURL)
        try? FileManager.default.removeItem(at: answers)
    }

    func testPiThinkingDeltasEmitted() async {
        let launcher = MockLauncher()
        let engine = PiEngine(launcher: launcher, fileExists: { _ in true })
        let box = EventBox()

        let driver = Task.detached {
            await waitForProcesses(launcher, count: 1)
            let process = launcher.processes[0]
            process.feedStdout(#"{"id":"1","type":"response","command":"prompt","success":true}"#)
            process.feedStdout(#"{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","delta":"thinking hard..."}}"#)
            process.feedStdout(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"answer"}}"#)
            process.feedStdout(#"{"type":"agent_settled"}"#)
            process.closeStdout()
            process.closeStderr()
            process.setExit(0)
        }

        await runEngine(engine, request: EngineRequest(prompt: "hi", images: [], settings: Self.makeSettings()), box: box)
        await driver.value

        let thinking = box.snapshot().compactMap { event -> String? in
            if case .thinking(_, let t) = event { return t }
            return nil
        }
        XCTAssertEqual(thinking.joined(), "thinking hard...")
    }

    func testPiToolExecutionActivity() async {
        let launcher = MockLauncher()
        let engine = PiEngine(launcher: launcher, fileExists: { _ in true })
        let box = EventBox()

        let driver = Task.detached {
            await waitForProcesses(launcher, count: 1)
            let process = launcher.processes[0]
            process.feedStdout(#"{"id":"1","type":"response","command":"prompt","success":true}"#)
            process.feedStdout(#"{"type":"tool_execution_start","toolName":"read","args":{"path":"foo.swift"}}"#)
            process.feedStdout(#"{"type":"tool_execution_end","toolName":"read","result":{},"isError":false}"#)
            process.feedStdout(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"done"}}"#)
            process.feedStdout(#"{"type":"agent_settled"}"#)
            process.closeStdout()
            process.closeStderr()
            process.setExit(0)
        }

        await runEngine(engine, request: EngineRequest(prompt: "hi", images: [], settings: Self.makeSettings()), box: box)
        await driver.value

        let activities = box.snapshot().compactMap { event -> String? in
            if case .activity(_, let a) = event { return a }
            return nil
        }
        XCTAssertTrue(activities.contains("Reading files…"))
    }

    func testPiPromptRejectedEmitsFailure() async {
        let launcher = MockLauncher()
        let engine = PiEngine(launcher: launcher, fileExists: { _ in true })
        let box = EventBox()

        let driver = Task.detached {
            await waitForProcesses(launcher, count: 1)
            let process = launcher.processes[0]
            process.feedStdout(#"{"id":"1","type":"response","command":"prompt","success":false,"error":"Invalid model name"}"#)
            process.closeStdout()
            process.closeStderr()
            process.setExit(1)
        }

        await runEngine(engine, request: EngineRequest(prompt: "hi", images: [], settings: Self.makeSettings()), box: box)
        await driver.value

        let failure = box.snapshot().compactMap { event -> String? in
            if case .failed(_, let m) = event { return m }
            return nil
        }.last
        XCTAssertEqual(failure, "Invalid model name")
    }

    func testPiExtensionErrorEmitsFailure() async {
        let launcher = MockLauncher()
        let engine = PiEngine(launcher: launcher, fileExists: { _ in true })
        let box = EventBox()

        let driver = Task.detached {
            await waitForProcesses(launcher, count: 1)
            let process = launcher.processes[0]
            process.feedStdout(#"{"id":"1","type":"response","command":"prompt","success":true}"#)
            process.feedStdout(#"{"type":"extension_error","error":"Hook error in session"}"#)
            process.closeStdout()
            process.closeStderr()
            process.setExit(1)
        }

        await runEngine(engine, request: EngineRequest(prompt: "hi", images: [], settings: Self.makeSettings()), box: box)
        await driver.value

        let failure = box.snapshot().compactMap { event -> String? in
            if case .failed(_, let m) = event { return m }
            return nil
        }.last
        XCTAssertEqual(failure, "Hook error in session")
    }

    func testPiAutoRetryEndFailureEmitsError() async {
        let launcher = MockLauncher()
        let engine = PiEngine(launcher: launcher, fileExists: { _ in true })
        let box = EventBox()

        let driver = Task.detached {
            await waitForProcesses(launcher, count: 1)
            let process = launcher.processes[0]
            process.feedStdout(#"{"id":"1","type":"response","command":"prompt","success":true}"#)
            process.feedStdout(#"{"type":"auto_retry_start","attempt":1,"maxAttempts":3,"errorMessage":"503 overloaded"}"#)
            process.feedStdout(#"{"type":"auto_retry_end","success":false,"finalError":"503 overloaded"}"#)
            process.feedStdout(#"{"type":"agent_settled"}"#)
            process.closeStdout()
            process.closeStderr()
            process.setExit(1)
        }

        await runEngine(engine, request: EngineRequest(prompt: "hi", images: [], settings: Self.makeSettings()), box: box)
        await driver.value

        let failure = box.snapshot().compactMap { event -> String? in
            if case .failed(_, let m) = event { return m }
            return nil
        }.last
        XCTAssertEqual(failure, "503 overloaded")
    }

    func testPiCancelMidRunSendsAbort() async {
        let launcher = MockLauncher()
        let engine = PiEngine(launcher: launcher, fileExists: { _ in true })
        let box = EventBox()
        let runID = UUID()

        let driver = Task.detached {
            await waitForProcesses(launcher, count: 1)
            await engine.cancel(runID: runID)
        }

        await runEngine(
            engine,
            request: EngineRequest(prompt: "hi", images: [], settings: Self.makeSettings()),
            runID: runID,
            box: box
        )
        await driver.value

        XCTAssertEqual(launcher.processes.count, 1)
        XCTAssertTrue(launcher.processes[0].terminated)
        let written = launcher.processes[0].written.joined()
        XCTAssertTrue(written.contains(#""type":"abort"#))
        let failure = box.snapshot().compactMap { event -> String? in
            if case .failed(_, let m) = event { return m }
            return nil
        }.last
        XCTAssertEqual(failure, EngineError.cancelled.localizedDescription)
    }

    func testPiAuthErrorOnStderr() async {
        let launcher = MockLauncher()
        let engine = PiEngine(launcher: launcher, fileExists: { _ in true })
        let box = EventBox()

        let driver = Task.detached {
            await waitForProcesses(launcher, count: 1)
            let process = launcher.processes[0]
            process.feedStderr("503: auth_unavailable: no auth available")
            process.closeStdout()
            process.closeStderr()
            process.setExit(1)
        }

        await runEngine(engine, request: EngineRequest(prompt: "hi", images: [], settings: Self.makeSettings()), box: box)
        await driver.value

        let failure = box.snapshot().compactMap { event -> String? in
            if case .failed(_, let m) = event { return m }
            return nil
        }.last
        XCTAssertEqual(failure, EngineError.notAuthenticated(Engine.pi).localizedDescription)
    }

    // MARK: Multi-turn on one process

    private static func makeMultiTurnSettings() -> AppSettings {
        var settings = AppSettings.default
        settings.engine = .pi
        settings.piPath = "/tmp/pi"
        settings.answersDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        return settings
    }

    private func feedTurn(
        _ process: MockProcess,
        deltas: [String],
        statsResponse: String? = nil
    ) {
        process.feedStdout(#"{"id":"1","type":"response","command":"prompt","success":true}"#)
        for delta in deltas {
            process.feedStdout(
                #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"\#(delta)"}}"#
            )
        }
        process.feedStdout(#"{"type":"agent_settled"}"#)
        if let statsResponse {
            process.feedStdout(statsResponse)
        }
    }

    func testPiServesTwoTurnsOnOneProcess() async throws {
        let launcher = MockLauncher()
        let engine = PiEngine(launcher: launcher, fileExists: { _ in true })
        let box = EventBox()
        let settings = Self.makeMultiTurnSettings()

        let handle = try await startSession(engine, settings: settings, box: box)
        let process = launcher.processes[0]

        let turn1 = UUID()
        let send1 = Task.detached {
            await engine.send(EngineRequest(prompt: "one", images: [], settings: settings), turnID: turn1, to: handle)
        }
        await waitForWritten(process, contains: #""type":"prompt""#)
        feedTurn(process, deltas: ["Hello ", "from Pi!"], statsResponse:
            #"{"type":"response","command":"get_session_stats","success":true,"data":{"contextUsage":{"tokens":60000,"contextWindow":200000,"percent":30}}}"#)
        await send1.value

        // Turn 2 rides the same process.
        let turn2 = UUID()
        let send2 = Task.detached {
            await engine.send(EngineRequest(prompt: "two", images: [], settings: settings), turnID: turn2, to: handle)
        }
        let sawSecondPrompt = await waitFor { writtenCount(process, containing: #""type":"prompt""#) >= 2 }
        XCTAssertTrue(sawSecondPrompt, "second turn never sent a prompt")
        // Null contextUsage fields right after compaction must not emit.
        feedTurn(process, deltas: ["World"], statsResponse:
            #"{"type":"response","command":"get_session_stats","success":true,"data":{"contextUsage":{"tokens":null,"contextWindow":200000,"percent":null}}}"#)
        await send2.value

        XCTAssertEqual(launcher.count, 1, "a second CLI process was launched")
        XCTAssertFalse(process.terminated, "process was killed between turns")

        let completions = box.snapshot().compactMap { event -> (UUID, String)? in
            if case .completed(let id, let result) = event { return (id, result.text) }
            return nil
        }
        XCTAssertEqual(completions.map(\.1), ["Hello from Pi!", "World"])
        XCTAssertEqual(completions.map(\.0), [turn1, turn2])

        let stats = box.snapshot().compactMap { event -> (Int, Int)? in
            if case .contextStats(let used, let limit) = event { return (used, limit) }
            return nil
        }
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats.first?.0, 60000)
        XCTAssertEqual(stats.first?.1, 200000)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: settings.answersDirectory))
        await engine.close(handle)
    }

    func testPiAbortKeepsProcessAlive() async throws {
        let launcher = MockLauncher()
        let engine = PiEngine(launcher: launcher, fileExists: { _ in true })
        let box = EventBox()
        let settings = Self.makeMultiTurnSettings()

        let handle = try await startSession(engine, settings: settings, box: box)
        let process = launcher.processes[0]

        let turn1 = UUID()
        let send1 = Task.detached {
            await engine.send(EngineRequest(prompt: "one", images: [], settings: settings), turnID: turn1, to: handle)
        }
        await waitForWritten(process, contains: #""type":"prompt""#)

        await engine.interrupt(handle)

        // Abort is protocol bytes, not a kill.
        XCTAssertTrue(process.written.joined().contains(#""type":"abort""#))
        XCTAssertFalse(process.terminated, "interrupt terminated the process")
        await send1.value

        let interruptions = box.snapshot().compactMap { event -> UUID? in
            if case .interrupted(let id) = event { return id }
            return nil
        }
        XCTAssertEqual(interruptions, [turn1])
        XCTAssertEqual(launcher.count, 1)
        await engine.close(handle)
    }

    /// Wire steering (plan 008 Phase 7): a queued prompt must carry
    /// streamingBehavior "steer", and Pi's queue_update must surface as
    /// .queueChanged.
    func testPiSteerWritesStreamingBehaviorAndSurfacesQueueUpdate() async throws {
        let launcher = MockLauncher()
        let engine = PiEngine(launcher: launcher, fileExists: { _ in true })
        let box = EventBox()
        let settings = Self.makeMultiTurnSettings()

        let handle = try await startSession(engine, settings: settings, box: box)
        let process = launcher.processes[0]

        let turn1 = UUID()
        let send1 = Task.detached {
            await engine.send(EngineRequest(prompt: "one", images: [], settings: settings), turnID: turn1, to: handle)
        }
        await waitForWritten(process, contains: #""type":"prompt""#)
        process.feedStdout(#"{"id":"1","type":"response","command":"prompt","success":true}"#)

        // Steer while turn 1 streams.
        try await engine.queue(EngineRequest(prompt: "look at the logs", images: [], settings: settings), to: handle)
        let sawSteer = await waitForWritten(process, contains: #""streamingBehavior":"steer""#)
        XCTAssertTrue(sawSteer, "queued prompt missing streamingBehavior")

        process.feedStdout(#"{"id":"2","type":"response","command":"prompt","success":true}"#)
        process.feedStdout(#"{"type":"queue_update","steering":["look at the logs"],"followUp":["then summarize"]}"#)
        let sawQueueUpdate = await waitFor {
            box.snapshot().contains { event in
                if case .queueChanged = event { return true }
                return false
            }
        }
        XCTAssertTrue(sawQueueUpdate, "queue_update never surfaced as .queueChanged")
        let queues = box.snapshot().compactMap { event -> [String]? in
            if case .queueChanged(let messages) = event { return messages }
            return nil
        }
        XCTAssertEqual(queues.last, ["look at the logs", "then summarize"])

        // A rejected steer must not tear down the running turn.
        try await engine.queue(EngineRequest(prompt: "second steer", images: [], settings: settings), to: handle)
        _ = await waitForWritten(process, contains: "second steer")
        process.feedStdout(#"{"id":"3","type":"response","command":"prompt","success":false,"error":"nope"}"#)
        try? await Task.sleep(for: .milliseconds(150))
        process.feedStdout(#"{"type":"agent_settled"}"#)
        await send1.value

        XCTAssertFalse(process.terminated, "a rejected steer killed the session")
        let failures = box.snapshot().compactMap { event -> String? in
            if case .failed(_, let message) = event { return message }
            return nil
        }
        XCTAssertTrue(failures.isEmpty, "steer rejection surfaced as a turn failure: \(failures)")
        await engine.close(handle)
    }

    /// The contextUsage flip the operator saw (922k → 262k mid-conversation)
    /// is Pi switching its reported window (it mirrors the active model, per
    /// rpc.md). Our contract: parse exactly `data.contextUsage`'s
    /// tokens/contextWindow, omit on nulls/absence, and replace each new
    /// reading wholesale — never merge one turn's tokens with another
    /// turn's window.
    func testPiContextStatsParsesDocumentedShapeAndReplacesWholesale() async throws {
        let launcher = MockLauncher()
        let engine = PiEngine(launcher: launcher, fileExists: { _ in true })
        let box = EventBox()
        let settings = Self.makeMultiTurnSettings()

        let handle = try await startSession(engine, settings: settings, box: box)
        let process = launcher.processes[0]

        let turn1 = UUID()
        let send1 = Task.detached {
            await engine.send(EngineRequest(prompt: "one", images: [], settings: settings), turnID: turn1, to: handle)
        }
        await waitForWritten(process, contains: #""type":"prompt""#)

        // Documented shape.
        process.feedStdout(
            #"{"type":"response","command":"get_session_stats","success":true,"data":{"contextUsage":{"tokens":11400,"contextWindow":922000,"percent":1}}}"#
        )
        var sawStats = await waitFor {
            box.snapshot().contains { if case .contextStats = $0 { return true }; return false }
        }
        XCTAssertTrue(sawStats)
        // A different window mid-session replaces the pair wholesale.
        process.feedStdout(
            #"{"type":"response","command":"get_session_stats","success":true,"data":{"contextUsage":{"tokens":11400,"contextWindow":262144,"percent":4}}}"#
        )
        sawStats = await waitFor {
            box.snapshot().compactMap { event -> Bool in
                if case .contextStats(let used, let limit) = event { return used == 11_400 && limit == 262_144 }
                return false
            }.contains(true)
        }
        XCTAssertTrue(sawStats, "new window never landed")

        let stats = box.snapshot().compactMap { event -> String? in
            if case .contextStats(let used, let limit) = event { return "\(used)/\(limit)" }
            return nil
        }
        XCTAssertEqual(stats, ["11400/922000", "11400/262144"], "pairs must be atomic, never field-merged")

        // Null fields right after compaction emit nothing…
        let beforeNulls = stats.count
        process.feedStdout(
            #"{"type":"response","command":"get_session_stats","success":true,"data":{"contextUsage":{"tokens":null,"contextWindow":262144,"percent":null}}}"#
        )
        // …and a response without contextUsage emits nothing either.
        process.feedStdout(
            #"{"type":"response","command":"get_session_stats","success":true,"data":{"sessionId":"x"}}"#
        )
        try? await Task.sleep(for: .milliseconds(150))
        let afterGaps = box.snapshot().compactMap { event -> String? in
            if case .contextStats(let used, let limit) = event { return "\(used)/\(limit)" }
            return nil
        }
        XCTAssertEqual(afterGaps.count, beforeNulls, "null or absent contextUsage must not emit")

        process.feedStdout(#"{"type":"agent_settled"}"#)
        await send1.value
        await engine.close(handle)
    }

    func testPiNewSessionClearsContextWithoutRelaunch() async throws {
        let launcher = MockLauncher()
        let engine = PiEngine(launcher: launcher, fileExists: { _ in true })
        let box = EventBox()
        let settings = Self.makeMultiTurnSettings()

        let handle = try await startSession(engine, settings: settings, box: box)
        let process = launcher.processes[0]

        let turn1 = UUID()
        let send1 = Task.detached {
            await engine.send(EngineRequest(prompt: "one", images: [], settings: settings), turnID: turn1, to: handle)
        }
        await waitForWritten(process, contains: #""type":"prompt""#)
        feedTurn(process, deltas: ["First"])
        await send1.value

        // Reset clears context in-process: new_session bytes, no relaunch.
        await engine.reset(handle)
        XCTAssertTrue(process.written.joined().contains(#""type":"new_session""#))
        XCTAssertEqual(launcher.count, 1, "reset relaunched the CLI")
        XCTAssertFalse(process.terminated, "reset killed the process")

        // The session is still usable after the reset.
        let turn2 = UUID()
        let send2 = Task.detached {
            await engine.send(EngineRequest(prompt: "two", images: [], settings: settings), turnID: turn2, to: handle)
        }
        _ = await waitFor { writtenCount(process, containing: #""type":"prompt""#) >= 2 }
        feedTurn(process, deltas: ["Second"])
        await send2.value

        let completions = box.snapshot().compactMap { event -> String? in
            if case .completed(_, let result) = event { return result.text }
            return nil
        }
        XCTAssertEqual(completions, ["First", "Second"])
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: settings.answersDirectory))
        await engine.close(handle)
    }
}

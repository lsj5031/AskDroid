import Foundation

/// A backend that can answer a one-shot question by driving a CLI process.
protocol EngineClient: AnyObject, Sendable {
    func run(
        _ request: EngineRequest,
        runID: UUID,
        onEvent: @escaping @Sendable (EngineEvent) -> Void
    ) async

    func cancel(runID: UUID) async
}

enum Engine: String, CaseIterable, Identifiable, Sendable {
    case pi = "pi"
    case droid = "droid"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pi: "Pi"
        case .droid: "Droid"
        }
    }

    var binaryName: String {
        switch self {
        case .pi: "pi"
        case .droid: "droid"
        }
    }
}

enum EngineError: LocalizedError, Equatable {
    case binaryNotFound(Engine)
    case notAuthenticated(Engine)
    case protocolFailure(String)
    case cancelled
    case failed(String)

    // Backwards-compatibility helpers for legacy call sites
    static var binaryNotFound: EngineError { .binaryNotFound(.droid) }
    static var notAuthenticated: EngineError { .notAuthenticated(.droid) }

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let engine):
            "\(engine.title) was not found. Install the CLI or set its path in Settings."
        case .notAuthenticated(let engine):
            "\(engine.title) is not authenticated. Run `\(engine.binaryName)` in Terminal and sign in."
        case .protocolFailure(let message):
            message
        case .cancelled:
            "Cancelled."
        case .failed(let message):
            message
        }
    }
}

struct EngineRequest: Sendable {
    var prompt: String
    var images: [AttachedImage]
    var settings: AppSettings
}

struct EngineResult: Sendable {
    var text: String
    var model: String?
    var duration: TimeInterval
    var tokenUsage: TokenUsage?
    var archiveURL: URL?
    var archiveError: String?
}

enum EngineEvent: Sendable {
    case started(UUID)
    case activity(UUID, String)
    case thinking(UUID, String)
    case textDelta(UUID, String)
    case log(UUID, String)
    case completed(UUID, EngineResult)
    case failed(UUID, String)
}

// Legacy typealiases for backwards compatibility
typealias DroidRunRequest = EngineRequest
typealias DroidRunResult = EngineResult
typealias DroidRunEvent = EngineEvent
typealias DroidEngineError = EngineError
typealias DroidProcessIO = ProcessIO
typealias DroidProcessLaunching = ProcessLaunching

protocol ProcessLaunching: Sendable {
    func launch(
        executable: String,
        arguments: [String],
        environment: [String: String],
        cwd: String
    ) throws -> any ProcessIO
}

protocol ProcessIO: AnyObject, Sendable {
    var standardOutput: FileHandle { get }
    var standardError: FileHandle { get }
    func write(_ line: String) throws
    func terminate()
    func waitUntilExit() -> Int32
}

final class FoundationProcess: ProcessIO, @unchecked Sendable {
    let process: Process
    let stdin: FileHandle
    let standardOutput: FileHandle
    let standardError: FileHandle

    init(process: Process, stdin: FileHandle, stdout: FileHandle, stderr: FileHandle) {
        self.process = process
        self.stdin = stdin
        self.standardOutput = stdout
        self.standardError = stderr
    }

    func write(_ line: String) throws {
        var payload = line
        if !payload.hasSuffix("\n") {
            payload.append("\n")
        }
        guard let data = payload.data(using: .utf8) else { return }
        try stdin.write(contentsOf: data)
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
        try? stdin.close()
    }

    func waitUntilExit() -> Int32 {
        process.waitUntilExit()
        return process.terminationStatus
    }
}

struct FoundationProcessLauncher: ProcessLaunching {
    func launch(
        executable: String,
        arguments: [String],
        environment: [String: String],
        cwd: String
    ) throws -> any ProcessIO {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        return FoundationProcess(
            process: process,
            stdin: stdin.fileHandleForWriting,
            stdout: stdout.fileHandleForReading,
            stderr: stderr.fileHandleForReading
        )
    }
}

/// Per-run state shared by both backends.
actor RunSession {
    let request: EngineRequest
    private(set) var startedAt: Date
    private(set) var model: String?
    private(set) var answer = ""
    private(set) var tokenUsage: TokenUsage?
    private(set) var lastError: String?
    private(set) var finished = false
    private(set) var didInitialize = false
    private(set) var didSendPrompt = false
    private(set) var didAccept = false
    private(set) var hasStreamedText = false

    var isFinished: Bool { finished }

    init(request: EngineRequest, startedAt: Date, model: String?) {
        self.request = request
        self.startedAt = startedAt
        self.model = model
    }

    func setModel(_ model: String) {
        self.model = model
    }

    func append(_ text: String) {
        hasStreamedText = true
        answer.append(text)
    }

    func setUsage(_ usage: TokenUsage) {
        self.tokenUsage = usage
    }

    func markInitialized() {
        didInitialize = true
    }

    func markPromptSent() {
        didSendPrompt = true
    }

    func markAccepted() {
        didAccept = true
    }

    func mark(error: String) {
        // First error wins: every mark() is followed by terminate(), so a later
        // mark (e.g. from a timeout racing process teardown) would only mask the
        // real cause.
        if lastError == nil { lastError = error }
    }

    func complete(durationMs: Double? = nil, tokenUsage: TokenUsage? = nil) {
        self.tokenUsage = tokenUsage ?? self.tokenUsage
        if let durationMs {
            startedAt = Date().addingTimeInterval(-(durationMs / 1000))
        }
        finished = true
    }

    func snapshot() -> (
        request: EngineRequest,
        startedAt: Date,
        model: String?,
        answer: String,
        tokenUsage: TokenUsage?
    ) {
        (request, startedAt, model, answer, tokenUsage)
    }
}

enum EngineSupport {
    /// Shared terminal flow: archive the answer (tagged with the engine) and
    /// emit `.completed`.
    static func emitCompletion(
        session: RunSession,
        runID: UUID,
        engine: Engine,
        onEvent: @Sendable (EngineEvent) -> Void
    ) async {
        let snapshot = await session.snapshot()
        let duration = Date().timeIntervalSince(snapshot.startedAt)
        if snapshot.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onEvent(.log(runID, "\(engine.title) ended the run with no text answer."))
        }
        var archiveURL: URL?
        var archiveError: String?
        if !snapshot.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                let archived = try AnswerArchive.write(
                    directory: URL(fileURLWithPath: snapshot.request.settings.resolvedAnswersDirectory, isDirectory: true),
                    question: snapshot.request.prompt,
                    answer: snapshot.answer,
                    model: snapshot.model,
                    duration: duration,
                    engine: engine.rawValue,
                    images: snapshot.request.images
                )
                archiveURL = archived.markdownURL
                onEvent(.log(runID, "Saved \(archived.markdownURL.lastPathComponent)"))
            } catch {
                archiveError = "Could not save the answer file: \(error.localizedDescription)"
                onEvent(.log(runID, archiveError ?? "Could not save the answer file."))
            }
        }
        onEvent(.completed(runID, EngineResult(
            text: snapshot.answer,
            model: snapshot.model,
            duration: duration,
            tokenUsage: snapshot.tokenUsage,
            archiveURL: archiveURL,
            archiveError: archiveError
        )))
    }

    /// Shared activity label mapping across engines
    static func activityLabel(for toolName: String) -> String {
        switch toolName.lowercased() {
        case "read", "readfile", "read_file":
            "Reading files…"
        case "grep", "rg", "search", "search_files", "find":
            "Searching…"
        case "glob", "ls", "list", "list_files":
            "Listing files…"
        case "execute", "execute-cli", "bash", "shell":
            "Running a command…"
        case "applypatch", "apply_patch", "edit", "write":
            "Editing…"
        case "web_search":
            "Searching the web…"
        default:
            toolName.isEmpty ? "Working…" : "Using \(toolName)…"
        }
    }

    /// PATH augmentation so CLIs installed outside the GUI session's PATH are found.
    static func augmentedEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> [String: String] {
        var environment = base
        let extras = [
            "\(home)/.local/bin",
            "\(home)/.local/share/mise/shims",
            "\(home)/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        let current = environment["PATH"] ?? ""
        environment["PATH"] = (extras + [current]).joined(separator: ":")
        return environment
    }
}

enum EngineProcessRunner {
    struct Configuration: Sendable {
        let engine: Engine
        let request: EngineRequest
        let runID: UUID
        let initialActivity: String
        let sendInitialMessage: @Sendable (any ProcessIO, RunSession) async throws -> Void
        let acceptTimeoutSeconds: Int
        let acceptTimeoutMessage: String
        let turnTimeoutSeconds: Int
        let turnTimeoutMessage: String
        let isInitialAccepted: @Sendable (RunSession) async -> Bool
        let isAuthError: @Sendable (String) -> Bool
        let handleLine: @Sendable (String, any ProcessIO, RunSession) async -> Void

        init(
            engine: Engine,
            request: EngineRequest,
            runID: UUID,
            initialActivity: String,
            sendInitialMessage: @escaping @Sendable (any ProcessIO, RunSession) async throws -> Void,
            acceptTimeoutSeconds: Int = 25,
            acceptTimeoutMessage: String,
            turnTimeoutSeconds: Int = 600,
            turnTimeoutMessage: String,
            isInitialAccepted: @escaping @Sendable (RunSession) async -> Bool,
            isAuthError: @escaping @Sendable (String) -> Bool,
            handleLine: @escaping @Sendable (String, any ProcessIO, RunSession) async -> Void
        ) {
            self.engine = engine
            self.request = request
            self.runID = runID
            self.initialActivity = initialActivity
            self.sendInitialMessage = sendInitialMessage
            self.acceptTimeoutSeconds = acceptTimeoutSeconds
            self.acceptTimeoutMessage = acceptTimeoutMessage
            self.turnTimeoutSeconds = turnTimeoutSeconds
            self.turnTimeoutMessage = turnTimeoutMessage
            self.isInitialAccepted = isInitialAccepted
            self.isAuthError = isAuthError
            self.handleLine = handleLine
        }
    }

    static func run(
        process: any ProcessIO,
        config: Configuration,
        onEvent: @escaping @Sendable (EngineEvent) -> Void
    ) async {
        let startedAt = Date()
        let runID = config.runID
        let engine = config.engine
        let request = config.request

        onEvent(.activity(runID, config.initialActivity))
        onEvent(.log(runID, "cwd \(request.settings.resolvedWorkingDirectory)"))

        let session = RunSession(
            request: request,
            startedAt: startedAt,
            model: request.settings.modelOverride.trimmedOrNil
        )

        do {
            try await config.sendInitialMessage(process, session)
        } catch {
            await session.mark(error: error.localizedDescription)
            process.terminate()
        }

        let acceptTimeout = Task {
            try? await Task.sleep(for: .seconds(config.acceptTimeoutSeconds))
            guard !Task.isCancelled else { return }
            if await !config.isInitialAccepted(session), await !session.isFinished {
                await session.mark(error: config.acceptTimeoutMessage)
                process.terminate()
            }
        }

        let turnTimeout = Task {
            try? await Task.sleep(for: .seconds(config.turnTimeoutSeconds))
            guard !Task.isCancelled else { return }
            if await !session.isFinished {
                await session.mark(error: config.turnTimeoutMessage)
                process.terminate()
            }
        }

        let stdoutTask = Task.detached {
            let reader = LineReader()
            while true {
                let data = process.standardOutput.availableData
                if data.isEmpty { break }
                for line in reader.push(data) {
                    await config.handleLine(line, process, session)
                    if await session.isFinished { return }
                }
            }
        }

        let stderrTask = Task.detached {
            let reader = LineReader()
            while true {
                let data = process.standardError.availableData
                if data.isEmpty { break }
                for line in reader.push(data) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    onEvent(.log(runID, trimmed))
                    if config.isAuthError(trimmed) {
                        await session.mark(error: EngineError.notAuthenticated(engine).localizedDescription)
                        process.terminate()
                    }
                }
            }
        }

        let status = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: process.waitUntilExit())
            }
        }
        acceptTimeout.cancel()
        turnTimeout.cancel()
        _ = await stdoutTask.result
        _ = await stderrTask.result

        if await session.isFinished { return }

        if let lastError = await session.lastError {
            onEvent(.failed(runID, lastError))
            return
        }
        if Task.isCancelled || status == SIGTERM || status == SIGKILL {
            onEvent(.failed(runID, EngineError.cancelled.localizedDescription))
            return
        }
        if status != 0 {
            onEvent(.failed(runID, "\(engine.title) exited with status \(status)."))
            return
        }
        await EngineSupport.emitCompletion(session: session, runID: runID, engine: engine, onEvent: onEvent)
    }
}

final class LineReader: @unchecked Sendable {
    private var buffer = Data()

    func push(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let range = buffer.range(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)
            if let line = String(data: lineData, encoding: .utf8) {
                let cleaned = line.hasSuffix("\r") ? String(line.dropLast()) : line
                if !cleaned.isEmpty {
                    lines.append(cleaned)
                }
            }
        }
        return lines
    }
}

extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

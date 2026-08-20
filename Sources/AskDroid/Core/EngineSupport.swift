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
    var readersAreClosed: Bool { get }
    func write(_ line: String) throws
    func terminate()
    func waitUntilExit() -> Int32

    /// Forces EOF on our side once the process is known dead (fold-in of plan
    /// 002): a surviving grandchild holding the pipe's write end would
    /// otherwise block the stdout/stderr readers forever.
    func closeReaders()
}

final class FoundationProcess: ProcessIO, @unchecked Sendable {
    let process: Process
    let stdin: FileHandle
    let standardOutput: FileHandle
    let standardError: FileHandle
    private let stateLock = NSLock()
    private var readersClosed = false

    init(process: Process, stdin: FileHandle, stdout: FileHandle, stderr: FileHandle) {
        self.process = process
        self.stdin = stdin
        self.standardOutput = stdout
        self.standardError = stderr
    }

    var readersAreClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return readersClosed
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

    func closeReaders() {
        // Deliberately does NOT close the stdout/stderr read handles: a
        // reader parked in availableData() would raise on a closed descriptor,
        // and close(2) does not wake a blocked read on Darwin anyway. The
        // kernel delivers real EOF once the process's own write ends die with
        // it; this call closes our stdin half and records that teardown ran.
        // (Full force-EOF semantics remain plan 002's scope.)
        stateLock.lock()
        readersClosed = true
        stateLock.unlock()
        try? stdin.close()
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

/// How a turn reached its terminal state. A turn ending is not a session
/// ending: every outcome leaves the CLI process alive unless a caller
/// explicitly closes it.
enum TurnOutcome: Equatable, Sendable {
    case completed
    case failed
    case interrupted
}

/// Signals that a turn reached a terminal state. The runner supplies the
/// implementation; engines call it from their line handler.
typealias TurnEnder = @Sendable (TurnState, TurnOutcome) async -> Void

/// Lives as long as the CLI process. Session-scoped identity and negotiation
/// state; nothing here describes a single turn.
actor EngineSession {
    let engine: Engine
    let settings: AppSettings
    private(set) var sessionID: String?
    private(set) var model: String?
    private(set) var didInitialize = false
    private(set) var didAccept = false
    private(set) var isClosed = false
    private(set) var nextRequestID = 1

    init(engine: Engine, settings: AppSettings) {
        self.engine = engine
        self.settings = settings
        // Seed with the operator override; the engine's reported model
        // replaces it once known.
        self.model = settings.modelOverride.trimmedOrNil
    }

    /// Monotonic JSON-RPC request id so responses correlate across turns.
    func claimRequestID() -> String {
        defer { nextRequestID += 1 }
        return String(nextRequestID)
    }

    func setSessionID(_ id: String) {
        sessionID = id
    }

    func setModel(_ model: String) {
        self.model = model
    }

    func markInitialized() {
        didInitialize = true
    }

    func markAccepted() {
        didAccept = true
    }

    func markClosed() {
        isClosed = true
    }
}

/// Lives for exactly one turn. Everything the HUD shows about a turn —
/// answer, usage, timing, diagnostics — is scoped here so one turn's state
/// can never bleed into the next.
actor TurnState {
    let turnID: UUID
    let request: EngineRequest
    private(set) var startedAt: Date
    private(set) var answer = ""
    private(set) var tokenUsage: TokenUsage?
    private(set) var lastError: String?
    private(set) var outcome: TurnOutcome?
    private(set) var log: [String] = []

    init(turnID: UUID, request: EngineRequest, startedAt: Date) {
        self.turnID = turnID
        self.request = request
        self.startedAt = startedAt
    }

    var isEnded: Bool { outcome != nil }

    func append(_ text: String) {
        answer.append(text)
    }

    func setUsage(_ usage: TokenUsage) {
        tokenUsage = usage
    }

    /// Rewinds the turn clock from an engine-reported duration (droid sends
    /// `durationMs` on completion).
    func applyDuration(durationMs: Double) {
        startedAt = Date().addingTimeInterval(-(durationMs / 1000))
    }

    func mark(error: String) {
        // First error wins: a later mark (e.g. from a timeout racing process
        // teardown) would only mask the real cause.
        if lastError == nil { lastError = error }
    }

    /// Ends the turn. The first outcome wins; later calls are no-ops so a
    /// timeout racing a protocol completion cannot flip the result.
    @discardableResult
    func end(_ result: TurnOutcome, tokenUsage usage: TokenUsage? = nil) -> Bool {
        if outcome != nil { return false }
        if let usage { tokenUsage = usage }
        outcome = result
        return true
    }

    func appendLog(_ line: String) {
        let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if log.last == cleaned { return }
        log.append(cleaned)
        if log.count > 40 {
            log.removeFirst(log.count - 40)
        }
    }

    func snapshot() -> (
        request: EngineRequest,
        startedAt: Date,
        answer: String,
        tokenUsage: TokenUsage?,
        lastError: String?,
        outcome: TurnOutcome?,
        log: [String]
    ) {
        (request, startedAt, answer, tokenUsage, lastError, outcome, log)
    }
}

enum EngineSupport {
    /// Shared terminal flow for a completed turn: archive the answer (tagged
    /// with the engine) and emit `.completed`. Called by the runner when a
    /// turn ends — never by the engines themselves.
    static func emitCompletion(
        session: EngineSession,
        turn: TurnState,
        turnID: UUID,
        engine: Engine,
        onEvent: @Sendable (EngineEvent) -> Void
    ) async {
        let snapshot = await turn.snapshot()
        let model = await session.model
        let duration = Date().timeIntervalSince(snapshot.startedAt)
        if snapshot.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onEvent(.log(turnID, "\(engine.title) ended the run with no text answer."))
        }
        var archiveURL: URL?
        var archiveError: String?
        if !snapshot.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                let archived = try AnswerArchive.write(
                    directory: URL(fileURLWithPath: snapshot.request.settings.resolvedAnswersDirectory, isDirectory: true),
                    question: snapshot.request.prompt,
                    answer: snapshot.answer,
                    model: model,
                    duration: duration,
                    engine: engine.rawValue,
                    images: snapshot.request.images
                )
                archiveURL = archived.markdownURL
                onEvent(.log(turnID, "Saved \(archived.markdownURL.lastPathComponent)"))
            } catch {
                archiveError = "Could not save the answer file: \(error.localizedDescription)"
                onEvent(.log(turnID, archiveError ?? "Could not save the answer file."))
            }
        }
        onEvent(.completed(turnID, EngineResult(
            text: snapshot.answer,
            model: model,
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
    typealias LineHandler = @Sendable (
        _ line: String,
        _ process: any ProcessIO,
        _ session: EngineSession,
        _ turn: TurnState,
        _ turnEnded: TurnEnder
    ) async -> Void

    struct Configuration: Sendable {
        let engine: Engine
        let initialActivity: String
        let sendInitialMessage: @Sendable (any ProcessIO, EngineSession) async throws -> Void
        // Session-scoped guard for initialization.
        let acceptTimeoutSeconds: Int
        let acceptTimeoutMessage: String
        let isInitialAccepted: @Sendable (EngineSession) async -> Bool
        // Per-turn timeout. Internal until a plan exposes these knobs
        // (absorbs plan 003).
        let turnTimeoutSeconds: Int
        let turnTimeoutMessage: String
        let isAuthError: @Sendable (String) -> Bool
        let handleLine: LineHandler
        /// Called by the engine's line handler when a turn reaches a terminal
        /// state. The runner finalizes the turn and returns to idle — the
        /// process keeps running.
        let onTurnEnd: TurnEnder
        /// Called once the process has exited and both readers have joined.
        let onProcessExit: @Sendable (_ status: Int32) async -> Void

        init(
            engine: Engine,
            initialActivity: String,
            sendInitialMessage: @escaping @Sendable (any ProcessIO, EngineSession) async throws -> Void,
            acceptTimeoutSeconds: Int = 25,
            acceptTimeoutMessage: String,
            turnTimeoutSeconds: Int = 600,
            turnTimeoutMessage: String,
            isInitialAccepted: @escaping @Sendable (EngineSession) async -> Bool,
            isAuthError: @escaping @Sendable (String) -> Bool,
            handleLine: @escaping LineHandler,
            onTurnEnd: @escaping TurnEnder,
            onProcessExit: @escaping @Sendable (_ status: Int32) async -> Void
        ) {
            self.engine = engine
            self.initialActivity = initialActivity
            self.sendInitialMessage = sendInitialMessage
            self.acceptTimeoutSeconds = acceptTimeoutSeconds
            self.acceptTimeoutMessage = acceptTimeoutMessage
            self.turnTimeoutSeconds = turnTimeoutSeconds
            self.turnTimeoutMessage = turnTimeoutMessage
            self.isInitialAccepted = isInitialAccepted
            self.isAuthError = isAuthError
            self.handleLine = handleLine
            self.onTurnEnd = onTurnEnd
            self.onProcessExit = onProcessExit
        }
    }

    /// Resumes the awaiting runner exactly once, when the first of
    /// {turn end, process exit} settles the current turn.
    private final class TurnSettler: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var settled = false

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if settled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        }

        func settle() {
            lock.lock()
            defer { lock.unlock() }
            guard !settled else { return }
            settled = true
            continuation?.resume()
            continuation = nil
        }
    }

    static func run(
        process: any ProcessIO,
        request: EngineRequest,
        turnID: UUID,
        config: Configuration,
        onEvent: @escaping @Sendable (EngineEvent) -> Void
    ) async {
        let session = EngineSession(engine: config.engine, settings: request.settings)
        let turn = TurnState(turnID: turnID, request: request, startedAt: Date())

        onEvent(.activity(turnID, config.initialActivity))
        onEvent(.log(turnID, "cwd \(request.settings.resolvedWorkingDirectory)"))

        let settler = TurnSettler()
        let engineTurnEnd = config.onTurnEnd
        let engineProcessExit = config.onProcessExit

        // A turn ends because the protocol said so — never because the process
        // died. First terminal state wins.
        let endTurn: TurnEnder = { turn, outcome in
            guard await turn.end(outcome) else { return }
            await engineTurnEnd(turn, outcome)
            settler.settle()
        }

        let handleProcessExit: @Sendable (Int32) async -> Void = { status in
            // The exit arrived before the protocol ended the turn: classify it.
            if await !turn.isEnded {
                if await turn.lastError != nil {
                    await turn.end(.failed)
                } else if status == SIGTERM || status == SIGKILL {
                    await turn.mark(error: EngineError.cancelled.localizedDescription)
                    await turn.end(.failed)
                } else if status != 0 {
                    await turn.mark(error: "\(config.engine.title) exited with status \(status).")
                    await turn.end(.failed)
                } else {
                    await turn.end(.completed)
                }
            }
            await engineProcessExit(status)
            settler.settle()
        }

        do {
            try await config.sendInitialMessage(process, session)
        } catch {
            await turn.mark(error: error.localizedDescription)
            process.terminate()
        }

        // Session-scoped: guards initialization only.
        let acceptTimeout = Task {
            try? await Task.sleep(for: .seconds(config.acceptTimeoutSeconds))
            guard !Task.isCancelled else { return }
            if await !config.isInitialAccepted(session), await !turn.isEnded {
                await turn.mark(error: config.acceptTimeoutMessage)
                process.terminate()
            }
        }

        // Per-turn timer: started with the turn, cancelled at turn end.
        let turnTimer = Task {
            try? await Task.sleep(for: .seconds(config.turnTimeoutSeconds))
            guard !Task.isCancelled else { return }
            if await !turn.isEnded {
                await turn.mark(error: config.turnTimeoutMessage)
                await endTurn(turn, .failed)
            }
        }

        // Process-lifetime reader: exits on EOF only. Lines that arrive after
        // the turn ended are ignored by the handlers, not by the reader.
        // NOTE: no readersAreClosed check here — availableData must be free
        // to drain everything already buffered, or a closeReaders() racing a
        // live stream would silently drop protocol lines.
        let stdoutTask = Task.detached {
            let reader = LineReader()
            while true {
                let data = process.standardOutput.availableData
                if data.isEmpty { break }
                for line in reader.push(data) {
                    await config.handleLine(line, process, session, turn, endTurn)
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
                    await turn.appendLog(trimmed)
                    onEvent(.log(turnID, trimmed))
                    if config.isAuthError(trimmed) {
                        await turn.mark(error: EngineError.notAuthenticated(config.engine).localizedDescription)
                        process.terminate()
                    }
                }
            }
        }

        // Death-watch instead of completion-wait: reports unexpected exit and
        // joins the readers once the pipes are done.
        let deathWatch = Task.detached {
            let status = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: process.waitUntilExit())
                }
            }
            process.closeReaders()
            _ = await stdoutTask.result
            _ = await stderrTask.result
            await handleProcessExit(status)
        }

        // The turn — not the process — is the unit of completion.
        await settler.wait()

        acceptTimeout.cancel()
        turnTimer.cancel()

        if await turn.outcome == nil, Task.isCancelled {
            await turn.mark(error: EngineError.cancelled.localizedDescription)
            await turn.end(.failed)
        }

        // Legacy one-shot epilogue: the run owns the process, so shut it down
        // now that the turn has settled. The persistent lifecycle (Phase 3+)
        // replaces this with an explicit close().
        process.terminate()
        _ = await deathWatch.value

        await finalizeTurn(
            turn: turn,
            session: session,
            turnID: turnID,
            engine: config.engine,
            onEvent: onEvent
        )
    }

    private static func finalizeTurn(
        turn: TurnState,
        session: EngineSession,
        turnID: UUID,
        engine: Engine,
        onEvent: @escaping @Sendable (EngineEvent) -> Void
    ) async {
        guard let outcome = await turn.outcome else { return }
        switch outcome {
        case .completed:
            await EngineSupport.emitCompletion(
                session: session,
                turn: turn,
                turnID: turnID,
                engine: engine,
                onEvent: onEvent
            )
        case .failed, .interrupted:
            let message = (await turn.lastError) ?? EngineError.failed("The turn ended without a result.").localizedDescription
            onEvent(.failed(turnID, message))
        }
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

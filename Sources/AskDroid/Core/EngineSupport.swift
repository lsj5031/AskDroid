import Foundation

/// A backend that can hold a multi-turn conversation by driving a CLI process.
///
/// The lifecycle is `begin` once per conversation, then any number of
/// `send`/`interrupt`/`reset` rounds, then `close`. A turn ending is not a
/// session ending: only `close` (or an unexpected process exit) retires the
/// CLI process.
protocol EngineClient: AnyObject, Sendable {
    /// Launch the CLI and initialize a session. Idempotent per engine: a new
    /// `begin` retires the previous session.
    func begin(
        settings: AppSettings,
        onEvent: @escaping @Sendable (EngineEvent) -> Void
    ) async throws -> SessionHandle

    /// Run a new turn on an existing session. Returns when the turn settles;
    /// the session stays usable.
    func send(_ request: EngineRequest, turnID: UUID, to handle: SessionHandle) async

    /// Stop the current turn. The session stays usable.
    func interrupt(_ handle: SessionHandle) async

    /// Clear conversation context without dropping the session where the
    /// engine supports it.
    func reset(_ handle: SessionHandle) async

    /// Graceful shutdown.
    func close(_ handle: SessionHandle) async

    /// Legacy one-shot convenience: `begin` → one turn → `close`. Retained so
    /// existing call sites and tests keep working; new code should hold a
    /// `SessionHandle` instead.
    func run(
        _ request: EngineRequest,
        runID: UUID,
        onEvent: @escaping @Sendable (EngineEvent) -> Void
    ) async

    /// Legacy cancel for one-shot `run`s: kills the process. Superseded by
    /// `interrupt(_:)`, which ends the turn and keeps the session.
    func cancel(runID: UUID) async
}

extension EngineClient {
    /// Runs a turn on an existing session. Identical for every engine — the
    /// per-turn pipeline lives on the handle.
    func send(_ request: EngineRequest, turnID: UUID, to handle: SessionHandle) async {
        await handle.send(request, turnID: turnID)
    }

    /// Deliver input while a turn is streaming (plan 008 Phase 7). Engines
    /// that gain steering override this.
    func queue(_ request: EngineRequest, to handle: SessionHandle) async throws {
        throw EngineError.failed("Steering isn't supported on this engine yet.")
    }
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
    /// The turn stopped without completing; the session stays usable.
    case interrupted(UUID)
    /// Context-window fill reported by the engine after a turn.
    case contextStats(used: Int, limit: Int)
    /// Steering queue changes (plan 008 Phase 7).
    case queueChanged([String])
    /// The CLI process is gone. `nil` reason means we closed it ourselves.
    case sessionEnded(String?)
    /// A session was established and is ready for turns.
    case sessionReady(SessionHandle, model: String?)
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
    /// What a claimed JSON-RPC request id was spent on, so responses can be
    /// correlated now that ids are monotonic instead of hardcoded.
    enum RequestKind {
        case initialize
        case userMessage
        case interrupt
        case contextStats
        case closeSession
    }

    let engine: Engine
    let settings: AppSettings
    private(set) var sessionID: String?
    private(set) var model: String?
    private(set) var didInitialize = false
    private(set) var didAccept = false
    private(set) var isClosed = false
    private(set) var nextRequestID = 1
    private var pendingRequests: [String: RequestKind] = [:]

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

    /// Claims the next request id and remembers what it was for.
    func registerRequest(as kind: RequestKind) -> String {
        let id = claimRequestID()
        pendingRequests[id] = kind
        return id
    }

    func requestKind(for id: String) -> RequestKind? {
        pendingRequests[id]
    }

    func fulfillRequest(id: String) {
        pendingRequests[id] = nil
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

    /// Forgets conversation-scoped identity after an in-process reset (Pi's
    /// `new_session`). Request ids stay monotonic so late responses can never
    /// collide with new ones.
    func resetContext() {
        sessionID = nil
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
        /// Sent once per session right after launch (droid's
        /// `initialize_session`; Pi has no handshake).
        let initializeSession: @Sendable (any ProcessIO, EngineSession) async throws -> Void
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
        /// Writes one turn's user message (droid `add_user_message`, Pi
        /// `prompt`). Called after the initialization handshake is accepted.
        let composeTurnMessage: @Sendable (any ProcessIO, EngineSession, TurnState) async throws -> Void
        /// Bookkeeping fired on the process after every settled turn in a
        /// persistent session (context-stats requests). Failures are ignored.
        let turnDidEnd: (@Sendable (any ProcessIO, EngineSession) async -> Void)?
        /// Called by the engine's line handler when a turn reaches a terminal
        /// state. The handle finalizes the turn and returns to idle — the
        /// process keeps running.
        let onTurnEnd: TurnEnder
        /// Called once the process has exited and both readers have joined.
        let onProcessExit: @Sendable (_ status: Int32) async -> Void

        init(
            engine: Engine,
            initialActivity: String,
            initializeSession: @escaping @Sendable (any ProcessIO, EngineSession) async throws -> Void,
            acceptTimeoutSeconds: Int = 25,
            acceptTimeoutMessage: String,
            turnTimeoutSeconds: Int = 600,
            turnTimeoutMessage: String,
            isInitialAccepted: @escaping @Sendable (EngineSession) async -> Bool,
            isAuthError: @escaping @Sendable (String) -> Bool,
            handleLine: @escaping LineHandler,
            composeTurnMessage: @escaping @Sendable (any ProcessIO, EngineSession, TurnState) async throws -> Void,
            turnDidEnd: (@Sendable (any ProcessIO, EngineSession) async -> Void)? = nil,
            onTurnEnd: @escaping TurnEnder,
            onProcessExit: @escaping @Sendable (_ status: Int32) async -> Void
        ) {
            self.engine = engine
            self.initialActivity = initialActivity
            self.initializeSession = initializeSession
            self.acceptTimeoutSeconds = acceptTimeoutSeconds
            self.acceptTimeoutMessage = acceptTimeoutMessage
            self.turnTimeoutSeconds = turnTimeoutSeconds
            self.turnTimeoutMessage = turnTimeoutMessage
            self.isInitialAccepted = isInitialAccepted
            self.isAuthError = isAuthError
            self.handleLine = handleLine
            self.composeTurnMessage = composeTurnMessage
            self.turnDidEnd = turnDidEnd
            self.onTurnEnd = onTurnEnd
            self.onProcessExit = onProcessExit
        }
    }
}

/// A live, multi-turn conversation with one CLI process. Returned by
/// `EngineClient.begin(settings:onEvent:)`; callers hold it and pass it back
/// for every turn.
///
/// The handle owns the process-lifetime supervision that used to live in the
/// one-shot runner: stdout/stderr readers that exit on EOF only, a death watch
/// that classifies unexpected exits, and a per-turn pipeline (readiness gate,
/// user message, timer, settlement, finalization). A turn ending is a protocol
/// event; only `shutdown` — or the process itself dying — ends the session.
actor SessionHandle {
    /// One-shot runs terminate the process as soon as the turn settles (the
    /// legacy `run(_:)` convenience); persistent sessions keep it alive for
    /// the next turn.
    enum TurnLifetime {
        case persistent
        case oneShot
    }

    let engine: Engine

    private let settings: AppSettings
    private let config: EngineProcessRunner.Configuration
    private let sink: @Sendable (EngineEvent) -> Void
    private let makeProcess: @Sendable () async throws -> any ProcessIO

    private struct Connection {
        let process: any ProcessIO
        let state: EngineSession
    }

    private var connection: Connection?
    private var readers: [Task<Void, Never>] = []
    private var deathWatch: Task<Void, Never>?
    private(set) var currentTurn: TurnState?
    /// Most recent turn, kept after it ends so session-scoped traffic (late
    /// RPC responses, context stats) still has somewhere to dispatch.
    private var lastTurn: TurnState?
    private var settler: TurnSettler?
    private var turnTimer: Task<Void, Never>?
    private(set) var lastExitStatus: Int32?
    private(set) var didClose = false
    /// Set synchronously inside `open()` so concurrent callers can't launch
    /// twice while the first open is suspended in the launcher.
    private var isOpening = false

    init(
        engine: Engine,
        settings: AppSettings,
        sink: @escaping @Sendable (EngineEvent) -> Void,
        config: EngineProcessRunner.Configuration,
        makeProcess: @escaping @Sendable () async throws -> any ProcessIO
    ) {
        self.engine = engine
        self.settings = settings
        self.sink = sink
        self.config = config
        self.makeProcess = makeProcess
    }

    // MARK: Accessors for engines

    var process: (any ProcessIO)? { connection?.process }
    var state: EngineSession? { connection?.state }

    func writeLine(_ line: String) throws {
        try connection?.process.write(line)
    }

    // MARK: Lifecycle

    /// Launches the CLI, starts the process-lifetime readers and death watch,
    /// and sends the engine's initialization handshake. Readiness is awaited
    /// per turn (see `send`) so cancelling never blocks `begin`.
    func open() async throws {
        guard connection == nil, !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        lastExitStatus = nil
        let process = try await makeProcess()
        let state = EngineSession(engine: engine, settings: settings)
        connection = Connection(process: process, state: state)
        startSupervision(process: process, state: state)
        do {
            try await config.initializeSession(process, state)
        } catch {
            process.terminate()
            throw error
        }
    }

    /// Runs one turn to completion. Returns when the turn settles; unless
    /// `lifetime` is `.oneShot`, the process stays alive for the next turn.
    func send(_ request: EngineRequest, turnID: UUID, lifetime: TurnLifetime = .persistent) async {
        if didClose {
            sink(.failed(turnID, EngineError.failed("The \(engine.title) session is closed.").localizedDescription))
            return
        }

        // A dead connection is replaced before the turn starts so a crash on
        // turn N doesn't poison turn N+1. `readersAreClosed` is set by the
        // death watch after `waitUntilExit` returns, so it proves the process
        // is gone even if `lastExitStatus` hasn't landed yet.
        if let conn = connection, conn.process.readersAreClosed || lastExitStatus != nil {
            connection = nil
        }
        // A reset/relaunch may be mid-flight; ride along instead of opening a
        // second process.
        while connection == nil, isOpening, !didClose {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if connection == nil {
            guard lifetime == .persistent else {
                sink(.failed(turnID, EngineError.failed("The \(engine.title) session has exited.").localizedDescription))
                return
            }
            do {
                try await open()
            } catch {
                sink(.failed(turnID, error.localizedDescription))
                return
            }
        }
        guard let conn = connection else {
            sink(.failed(turnID, "Could not start a \(engine.title) session."))
            return
        }

        sink(.activity(turnID, config.initialActivity))
        sink(.log(turnID, "cwd \(request.settings.resolvedWorkingDirectory)"))

        let turn = TurnState(turnID: turnID, request: request, startedAt: Date())
        currentTurn = turn
        lastTurn = turn
        let settle = TurnSettler()
        settler = settle

        let timeoutSeconds = config.turnTimeoutSeconds
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard !Task.isCancelled else { return }
            await self?.timeOut(turn)
        }
        turnTimer = timer

        let ready = await waitForReady(state: conn.state, process: conn.process, turn: turn)
        if ready, !(await turn.isEnded) {
            do {
                try await config.composeTurnMessage(conn.process, conn.state, turn)
            } catch {
                await turn.mark(error: error.localizedDescription)
                await endTurn(turn, .failed)
            }
        }

        await settle.wait()
        timer.cancel()
        turnTimer = nil

        if lifetime == .oneShot {
            // Legacy epilogue: the run owns the process, so shut it down now
            // that the turn has settled.
            conn.process.terminate()
            if let deathWatch { _ = await deathWatch.value }
        } else if let turnDidEnd = config.turnDidEnd {
            // Post-turn bookkeeping (context stats). Failures are noise.
            await turnDidEnd(conn.process, conn.state)
        }

        await finalize(turn, state: conn.state)

        if currentTurn?.turnID == turnID {
            currentTurn = nil
            settler = nil
        }
    }

    /// Ends the in-flight turn as `.interrupted`. The session — and the
    /// process — stay usable for the next turn.
    func interruptCurrentTurn() async {
        guard let turn = currentTurn, await !turn.isEnded else { return }
        await endTurn(turn, .interrupted)
    }

    /// Forgets conversation-scoped identity after an in-process reset.
    func clearConversationContext() async {
        await connection?.state.resetContext()
    }

    /// Tears the current process down and launches a fresh one in its place.
    /// Used by engines whose reset semantics require a new process (droid).
    func relaunch() async throws {
        await shutdown()
        didClose = false
        try await open()
    }

    /// Graceful shutdown: stops timers, terminates the process, joins the
    /// death watch.
    func shutdown() async {
        turnTimer?.cancel()
        turnTimer = nil
        currentTurn = nil
        settler = nil
        didClose = true
        guard let conn = connection else { return }
        connection = nil
        conn.process.terminate()
        if let deathWatch { _ = await deathWatch.value }
        readers = []
        deathWatch = nil
    }

    /// Immediate teardown without graceful-close bookkeeping. The legacy
    /// `cancel(runID:)` path uses this; the death watch classifies the turn.
    func terminateProcess() async {
        didClose = true
        connection?.process.terminate()
        connection = nil
    }

    // MARK: Turn pipeline

    /// Waits for the engine's initialization handshake. Returns false when
    /// the turn was ended while waiting (cancel, process death, timeout) —
    /// the caller then skips composing the turn message.
    private func waitForReady(state: EngineSession, process: any ProcessIO, turn: TurnState) async -> Bool {
        if await config.isInitialAccepted(state) { return true }
        let deadline = Date().addingTimeInterval(TimeInterval(config.acceptTimeoutSeconds))
        while !(await config.isInitialAccepted(state)) {
            if await turn.isEnded { return false }
            if process.readersAreClosed || lastExitStatus != nil { return false }
            if Date() >= deadline {
                await turn.mark(error: config.acceptTimeoutMessage)
                process.terminate()
                await endTurn(turn, .failed)
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func timeOut(_ turn: TurnState) async {
        guard await !turn.isEnded else { return }
        await turn.mark(error: config.turnTimeoutMessage)
        await endTurn(turn, .failed)
    }

    /// The `TurnEnder` implementation. The first terminal state wins the
    /// outcome, but losing that race must never prevent settlement: whenever
    /// a terminal outcome is reported for this handle's turn, the waiting
    /// `send` wakes up. Only the winner drives `onTurnEnd` bookkeeping.
    func endTurn(_ turn: TurnState, _ outcome: TurnOutcome) async {
        let wonRace = await turn.end(outcome)
        guard currentTurn === turn || lastTurn === turn else { return }
        if wonRace {
            await config.onTurnEnd(turn, outcome)
        }
        settler?.settle()
    }

    private func finalize(_ turn: TurnState, state: EngineSession) async {
        guard let outcome = await turn.outcome else { return }
        switch outcome {
        case .completed:
            await EngineSupport.emitCompletion(
                session: state,
                turn: turn,
                turnID: turn.turnID,
                engine: engine,
                onEvent: sink
            )
        case .failed:
            let message = (await turn.lastError) ?? EngineError.failed("The turn ended without a result.").localizedDescription
            sink(.failed(turn.turnID, message))
        case .interrupted:
            sink(.interrupted(turn.turnID))
        }
    }

    // MARK: Process supervision

    private func startSupervision(process: any ProcessIO, state: EngineSession) {
        let turnEnder: TurnEnder = { [weak self] turn, outcome in
            await self?.endTurn(turn, outcome)
        }
        // Blocking `availableData` reads must not occupy Swift's cooperative
        // thread pool: a persistent session parks its readers for the life of
        // the process, and parked pool threads starve every other task. The
        // reads run on GCD utility threads and hand lines to an ordered
        // AsyncStream consumed on the pool.
        func makeLineStream(_ handle: FileHandle) -> AsyncStream<String> {
            AsyncStream { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let reader = LineReader()
                    while true {
                        let data = handle.availableData
                        if data.isEmpty { break }
                        for line in reader.push(data) {
                            continuation.yield(line)
                        }
                    }
                    continuation.finish()
                }
            }
        }

        let stdoutLines = makeLineStream(process.standardOutput)
        let stderrLines = makeLineStream(process.standardError)

        let stdoutTask = Task.detached { [weak self] in
            for await line in stdoutLines {
                await self?.route(line, process: process, state: state, turnEnder: turnEnder, isStdout: true)
            }
        }
        let stderrTask = Task.detached { [weak self] in
            for await line in stderrLines {
                await self?.route(line, process: process, state: state, turnEnder: turnEnder, isStdout: false)
            }
        }
        readers = [stdoutTask, stderrTask]
        deathWatch = Task.detached { [weak self] in
            let status = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: process.waitUntilExit())
                }
            }
            process.closeReaders()
            _ = await stdoutTask.result
            _ = await stderrTask.result
            await self?.processDidExit(status)
        }
    }

    private func route(
        _ line: String,
        process: any ProcessIO,
        state: EngineSession,
        turnEnder: TurnEnder,
        isStdout: Bool
    ) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isStdout {
            // `lastTurn` keeps session-scoped traffic dispatchable between
            // turns; handlers gate turn-scoped work on `turn.isEnded`.
            guard let turn = currentTurn ?? lastTurn else { return }
            await config.handleLine(trimmed, process, state, turn, turnEnder)
        } else {
            guard let turn = currentTurn else { return }
            await turn.appendLog(trimmed)
            sink(.log(turn.turnID, trimmed))
            if config.isAuthError(trimmed) {
                await turn.mark(error: EngineError.notAuthenticated(engine).localizedDescription)
                process.terminate()
            }
        }
    }

    private func processDidExit(_ status: Int32) async {
        lastExitStatus = status
        // An exit that arrives before the protocol ended the turn classifies it.
        if let turn = currentTurn, await !turn.isEnded {
            if await turn.lastError != nil {
                await endTurn(turn, .failed)
            } else if status == SIGTERM || status == SIGKILL {
                await turn.mark(error: EngineError.cancelled.localizedDescription)
                await endTurn(turn, .failed)
            } else if status != 0 {
                await turn.mark(error: "\(engine.title) exited with status \(status).")
                await endTurn(turn, .failed)
            } else {
                await endTurn(turn, .completed)
            }
        }
        await config.onProcessExit(status)
        // An exit always wakes a waiting send, even if the protocol had
        // already settled the turn.
        settler?.settle()
        sink(.sessionEnded(didClose ? nil : "The \(engine.title) process exited."))
    }

    /// Resumes the awaiting turn exactly once, when the first of
    /// {turn end, process exit} settles it.
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

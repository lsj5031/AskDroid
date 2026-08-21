import AppKit
import Foundation
import ServiceManagement
import UserNotifications

/// One question-and-answer round in the conversation. The transcript is the
/// source of truth; the session's flat published properties are mirrors of
/// the newest turn kept for the current HUD surface.
struct Turn: Identifiable, Equatable {
    enum Status: Equatable {
        case running
        case completed
        case failed
        case interrupted
    }

    /// What a transcript entry represents.
    enum Kind: Equatable {
        /// A real question-and-answer round.
        case turn
        /// A muted divider marking a context break — e.g. the idle-expired
        /// session was replaced by a fresh one, so history above this line
        /// is no longer in the engine's context.
        case sessionBreak
    }

    let id: UUID
    var question: String
    var images: [AttachedImage]
    var answer: String
    var thinking: String
    var log: [String]
    var status: Status
    var errorMessage: String?
    var durationText: String?
    var tokenSummary: String?
    var archiveURL: URL?
    var kind: Kind = .turn
}

/// Context-window fill reported by the engine, for footer meta.
struct ContextStats: Equatable {
    let used: Int
    let limit: Int

    /// Compact footer label ("ctx 14.6k / 922k"). In a notch panel where the
    /// conversation scrolls out of view, this is the one number worth
    /// surfacing.
    var label: String {
        func short(_ value: Int) -> String {
            switch value {
            case ..<1_000:
                "\(value)"
            case ..<100_000:
                String(format: "%.1fk", Double(value) / 1_000)
            default:
                "\(value / 1_000)k"
            }
        }
        guard limit > 0 else { return "ctx ?" }
        return "ctx \(short(used)) / \(short(limit))"
    }
}

/// One message typed while a turn streams, waiting to land.
struct PendingMessage: Identifiable, Equatable {
    /// How the message will be delivered.
    enum Mode: Equatable {
        /// Injected into the live turn on the wire; the chip clears when the
        /// engine acks (or at settle if no ack ever comes).
        case steering
        /// Held client-side; auto-sends as the next turn when the current
        /// one settles.
        case queued
    }

    let id: UUID
    var text: String
    var mode: Mode
}

@MainActor
final class AskSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case composing
        case running
        case completed
        case failed
        /// The turn was stopped on request; the conversation continues.
        case interrupted
    }

    @Published var settings: AppSettings
    @Published var isExpanded = false
    @Published var isSettingsOpen = false
    @Published var prompt = ""
    @Published var images: [AttachedImage] = []
    @Published var transcript: [Turn] = []
    /// Prior turns the HUD renders expanded. Lives on the session (not the
    /// view) so the panel's reposition sinks can track it.
    @Published var expandedTurnIDs: Set<UUID> = []
    @Published var contextStats: ContextStats?
    /// Messages typed while a turn is streaming, each with its delivery
    /// mode. Steered entries mirror the engine's wire queue; queued entries
    /// are held client-side and auto-send as the next turn.
    @Published var pending: [PendingMessage] = []
    /// The session's display name (droid's `session_title_updated`, or a
    /// local derivation pushed to Pi via `set_session_name`). Drives the HUD
    /// header and the archive filename.
    @Published var sessionTitle: String?
    @Published var answer = ""
    @Published var thinking = ""
    @Published var activity = ""
    @Published var runLog: [String] = []
    @Published var phase: Phase = .idle
    @Published var errorMessage: String?
    @Published var archiveURL: URL?
    @Published var archiveError: String?
    @Published var tokenSummary: String?
    @Published var durationText: String?
    @Published var copied = false
    @Published var elapsed: TimeInterval = 0
    @Published var notice: String?

    static let maxImageBytes = 5 * 1024 * 1024
    static let maxTotalImageBytes = 15 * 1024 * 1024
    /// How long an open CLI session may sit unused before it is closed.
    /// The session id stays in memory so a follow-up plan can reattach —
    /// but Pi runs `--no-session`, so an idle close always means the next
    /// turn starts from zero. Long enough that closing only happens while
    /// the operator is truly away.
    static let idleSessionTimeout: TimeInterval = 60 * 60
    /// Instance override so tests can exercise expiry without waiting the
    /// real timeout. Production reads the constant.
    var idleSessionTimeoutOverride: TimeInterval?
    private var effectiveIdleSessionTimeout: TimeInterval {
        idleSessionTimeoutOverride ?? Self.idleSessionTimeout
    }
    /// Set when the idle timer replaced a live session: the next turn runs
    /// on a brand-new session, and the transcript says so instead of
    /// pretending continuity.
    private var needsFreshSessionNotice = false
    /// Transcript text for that context break.
    static let sessionBreakNotice = "Previous session expired — starting fresh"

    let droidEngine: DroidEngine
    let piEngine: PiEngine

    var engine: any EngineClient {
        switch settings.engine {
        case .droid: droidEngine
        case .pi: piEngine
        }
    }

    private var runTask: Task<Void, Never>?
    private var interruptTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var copiedResetTask: Task<Void, Never>?
    private var idleTimer: Task<Void, Never>?
    private var runStartedAt: Date?
    private(set) var currentRunID: UUID?
    /// The live conversation handle. A nil handle means the next submit
    /// begins a fresh session.
    private var activeHandle: SessionHandle?
    private var isBeginningSession = false
    /// Retained across an idle close; resumption across relaunches is a
    /// documented follow-up plan.
    private var retainedSessionID: String?
    // Conversation archive state (plan 008 Phase 8). The archive is one file
    // per conversation, rewritten as turns complete.
    private var conversationArchiveBase: String?
    private var conversationStartedAt: Date?
    private var conversationModel: String?
    private var didNameSession = false

    init(
        settings: AppSettings = SettingsStore.load(),
        droidEngine: DroidEngine = DroidEngine(),
        piEngine: PiEngine = PiEngine()
    ) {
        self.settings = settings
        self.droidEngine = droidEngine
        self.piEngine = piEngine
    }

    /// Convenience for callers that inject a single known engine. The injected
    /// engine is authoritative: `settings.engine` is updated to match it, so the
    /// session always uses the instance the caller supplied. Unknown
    /// `EngineClient` implementations fall back to the default engines; prefer
    /// the designated initializer in that case.
    convenience init(settings: AppSettings = SettingsStore.load(), engine: any EngineClient) {
        if let droid = engine as? DroidEngine {
            var settings = settings
            settings.engine = .droid
            self.init(settings: settings, droidEngine: droid, piEngine: PiEngine())
        } else if let pi = engine as? PiEngine {
            var settings = settings
            settings.engine = .pi
            self.init(settings: settings, droidEngine: DroidEngine(), piEngine: pi)
        } else {
            self.init(settings: settings)
        }
    }

    var canSubmit: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty
    }

    /// Short status text for the passive pill. Detailed failures stay in the
    /// expanded panel so the pill remains scannable at notch width.
    var compactTitle: String {
        switch phase {
        case .running:
            activity.isEmpty ? "Asking \(settings.engine.title)…" : activity
        case .completed:
            "Done"
        case .failed:
            "Failed"
        case .interrupted:
            "Interrupted"
        default:
            "AskDroid"
        }
    }

    func toggleExpanded() {
        if isExpanded {
            dismiss()
        } else {
            present()
        }
    }

    func present() {
        isExpanded = true
        isSettingsOpen = false
        if phase == .idle {
            phase = .composing
        }
        touchPresence()
        NotificationCenter.default.post(name: .askDroidFocusInput, object: nil)
    }

    func dismiss() {
        if isSettingsOpen {
            saveSettings()
        }
        isExpanded = false
        isSettingsOpen = false
        if phase == .composing, prompt.isEmpty, images.isEmpty {
            phase = .idle
        }
    }

    func closeSettings() {
        guard isSettingsOpen else { return }
        saveSettings()
        isSettingsOpen = false
    }

    // MARK: Conversation lifecycle

    /// How input typed while a turn streams should be delivered.
    enum DeliveryIntent {
        /// Inject into the live turn on the wire (wire-steering engines).
        case steer
        /// Hold visibly; auto-send as the next turn when the current one
        /// settles (any engine).
        case queue
    }

    /// Sends a follow-up turn, or handles input while a turn streams. Prior
    /// turns stay in the transcript; only the composer empties. While
    /// running, a nil intent means the engine default (steer on
    /// wire-steering engines, queue elsewhere); ⌘↩ and the primary button
    /// both land here.
    func submit(_ intent: DeliveryIntent? = nil) {
        guard canSubmit else { return }
        if phase == .running {
            deliverWhileRunning(intent ?? defaultDeliveryIntent)
            return
        }
        let turnID = UUID()
        if conversationStartedAt == nil {
            conversationStartedAt = Date()
        }
        // An idle-expired session was replaced by a fresh one: say so
        // instead of letting the new answer masquerade as continuity.
        if needsFreshSessionNotice {
            needsFreshSessionNotice = false
            if !transcript.isEmpty {
                transcript.append(Turn(
                    id: UUID(),
                    question: Self.sessionBreakNotice,
                    images: [],
                    answer: "",
                    thinking: "",
                    log: [],
                    status: .completed,
                    errorMessage: nil,
                    durationText: nil,
                    tokenSummary: nil,
                    archiveURL: nil,
                    kind: .sessionBreak
                ))
            }
        }
        let request = EngineRequest(
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Look at the attached image(s)."
                : prompt,
            images: images,
            settings: settings
        )
        transcript.append(Turn(
            id: turnID,
            question: request.prompt,
            images: request.images,
            answer: "",
            thinking: "",
            log: [],
            status: .running,
            errorMessage: nil,
            durationText: nil,
            tokenSummary: nil,
            archiveURL: nil
        ))
        prompt = ""
        images = []
        syncMirrorsToNewestTurn()
        errorMessage = nil
        archiveError = nil
        copied = false
        notice = nil
        phase = .running
        activity = "Starting \(settings.engine.title)…"
        runStartedAt = Date()
        elapsed = 0
        currentRunID = turnID
        startTicker()
        touchSessionActivity()

        let client = self.engine
        runTask?.cancel()
        runTask = Task { [client, weak self] in
            guard let self else { return }
            // Drain a pending interrupt first: it must land on the turn the
            // user stopped, never on this new one.
            if let interruptTask {
                await interruptTask.value
            }
            guard let handle = await self.ensureSession(client) else { return }
            await client.send(request, turnID: turnID, to: handle)
        }
    }

    /// The action the primary composer button takes while a turn streams.
    private var defaultDeliveryIntent: DeliveryIntent {
        engine.steersOnWire ? .steer : .queue
    }

    /// Delivers input into the turn that is currently streaming. `.steer`
    /// injects on the wire where the engine supports it (droid never does:
    /// its mid-turn queue auto-executes as an engine-initiated turn whose
    /// output the handle can never settle, so it falls back to the
    /// client-side queue). `.queue` holds the message visibly on any engine
    /// and auto-sends it as the next turn.
    private func deliverWhileRunning(_ intent: DeliveryIntent) {
        let request = EngineRequest(
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Look at the attached image(s)."
                : prompt,
            images: images,
            settings: settings
        )
        guard let handle = activeHandle else { return }
        let client = self.engine
        let wireSteer = intent == .steer && client.steersOnWire
        pending.append(PendingMessage(
            id: UUID(),
            text: request.prompt,
            mode: wireSteer ? .steering : .queued
        ))
        prompt = ""
        images = []
        guard wireSteer else { return }
        Task { [client, weak self] in
            do {
                try await client.queue(request, to: handle)
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // Nothing was delivered; give the message back.
                    if let index = pending.firstIndex(where: { $0.text == request.prompt && $0.mode == .steering }) {
                        pending.remove(at: index)
                    }
                    prompt = prompt.isEmpty ? request.prompt : prompt + "\n" + request.prompt
                    notice = error.localizedDescription
                }
            }
        }
    }

    /// Runs when a turn settles. Steered leftovers stop promising delivery
    /// (no ack came); one queued message auto-sends as the next turn —
    /// later ones drain at each subsequent settle.
    private func settlePendingQueue() {
        pending.removeAll { $0.mode == .steering }
        guard let next = pending.first(where: { $0.mode == .queued }) else { return }
        pending.removeAll { $0.id == next.id }
        prompt = next.text
        submit()
    }

    /// Reconciles the steered entries with the engine's authoritative wire
    /// queue. Client-queued entries are invisible to the engine and survive;
    /// steered texts keep their identity across updates so chips don't
    /// flicker.
    private func reconcileSteering(with messages: [String]) {
        var steered: [PendingMessage] = []
        var claimed = Set<UUID>()
        for text in messages {
            if let existing = pending.first(where: {
                $0.mode == .steering && $0.text == text && !claimed.contains($0.id)
            }) {
                claimed.insert(existing.id)
                steered.append(existing)
            } else {
                steered.append(PendingMessage(id: UUID(), text: text, mode: .steering))
            }
        }
        let queued = pending.filter { $0.mode == .queued }
        pending = steered + queued
    }

    /// Stops the running turn without ending the conversation. The composer
    /// is immediately usable again; this is not an error.
    func interruptTurn() {
        guard phase == .running, let turnID = currentRunID else { return }
        let client = self.engine
        let handle = activeHandle
        runTask?.cancel()
        ticker?.cancel()
        interruptTask = Task { [client] in
            if let handle {
                await client.interrupt(handle)
            }
        }
        // Local, immediate: don't wait for the engine's acknowledgement. The
        // late .interrupted event routes here too and finds the turn terminal.
        markTurnInterrupted(turnID)
        AskLog.line("turn \(turnID.uuidString.prefix(8)) interrupted by user")
    }

    /// Expands or collapses a prior turn's row in the transcript surface.
    func toggleExpandedRow(_ id: UUID) {
        if expandedTurnIDs.contains(id) {
            expandedTurnIDs.remove(id)
        } else {
            expandedTurnIDs.insert(id)
        }
    }

    /// Resubmits the most recent failed turn's question (and images) as a new
    /// turn. The failed turn stays in the transcript.
    func retryFailedTurn() {
        guard phase != .running else { return }
        guard let failed = transcript.last(where: { $0.status == .failed }) else { return }
        prompt = failed.question
        images = failed.images
        submit()
    }

    /// Clears the engine's conversation context and the transcript. The
    /// footer's "New" button maps here. The handle stays live: Pi resets
    /// in-process and droid relaunches inside the same handle.
    func startNewConversation() {
        let client = self.engine
        let handle = activeHandle
        retainedSessionID = nil
        Task { [client] in
            if let handle {
                await client.reset(handle)
            }
        }
        transcript = []
        clearConversationUI()
        NotificationCenter.default.post(name: .askDroidResetComposer, object: nil)
    }

    /// Clears the composer without dropping conversation context or history.
    func resetComposer() {
        prompt = ""
        images = []
        answer = ""
        thinking = ""
        runLog = []
        errorMessage = nil
        archiveURL = nil
        archiveError = nil
        tokenSummary = nil
        durationText = nil
        copied = false
        notice = nil
        phase = isExpanded ? .composing : .idle
        activity = ""
        NotificationCenter.default.post(name: .askDroidResetComposer, object: nil)
    }

    /// Called when the operator switches engines in Settings. Sessions are
    /// engine-specific, so the live session closes and the transcript clears.
    func engineDidChange() {
        guard let handle = activeHandle else { return }
        activeHandle = nil
        retainedSessionID = nil
        transcript = []
        clearConversationUI()
        let client = self.engine
        Task { [client] in
            await client.close(handle)
        }
    }

    private func ensureSession(_ client: any EngineClient) async -> SessionHandle? {
        if let handle = activeHandle { return handle }
        guard !isBeginningSession else { return nil }
        isBeginningSession = true
        defer { isBeginningSession = false }
        do {
            let handle = try await client.begin(settings: settings) { [weak self] event in
                Task { @MainActor in
                    self?.handle(event)
                }
            }
            activeHandle = handle
            touchSessionActivity()
            return handle
        } catch {
            failActiveTurn(error.localizedDescription)
            return nil
        }
    }

    private func closeIdleSession() async {
        guard let handle = activeHandle else { return }
        activeHandle = nil
        retainedSessionID = await handle.state?.sessionID
        // The next turn relaunches a fresh CLI with zero prior context (Pi
        // runs --no-session, so there is nothing to reattach to). Flag it
        // so the transcript says so.
        needsFreshSessionNotice = true
        AskLog.line("closing idle session id=\(retainedSessionID ?? "none")")
        let client = self.engine
        Task { [client] in
            await client.close(handle)
        }
    }

    private func touchSessionActivity() {
        idleTimer?.cancel()
        guard activeHandle != nil else { return }
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.effectiveIdleSessionTimeout ?? Self.idleSessionTimeout))
            guard !Task.isCancelled else { return }
            await self?.closeIdleSession()
        }
    }

    /// User presence: panel summon/open, typing in the composer, submit.
    /// Closing an idle session only makes sense while the operator is truly
    /// away, so any of these restarts the clock.
    func touchPresence() {
        touchSessionActivity()
    }

    /// Test seam: fires the idle timer now instead of waiting the real
    /// timeout.
    func expireIdleSessionForTesting() async {
        await closeIdleSession()
    }

    // MARK: Attachments

    @discardableResult
    func attachFromPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        attach(images: AttachedImage.fromPasteboard(pasteboard))
    }

    @discardableResult
    func attach(images incoming: [AttachedImage]) -> Bool {
        guard !incoming.isEmpty else { return false }
        var added = false
        var skipped = 0
        for image in incoming where !images.contains(where: { $0.data == image.data }) {
            let wouldBeTotal = images.reduce(0) { $0 + $1.data.count } + image.data.count
            if image.data.count > Self.maxImageBytes || wouldBeTotal > Self.maxTotalImageBytes {
                skipped += 1
                continue
            }
            images.append(image)
            added = true
        }
        if skipped > 0 {
            notice = skipped == 1
                ? "Skipped an image over the size limit (5 MB each, 15 MB total)."
                : "Skipped \(skipped) images over the size limit (5 MB each, 15 MB total)."
            AskLog.line("skipped \(skipped) oversized image(s)")
        }
        if added {
            AskLog.line("attached \(incoming.count) image(s) total=\(images.count)")
        }
        if added, !isExpanded {
            present()
        }
        return added
    }

    func attach(urls: [URL]) {
        attach(images: urls.compactMap(AttachedImage.fromFileURL))
    }

    func removeImage(_ image: AttachedImage) {
        images.removeAll { $0.id == image.id }
    }

    // MARK: Answer actions

    func copyAnswer() {
        guard !answer.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
        copied = true
        copiedResetTask?.cancel()
        copiedResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }

    func openArchive() {
        guard let archiveURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([archiveURL])
    }

    func saveSettings() {
        SettingsStore.save(settings)
        let applied = LaunchAtLogin.setEnabled(settings.launchAtLogin)
        if !applied {
            settings.launchAtLogin = LaunchAtLogin.isEnabled
            SettingsStore.save(settings)
        }
        NotificationCenter.default.post(name: .askDroidHotkeyChanged, object: settings)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Engine events

    func handle(_ event: EngineEvent) {
        switch event {
        case .started(let turnID):
            guard turnID == currentRunID, turnByID(turnID)?.status == .running else { return }
            phase = .running
            AskLog.line("turn \(turnID.uuidString.prefix(8)) started")
        case .activity(let turnID, let text):
            guard turnID == currentRunID, turnByID(turnID)?.status == .running else { return }
            activity = text
        case .thinking(let turnID, let text):
            guard turnID == currentRunID, turnByID(turnID)?.status == .running else { return }
            mutateTurn(turnID) { $0.thinking.append(text) }
        case .textDelta(let turnID, let text):
            guard turnID == currentRunID, turnByID(turnID)?.status == .running else { return }
            mutateTurn(turnID) { $0.answer.append(text) }
        case .log(let turnID, let text):
            guard turnID == currentRunID, turnByID(turnID)?.status == .running else { return }
            mutateTurn(turnID) { turn in
                appendLogLine(text, into: &turn.log)
            }
            AskLog.line("turn: \(text)")
        case .completed(let turnID, let result):
            completeTurn(turnID, result)
        case .failed(let turnID, let message):
            failTurn(turnID, message)
        case .interrupted(let turnID):
            settleInterrupted(turnID)
        case .sessionReady:
            break
        case .contextStats(let used, let limit):
            contextStats = ContextStats(used: used, limit: limit)
        case .queueChanged(let messages):
            // Authoritative mirror of the engine's wire queue while a turn
            // streams. Steered entries reconcile; client-queued entries are
            // invisible to the engine and survive. A delivery after settle
            // is stale — steered entries cleared when the turn ended.
            if phase == .running {
                reconcileSteering(with: messages)
            } else {
                pending.removeAll { $0.mode == .steering }
            }
        case .steerAccepted:
            // The engine confirmed injection into the live turn: the chip's
            // job is done. First-in is first delivered (Pi drains FIFO).
            if let index = pending.firstIndex(where: { $0.mode == .steering }) {
                pending.remove(at: index)
            }
        case .sessionTitle(let title):
            // Droid names sessions itself; its title wins over any local
            // derivation for the header and the archive filename.
            guard !title.isEmpty else { return }
            didNameSession = true
            sessionTitle = title
        case .sessionEnded(let reason):
            sessionDidEnd(reason)
        }
    }

    // MARK: Turn bookkeeping

    private func turnByID(_ id: UUID) -> Turn? {
        transcript.first { $0.id == id }
    }

    /// Mutates a turn in place and refreshes the newest-turn mirrors when the
    /// mutated turn is the one on display.
    private func mutateTurn(_ id: UUID, _ mutate: (inout Turn) -> Void) {
        guard let index = transcript.firstIndex(where: { $0.id == id }) else { return }
        mutate(&transcript[index])
        if index == transcript.count - 1 {
            syncMirrorsToNewestTurn()
        }
    }

    private func syncMirrorsToNewestTurn() {
        guard let turn = transcript.last else {
            answer = ""
            thinking = ""
            runLog = []
            archiveURL = nil
            tokenSummary = nil
            durationText = nil
            return
        }
        answer = turn.answer
        thinking = turn.thinking
        runLog = turn.log
        archiveURL = turn.archiveURL
        tokenSummary = turn.tokenSummary
        durationText = turn.durationText
    }

    private func completeTurn(_ turnID: UUID, _ result: EngineResult) {
        guard var turn = turnByID(turnID), turn.status == .running else {
            if let url = result.archiveURL {
                AskLog.line("late completion from turn \(turnID.uuidString.prefix(8)); archived \(url.lastPathComponent)")
                notifyLateArchive(url)
            }
            return
        }
        ticker?.cancel()
        turn.answer = result.text
        turn.archiveURL = result.archiveURL
        turn.tokenSummary = result.tokenUsage?.summary
        turn.durationText = AnswerArchive.formatDuration(result.duration)
        if turn.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            turn.status = .failed
            turn.errorMessage = emptyAnswerMessage(for: turn)
            replaceTurn(turn)
            errorMessage = turn.errorMessage
            activity = "\(settings.engine.title) ended the turn with no answer"
            phase = .failed
            AskLog.line("turn \(turnID.uuidString.prefix(8)) completed with empty answer")
            notifyIfCollapsed(success: false)
        } else {
            turn.status = .completed
            if let model = result.model, !model.isEmpty {
                conversationModel = model
            }
            replaceTurn(turn)
            activity = "Done"
            phase = .completed
            AskLog.line("turn \(turnID.uuidString.prefix(8)) completed")
            maybeNameSession()
            archiveConversation()
            notifyIfCollapsed(success: true)
        }
        settlePendingQueue()
    }

    private func failTurn(_ turnID: UUID, _ message: String) {
        guard var turn = turnByID(turnID), turn.status == .running else { return }
        ticker?.cancel()
        turn.status = .failed
        turn.errorMessage = message
        replaceTurn(turn)
        if turnID == currentRunID {
            errorMessage = message
            activity = "Failed"
            phase = .failed
            AskLog.line("turn \(turnID.uuidString.prefix(8)) failed: \(message)")
            notifyIfCollapsed(success: false)
            settlePendingQueue()
        }
    }

    private func settleInterrupted(_ turnID: UUID) {
        guard var turn = turnByID(turnID), turn.status == .running else { return }
        ticker?.cancel()
        turn.status = .interrupted
        replaceTurn(turn)
        if turnID == currentRunID, phase == .running {
            activity = "Interrupted"
            phase = .interrupted
            settlePendingQueue()
        }
    }

    private func markTurnInterrupted(_ turnID: UUID) {
        guard var turn = turnByID(turnID), turn.status == .running else { return }
        turn.status = .interrupted
        replaceTurn(turn)
        activity = "Interrupted"
        phase = .interrupted
        settlePendingQueue()
    }

    private func replaceTurn(_ turn: Turn) {
        guard let index = transcript.firstIndex(where: { $0.id == turn.id }) else { return }
        transcript[index] = turn
        if index == transcript.count - 1 {
            syncMirrorsToNewestTurn()
        }
    }

    // MARK: Conversation archive

    /// Rewrites the conversation archive with every completed turn so far.
    /// One file per conversation: the first write resolves the base name
    /// (title-derived when the session has one), later writes reuse it.
    private func archiveConversation() {
        let completed = transcript.filter { $0.status == .completed && $0.kind == .turn }
        guard !completed.isEmpty else { return }
        do {
            let archived = try AnswerArchive.write(
                directory: URL(fileURLWithPath: settings.resolvedAnswersDirectory, isDirectory: true),
                date: conversationStartedAt ?? Date(),
                turns: completed.map { turn in
                    ArchivedTurn(
                        question: turn.question,
                        answer: turn.answer,
                        images: turn.images,
                        durationText: turn.durationText
                    )
                },
                model: conversationModel,
                engine: settings.engine.rawValue,
                title: sessionTitle,
                base: conversationArchiveBase
            )
            conversationArchiveBase = archived.baseName
            // Every completed turn points at the same living file.
            for turn in transcript
            where turn.kind == .turn && turn.status == .completed && turn.archiveURL != archived.markdownURL {
                mutateTurn(turn.id) { $0.archiveURL = archived.markdownURL }
            }
            archiveError = nil
        } catch {
            archiveError = "Could not save the answer file: \(error.localizedDescription)"
            AskLog.line("archive failed: \(error.localizedDescription)")
        }
    }

    /// Derives a display name from the first question for engines that don't
    /// title sessions themselves. Droid's own `session_title_updated`
    /// overwrites this when it arrives.
    private func maybeNameSession() {
        guard sessionTitle == nil, !didNameSession, !transcript.isEmpty else { return }
        didNameSession = true
        let title = Self.derivedSessionTitle(from: transcript[0].question)
        guard !title.isEmpty else { return }
        sessionTitle = title
        guard let handle = activeHandle else { return }
        let client = self.engine
        Task { [client] in
            await client.setName(title, to: handle)
        }
    }

    static func derivedSessionTitle(from question: String) -> String {
        // No regex here: Foundation's regularExpression matching can match a
        // single whitespace character, so a replace-with-" " loop never
        // advances. split/join is total.
        let collapsed = question.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > 3 else { return "" }
        if collapsed.count <= 48 {
            return collapsed
        }
        return String(collapsed.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func failActiveTurn(_ message: String) {
        guard let turnID = currentRunID else { return }
        ticker?.cancel()
        if var turn = turnByID(turnID), turn.status == .running {
            turn.status = .failed
            turn.errorMessage = message
            replaceTurn(turn)
        }
        errorMessage = message
        activity = "Failed"
        phase = .failed
        AskLog.line("turn \(turnID.uuidString.prefix(8)) failed: \(message)")
        notifyIfCollapsed(success: false)
    }

    private func sessionDidEnd(_ reason: String?) {
        activeHandle = nil
        guard let reason else { return } // nil = we closed it ourselves
        AskLog.line("engine session ended: \(reason)")
        if let turnID = currentRunID, phase == .running {
            failTurn(turnID, reason)
        }
    }

    private func clearConversationUI() {
        prompt = ""
        images = []
        answer = ""
        thinking = ""
        runLog = []
        errorMessage = nil
        archiveURL = nil
        archiveError = nil
        tokenSummary = nil
        durationText = nil
        copied = false
        notice = nil
        contextStats = nil
        pending = []
        expandedTurnIDs = []
        sessionTitle = nil
        conversationArchiveBase = nil
        conversationStartedAt = nil
        conversationModel = nil
        didNameSession = false
        activity = ""
        currentRunID = nil
        phase = isExpanded ? .composing : .idle
    }

    /// Diagnostics for a turn that produced no text. Reads that turn's own log
    /// only — a previous turn's "connection error" must not leak into this
    /// turn's explanation.
    private func emptyAnswerMessage(for turn: Turn) -> String {
        let log = turn.log.joined(separator: "\n").lowercased()
        let title = settings.engine.title
        if log.contains("connection error") {
            return "\(title) hit a connection error and couldn't reach the model. If you use a local or network model, make sure AskDroid has Local Network permission in System Settings → Privacy & Security → Local Network, then try again."
        }
        if settings.engine == .droid, settings.autonomy == .off {
            return "Droid produced no text. In read-only mode every tool call is auto-rejected, so Droid may have had nothing to say. Try rephrasing, or raise autonomy in Settings."
        }
        return "\(title) ended the turn without writing an answer. Open Activity to see what happened, then try again."
    }

    private func appendLogLine(_ text: String, into log: inout [String]) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if log.last == cleaned { return }
        log.append(cleaned)
        if log.count > 40 {
            log.removeFirst(log.count - 40)
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let started = self.runStartedAt else { continue }
                self.elapsed = Date().timeIntervalSince(started)
            }
        }
    }

    private func notifyLateArchive(_ url: URL) {
        let content = UNMutableNotificationContent()
        content.title = "AskDroid"
        content.body = "A cancelled run finished and saved \(url.lastPathComponent)."
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func notifyIfCollapsed(success: Bool) {
        guard !isExpanded else { return }
        let content = UNMutableNotificationContent()
        content.title = success ? "AskDroid finished" : "AskDroid failed"
        content.body = success
            ? (archiveError ?? archiveURL.map { "Saved \($0.lastPathComponent)" } ?? "Answer ready.")
            : (errorMessage ?? "Something went wrong.")
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

enum LaunchContext {
    static let openApplicationEvent: UInt32 = 0x6F61_7070 // 'oapp'
    static let propDataKeyword: UInt32 = 0x7072_6474 // 'prdt'
    static let launchedAsLoginItem: UInt32 = 0x6C67_6974 // 'lgit'

    static func isLoginLaunch(event: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent) -> Bool {
        guard let event, event.eventID == openApplicationEvent else { return false }
        return event.paramDescriptor(forKeyword: propDataKeyword)?.enumCodeValue == launchedAsLoginItem
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("AskDroid launch-at-login failed: \(error.localizedDescription)")
            AskLog.line("launch-at-login failed: \(error.localizedDescription)")
            return false
        }
    }
}

extension Notification.Name {
    static let askDroidFocusInput = Notification.Name("askDroidFocusInput")
    static let askDroidHotkeyChanged = Notification.Name("askDroidHotkeyChanged")
    static let askDroidResetComposer = Notification.Name("askDroidResetComposer")
}

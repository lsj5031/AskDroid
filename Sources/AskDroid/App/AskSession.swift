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
}

/// Context-window fill reported by the engine, for footer meta.
struct ContextStats: Equatable {
    let used: Int
    let limit: Int
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
    @Published var contextStats: ContextStats?
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
    /// The session id stays in memory so a follow-up plan can reattach.
    static let idleSessionTimeout: TimeInterval = 10 * 60

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

    /// Sends a follow-up turn. Prior turns stay in the transcript; only the
    /// composer empties.
    func submit() {
        guard canSubmit, phase != .running else { return }
        let turnID = UUID()
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
            try? await Task.sleep(for: .seconds(Self.idleSessionTimeout))
            guard !Task.isCancelled else { return }
            await self?.closeIdleSession()
        }
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
        case .queueChanged:
            break // steering lands in plan 008 Phase 7
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
            replaceTurn(turn)
            archiveError = result.archiveError
            activity = result.archiveError == nil ? "Done" : "Answer ready, file not saved"
            phase = .completed
            AskLog.line("turn \(turnID.uuidString.prefix(8)) completed archive=\(result.archiveURL?.lastPathComponent ?? "none") archiveError=\(result.archiveError ?? "none")")
            notifyIfCollapsed(success: true)
        }
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
        }
    }

    private func markTurnInterrupted(_ turnID: UUID) {
        guard var turn = turnByID(turnID), turn.status == .running else { return }
        turn.status = .interrupted
        replaceTurn(turn)
        activity = "Interrupted"
        phase = .interrupted
    }

    private func replaceTurn(_ turn: Turn) {
        guard let index = transcript.firstIndex(where: { $0.id == turn.id }) else { return }
        transcript[index] = turn
        if index == transcript.count - 1 {
            syncMirrorsToNewestTurn()
        }
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

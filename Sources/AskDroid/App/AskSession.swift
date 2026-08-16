import AppKit
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class AskSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case composing
        case running
        case completed
        case failed
    }

    @Published var settings: AppSettings
    @Published var isExpanded = false
    @Published var isSettingsOpen = false
    @Published var prompt = ""
    @Published var images: [AttachedImage] = []
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

    let engine: DroidEngine
    private var runTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var copiedResetTask: Task<Void, Never>?
    private var runStartedAt: Date?
    private(set) var currentRunID: UUID?

    init(settings: AppSettings = SettingsStore.load(), engine: DroidEngine = DroidEngine()) {
        self.settings = settings
        self.engine = engine
    }

    var canSubmit: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty
    }

    /// Short status text for the passive pill. Detailed failures stay in the
    /// expanded panel so the pill remains scannable at notch width.
    var compactTitle: String {
        switch phase {
        case .running:
            activity.isEmpty ? "Asking Droid…" : activity
        case .completed:
            "Done"
        case .failed:
            "Failed"
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

    func submit() {
        guard canSubmit, phase != .running else { return }
        let runID = UUID()
        let request = DroidRunRequest(
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Look at the attached image(s)."
                : prompt,
            images: images,
            settings: settings
        )
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
        phase = .running
        activity = "Starting Droid…"
        runStartedAt = Date()
        elapsed = 0
        currentRunID = runID
        startTicker()

        runTask?.cancel()
        runTask = Task { [engine] in
            await engine.run(request, runID: runID) { [weak self] event in
                Task { @MainActor in
                    self?.handle(event)
                }
            }
        }
    }

    func cancelRun() {
        let runID = currentRunID
        runTask?.cancel()
        if let runID {
            Task { await engine.cancel(runID: runID) }
        }
        currentRunID = nil
        ticker?.cancel()
        phase = .failed
        errorMessage = DroidEngineError.cancelled.localizedDescription
        activity = "Cancelled"
        AskLog.line("run \(runID?.uuidString.prefix(8) ?? "none") cancelled by user")
    }

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

    func handle(_ event: DroidRunEvent) {
        switch event {
        case .started(let runID):
            guard runID == currentRunID else { return }
            phase = .running
            AskLog.line("run \(runID.uuidString.prefix(8)) started")
        case .activity(let runID, let text):
            guard runID == currentRunID else { return }
            activity = text
        case .thinking(let runID, let text):
            guard runID == currentRunID else { return }
            thinking.append(text)
        case .textDelta(let runID, let text):
            guard runID == currentRunID else { return }
            answer.append(text)
        case .log(let runID, let text):
            guard runID == currentRunID else { return }
            appendLog(text)
            AskLog.line("run: \(text)")
        case .completed(let runID, let result):
            guard runID == currentRunID, phase == .running else {
                if let url = result.archiveURL {
                    AskLog.line("late completion from run \(runID.uuidString.prefix(8)); archived \(url.lastPathComponent)")
                    notifyLateArchive(url)
                }
                return
            }
            ticker?.cancel()
            answer = result.text
            archiveURL = result.archiveURL
            archiveError = result.archiveError
            tokenSummary = result.tokenUsage?.summary
            durationText = AnswerArchive.formatDuration(result.duration)
            if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                activity = "Droid ended the turn with no answer"
                errorMessage = emptyAnswerMessage()
                phase = .failed
                AskLog.line("run \(runID.uuidString.prefix(8)) completed with empty answer")
                notifyIfCollapsed(success: false)
            } else {
                activity = result.archiveError == nil ? "Done" : "Answer ready, file not saved"
                phase = .completed
                AskLog.line("run \(runID.uuidString.prefix(8)) completed archive=\(result.archiveURL?.lastPathComponent ?? "none") archiveError=\(result.archiveError ?? "none")")
                notifyIfCollapsed(success: true)
            }
        case .failed(let runID, let message):
            guard runID == currentRunID, phase == .running else { return }
            ticker?.cancel()
            errorMessage = message
            activity = "Failed"
            phase = .failed
            AskLog.line("run \(runID.uuidString.prefix(8)) failed: \(message)")
            notifyIfCollapsed(success: false)
        }
    }

    private func emptyAnswerMessage() -> String {
        let log = runLog.joined(separator: "\n").lowercased()
        if log.contains("connection error") {
            return "Droid hit a connection error and couldn't reach the model. If you use a local or network model, make sure AskDroid has Local Network permission in System Settings → Privacy & Security → Local Network, then try again."
        }
        if settings.autonomy == .off {
            return "Droid produced no text. In read-only mode every tool call is auto-rejected, so Droid may have had nothing to say. Try rephrasing, or raise autonomy in Settings."
        }
        return "Droid ended the turn without writing an answer. Open Activity to see what happened, then try again."
    }

    private func appendLog(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if runLog.last == cleaned { return }
        runLog.append(cleaned)
        if runLog.count > 40 {
            runLog.removeFirst(runLog.count - 40)
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

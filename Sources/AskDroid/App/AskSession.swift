import AppKit
import Foundation
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

    let engine: DroidEngine
    private var runTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var runStartedAt: Date?

    init(settings: AppSettings = SettingsStore.load(), engine: DroidEngine = DroidEngine()) {
        self.settings = settings
        self.engine = engine
    }

    var canSubmit: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty
    }

    var compactTitle: String {
        switch phase {
        case .running:
            activity.isEmpty ? "Asking Droid…" : activity
        case .completed:
            "Done"
        case .failed:
            errorMessage ?? "Failed"
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
        isExpanded = false
        isSettingsOpen = false
        if phase == .composing, prompt.isEmpty, images.isEmpty {
            phase = .idle
        }
    }

    func submit() {
        guard canSubmit, phase != .running else { return }
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
        phase = .running
        activity = "Starting Droid…"
        runStartedAt = Date()
        startTicker()

        runTask?.cancel()
        runTask = Task { [engine] in
            await engine.run(request) { [weak self] event in
                Task { @MainActor in
                    self?.handle(event)
                }
            }
        }
    }

    func cancelRun() {
        runTask?.cancel()
        Task { await engine.cancel() }
        ticker?.cancel()
        phase = .failed
        errorMessage = DroidEngineError.cancelled.localizedDescription
        activity = "Cancelled"
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
        phase = isExpanded ? .composing : .idle
        activity = ""
    }

    @discardableResult
    func attachFromPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        attach(images: AttachedImage.fromPasteboard(pasteboard))
    }

    @discardableResult
    func attach(images incoming: [AttachedImage]) -> Bool {
        guard !incoming.isEmpty else { return false }
        var added = false
        for image in incoming where !images.contains(where: { $0.data == image.data }) {
            images.append(image)
            added = true
        }
        if added {
            AskLog.line("attached \(incoming.count) image(s) total=\(images.count)")
        }
        if !isExpanded {
            present()
        }
        return added
    }

    func attach(urls: [URL]) {
        for url in urls {
            if let image = AttachedImage.fromFileURL(url) {
                images.append(image)
            }
        }
    }

    func removeImage(_ image: AttachedImage) {
        images.removeAll { $0.id == image.id }
    }

    func copyAnswer() {
        guard !answer.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
        copied = true
    }

    func openArchive() {
        guard let archiveURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([archiveURL])
    }

    func saveSettings() {
        SettingsStore.save(settings)
        LaunchAtLogin.setEnabled(settings.launchAtLogin)
        NotificationCenter.default.post(name: .askDroidHotkeyChanged, object: settings)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func handle(_ event: DroidRunEvent) {
        switch event {
        case .started:
            phase = .running
        case .activity(let text):
            activity = text
        case .thinking(let text):
            thinking.append(text)
        case .textDelta(let text):
            answer.append(text)
        case .log(let text):
            appendLog(text)
        case .completed(let result):
            guard phase == .running else { return }
            ticker?.cancel()
            answer = result.text
            archiveURL = result.archiveURL
            archiveError = result.archiveError
            tokenSummary = result.tokenUsage?.summary
            durationText = AnswerArchive.formatDuration(result.duration)
            activity = result.archiveError == nil ? "Done" : "Answer ready, file not saved"
            phase = .completed
            notifyIfCollapsed(success: true)
        case .failed(let message):
            guard phase == .running else { return }
            ticker?.cancel()
            errorMessage = message
            activity = "Failed"
            phase = .failed
            notifyIfCollapsed(success: false)
        }
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

enum LaunchAtLogin {
    static func setEnabled(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                try SMAppServiceAdapter.register()
            } else {
                try SMAppServiceAdapter.unregister()
            }
        } catch {
            NSLog("AskDroid launch-at-login failed: \(error.localizedDescription)")
        }
    }
}

enum SMAppServiceAdapter {
    static func register() throws {
        if #available(macOS 13.0, *) {
            try ServiceManagementBridge.register()
        }
    }

    static func unregister() throws {
        if #available(macOS 13.0, *) {
            try ServiceManagementBridge.unregister()
        }
    }
}

import ServiceManagement

enum ServiceManagementBridge {
    @available(macOS 13.0, *)
    static func register() throws {
        try SMAppService.mainApp.register()
    }

    @available(macOS 13.0, *)
    static func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

extension Notification.Name {
    static let askDroidFocusInput = Notification.Name("askDroidFocusInput")
    static let askDroidHotkeyChanged = Notification.Name("askDroidHotkeyChanged")
}

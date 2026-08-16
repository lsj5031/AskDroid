import AppKit

/// Hides the HUD from screenshots and screen recordings.
///
/// `NSWindow.sharingType = .none` is the supported capture-exclusion flag.
/// Screenshot chords (⌘⇧3/4/5) and Screenshot.app still briefly expose some
/// overlays on newer macOS, so we also order the panel out for the capture.
@MainActor
final class CapturePrivacy {
    private weak var panel: NSWindow?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var hideUntil: Date?
    private var restoreTask: Task<Void, Never>?
    private var suppressedBundleID: String?
    private(set) var isCaptureHidden = false

    var onHideChanged: ((Bool) -> Void)?

    nonisolated static let screenshotBundleIDs: Set<String> = [
        "com.apple.screencaptureui",
        "com.apple.screenshot.launcher",
        "com.apple.Screenshot",
    ]

    /// Recorders / meeting apps that commonly use ScreenCaptureKit, which
    /// ignores `sharingType` on macOS 15+. Hide while they are frontmost.
    nonisolated static let recorderBundleIDs: Set<String> = [
        "com.apple.QuickTimePlayerX",
        "com.apple.replayd",
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.obsproject.obs-studio",
        "com.loom.desktop",
    ]

    nonisolated static func shouldHideForBundle(_ id: String?) -> Bool {
        guard let id else { return false }
        return screenshotBundleIDs.contains(id) || recorderBundleIDs.contains(id)
    }

    static var isDisabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["ASKDROID_ALLOW_CAPTURE"] == "1" || env["ASKDROID_SCREENSHOTS"] != nil
    }

    init(panel: NSWindow) {
        self.panel = panel
        if Self.isDisabled {
            panel.sharingType = .readWrite
            return
        }
        panel.sharingType = .none
        start()
    }

    func start() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self, Self.isScreenshotChord(event) else { return }
            Task { @MainActor in
                self.hideForCapture(duration: 1.4)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                self?.handleActivation(app?.bundleIdentifier)
            }
        }
    }

    nonisolated static func isScreenshotChord(_ event: NSEvent) -> Bool {
        isScreenshotChord(
            keyCode: event.keyCode,
            flags: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        )
    }

    nonisolated static func isScreenshotChord(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let commandShift = flags.contains(.command) && flags.contains(.shift)
        guard commandShift, !flags.contains(.option), !flags.contains(.control) else { return false }
        // ANSI 3 / 4 / 5 (screenshot, selection, Screenshot toolbar).
        switch keyCode {
        case 20, 21, 23:
            return true
        default:
            return false
        }
    }

    func hideForCapture(duration: TimeInterval) {
        let until = Date().addingTimeInterval(duration)
        hideUntil = max(hideUntil ?? .distantPast, until)
        refresh()
        scheduleTimedRestore()
    }

    private func handleActivation(_ bundleID: String?) {
        if let bundleID, Self.shouldHideForBundle(bundleID) {
            suppressedBundleID = bundleID
        } else {
            suppressedBundleID = nil
        }
        refresh()
    }

    private func scheduleTimedRestore() {
        restoreTask?.cancel()
        guard let hideUntil else { return }
        let delay = max(hideUntil.timeIntervalSinceNow, 0.2)
        restoreTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.timedHideExpired()
            }
        }
    }

    private func timedHideExpired() {
        guard let hideUntil, Date() >= hideUntil else {
            refresh()
            return
        }
        self.hideUntil = nil
        refresh()
    }

    private func refresh() {
        let timedActive = hideUntil.map { Date() < $0 } ?? false
        let shouldHide = timedActive || suppressedBundleID != nil
        if shouldHide, !isCaptureHidden {
            isCaptureHidden = true
            panel?.orderOut(nil)
            onHideChanged?(true)
            AskLog.line("capture hide")
        } else if !shouldHide, isCaptureHidden {
            isCaptureHidden = false
            onHideChanged?(false)
            AskLog.line("capture restore")
        }
    }
}

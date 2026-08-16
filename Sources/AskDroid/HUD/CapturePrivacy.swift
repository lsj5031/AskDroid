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
        "com.apple.ControlCenter",
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.obsproject.obs-studio",
        "com.loom.desktop",
        "com.raycast.macos",
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
            guard Self.shouldHideForBundle(app?.bundleIdentifier) else { return }
            let isShot = Self.screenshotBundleIDs.contains(app?.bundleIdentifier ?? "")
            Task { @MainActor in
                self?.hideForCapture(duration: isShot ? 8 : 4)
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
        if let hideUntil, until < hideUntil { return }
        hideUntil = until
        if !isCaptureHidden {
            isCaptureHidden = true
            panel?.orderOut(nil)
            onHideChanged?(true)
            AskLog.line("capture hide")
        }
        restoreTask?.cancel()
        restoreTask = Task { [weak self] in
            let nanos = UInt64(max(duration, 0.2) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.restoreIfDue()
            }
        }
    }

    private func restoreIfDue() {
        guard isCaptureHidden else { return }
        if let hideUntil, Date() < hideUntil { return }
        isCaptureHidden = false
        hideUntil = nil
        onHideChanged?(false)
        AskLog.line("capture restore")
    }
}

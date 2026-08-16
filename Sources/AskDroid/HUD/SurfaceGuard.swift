import AppKit
import CoreGraphics

/// Hides the passive pill from screenshots and fullscreen covers.
/// An explicit user present always wins.
@MainActor
final class SurfaceGuard {
    private weak var panel: NSWindow?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var hideUntil: Date?
    private var restoreTask: Task<Void, Never>?
    private var suppressedBundleID: String?
    private(set) var isHidden = false

    var onHideChanged: ((Bool) -> Void)?

    nonisolated static let screenshotBundleIDs: Set<String> = [
        "com.apple.screencaptureui",
        "com.apple.screenshot.launcher",
        "com.apple.Screenshot",
    ]

    static var isDisabled: Bool {
        ProcessInfo.processInfo.environment["ASKDROID_ALLOW_CAPTURE"] == "1"
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
        switch keyCode {
        case 20, 21, 23: return true
        default: return false
        }
    }

    nonisolated static func shouldHideForBundle(_ id: String?) -> Bool {
        guard let id else { return false }
        return screenshotBundleIDs.contains(id)
    }

    nonisolated static func shouldHidePassiveSurface(captureHidden: Bool, fullscreenCovered: Bool, userSummoned: Bool) -> Bool {
        guard !userSummoned else { return false }
        return captureHidden || fullscreenCovered
    }

    func hideForCapture(duration: TimeInterval) {
        let until = Date().addingTimeInterval(duration)
        hideUntil = max(hideUntil ?? .distantPast, until)
        refresh()
        scheduleTimedRestore()
    }

    private func handleActivation(_ bundleID: String?) {
        suppressedBundleID = Self.shouldHideForBundle(bundleID) ? bundleID : nil
        refresh()
    }

    private func scheduleTimedRestore() {
        restoreTask?.cancel()
        guard let hideUntil else { return }
        let delay = max(hideUntil.timeIntervalSinceNow, 0.2)
        restoreTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.timedHideExpired() }
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
        if shouldHide, !isHidden {
            isHidden = true
            panel?.orderOut(nil)
            onHideChanged?(true)
            AskLog.line("capture hide")
        } else if !shouldHide, isHidden {
            isHidden = false
            onHideChanged?(false)
            AskLog.line("capture restore")
        }
    }
}

enum DisplayOccupation {
    static func coversScreen(_ bounds: CGRect, screen: CGRect, tolerance: CGFloat = 4) -> Bool {
        bounds.width + tolerance >= screen.width && bounds.height + tolerance >= screen.height - 8
    }

    static func isForeignFullscreen(
        bounds: CGRect,
        screen: CGRect,
        layer: Int,
        ownerPID: pid_t,
        ourPID: pid_t
    ) -> Bool {
        guard ownerPID != ourPID, ownerPID != 0, layer <= 0 else { return false }
        return coversScreen(bounds, screen: screen)
    }

    static func frontmostCovers(_ screen: NSScreen, ourPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> Bool {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        guard frontPID != 0, frontPID != ourPID else { return false }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        guard let windows = info as? [[String: Any]] else { return false }
        let screenFrame = screen.frame
        for window in windows {
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let owner = window[kCGWindowOwnerPID as String] as? pid_t ?? 0
            guard owner == frontPID else { continue }
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat] ??
                (window[kCGWindowBounds as String] as? NSDictionary) as? [String: CGFloat]
            else { continue }
            let candidate = CGRect(x: 0, y: 0, width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0)
            let quartzScreen = CGRect(x: 0, y: 0, width: screenFrame.width, height: screenFrame.height)
            if isForeignFullscreen(
                bounds: candidate,
                screen: quartzScreen,
                layer: layer,
                ownerPID: owner,
                ourPID: ourPID
            ) {
                return true
            }
        }
        return false
    }
}

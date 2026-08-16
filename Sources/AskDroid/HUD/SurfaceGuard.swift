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
                self.hideForCapture(duration: Self.captureHideDuration(for: event.keyCode))
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

    /// How long a screenshot chord keeps the surface hidden. ⌘⇧4 opens a
    /// region selection the user can drag for several seconds and there is no
    /// app to observe while it is in progress, so it gets a longer timer.
    /// ⌘⇧5 is covered by the suppressed-until-resign state once Screenshot.app
    /// activates, so its chord timer only bridges that gap.
    nonisolated static func captureHideDuration(for keyCode: UInt16) -> TimeInterval {
        switch keyCode {
        case 21: return 8 // ⌘⇧4 region selection
        default: return 1.4 // ⌘⇧3 instant capture; ⌘⇧5 handled on activation
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
        // The restore task always wakes at or after the latest hideUntil:
        // scheduleTimedRestore cancels any prior task and re-arms with the
        // current deadline, so there is no early-wake path here.
        hideUntil = nil
        refresh()
    }

    private func refresh() {
        let timedActive = hideUntil.map { Date() < $0 } ?? false
        let shouldHide = timedActive || suppressedBundleID != nil
        if shouldHide, !isHidden {
            // Only flip state; NotchPanelController decides whether to actually
            // order the panel out, so an explicitly summoned (expanded) HUD is
            // never hidden by a capture.
            isHidden = true
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
        // Width/height alone match any same-sized display, so a fullscreen
        // window on an identical monitor must not count as covering this one.
        guard coversScreen(bounds, screen: screen) else { return false }
        let overlap = bounds.intersection(screen)
        return !overlap.isNull && overlap.width > 1 && overlap.height > 1
    }

    static func frontmostCovers(_ screen: NSScreen, ourPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> Bool {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        guard frontPID != 0, frontPID != ourPID else { return false }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        guard let windows = info as? [[String: Any]] else { return false }
        // Window-list bounds live in Quartz's top-left-origin global space, so
        // compare against the display's bounds in that same space (origin
        // included) rather than AppKit screen coordinates.
        let quartzScreen: CGRect
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            quartzScreen = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        } else {
            quartzScreen = CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height)
        }
        for window in windows {
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let owner = window[kCGWindowOwnerPID as String] as? pid_t ?? 0
            guard owner == frontPID else { continue }
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat] ??
                (window[kCGWindowBounds as String] as? NSDictionary) as? [String: CGFloat]
            else { continue }
            let candidate = CGRect(x: 0, y: 0, width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0)
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

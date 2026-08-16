import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class NotchPanelController {
    private let session: AskSession
    private let panel: HUDWindow
    private let chrome: HUDChromeView
    private let hosting: NSHostingView<HUDRootView>
    private var localMonitor: Any?
    private var pinnedDisplayID: UInt32?
    private var lastLoggedFrame = NSRect.zero
    private var lastLoggedScreen = ""
    private var guardSurface: SurfaceGuard?
    private var lastMetrics: NotchMetrics?
    private var lastAppliedSize: CGSize?
    private var wasExpanded = false
    private var spaceObservers: [NSObjectProtocol] = []

    var debugDescription: String {
        let responder = String(describing: type(of: panel.firstResponder ?? NSNull()))
        return "visible=\(panel.isVisible) key=\(panel.isKeyWindow) alpha=\(panel.alphaValue) frame=\(panel.frame) screen=\(targetScreen().localizedName) responder=\(responder)"
    }

    init(session: AskSession) {
        self.session = session

        let chrome = HUDChromeView(frame: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 260))
        chrome.wantsLayer = true
        chrome.layer?.backgroundColor = NSColor.clear.cgColor
        chrome.layer?.isOpaque = false
        chrome.layer?.masksToBounds = true
        self.chrome = chrome

        let hosting = NSHostingView(rootView: HUDRootView(session: session, metrics: .from(
            screenFrame: CGRect(x: 0, y: 0, width: Theme.panelWidth, height: 260),
            visibleFrame: CGRect(x: 0, y: 0, width: Theme.panelWidth, height: 260),
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil,
            safeAreaTop: 0
        )))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        hosting.safeAreaRegions = []
        hosting.sizingOptions = []
        hosting.frame = chrome.bounds
        hosting.autoresizingMask = [.width, .height]
        chrome.addSubview(hosting)
        self.hosting = hosting

        let panel = HUDWindow(
            contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 260),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.alphaValue = 1
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.contentView = chrome
        self.panel = panel
        panel.onPasteImages = { [weak session] in
            session?.attachFromPasteboard() ?? false
        }
        panel.onRequestFocus = { [weak self] in
            self?.focusEditor(activate: false)
        }

        chrome.clickThroughGap = { [weak self] point in
            self?.isCameraGap(point) ?? false
        }

        let guardSurface = SurfaceGuard(panel: panel)
        guardSurface.onHideChanged = { [weak self] hidden in
            guard let self, !hidden else { return }
            self.updateVisibility()
        }
        self.guardSurface = guardSurface

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.updateVisibility()
                }
            }
            spaceObservers.append(token)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                if HotkeyCenter.shared.isRecordingShortcut { return event }
                self.session.dismiss()
                return nil
            }
            return event
        }
    }

    func pinToCurrentScreen() {
        guard let screen = preferredScreen() else { return }
        pinToScreen(screen)
    }

    func pinToScreen(_ screen: NSScreen) {
        pinnedDisplayID = displayID(of: screen)
        lastMetrics = nil
        lastAppliedSize = nil
        AskLog.line("pin screen=\(screen.localizedName) id=\(pinnedDisplayID ?? 0) notch=\(NotchMetrics.from(screen: screen).hasNotch)")
    }

    func refreshPinning() {
        if let notched = screenWithHardwareNotch(), pinnedDisplayID != displayID(of: notched) {
            pinToScreen(notched)
        } else if let id = pinnedDisplayID,
                  !NSScreen.screens.contains(where: { displayID(of: $0) == id }) {
            pinToCurrentScreen()
        }
        reposition()
    }

    func updateVisibility() {
        let userSummoned = session.isExpanded
        let captureHidden = guardSurface?.isHidden == true
        let fullscreen = !SurfaceGuard.isDisabled && DisplayOccupation.frontmostCovers(targetScreen())
        if SurfaceGuard.shouldHidePassiveSurface(
            captureHidden: captureHidden,
            fullscreenCovered: fullscreen,
            userSummoned: userSummoned
        ) {
            panel.orderOut(nil)
            if fullscreen { AskLog.line("hide for fullscreen") }
            return
        }
        if session.isExpanded {
            let newlyExpanded = !wasExpanded
            wasExpanded = true
            showExpanded(shouldStealFocus: newlyExpanded)
            return
        }
        wasExpanded = false
        if session.phase == .running || session.phase == .completed || session.phase == .failed {
            showPill()
        } else {
            hide()
        }
    }

    func reposition() {
        applySize(measuredSize())
    }

    private func showExpanded(shouldStealFocus: Bool) {
        applySize(measuredSize())
        panel.alphaValue = 1
        if shouldStealFocus {
            stealFocus()
            focusEditorSoon()
        } else {
            panel.orderFrontRegardless()
        }
        AskLog.line("showExpanded \(debugDescription)")
    }

    private func showPill() {
        applySize(measuredSize())
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        AskLog.line("showPill \(debugDescription)")
    }

    private func hide() {
        panel.orderOut(nil)
        AskLog.line("hide")
    }

    private func stealFocus() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
    }

    private func displayID(of screen: NSScreen) -> UInt32 {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return number.uint32Value
        }
        return 0
    }

    private func targetScreen() -> NSScreen {
        if let id = pinnedDisplayID,
           let match = NSScreen.screens.first(where: { displayID(of: $0) == id })
        {
            return match
        }
        let fallback = preferredScreen() ?? NSScreen.screens[0]
        pinnedDisplayID = displayID(of: fallback)
        return fallback
    }

    private func screenWithHardwareNotch() -> NSScreen? {
        NSScreen.screens.first(where: { NotchMetrics.from(screen: $0).hasNotch })
    }

    private func preferredScreen() -> NSScreen? {
        if let notched = screenWithHardwareNotch() {
            return notched
        }
        return screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func currentMetrics() -> NotchMetrics {
        NotchMetrics.from(screen: targetScreen())
    }

    private func contentHeight() -> CGFloat {
        if session.isSettingsOpen { return Theme.settingsContentHeight }
        var height = Theme.composerContentHeight
        if !session.images.isEmpty { height += Theme.imageStripHeight }
        if session.phase == .running || session.phase == .failed || !session.answer.isEmpty {
            height += Theme.answerBlockHeight
        }
        return height
    }

    private func measuredSize() -> CGSize {
        let metrics = currentMetrics()
        if session.isExpanded {
            return metrics.expandedSize(contentHeight: contentHeight())
        }
        return metrics.compactSize
    }

    private func applySize(_ size: CGSize) {
        let screen = targetScreen()
        let metrics = currentMetrics()
        let metricsChanged = metrics != lastMetrics
        let sizeChanged = size != lastAppliedSize
        guard metricsChanged || sizeChanged else { return }

        if metricsChanged {
            lastMetrics = metrics
            hosting.rootView = HUDRootView(session: session, metrics: metrics)
        }
        var next = metrics.frame(
            for: CGSize(width: size.width.rounded(), height: size.height.rounded()),
            expanded: session.isExpanded
        )
        if !screen.frame.intersects(next) {
            next.origin.x = screen.frame.midX - next.width / 2
            next.origin.y = screen.frame.maxY - next.height
        }
        chrome.frame = NSRect(x: 0, y: 0, width: next.width, height: next.height)
        hosting.frame = chrome.bounds
        panel.hasShadow = !metrics.hasNotch
        animateFrame(to: next)
        lastAppliedSize = size
        let screenName = screen.localizedName
        if next != lastLoggedFrame || screenName != lastLoggedScreen {
            lastLoggedFrame = next
            lastLoggedScreen = screenName
            AskLog.line("place frame=\(next) notch=\(metrics.hasNotch) screen=\(screenName)")
        }
    }

    private func isCameraGap(_ point: NSPoint) -> Bool {
        guard !session.isExpanded else { return false }
        let metrics = currentMetrics()
        guard metrics.hasNotch else { return false }
        return NSRect(
            x: metrics.compactLeadingWidth,
            y: 0,
            width: metrics.notchWidth,
            height: panel.frame.height
        ).contains(point)
    }

    private func animateFrame(to next: NSRect) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.12 : 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = !reduceMotion
            panel.animator().setFrame(next, display: true)
        }
    }

    private func focusEditorSoon() {
        focusEditor(activate: true)
        DispatchQueue.main.async { [weak self] in
            self?.focusEditor(activate: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.focusEditor(activate: false)
        }
    }

    private func focusEditor(activate: Bool) {
        guard session.isExpanded, !session.isSettingsOpen else { return }
        if activate {
            stealFocus()
        }
        if let textView = findTextView(), panel.firstResponder !== textView {
            panel.makeFirstResponder(textView)
        }
        NotificationCenter.default.post(name: .askDroidFocusInput, object: nil)
    }

    private func findTextView() -> NSTextView? {
        func search(_ view: NSView?) -> NSTextView? {
            guard let view else { return nil }
            if let textView = view as? NSTextView, textView.identifier == .askDroidPrompt {
                return textView
            }
            for child in view.subviews {
                if let found = search(child) { return found }
            }
            return nil
        }
        return search(panel.contentView)
    }
}

final class HUDChromeView: NSView {
    var clickThroughGap: ((NSPoint) -> Bool)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        if clickThroughGap?(point) == true { return nil }
        return super.hitTest(point)
    }
}

final class HUDWindow: NSWindow {
    var onPasteImages: (() -> Bool)?
    var onRequestFocus: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isDocumentEdited: Bool {
        get { false }
        set {}
    }

    override func mouseDown(with event: NSEvent) {
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        if !isKeyWindow {
            makeKeyAndOrderFront(nil)
        }
        super.mouseDown(with: event)
        onRequestFocus?()
    }

    @objc func save(_ sender: Any?) {}
    @objc func saveDocument(_ sender: Any?) {}
    @objc func saveDocumentAs(_ sender: Any?) {}
    @objc func saveDocumentTo(_ sender: Any?) {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        if event.type == .keyDown, command, event.charactersIgnoringModifiers == "s" {
            return true
        }
        if event.type == .keyDown,
           command,
           event.charactersIgnoringModifiers == "v",
           !AttachedImage.fromPasteboard().isEmpty
        {
            _ = onPasteImages?()
            if NSPasteboard.general.string(forType: .string) == nil {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

extension NSUserInterfaceItemIdentifier {
    static let askDroidPrompt = NSUserInterfaceItemIdentifier("AskDroidPrompt")
}

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
    private var hoverTask: Task<Void, Never>?
    private var capturePrivacy: CapturePrivacy?
    private var metricsOverride: NotchMetrics?
    private var suppressFrameAnimation = false

    var debugDescription: String {
        let responder = String(describing: type(of: panel.firstResponder ?? NSNull()))
        return "visible=\(panel.isVisible) key=\(panel.isKeyWindow) alpha=\(panel.alphaValue) frame=\(panel.frame) screen=\(targetScreen().localizedName) responder=\(responder)"
    }

    init(session: AskSession) {
        self.session = session

        let chrome = HUDChromeView(frame: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 260))
        chrome.wantsLayer = true
        chrome.layer?.backgroundColor = NSColor.clear.cgColor
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
        chrome.registerForDraggedTypes([
            .png, .tiff, .fileURL,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.gif"),
            NSPasteboard.PasteboardType("public.webp"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
        ])
        chrome.onDropPasteboard = { [weak session] pasteboard in
            session?.attachFromPasteboard(pasteboard) ?? false
        }
        panel.onPasteImages = { [weak session] in
            session?.attachFromPasteboard() ?? false
        }
        panel.onRequestFocus = { [weak self] in
            self?.session.promoteHoverToUser()
            self?.focusEditor(activate: false)
        }

        chrome.onHoverChanged = { [weak self] hovering in
            self?.handleHover(hovering)
        }

        let privacy = CapturePrivacy(panel: panel)
        privacy.onHideChanged = { [weak self] hidden in
            guard let self, !hidden else { return }
            self.updateVisibility()
        }
        self.capturePrivacy = privacy

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.session.dismiss()
                return nil
            }
            return event
        }
    }

    func pinToCurrentScreen() {
        let screen = screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        pinnedDisplayID = displayID(of: screen)
        AskLog.line("pin screen=\(screen.localizedName) id=\(pinnedDisplayID ?? 0)")
    }

    func updateVisibility() {
        if capturePrivacy?.isCaptureHidden == true {
            panel.orderOut(nil)
            return
        }
        if session.isExpanded {
            showExpanded()
            return
        }
        if session.phase == .running || session.phase == .completed || session.phase == .failed {
            showPill()
        } else {
            hide()
        }
    }

    func reposition() {
        applySize(measuredSize())
    }

    private func showExpanded() {
        applySize(measuredSize())
        panel.alphaValue = 1
        if session.presentSource == .user {
            stealFocus()
            focusEditorSoon()
        } else {
            panel.orderFrontRegardless()
        }
        AskLog.line("showExpanded source=\(session.presentSource) \(debugDescription)")
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
        let fallback = screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens[0]
        pinnedDisplayID = displayID(of: fallback)
        return fallback
    }

    func useMarketingNotchForScreenshots() {
        metricsOverride = .marketing
        suppressFrameAnimation = true
    }

    func snapshotPNG() -> Data? {
        panel.displayIfNeeded()
        chrome.layoutSubtreeIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        let bounds = chrome.bounds
        guard bounds.width > 2, bounds.height > 2,
              let hud = chrome.bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }
        chrome.cacheDisplay(in: bounds, to: hud)

        let pad: CGFloat = 28
        let canvas = NSSize(width: bounds.width + pad * 2, height: bounds.height + pad * 2)
        let scale = max(panel.backingScaleFactor, 2)
        guard let paper = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((canvas.width * scale).rounded()),
            pixelsHigh: Int((canvas.height * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        paper.size = canvas
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: paper)
        NSColor(calibratedWhite: 0.82, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: canvas)).fill()
        hud.draw(in: NSRect(x: pad, y: pad, width: bounds.width, height: bounds.height))
        NSGraphicsContext.restoreGraphicsState()
        return paper.representation(using: .png, properties: [:])
    }

    private func currentMetrics() -> NotchMetrics {
        let screen = targetScreen()
        if let metricsOverride {
            return metricsOverride.placed(on: screen)
        }
        return NotchMetrics.from(screen: screen)
    }

    private func contentHeight() -> CGFloat {
        var height: CGFloat = session.isSettingsOpen ? 560 : 280
        if !session.images.isEmpty { height += 72 }
        if !session.answer.isEmpty || !session.thinking.isEmpty || !session.runLog.isEmpty || session.phase == .running || session.phase == .failed {
            height += 220
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
        hosting.rootView = HUDRootView(session: session, metrics: metrics)
        var next = metrics.frame(for: CGSize(width: size.width.rounded(), height: size.height.rounded()), expanded: session.isExpanded)
        if !screen.frame.intersects(next) {
            next.origin.x = screen.frame.midX - next.width / 2
            next.origin.y = screen.frame.maxY - next.height
        }
        chrome.frame = NSRect(x: 0, y: 0, width: next.width, height: next.height)
        hosting.frame = chrome.bounds
        panel.hasShadow = !metrics.hasNotch
        animateFrame(to: next)
        let screenName = screen.localizedName
        if next != lastLoggedFrame || screenName != lastLoggedScreen {
            lastLoggedFrame = next
            lastLoggedScreen = screenName
            AskLog.line("place frame=\(next) notch=\(metrics.hasNotch) screen=\(screenName)")
        }
    }

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let delay = hovering ? 0.16 : 0.28
        hoverTask = Task { [weak self] in
            if !reduceMotion {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self else { return }
            if hovering {
                let canPeek = !self.session.isExpanded
                    && (self.session.phase == .running || self.session.phase == .completed || self.session.phase == .failed)
                if canPeek {
                    self.session.present(source: .hover)
                    self.updateVisibility()
                }
            } else {
                self.session.dismissHoverIfNeeded()
                self.updateVisibility()
            }
        }
    }

    private func animateFrame(to next: NSRect) {
        if suppressFrameAnimation {
            panel.setFrame(next, display: true)
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            if reduceMotion {
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            } else {
                // Underdamped ease so the window overshoots slightly like Island jelly.
                context.duration = 0.42
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.18, 0.32, 1)
            }
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
            if let textView = view as? NSTextView,
               textView.identifier == .askDroidPrompt
            {
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
    var onDropPasteboard: ((NSPasteboard) -> Bool)?
    var onHoverChanged: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
        super.mouseExited(with: event)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        AttachedImage.fromPasteboard(sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        AttachedImage.fromPasteboard(sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onDropPasteboard?(sender.draggingPasteboard) ?? false
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

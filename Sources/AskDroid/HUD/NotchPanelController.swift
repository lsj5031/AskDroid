import AppKit
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

    var debugDescription: String {
        let responder = String(describing: type(of: panel.firstResponder ?? NSNull()))
        return "visible=\(panel.isVisible) key=\(panel.isKeyWindow) alpha=\(panel.alphaValue) frame=\(panel.frame) screen=\(targetScreen().localizedName) responder=\(responder)"
    }

    init(session: AskSession) {
        self.session = session

        let chrome = HUDChromeView(frame: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 260))
        chrome.wantsLayer = true
        chrome.layer?.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.075, alpha: 1).cgColor
        chrome.layer?.cornerRadius = Theme.panelCorner
        chrome.layer?.masksToBounds = true
        self.chrome = chrome

        let hosting = NSHostingView(rootView: HUDRootView(session: session))
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
        panel.isOpaque = true
        panel.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.075, alpha: 1)
        panel.hasShadow = true
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
            self?.focusEditor(activate: false)
        }

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
        stealFocus()
        focusEditorSoon()
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
        let fallback = screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens[0]
        pinnedDisplayID = displayID(of: fallback)
        return fallback
    }

    private func measuredSize() -> CGSize {
        if session.isExpanded {
            var height: CGFloat = session.isSettingsOpen ? 560 : 280
            if !session.images.isEmpty { height += 72 }
            if !session.answer.isEmpty || !session.thinking.isEmpty || !session.runLog.isEmpty || session.phase == .running || session.phase == .failed {
                height += 220
            }
            return CGSize(width: Theme.panelWidth, height: min(height, 640))
        }
        return CGSize(width: Theme.pillWidth, height: Theme.pillHeight)
    }

    private func applySize(_ size: CGSize) {
        let screen = targetScreen()
        let visible = screen.visibleFrame
        let width = min(size.width.rounded(), visible.width - 24)
        let height = min(size.height.rounded(), visible.height - 24)
        let x = visible.midX - width / 2
        let y = min(visible.maxY - height - 16, visible.maxY - height)
        var next = NSRect(x: x, y: max(visible.minY + 8, y), width: width, height: height)
        if !visible.intersects(next) {
            next.origin.x = visible.midX - width / 2
            next.origin.y = visible.midY - height / 2
        }
        chrome.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.frame = chrome.bounds
        panel.setFrame(next, display: true)
        let screenName = screen.localizedName
        if next != lastLoggedFrame || screenName != lastLoggedScreen {
            lastLoggedFrame = next
            lastLoggedScreen = screenName
            AskLog.line("place frame=\(next) visible=\(visible) screen=\(screenName)")
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

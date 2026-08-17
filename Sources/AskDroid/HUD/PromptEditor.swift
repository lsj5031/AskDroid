import AppKit
import SwiftUI

/// AppKit-backed prompt field. AppKit owns text editing, image-paste handling,
/// the ⌘↩ submission, and drawing the placeholder *at the insertion point* so
/// the caret and placeholder share one origin. SwiftUI owns the visual chrome
/// (well fill and focus border), driven by the focus callback this view
/// reports up.
struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onPasteImages: () -> Void
    var onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onPasteImages: onPasteImages,
            onFocusChange: onFocusChange
        )
    }

    func makeNSView(context: Context) -> InputScrollView {
        let scroll = InputScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.focusRingType = .none
        scroll.scrollerStyle = .overlay

        let textView = InputTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onPasteImages = onPasteImages
        textView.onFocusChange = context.coordinator.focusChanged
        textView.placeholder = placeholder
        textView.identifier = .askDroidPrompt
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        textView.textColor = NSColor.white.withAlphaComponent(0.92)
        textView.insertionPointColor = NSColor(red: 0.98, green: 0.62, blue: 0.18, alpha: 1)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(red: 0.98, green: 0.62, blue: 0.18, alpha: 0.28),
            .foregroundColor: NSColor.white,
        ]
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: Theme.fieldInset, height: Theme.fieldVerticalInset)
        textView.string = text
        textView.isEditable = true
        textView.isSelectable = true
        textView.usesFindBar = false
        textView.focusRingType = .none
        textView.isAutomaticTextCompletionEnabled = false
        textView.allowsDocumentBackgroundColorChange = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        context.coordinator.textView = textView

        scroll.documentView = textView
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width - textView.textContainerInset.width * 2,
            height: CGFloat.greatestFiniteMagnitude
        )

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.focusEditor),
            name: .askDroidFocusInput,
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.resetEditor),
            name: .askDroidResetComposer,
            object: nil
        )
        return scroll
    }

    func updateNSView(_ nsView: InputScrollView, context: Context) {
        guard let textView = nsView.documentView as? InputTextView else { return }
        context.coordinator.textView = textView
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onPasteImages = onPasteImages
        context.coordinator.onFocusChange = onFocusChange
        textView.onSubmit = onSubmit
        textView.onPasteImages = onPasteImages
        textView.onFocusChange = context.coordinator.focusChanged
        textView.placeholder = placeholder
        if textView.string != text, textView.window?.firstResponder !== textView {
            let selected = textView.selectedRange()
            textView.string = text
            let clamped = NSRange(
                location: min(selected.location, textView.string.utf16.count),
                length: 0
            )
            textView.setSelectedRange(clamped)
        }
        let width = max(0, nsView.contentView.bounds.width - textView.textContainerInset.width * 2)
        if width > 0 {
            textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        nsView.invalidateIntrinsicContentSize()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void
        var onPasteImages: () -> Void
        var onFocusChange: (Bool) -> Void
        weak var textView: InputTextView?

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onPasteImages: @escaping () -> Void,
            onFocusChange: @escaping (Bool) -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onPasteImages = onPasteImages
            self.onFocusChange = onFocusChange
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            // The field hugs its content; re-report its ideal height so the
            // SwiftUI frame (and the panel that measures it) follow the text.
            textView.enclosingScrollView?.invalidateIntrinsicContentSize()
        }

        func focusChanged(_ focused: Bool) {
            onFocusChange(focused)
        }

        @objc func focusEditor() {
            guard let textView else { return }
            textView.window?.makeKey()
            if textView.window?.firstResponder !== textView {
                textView.window?.makeFirstResponder(textView)
            }
        }

        @objc func resetEditor() {
            guard let textView, textView.string != text.wrappedValue else { return }
            textView.string = text.wrappedValue
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }
}

final class InputScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { false }

    /// Ideal height = the laid-out text height plus the field's top/bottom
    /// insets, so SwiftUI can size the field to its content and grow it as the
    /// user types instead of reserving a fixed tall box.
    override var intrinsicContentSize: NSSize {
        guard let textView = documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let lineHeight = used.height > 0 ? used.height : layoutManager.extraLineFragmentRect.height
        let height = lineHeight + textView.textContainerInset.height * 2
        return NSSize(width: NSView.noIntrinsicMetric, height: max(0, height))
    }
}

final class InputTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onPasteImages: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    /// Placeholder shown only while the field is empty. Drawn by this view at
    /// the insertion point (see `drawPlaceholderIfNeeded`) so it always lines
    /// up with the caret instead of relying on an overlay's magic padding.
    var placeholder = "" {
        didSet {
            guard placeholder != oldValue else { return }
            needsDisplay = true
        }
    }

    private var windowObservers: [NSObjectProtocol] = []
    private var lastReportedFocus: Bool?

    override var acceptsFirstResponder: Bool { true }

    @objc func save(_ sender: Any?) {}
    @objc func saveDocument(_ sender: Any?) {}
    @objc func saveDocumentAs(_ sender: Any?) {}
    @objc func saveDocumentTo(_ sender: Any?) {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            windowObservers.removeAll()
            return
        }
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportFocus() }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportFocus() }
            },
        ]
        reportFocus()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
            self.reportFocus()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        // The window's firstResponder is not updated until after this method
        // returns, so defer the focus report to the next runloop turn.
        DispatchQueue.main.async { [weak self] in self?.reportFocus() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.reportFocus() }
        return accepted
    }

    /// The field has no system focus ring; report whether the text view is the
    /// key window's first responder so the SwiftUI chrome can switch its
    /// hairline to an accent color. Kept here (not in SwiftUI `.focused`)
    /// because the AppKit text view owns the real first-responder state.
    private func reportFocus() {
        let focused = window?.isKeyWindow == true && window?.firstResponder === self
        guard lastReportedFocus != focused else { return }
        lastReportedFocus = focused
        onFocusChange?(focused)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawPlaceholderIfNeeded()
    }

    private func drawPlaceholderIfNeeded() {
        guard string.isEmpty, !placeholder.isEmpty, let layoutManager else { return }
        // Reuse the layout manager's extra line fragment (the line that hosts
        // the insertion point when the string is empty) so the placeholder and
        // caret share the exact same origin.
        let origin = NSPoint(
            x: textContainerOrigin.x + layoutManager.extraLineFragmentRect.minX,
            y: textContainerOrigin.y + layoutManager.extraLineFragmentRect.minY
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.56),
        ]
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        if command && (event.keyCode == 36 || event.keyCode == 76) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let hasImages = !AttachedImage.fromPasteboard().isEmpty
        if hasImages {
            onPasteImages?()
        }
        if NSPasteboard.general.string(forType: .string) != nil {
            super.paste(sender)
        }
    }

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
            onPasteImages?()
            if NSPasteboard.general.string(forType: .string) == nil {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

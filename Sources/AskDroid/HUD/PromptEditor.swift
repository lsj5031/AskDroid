import AppKit
import SwiftUI

struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onPasteImages: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onPasteImages: onPasteImages)
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
        textView.textContainerInset = NSSize(width: 0, height: 4)
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
            width: scroll.contentSize.width,
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
        textView.onSubmit = onSubmit
        textView.onPasteImages = onPasteImages
        if textView.string != text, textView.window?.firstResponder !== textView {
            let selected = textView.selectedRange()
            textView.string = text
            let clamped = NSRange(
                location: min(selected.location, textView.string.utf16.count),
                length: 0
            )
            textView.setSelectedRange(clamped)
        }
        let width = nsView.contentView.bounds.width
        if width > 0 {
            textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void
        var onPasteImages: () -> Void
        weak var textView: InputTextView?

        init(text: Binding<String>, onSubmit: @escaping () -> Void, onPasteImages: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
            self.onPasteImages = onPasteImages
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
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
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 84) }
}

final class InputTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onPasteImages: (() -> Void)?
    private var windowObservers: [NSObjectProtocol] = []

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
                MainActor.assumeIsolated { self?.updateFocusAppearance() }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateFocusAppearance() }
            },
        ]
        updateFocusAppearance()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
            self.updateFocusAppearance()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        updateFocusAppearance()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        updateFocusAppearance()
        return accepted
    }

    /// The composer's field has no system focus ring; draw an amber hairline
    /// around the scroll area while the text view is the key window's
    /// first responder so keyboard users can see where they are.
    private func updateFocusAppearance() {
        guard let scroll = enclosingScrollView else { return }
        let focused = window?.isKeyWindow == true && window?.firstResponder === self
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = focused
            ? NSColor(red: 0.98, green: 0.62, blue: 0.18, alpha: 0.85).cgColor
            : NSColor.clear.cgColor
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

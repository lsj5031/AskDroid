import AppKit
import SwiftUI

struct HotkeyRecorder: View {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32
    @State private var listening = false

    var body: some View {
        Button {
            listening.toggle()
        } label: {
            Text(listening ? "Press a shortcut…" : HotkeyCodec.display(keyCode: keyCode, modifiers: modifiers))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(listening ? Theme.accent : Color.clear, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hotkey")
        .background(HotkeyCatcher(isActive: $listening, keyCode: $keyCode, modifiers: $modifiers))
    }
}

private struct HotkeyCatcher: NSViewRepresentable {
    @Binding var isActive: Bool
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onCapture = { code, mods in
            keyCode = code
            modifiers = mods
            isActive = false
        }
        view.onCancel = { isActive = false }
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.isArmed = isActive
        HotkeyCenter.shared.isRecordingShortcut = isActive
        if isActive {
            nsView.window?.makeFirstResponder(nsView)
        } else if nsView.window?.firstResponder === nsView {
            nsView.window?.makeFirstResponder(nil)
        }
    }

    final class CatcherView: NSView {
        var isArmed = false
        var onCapture: ((UInt32, UInt32) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned, isArmed {
                isArmed = false
                HotkeyCenter.shared.isRecordingShortcut = false
                onCancel?()
            }
            return resigned
        }

        override func keyDown(with event: NSEvent) {
            guard isArmed else {
                super.keyDown(with: event)
                return
            }
            if event.keyCode == 53 {
                isArmed = false
                HotkeyCenter.shared.isRecordingShortcut = false
                onCancel?()
                return
            }
            guard !(54...63).contains(Int(event.keyCode)) else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var mods: UInt32 = 0
            if flags.contains(.command) { mods |= HotkeyCodec.command }
            if flags.contains(.control) { mods |= HotkeyCodec.control }
            if flags.contains(.option) { mods |= HotkeyCodec.option }
            if flags.contains(.shift) { mods |= HotkeyCodec.shift }
            guard mods & (HotkeyCodec.command | HotkeyCodec.control | HotkeyCodec.option) != 0 else { return }
            isArmed = false
            HotkeyCenter.shared.isRecordingShortcut = false
            onCapture?(UInt32(event.keyCode), mods)
        }
    }
}

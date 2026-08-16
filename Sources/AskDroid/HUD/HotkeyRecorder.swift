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
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.isArmed = isActive
    }

    final class CatcherView: NSView {
        var isArmed = false
        var onCapture: ((UInt32, UInt32) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, self.isArmed else { return event }
                    if event.keyCode == 53 {
                        self.isArmed = false
                        return nil
                    }
                    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    var mods: UInt32 = 0
                    if flags.contains(.command) { mods |= HotkeyCodec.command }
                    if flags.contains(.control) { mods |= HotkeyCodec.control }
                    if flags.contains(.option) { mods |= HotkeyCodec.option }
                    if flags.contains(.shift) { mods |= HotkeyCodec.shift }
                    guard mods != 0 else { return nil }
                    self.onCapture?(UInt32(event.keyCode), mods)
                    return nil
                }
            }
        }
    }
}

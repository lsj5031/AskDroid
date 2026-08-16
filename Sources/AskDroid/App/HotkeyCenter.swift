import AppKit
import Carbon

@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var hotKeyRef: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var callback: (() -> Void)?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastFire: Date = .distantPast
    private var keyCode: UInt32 = AppSettings.defaultHotkeyKeyCode
    private var modifiers: UInt32 = AppSettings.defaultHotkeyModifiers
    /// Settings recorder is capturing a new shortcut; swallow neither Esc nor the current hotkey.
    var isRecordingShortcut = false

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler callback: @escaping () -> Void) -> OSStatus {
        unregister()
        self.callback = callback
        self.keyCode = keyCode
        self.modifiers = modifiers

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let installStatus = InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let userData else { return noErr }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if hotKeyID.id == 1 {
                DispatchQueue.main.async {
                    center.fire(source: "carbon")
                }
            }
            return noErr
        }, 1, &eventType, userData, &handler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x41534B44), id: 1) // ASKD
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
        AskLog.line("hotkey carbon install=\(installStatus) register=\(registerStatus) key=\(keyCode) mods=\(modifiers)")
        if registerStatus != noErr {
            AskLog.line("hotkey carbon failed; NSEvent monitors are the fallback")
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleMonitor(event, source: "global")
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.isRecordingShortcut else { return event }
            if self.isConfiguredHotkey(event) {
                self.fire(source: "local")
                return nil
            }
            return event
        }
        return registerStatus
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func handleMonitor(_ event: NSEvent, source: String) {
        guard isConfiguredHotkey(event) else { return }
        fire(source: source)
    }

    private func isConfiguredHotkey(_ event: NSEvent) -> Bool {
        guard event.keyCode == UInt16(keyCode) else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let wantCommand = modifiers & HotkeyCodec.command != 0
        let wantControl = modifiers & HotkeyCodec.control != 0
        let wantOption = modifiers & HotkeyCodec.option != 0
        let wantShift = modifiers & HotkeyCodec.shift != 0
        return flags.contains(.command) == wantCommand
            && flags.contains(.control) == wantControl
            && flags.contains(.option) == wantOption
            && flags.contains(.shift) == wantShift
    }

    private func fire(source: String) {
        guard !isRecordingShortcut else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFire) > 0.2 else { return }
        lastFire = now
        AskLog.line("hotkey \(source)")
        callback?()
    }
}

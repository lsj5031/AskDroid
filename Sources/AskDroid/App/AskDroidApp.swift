import AppKit
import Combine
import UserNotifications

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    let session = AskSession()
    private var panel: NotchPanelController?
    private var cancellables: Set<AnyCancellable> = []

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        AskLog.line("launch pid=\(ProcessInfo.processInfo.processIdentifier)")
        prepareSupportDirectories()

        let controller = NotchPanelController(session: session)
        panel = controller
        registerHotkey()
        session.present()
        controller.pinToCurrentScreen()
        controller.updateVisibility()
        AskLog.line("presented on launch \(controller.debugDescription)")

        Publishers.CombineLatest3(session.$isExpanded, session.$phase, session.$isSettingsOpen)
            .dropFirst()
            .removeDuplicates { lhs, rhs in
                lhs.0 == rhs.0 && lhs.1 == rhs.1 && lhs.2 == rhs.2
            }
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.panel?.updateVisibility()
            }
            .store(in: &cancellables)

        session.$images
            .map(\.count)
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.panel?.reposition()
            }
            .store(in: &cancellables)

        session.$answer
            .map { !$0.isEmpty }
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.panel?.reposition()
            }
            .store(in: &cancellables)

        session.$runLog
            .map(\.count)
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.panel?.reposition()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .askDroidHotkeyChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.registerHotkey()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.panel?.reposition()
            }
            .store(in: &cancellables)
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        session.present()
        panel?.pinToCurrentScreen()
        panel?.updateVisibility()
        return false
    }

    public func applicationWillTerminate(_ notification: Notification) {
        HotkeyCenter.shared.unregister()
        AskLog.line("terminate")
    }

    private func registerHotkey() {
        HotkeyCenter.shared.register(
            keyCode: session.settings.hotkeyKeyCode,
            modifiers: session.settings.hotkeyModifiers
        ) { [weak self] in
            guard let self else { return }
            AskLog.line("hotkey fired expanded=\(self.session.isExpanded)")
            if !self.session.isExpanded {
                self.panel?.pinToCurrentScreen()
            }
            self.session.toggleExpanded()
            self.panel?.updateVisibility()
            AskLog.line("after hotkey \(self.panel?.debugDescription ?? "nil")")
        }
    }

    private func prepareSupportDirectories() {
        let manager = FileManager.default
        let paths = [
            session.settings.resolvedWorkingDirectory,
            session.settings.resolvedAnswersDirectory,
        ]
        for path in paths {
            do {
                try manager.createDirectory(atPath: path, withIntermediateDirectories: true)
            } catch {
                AskLog.line("mkdir failed \(path): \(error.localizedDescription)")
            }
        }
    }
}

enum AskLog {
    static func line(_ message: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AskDroid", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("askdroid.log")
            let stamp = ISO8601DateFormatter().string(from: Date())
            let data = Data("\(stamp) \(message)\n".utf8)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url)
            }
        } catch {
            NSLog("AskDroid log failed: \(error.localizedDescription)")
        }
    }
}

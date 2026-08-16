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
        NSApp.mainMenu = MainMenuBuilder.build()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        AskLog.line("launch pid=\(ProcessInfo.processInfo.processIdentifier)")
        prepareSupportDirectories()

        let controller = NotchPanelController(session: session)
        panel = controller
        registerHotkey()

        if let directory = ProcessInfo.processInfo.environment["ASKDROID_SCREENSHOTS"], !directory.isEmpty {
            ScreenshotStudio.bind(controller)
            Task { @MainActor in
                await ScreenshotStudio.run(
                    session: session,
                    panel: controller,
                    directory: URL(fileURLWithPath: directory, isDirectory: true)
                )
                NSApp.terminate(nil)
            }
            return
        }

        if LaunchContext.isLoginLaunch() {
            AskLog.line("login launch; staying hidden")
        } else {
            session.present()
            controller.pinToCurrentScreen()
            controller.updateVisibility()
            AskLog.line("presented on launch \(controller.debugDescription)")
        }

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
                self?.panel?.refreshPinning()
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
        let status = HotkeyCenter.shared.register(
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
        if status != noErr {
            session.notice = "Could not exclusively register \(session.settings.hotkeyDisplay). A fallback listener is on; another app may already own that shortcut."
            AskLog.line("hotkey register failed status=\(status)")
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

/// Agent apps have no visible menu bar, but AppKit still routes standard key
/// equivalents (⌘A/⌘C/⌘V/⌘X/⌘Z) through the main menu into the responder
/// chain. Without one, the composer silently ignores them.
enum MainMenuBuilder {
    static func build() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem()
        editItem.submenu = edit

        let menu = NSMenu()
        menu.addItem(editItem)
        return menu
    }
}

enum AskLog {
    private static let maxBytes: UInt64 = 512 * 1024
    private static let state = LogState()

    static func line(_ message: String) {
        state.write(message)
    }

    /// Redirects the log file. Tests use this to keep runs out of the real log.
    static func setDirectoryOverrideForTesting(_ url: URL?) {
        state.setDirectoryOverride(url)
    }

    private final class LogState: @unchecked Sendable {
        private let lock = NSLock()
        private var handle: FileHandle?
        private var url: URL?
        private var directoryOverride: URL?

        func setDirectoryOverride(_ url: URL?) {
            lock.lock()
            defer { lock.unlock() }
            directoryOverride = url
            try? handle?.close()
            handle = nil
            self.url = nil
        }

        func write(_ message: String) {
            lock.lock()
            defer { lock.unlock() }
            let dir = directoryOverride ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/AskDroid", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let fileURL = dir.appendingPathComponent("askdroid.log")
                rotateIfNeeded(fileURL)
                let handle = try openHandle(fileURL)
                let stamp = ISO8601DateFormatter().string(from: Date())
                let data = Data("\(stamp) \(message)\n".utf8)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                NSLog("AskDroid log failed: \(error.localizedDescription)")
            }
        }

        private func openHandle(_ fileURL: URL) throws -> FileHandle {
            if let handle, url == fileURL {
                return handle
            }
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            self.handle = handle
            self.url = fileURL
            return handle
        }

        private func rotateIfNeeded(_ fileURL: URL) {
            guard let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64,
                  size > AskLog.maxBytes
            else { return }
            try? handle?.close()
            handle = nil
            let rotated = fileURL.deletingLastPathComponent().appendingPathComponent("askdroid.1.log")
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: fileURL, to: rotated)
        }
    }
}

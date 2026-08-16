import AppKit
import Foundation

@MainActor
enum ScreenshotStudio {
    static func run(session: AskSession, panel: NotchPanelController, directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        bind(panel)
        panel.useMarketingNotchForScreenshots()
        panel.pinToCurrentScreen()

        await capture(name: "composer", directory: directory) {
            session.resetComposer()
            session.present(source: .user)
            session.prompt = "Summarise what a notch HUD is in two sentences."
            session.phase = .composing
            session.activity = ""
        }

        await capture(name: "progress", directory: directory) {
            session.present(source: .user)
            session.isSettingsOpen = false
            session.prompt = "Summarise what a notch HUD is in two sentences."
            session.phase = .running
            session.activity = "Working…"
            session.elapsed = 6.8
            session.tokenSummary = "351 in · 9 out"
            session.answer = "A notch HUD is a heads-up display overlay that renders UI in and around the camera notch cutout at the top of a screen, most commonly on MacBoo"
            session.runLog = [
                "Looking for the droid CLI…",
                "Using ~/.local/bin/droid",
                "cwd ~/Library/Application Support/AskDroid/workspace",
                "initialize_session sent",
                "No MCP servers configured",
                "Session settings loaded",
                "Running SessionStart hook…",
            ]
        }

        await capture(name: "answer", directory: directory) {
            session.present(source: .user)
            session.phase = .completed
            session.activity = "Done"
            session.answer = """
            A notch HUD is a heads-up display overlay that renders UI in and around the camera notch cutout at the top of a screen, most commonly on MacBooks with a display notch or on notched phones. It turns that otherwise dead pixel area into a live surface for things like now-playing controls, battery and charging status, file drop targets, timers, and transient notifications, typically expanding into a larger panel on hover or click.
            """
            session.durationText = "5.6s"
            session.tokenSummary = "353 in · 142 out"
            session.archiveURL = URL(fileURLWithPath: "/tmp/droid-demo.md")
            session.runLog = [
                "Looking for the droid CLI…",
                "Using ~/.local/bin/droid",
                "cwd ~/Library/Application Support/AskDroid/workspace",
            ]
        }

        await capture(name: "settings", directory: directory) {
            session.present(source: .user)
            session.isSettingsOpen = true
            session.phase = .completed
            session.settings.workingDirectory = "~/Library/Application Support/AskDroid/workspace"
            session.settings.answersDirectory = "~/Library/Application Support/AskDroid/answers"
        }

        await capture(name: "pill", directory: directory) {
            session.isSettingsOpen = false
            session.isExpanded = false
            session.presentSource = .user
            session.phase = .running
            session.activity = "Thinking…"
            session.elapsed = 4.6
            session.answer = ""
            session.runLog = []
        }

        await captureLiveIfPossible(session: session, directory: directory)
        AskLog.line("screenshots written to \(directory.path)")
    }

    private static func captureLiveIfPossible(session: AskSession, directory: URL) async {
        guard let panel = activePanel() else { return }
        let hardware = NSScreen.screens.first { NotchMetrics.from(screen: $0).hasNotch }
        panel.useHardwareNotch()
        if let hardware {
            panel.pinToScreen(hardware)
        }
        session.resetComposer()
        session.present(source: .user)
        session.prompt = "Summarise what a notch HUD is in two sentences."
        session.phase = .composing
        session.isSettingsOpen = false
        session.answer = ""
        session.runLog = []
        session.durationText = nil
        session.tokenSummary = nil
        session.archiveURL = nil
        panel.updateVisibility()
        panel.reposition()
        try? await Task.sleep(for: .milliseconds(280))
        let dest = directory.appendingPathComponent("notch-live.png").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-l\(panel.windowNumber)", "-o", dest]
        do {
            try process.run()
            process.waitUntilExit()
            AskLog.line("live capture status=\(process.terminationStatus) \(dest)")
        } catch {
            AskLog.line("live capture failed: \(error.localizedDescription)")
        }
    }

    private static func capture(name: String, directory: URL, mutate: () -> Void) async {
        mutate()
        panelVisibility()
        try? await Task.sleep(for: .milliseconds(220))
        guard let data = activePanel()?.snapshotPNG() else {
            AskLog.line("screenshot failed \(name)")
            return
        }
        let url = directory.appendingPathComponent("\(name).png")
        do {
            try data.write(to: url)
            AskLog.line("screenshot \(name) \(data.count) bytes")
        } catch {
            AskLog.line("screenshot write failed \(name): \(error.localizedDescription)")
        }
    }

    private static weak var boundPanel: NotchPanelController?

    static func bind(_ panel: NotchPanelController) {
        boundPanel = panel
    }

    private static func activePanel() -> NotchPanelController? { boundPanel }

    private static func panelVisibility() {
        boundPanel?.updateVisibility()
        boundPanel?.reposition()
    }
}

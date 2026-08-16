import AppKit
import AskDroidKit
import Foundation

@main
enum AskDroidScreenshotsMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let dest = CommandLine.arguments.dropFirst().first
            ?? FileManager.default.currentDirectoryPath + "/docs/screenshots"
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                ScreenshotRender.write(to: URL(fileURLWithPath: dest, isDirectory: true))
            }
        } else {
            DispatchQueue.main.sync {
                ScreenshotRender.write(to: URL(fileURLWithPath: dest, isDirectory: true))
            }
        }
    }
}

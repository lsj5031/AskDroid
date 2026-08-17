import AppKit
import SwiftUI

/// Off-process README captures. Not wired into the running accessory.
@MainActor
public enum ScreenshotRender {
    public static func write(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metrics = NotchMetrics.marketing
        write(name: "composer", directory: directory, metrics: metrics) { session in
            session.present()
            session.prompt = "Summarise what a notch HUD is in two sentences."
            session.phase = .composing
        }
        write(name: "progress", directory: directory, metrics: metrics) { session in
            session.present()
            session.prompt = "Summarise what a notch HUD is in two sentences."
            session.phase = .running
            session.activity = "Working…"
            session.elapsed = 6.8
            session.tokenSummary = "351 in · 9 out"
            session.answer = "A notch HUD is a heads-up display overlay that renders UI in and around the camera notch cutout at the top of a screen."
        }
        write(name: "answer", directory: directory, metrics: metrics) { session in
            session.present()
            session.prompt = "Summarise what a notch HUD is in two sentences."
            session.phase = .completed
            session.activity = "Done"
            session.answer = "A notch HUD is a heads-up display overlay that renders UI in and around the camera notch cutout. It turns that otherwise dead pixel area into a live surface for controls, status, and answers."
            session.durationText = "5.6s"
            session.tokenSummary = "353 in · 142 out"
            session.archiveURL = URL(fileURLWithPath: "/tmp/droid-demo.md")
        }
        write(name: "settings", directory: directory, metrics: metrics) { session in
            session.present()
            session.isSettingsOpen = true
            session.phase = .completed
            session.settings.workingDirectory = "~/Library/Application Support/AskDroid/workspace"
            session.settings.answersDirectory = "~/Library/Application Support/AskDroid/answers"
        }
        write(name: "pill", directory: directory, metrics: metrics) { session in
            session.dismiss()
            session.phase = .running
            session.activity = "Thinking…"
            session.elapsed = 4.6
        }
    }

    private static func write(name: String, directory: URL, metrics: NotchMetrics, mutate: (AskSession) -> Void) {
        let session = AskSession()
        mutate(session)
        let size = session.isExpanded
            ? metrics.expandedSize(contentHeight: contentHeight(session))
            : metrics.compactSize
        let view = HUDRootView(session: session, metrics: metrics)
            .frame(width: size.width, height: size.height, alignment: .top)
        guard let data = rasterize(view, size: size) else {
            fputs("screenshot failed \(name)\n", stderr)
            return
        }
        let url = directory.appendingPathComponent("\(name).png")
        try? data.write(to: url)
        fputs("wrote \(url.path) \(data.count) bytes\n", stderr)
    }

    private static func contentHeight(_ session: AskSession) -> CGFloat {
        if session.isSettingsOpen { return Theme.settingsContentHeight }
        if session.phase != .running {
            let probe = NSHostingView(
                rootView: HUDRootView(session: session, metrics: .marketing)
                    .frame(width: Theme.panelWidth)
            )
            probe.safeAreaRegions = []
            probe.layoutSubtreeIfNeeded()
            let measured = probe.fittingSize.height
            if measured > 0, measured.isFinite, measured < Theme.maxExpandedHeight {
                // The probe includes the notch spacer; expandedSize re-adds it.
                return PanelLayout.expandedContentHeight(fromHostingHeight: measured, metrics: .marketing)
            }
        }
        return PanelLayout.fallbackContentHeight(for: session)
    }

    private static func rasterize<V: View>(_ view: V, size: CGSize) -> Data? {
        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true
        hosting.layer?.isOpaque = false
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.safeAreaRegions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        hosting.display()

        let scale: CGFloat = 2
        guard let paper = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        paper.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: paper)
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        hosting.cacheDisplay(in: hosting.bounds, to: paper)
        NSGraphicsContext.restoreGraphicsState()
        return paper.representation(using: .png, properties: [:])
    }
}

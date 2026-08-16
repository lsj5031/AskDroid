import AppKit
import CoreGraphics

/// Whether another app is covering a display in a fullscreen / presentation way.
enum DisplayOccupation {
    static func coversScreen(_ bounds: CGRect, screen: CGRect, tolerance: CGFloat = 4) -> Bool {
        bounds.width + tolerance >= screen.width && bounds.height + tolerance >= screen.height - 8
    }

    static func isForeignFullscreen(
        bounds: CGRect,
        screen: CGRect,
        layer: Int,
        ownerPID: pid_t,
        ourPID: pid_t
    ) -> Bool {
        guard ownerPID != ourPID, ownerPID != 0 else { return false }
        guard layer <= 0 else { return false }
        return coversScreen(bounds, screen: screen)
    }

    static func frontmostCovers(_ screen: NSScreen, ourPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> Bool {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        guard frontPID != 0, frontPID != ourPID else { return false }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        guard let windows = info as? [[String: Any]] else { return false }
        let screenFrame = screen.frame
        for window in windows {
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let owner = window[kCGWindowOwnerPID as String] as? pid_t ?? 0
            guard owner == frontPID else { continue }
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat] ??
                (window[kCGWindowBounds as String] as? NSDictionary) as? [String: CGFloat]
            else { continue }
            let candidate = CGRect(
                x: 0,
                y: 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            let quartzScreen = CGRect(x: 0, y: 0, width: screenFrame.width, height: screenFrame.height)
            if isForeignFullscreen(
                bounds: candidate,
                screen: quartzScreen,
                layer: layer,
                ownerPID: owner,
                ourPID: ourPID
            ) {
                return true
            }
        }
        return false
    }
}

enum LaunchContext {
    static let openApplicationEvent: UInt32 = 0x6F61_7070 // 'oapp'
    static let propDataKeyword: UInt32 = 0x7072_6474 // 'prdt'
    static let launchedAsLoginItem: UInt32 = 0x6C67_6974 // 'lgit'

    static func isLoginLaunch(event: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent) -> Bool {
        guard let event, event.eventID == openApplicationEvent else { return false }
        return event.paramDescriptor(forKeyword: propDataKeyword)?.enumCodeValue == launchedAsLoginItem
    }
}

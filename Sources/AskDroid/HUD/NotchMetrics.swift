import AppKit
import SwiftUI

/// Hardware-accurate notch (or menu-bar fallback) used to pin the HUD.
///
/// Measured cutout geometry, in points at the current scaling:
///  - 14-inch MacBook Pro: 185 × 32
///  - 16-inch MacBook Pro: 220 × 38
/// The lens is ~12.2% of the screen width on every notched model, and its
/// corners are ~4 pt on top and ~8 pt on the bottom (the bottom flares wider).
/// `NSScreen.safeAreaInsets.top` reports the exact lens height — not a loose
/// menu-bar inset — so it is the vertical measure; the horizontal span is
/// measured directly from the menu-bar ears.
struct NotchMetrics: Equatable, Sendable {
    var hasNotch: Bool
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    /// Absolute screen-space X of the lens's left edge, measured from the
    /// menu-bar ears rather than assumed perfectly centered at midX.
    var notchLeftEdge: CGFloat
    var menubarHeight: CGFloat
    var screenFrame: CGRect
    var visibleFrame: CGRect

    static let fallbackNotchWidth: CGFloat = 300

    /// Physical cutout corner radii (approx): the top corners are squarer and
    /// the bottom corners flare wider. Named for any surface that redraws the
    /// lens itself.
    static let notchTopCornerRadius: CGFloat = 4
    static let notchBottomCornerRadius: CGFloat = 8

    /// 14-inch MacBook-style notch used for README captures so the Island
    /// silhouette is visible even on a non-notched display.
    static let marketing = NotchMetrics.from(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
        auxiliaryTopLeft: 650,
        auxiliaryTopRight: 650,
        safeAreaTop: 32
    )

    func placed(on screen: NSScreen) -> NotchMetrics {
        var copy = self
        copy.screenFrame = screen.frame
        copy.visibleFrame = screen.visibleFrame
        // Re-center the measured lens on the target screen (the marketing
        // metrics carry a synthetic origin).
        copy.notchLeftEdge = screen.frame.midX - copy.notchWidth / 2
        return copy
    }

    var notchFrame: CGRect {
        CGRect(
            x: notchLeftEdge,
            y: screenFrame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )
    }

    /// Compact wings sit beside the camera housing.
    var compactLeadingWidth: CGFloat { 108 }
    var compactTrailingWidth: CGFloat { 72 }

    var compactSize: CGSize {
        if hasNotch {
            return CGSize(
                width: compactLeadingWidth + notchWidth + compactTrailingWidth,
                height: max(notchHeight, menubarHeight, 34)
            )
        }
        return CGSize(width: Theme.pillWidth, height: Theme.pillHeight)
    }

    func expandedSize(contentHeight: CGFloat) -> CGSize {
        let topInset = hasNotch ? notchHeight : 0
        return CGSize(
            width: Theme.panelWidth,
            height: min(contentHeight + topInset, Theme.maxExpandedHeight)
        )
    }

    static func looksLikeHardwareNotch(
        left: CGFloat,
        right: CGFloat,
        safeAreaTop: CGFloat,
        screenWidth: CGFloat
    ) -> Bool {
        guard left >= 80, right >= 80 else { return false }
        guard safeAreaTop >= 22, safeAreaTop <= 52 else { return false }
        let width = screenWidth - left - right
        return width >= 80 && width <= 420
    }

    func frame(for size: CGSize, expanded: Bool) -> CGRect {
        let width = min(size.width, max(80, screenFrame.width - 16))
        let height = min(size.height, max(24, visibleFrame.height - 8))
        if hasNotch {
            let x: CGFloat
            if expanded {
                x = notchFrame.midX - width / 2
            } else {
                // Keep the physical notch centered; wings grow left/right.
                x = notchFrame.minX - compactLeadingWidth
            }
            let y = screenFrame.maxY - height
            return CGRect(x: x, y: y, width: width, height: height)
        }

        let x = visibleFrame.midX - width / 2
        let y = visibleFrame.maxY - height - (expanded ? 0 : 8)
        return CGRect(x: x, y: max(visibleFrame.minY + 8, y), width: width, height: height)
    }

    static func from(screen: NSScreen) -> NotchMetrics {
        from(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea?.width,
            auxiliaryTopRight: screen.auxiliaryTopRightArea?.width,
            safeAreaTop: screen.safeAreaInsets.top
        )
    }

    static func from(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        auxiliaryTopLeft: CGFloat?,
        auxiliaryTopRight: CGFloat?,
        safeAreaTop: CGFloat
    ) -> NotchMetrics {
        let menubarHeight = max(0, screenFrame.maxY - visibleFrame.maxY)
        // Require camera-housing-shaped auxiliary areas. A menu-bar-only
        // safeAreaInset on an external display must not become an Island.
        if let left = auxiliaryTopLeft, let right = auxiliaryTopRight,
           looksLikeHardwareNotch(left: left, right: right, safeAreaTop: safeAreaTop, screenWidth: screenFrame.width)
        {
            // The ears run from the screen's left/right edges to the camera
            // housing, so the lens spans [minX + left, maxX - right] exactly.
            let notchLeft = screenFrame.minX + left
            let notchRight = screenFrame.maxX - right
            return NotchMetrics(
                hasNotch: true,
                notchWidth: notchRight - notchLeft,
                notchHeight: safeAreaTop,
                notchLeftEdge: notchLeft,
                menubarHeight: menubarHeight,
                screenFrame: screenFrame,
                visibleFrame: visibleFrame
            )
        }
        return NotchMetrics(
            hasNotch: false,
            notchWidth: fallbackNotchWidth,
            notchHeight: max(menubarHeight, 24),
            notchLeftEdge: screenFrame.midX - fallbackNotchWidth / 2,
            menubarHeight: menubarHeight,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )
    }
}

private struct NotchMetricsKey: EnvironmentKey {
    static let defaultValue = NotchMetrics.from(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
        auxiliaryTopLeft: nil,
        auxiliaryTopRight: nil,
        safeAreaTop: 0
    )
}

extension EnvironmentValues {
    var notchMetrics: NotchMetrics {
        get { self[NotchMetricsKey.self] }
        set { self[NotchMetricsKey.self] = newValue }
    }
}

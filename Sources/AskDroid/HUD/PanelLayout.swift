import Foundation

/// Shared sizing rules for the expanded panel.
///
/// The window placement itself (notch-relative frames, animation) stays in
/// `NotchPanelController`; this type only answers "how tall is the content"
/// so the live controller and the off-process screenshot renderer don't
/// drift apart.
@MainActor
enum PanelLayout {
    /// Fixed reserve used before SwiftUI has laid out, or for states that
    /// reflow constantly (streaming answers). Measured heights override this
    /// once a plausible value is available.
    static func fallbackContentHeight(for session: AskSession) -> CGFloat {
        if session.isSettingsOpen { return Theme.settingsContentHeight }
        var height = Theme.composerContentHeight
        if !session.images.isEmpty { height += Theme.imageStripHeight }
        if session.phase == .running
            || session.phase == .completed
            || session.phase == .failed
            || !session.answer.isEmpty
        {
            height += Theme.answerBlockHeight
        }
        return height
    }

    /// Converts a measured hosting height (which includes the notch spacer)
    /// into the content height `expandedSize` expects, clamped to a usable
    /// floor so a transient bogus measurement can never collapse the panel.
    static func expandedContentHeight(fromHostingHeight measured: CGFloat, metrics: NotchMetrics) -> CGFloat {
        let topInset = metrics.hasNotch ? metrics.notchHeight : 0
        return max(measured - topInset, Theme.minExpandedContentHeight)
    }
}

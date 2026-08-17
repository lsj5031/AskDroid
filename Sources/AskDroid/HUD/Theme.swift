import SwiftUI

enum Theme {
    static let accent = Color(red: 0.98, green: 0.62, blue: 0.18)
    static let ink = Color.white.opacity(0.92)
    static let mute = Color.white.opacity(0.56)
    static let hairline = Color.white.opacity(0.10)
    static let well = Color.black.opacity(0.28)
    /// Hover fill for well-based controls; just brighter than `well`.
    static let wellHover = Color.white.opacity(0.15)
    static let panelFill = Color(red: 0.07, green: 0.07, blue: 0.075, opacity: 0.96)
    static let pillFill = Color(red: 0.08, green: 0.08, blue: 0.085)
    static let success = Color(red: 0.45, green: 0.84, blue: 0.52)
    static let danger = Color(red: 1, green: 0.45, blue: 0.38)
    /// Softened danger for body text; raw `danger` reads too hot at 13 pt.
    static let dangerText = Color(red: 1, green: 0.62, blue: 0.52)
    /// Amber warning for notices (size limits, hotkey conflicts).
    static let notice = Color(red: 1, green: 0.72, blue: 0.42)

    static let panelWidth: CGFloat = 560
    static let pillWidth: CGFloat = 280
    static let pillHeight: CGFloat = 34
    static let panelCorner: CGFloat = 18
    static let pillCorner: CGFloat = 17

    /// Composer field chrome and text insets. The caret and the placeholder
    /// share these values (the placeholder is drawn by the text view at the
    /// insertion point), so text can never drift from the field's visual
    /// chrome the way a separately-padded overlay can.
    static let fieldCorner: CGFloat = 10
    static let fieldInset: CGFloat = 12
    static let fieldVerticalInset: CGFloat = 12
    static let fieldMinHeight: CGFloat = 44
    static let fieldMaxHeight: CGFloat = 88

    /// Corner radius and vertical padding for the settings controls' wells.
    static let settingsControlCorner: CGFloat = 8
    static let settingsControlPadding: CGFloat = 8

    static let settingsContentHeight: CGFloat = 720
    static let composerContentHeight: CGFloat = 188
    static let imageStripHeight: CGFloat = 72
    static let answerBlockHeight: CGFloat = 240
    static let maxExpandedHeight: CGFloat = 780
    /// Floor for a measured expanded content height, so a transient bogus
    /// measurement can never collapse the panel below a usable size.
    static let minExpandedContentHeight: CGFloat = 160
}

import SwiftUI

/// Anchor used to follow the streaming answer and to jump back to it.
enum AnswerScrollAnchor {
    static let bottom = "answer-bottom"
}

enum AnswerScrollSpace {
    static let name = "AskDroidAnswerScroll"
}

/// Reports the rendered answer content's total height.
struct AnswerContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports the rendered answer content's minY in the scroll coordinate space.
struct AnswerContentMinYKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Reports the answer viewport's height.
struct AnswerViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

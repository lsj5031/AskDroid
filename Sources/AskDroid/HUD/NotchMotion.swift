import SwiftUI

enum NotchMotion {
    static let conversion = Animation.easeOut(duration: 0.22)
    static let reduced = Animation.easeOut(duration: 0.12)

    static func conversion(reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : conversion
    }
}

struct NotchRadii: Equatable {
    var top: CGFloat
    var bottom: CGFloat

    static let compact = NotchRadii(top: 6, bottom: 14)
    static let expanded = NotchRadii(top: 12, bottom: 18)
}

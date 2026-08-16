import SwiftUI

enum NotchMotion {
    /// Island conversion: slightly underdamped so the surface overshoots.
    static let jelly = Animation.interpolatingSpring(mass: 0.62, stiffness: 210, damping: 15.5, initialVelocity: 6)
    static let hover = Animation.interpolatingSpring(mass: 0.8, stiffness: 260, damping: 22, initialVelocity: 0)
    static let reduced = Animation.easeOut(duration: 0.12)

    static func conversion(reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : jelly
    }
}

/// Stretch / squash pulse when the surface changes size, anchored at the notch.
struct JellyPulseModifier: ViewModifier {
    var isExpanded: Bool
    var reduceMotion: Bool
    @State private var scale = CGSize(width: 1, height: 1)

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: scale.width, y: scale.height, anchor: .top)
            .onChange(of: isExpanded) { _, expanded in
                pulse(expanding: expanded)
            }
    }

    private func pulse(expanding: Bool) {
        guard !reduceMotion else {
            scale = CGSize(width: 1, height: 1)
            return
        }
        // Expanding: squash vertically and grow wider, then settle.
        // Collapsing: stretch tall and pinch, then settle.
        scale = expanding
            ? CGSize(width: 1.08, height: 0.78)
            : CGSize(width: 0.90, height: 1.14)
        withAnimation(NotchMotion.jelly) {
            scale = CGSize(width: 1, height: 1)
        }
    }
}

extension View {
    func jellyPulse(isExpanded: Bool, reduceMotion: Bool) -> some View {
        modifier(JellyPulseModifier(isExpanded: isExpanded, reduceMotion: reduceMotion))
    }
}

struct NotchRadii: Equatable {
    var top: CGFloat
    var bottom: CGFloat

    static let compact = NotchRadii(top: 6, bottom: 14)
    static let expanded = NotchRadii(top: 12, bottom: 18)
}

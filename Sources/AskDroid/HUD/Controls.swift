import MarkdownUI
import SwiftUI

struct StatusDot: View {
    let phase: AskSession.Phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(phase == .running && !reduceMotion ? 0.45 : 1)
            .animation(phase == .running && !reduceMotion ? .easeInOut(duration: 0.8).repeatForever() : .default, value: phase)
    }

    private var color: Color {
        switch phase {
        case .running: Theme.accent
        case .completed: Theme.success
        case .failed: Theme.danger
        default: Theme.mute
        }
    }
}

struct IconButton: View {
    let systemName: String
    let label: String
    var tint: Color = Theme.ink
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.isFocused) private var focused

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(hovering ? Theme.wellHover : Theme.well, in: Circle())
                .overlay {
                    if focused {
                        Circle().stroke(Theme.accent.opacity(0.8), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .focusable()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(label)
    }
}

struct MetaLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Theme.mute)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var focused
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.black : Color.black.opacity(0.55))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(fill(isPressed: configuration.isPressed), in: Capsule())
            .overlay {
                if focused, isEnabled {
                    Capsule().stroke(Theme.accent.opacity(0.8), lineWidth: 1)
                }
            }
            .focusable()
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func fill(isPressed: Bool) -> Color {
        guard isEnabled else { return Theme.accent.opacity(0.32) }
        if isPressed { return Theme.accent.opacity(0.82) }
        if hovering { return Theme.accent.opacity(0.9) }
        return Theme.accent
    }
}

struct GhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var focused
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.ink.opacity(labelOpacity(isPressed: configuration.isPressed)))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(hovering && isEnabled ? Theme.wellHover : Theme.well, in: Capsule())
            .overlay {
                if focused, isEnabled {
                    Capsule().stroke(Theme.accent.opacity(0.8), lineWidth: 1)
                }
            }
            .focusable()
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func labelOpacity(isPressed: Bool) -> Double {
        guard isEnabled else { return 0.35 }
        return isPressed ? 0.7 : 1
    }
}

/// Shared dark-theme styling for settings controls. Applies ink text and, for
/// field-like controls, a well fill with a hairline border that brightens to
/// accent while the control is active. The toggle opts out of the well (a
/// switch carries its own chrome) but still takes the ink color from here.
struct SettingsControlStyle: ViewModifier {
    var isActive = false
    var showsWell = true

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Theme.ink)
            .background {
                if showsWell {
                    RoundedRectangle(cornerRadius: Theme.settingsControlCorner, style: .continuous)
                        .fill(Theme.well)
                }
            }
            .overlay {
                if showsWell {
                    RoundedRectangle(cornerRadius: Theme.settingsControlCorner, style: .continuous)
                        .stroke(isActive ? Theme.accent.opacity(0.85) : Theme.hairline, lineWidth: 1)
                }
            }
    }
}

extension View {
    func settingsControlStyle(isActive: Bool = false, showsWell: Bool = true) -> some View {
        modifier(SettingsControlStyle(isActive: isActive, showsWell: showsWell))
    }
}

enum AskDroidMarkdown {
    @MainActor
    static var theme: MarkdownUI.Theme {
        MarkdownUI.Theme.basic
            .text {
                ForegroundColor(Theme.ink)
                FontSize(14)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(13)
                ForegroundColor(Theme.ink)
                BackgroundColor(Theme.well)
            }
            .link {
                ForegroundColor(Theme.accent)
            }
    }
}

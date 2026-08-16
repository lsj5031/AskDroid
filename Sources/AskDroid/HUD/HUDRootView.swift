import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers

struct HUDRootView: View {
    @ObservedObject var session: AskSession
    var metrics: NotchMetrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if session.isExpanded {
                ExpandedHUD(session: session)
            } else if session.phase == .running || session.phase == .failed || session.phase == .completed {
                CompactPill(session: session)
            } else {
                Color.clear
            }
        }
        .environment(\.notchMetrics, metrics)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(NotchMotion.conversion(reduceMotion: reduceMotion), value: session.isExpanded)
    }
}

struct CompactPill: View {
    @ObservedObject var session: AskSession
    @Environment(\.notchMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: session.present) {
            if metrics.hasNotch {
                notchedPill
            } else {
                floatingPill
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(session.compactTitle)
        .animation(NotchMotion.conversion(reduceMotion: reduceMotion), value: session.phase)
    }

    private var notchedPill: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                StatusDot(phase: session.phase)
                Text(session.compactTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            .padding(.leading, 10)
            .frame(width: metrics.compactLeadingWidth, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(Theme.pillFill)

            Color.black
                .frame(width: metrics.notchWidth)
                .clipShape(NotchShape(
                    topCornerRadius: NotchMetrics.notchTopCornerRadius,
                    bottomCornerRadius: NotchMetrics.notchBottomCornerRadius
                ))
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            Group {
                if session.phase == .running {
                    Text(AnswerArchive.formatDuration(session.elapsed))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.mute)
                } else {
                    Image(systemName: session.phase == .failed ? "exclamationmark" : "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(session.phase == .failed ? Theme.danger : Theme.success)
                }
            }
            .padding(.trailing, 10)
            .frame(width: metrics.compactTrailingWidth, alignment: .trailing)
            .frame(maxHeight: .infinity)
            .background(Theme.pillFill)
        }
        .frame(height: metrics.compactSize.height)
        .background(Color.black)
        .overlay {
            NotchShape(
                topCornerRadius: NotchRadii.compact.top,
                bottomCornerRadius: NotchRadii.compact.bottom
            )
            .stroke(Theme.hairline, lineWidth: 1)
        }
        .clipShape(NotchShape(
            topCornerRadius: NotchRadii.compact.top,
            bottomCornerRadius: NotchRadii.compact.bottom
        ))
        .animation(NotchMotion.conversion(reduceMotion: reduceMotion), value: session.phase)
    }

    private var floatingPill: some View {
        HStack(spacing: 8) {
            StatusDot(phase: session.phase)
            Text(session.compactTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            if session.phase == .running {
                Text(AnswerArchive.formatDuration(session.elapsed))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.mute)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: Theme.pillWidth, height: Theme.pillHeight)
        .background(Theme.pillFill, in: Capsule())
        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
    }

}

struct ExpandedHUD: View {
    @ObservedObject var session: AskSession
    @Environment(\.notchMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTargeted = false
    @State private var activityLogExpanded = false
    @State private var answerContentHeight: CGFloat = 0
    @State private var answerContentMinY: CGFloat = 0
    @State private var answerViewportHeight: CGFloat = 0

    private var showingResult: Bool {
        session.phase == .running || session.phase == .failed || !session.answer.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if metrics.hasNotch {
                Color.clear
                    .frame(height: metrics.notchHeight)
                    .accessibilityHidden(true)
            }
            header
            Divider().overlay(Theme.hairline)
            if session.isSettingsOpen {
                ScrollView {
                    SettingsPane(session: session)
                        .padding(20)
                }
            } else if showingResult {
                questionLine
                Divider().overlay(Theme.hairline)
                answerBlock
                footer
            } else {
                composer
            }
        }
        .frame(width: Theme.panelWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panelFill)
        .overlay {
            if metrics.hasNotch {
                NotchShape(
                    topCornerRadius: NotchRadii.expanded.top,
                    bottomCornerRadius: NotchRadii.expanded.bottom
                )
                .stroke(Theme.hairline, lineWidth: 1)
            } else {
                RoundedRectangle(cornerRadius: Theme.panelCorner, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            }
            if isDropTargeted {
                if metrics.hasNotch {
                    NotchShape(
                        topCornerRadius: NotchRadii.expanded.top,
                        bottomCornerRadius: NotchRadii.expanded.bottom
                    )
                    .stroke(Theme.accent, lineWidth: 2)
                } else {
                    RoundedRectangle(cornerRadius: Theme.panelCorner, style: .continuous)
                        .stroke(Theme.accent, lineWidth: 2)
                }
            }
        }
        .mask {
            if metrics.hasNotch {
                NotchShape(
                    topCornerRadius: NotchRadii.expanded.top,
                    bottomCornerRadius: NotchRadii.expanded.bottom
                )
            } else {
                RoundedRectangle(cornerRadius: Theme.panelCorner, style: .continuous)
            }
        }
        .animation(NotchMotion.conversion(reduceMotion: reduceMotion), value: session.isSettingsOpen)
        .onDrop(of: [.fileURL, .image, .png, .jpeg, .tiff, .gif, UTType.webP], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusDot(phase: session.phase)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.isSettingsOpen ? "Settings" : "AskDroid")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(session.isSettingsOpen ? "Optional overrides. Blank uses Droid defaults." : session.activity.isEmpty ? "\(session.settings.hotkeyDisplay) · ⌘↩ ask · Esc hide" : session.activity)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.mute)
                    .lineLimit(1)
            }
            Spacer()
            IconButton(systemName: session.isSettingsOpen ? "chevron.left" : "gearshape", label: session.isSettingsOpen ? "Back" : "Settings") {
                if session.isSettingsOpen {
                    session.closeSettings()
                } else {
                    session.isSettingsOpen = true
                }
            }
            IconButton(systemName: "xmark", label: "Hide") {
                session.dismiss()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var questionLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(session.prompt.isEmpty ? "Look at the attached image(s)." : session.prompt)
                .font(.system(size: 13))
                .foregroundStyle(Theme.mute)
                .lineSpacing(2)
                .lineLimit(session.phase == .running ? 2 : 3)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .help(session.prompt.isEmpty ? "Look at the attached image(s)." : session.prompt)
            Spacer(minLength: 8)
            if session.phase == .running {
                Button("Cancel", action: session.cancelRun)
                    .buttonStyle(GhostButtonStyle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !session.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(session.images) { image in
                            ImageChip(image: image) {
                                session.removeImage(image)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 64)
            }

            ZStack(alignment: .topLeading) {
                if session.prompt.isEmpty {
                    Text(session.images.isEmpty ? "Ask Droid anything" : "Add a note, or just send the image")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.mute)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
                PromptEditor(
                    text: $session.prompt,
                    onSubmit: session.submit,
                    onPasteImages: { session.attachFromPasteboard() }
                )
                .frame(minHeight: 52, maxHeight: 88)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .background(Theme.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            }

            if let notice = session.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.notice)
            }
            HStack {
                Label(
                    isDropTargeted ? "Release to attach" : "Paste or drop images",
                    systemImage: isDropTargeted ? "arrow.down.circle" : "paperclip"
                )
                .font(.system(size: 11, weight: isDropTargeted ? .medium : .regular))
                .foregroundStyle(isDropTargeted ? Theme.accent : Theme.mute)
                .labelStyle(.titleAndIcon)
                .animation(.easeOut(duration: 0.12), value: isDropTargeted)
                Spacer()
                Button("Ask", action: session.submit)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!session.canSubmit)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var answerIsNearBottom: Bool {
        guard answerContentHeight > answerViewportHeight + 8 else { return true }
        return answerContentHeight + answerContentMinY <= answerViewportHeight + 28
    }

    private var answerHasOverflow: Bool {
        answerContentHeight > answerViewportHeight + 8
    }

    private var answerBlock: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if session.phase == .failed, let errorMessage = session.errorMessage {
                            failureBlock(errorMessage)
                        }
                        if let archiveError = session.archiveError {
                            Text(archiveError)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.dangerText)
                                .textSelection(.enabled)
                        }
                        if !session.thinking.isEmpty, session.answer.isEmpty || session.phase == .running {
                            Text(session.thinking)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.mute)
                                .lineSpacing(2)
                                .textSelection(.enabled)
                        }
                        if !session.answer.isEmpty {
                            Markdown(session.answer)
                                .markdownTheme(AskDroidMarkdown.theme)
                                .lineSpacing(3)
                                .tracking(0.1)
                                .textSelection(.enabled)
                        } else if session.phase == .running {
                            Text(session.activity)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.mute)
                        }
                        if !session.runLog.isEmpty {
                            DisclosureGroup("Activity", isExpanded: $activityLogExpanded) {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(Array(session.runLog.suffix(20).enumerated()), id: \.offset) { _, line in
                                        Text(line)
                                            .font(.system(size: 11).monospaced())
                                            .foregroundStyle(Theme.mute)
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.mute)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(AnswerScrollAnchor.bottom)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .preference(
                                    key: AnswerContentHeightKey.self,
                                    value: proxy.size.height
                                )
                                .preference(
                                    key: AnswerContentMinYKey.self,
                                    value: proxy.frame(in: .named(AnswerScrollSpace.name)).minY
                                )
                        }
                    }
                }
                .frame(maxHeight: 280)
                .coordinateSpace(name: AnswerScrollSpace.name)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .preference(
                                key: AnswerViewportHeightKey.self,
                                value: proxy.size.height
                            )
                    }
                }

                if session.phase == .running, answerHasOverflow, !answerIsNearBottom {
                    Button {
                        followAnswer(proxy)
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                    }
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityLabel("Jump to latest answer")
                    .padding(.trailing, 20)
                    .padding(.bottom, 12)
                    .transition(.opacity)
                }
            }
            .onPreferenceChange(AnswerContentHeightKey.self) { answerContentHeight = $0 }
            .onPreferenceChange(AnswerContentMinYKey.self) { answerContentMinY = $0 }
            .onPreferenceChange(AnswerViewportHeightKey.self) { answerViewportHeight = $0 }
            .onChange(of: session.phase) { _, phase in
                switch phase {
                case .failed:
                    activityLogExpanded = true
                case .running:
                    activityLogExpanded = false
                default:
                    break
                }
            }
            .onAppear {
                if session.phase == .failed {
                    activityLogExpanded = true
                }
            }
            .onChange(of: session.answer.count) { _, _ in
                if session.phase == .running, answerIsNearBottom {
                    followAnswer(proxy)
                }
            }
            .onChange(of: session.thinking.count) { _, _ in
                if session.phase == .running, answerIsNearBottom {
                    followAnswer(proxy)
                }
            }
        }
    }

    private func followAnswer(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(AnswerScrollAnchor.bottom, anchor: .bottom)
        }
    }

    private func failureBlock(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.danger)
                .padding(.top, 2)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if session.phase == .running {
                MetaLabel(AnswerArchive.formatDuration(session.elapsed))
            }
            if let durationText = session.durationText {
                MetaLabel(durationText)
            }
            if let tokenSummary = session.tokenSummary {
                MetaLabel(tokenSummary)
            }
            Spacer()
            if !session.answer.isEmpty {
                Button {
                    session.copyAnswer()
                } label: {
                    Label(
                        session.copied ? "Copied" : "Copy",
                        systemImage: session.copied ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(GhostButtonStyle())
                .foregroundStyle(session.copied ? Theme.success : Theme.ink)
                .help("Copy answer")
            }
            if session.archiveURL != nil {
                Button {
                    session.openArchive()
                } label: {
                    Label("Open file", systemImage: "folder")
                }
                .buttonStyle(GhostButtonStyle())
                .help("Reveal the saved answer file")
            }
            if session.phase == .failed {
                Button("Try again") {
                    session.submit()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            if session.phase == .completed || session.phase == .failed {
                Button {
                    session.resetComposer()
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(GhostButtonStyle())
                .help("Start a new question")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async {
                        session.attach(urls: [url])
                    }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                accepted = true
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage,
                          let attached = AttachedImage.fromNSImage(image)
                    else { return }
                    DispatchQueue.main.async {
                        session.attach(images: [attached])
                    }
                }
            }
        }
        return accepted
    }
}

struct ImageChip: View {
    let image: AttachedImage
    var onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let nsImage = image.nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.black.opacity(0.72), in: Circle())
                    .overlay {
                        Circle().stroke(Color.white.opacity(0.18), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .offset(x: 4, y: -4)
            .accessibilityLabel("Remove \(image.filename)")
            .accessibilityHint("Removes this attached image")
            .help("Remove \(image.filename)")
        }
    }
}

enum AnswerScrollAnchor {
    static let bottom = "answer-bottom"
}

private enum AnswerScrollSpace {
    static let name = "AskDroidAnswerScroll"
}

private struct AnswerContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct AnswerContentMinYKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct AnswerViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

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

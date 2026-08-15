import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers

struct HUDRootView: View {
    @ObservedObject var session: AskSession

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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct CompactPill: View {
    @ObservedObject var session: AskSession

    var body: some View {
        Button(action: session.present) {
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
        .buttonStyle(.plain)
        .accessibilityLabel(session.compactTitle)
    }
}

struct ExpandedHUD: View {
    @ObservedObject var session: AskSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            if session.isSettingsOpen {
                SettingsPane(session: session)
                    .padding(16)
            } else {
                composer
                if !session.answer.isEmpty || session.phase == .running || session.phase == .failed {
                    Divider().overlay(Theme.hairline)
                    answerBlock
                }
                footer
            }
        }
        .frame(width: Theme.panelWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panelFill)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.panelCorner, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelCorner, style: .continuous))
        .onDrop(of: [.fileURL, .image, .png, .jpeg, .tiff, .gif, UTType.webP], isTargeted: nil) { providers in
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
                Text(session.isSettingsOpen ? "Optional overrides. Blank uses Droid defaults." : session.activity.isEmpty ? "⌃⌘D · ⌘↩ ask · Esc hide" : session.activity)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.mute)
                    .lineLimit(1)
            }
            Spacer()
            IconButton(systemName: session.isSettingsOpen ? "bubble.left" : "gearshape", label: session.isSettingsOpen ? "Back" : "Settings") {
                session.isSettingsOpen.toggle()
            }
            IconButton(systemName: "xmark", label: "Hide") {
                session.dismiss()
            }
        }
        .padding(.horizontal, 16)
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
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                }
                PromptEditor(
                    text: $session.prompt,
                    onSubmit: session.submit,
                    onPasteImages: { session.attachFromPasteboard() }
                )
                .frame(minHeight: 84, maxHeight: 140)
                .contentShape(Rectangle())
            }

            HStack {
                Text("Paste or drop images")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.mute)
                Spacer()
                if session.phase == .running {
                    Button("Cancel", action: session.cancelRun)
                        .buttonStyle(GhostButtonStyle())
                } else {
                    Button("Ask", action: session.submit)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!session.canSubmit)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(16)
    }

    private var answerBlock: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if session.phase == .failed, let errorMessage = session.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.52))
                }
                if let archiveError = session.archiveError {
                    Text(archiveError)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.52))
                        .textSelection(.enabled)
                }
                if !session.thinking.isEmpty, session.answer.isEmpty || session.phase == .running {
                    Text(session.thinking)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.mute)
                        .textSelection(.enabled)
                }
                if !session.answer.isEmpty {
                    Markdown(session.answer)
                        .markdownTheme(AskDroidMarkdown.theme)
                        .textSelection(.enabled)
                } else if session.phase == .running {
                    Text(session.activity)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.mute)
                }
                if !session.runLog.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(session.runLog.suffix(8).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11).monospaced())
                                .foregroundStyle(Theme.mute)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(maxHeight: 280)
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
                Button(session.copied ? "Copied" : "Copy") {
                    session.copyAnswer()
                }
                .buttonStyle(GhostButtonStyle())
            }
            if session.archiveURL != nil {
                Button("Open file", action: session.openArchive)
                    .buttonStyle(GhostButtonStyle())
            }
            if session.phase == .completed || session.phase == .failed {
                Button("New") {
                    session.resetComposer()
                }
                .buttonStyle(GhostButtonStyle())
            }
            Button("Quit", action: session.quit)
                .buttonStyle(GhostButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white, Color.black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
            .accessibilityLabel("Remove image")
        }
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
        case .completed: Color(red: 0.45, green: 0.84, blue: 0.52)
        case .failed: Color(red: 1, green: 0.45, blue: 0.38)
        default: Theme.mute
        }
    }
}

struct IconButton: View {
    let systemName: String
    let label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 28, height: 28)
                .background(Theme.well, in: Circle())
        }
        .buttonStyle(.plain)
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.82 : 1), in: Capsule())
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.ink.opacity(configuration.isPressed ? 0.7 : 1))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.well, in: Capsule())
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

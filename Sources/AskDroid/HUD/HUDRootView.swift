import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers

extension AnswerScrollAnchor {
    /// The newest turn's question line, used to keep the live topic visible
    /// at turn start and completion.
    static let question = "answer-question"
}

/// Resolves the expanded header's two lines. The newest turn's question
/// leads while a conversation is on screen — a session title naming an
/// earlier topic above a different answer reads as broken. The title drops
/// to the secondary line (unless it IS the topic) whenever nothing live is
/// talking.
enum HeaderLines {
    static func primary(
        isSettingsOpen: Bool,
        newestQuestion: String?,
        sessionTitle: String?
    ) -> String {
        if isSettingsOpen { return "Settings" }
        if let newestQuestion {
            return newestQuestion.isEmpty ? "Look at the attached image(s)." : newestQuestion
        }
        return sessionTitle ?? "AskDroid"
    }

    static func secondary(
        isSettingsOpen: Bool,
        phase: AskSession.Phase,
        activity: String,
        newestQuestion: String?,
        sessionTitle: String?,
        hotkeyDisplay: String,
        engineTitle: String
    ) -> String? {
        if isSettingsOpen {
            return "Optional overrides. Blank uses \(engineTitle) defaults."
        }
        // Live status wins while a turn streams.
        if phase == .running, !activity.isEmpty {
            return activity
        }
        if let sessionTitle, !sessionTitle.isEmpty,
           sessionTitle != primary(
            isSettingsOpen: isSettingsOpen,
            newestQuestion: newestQuestion,
            sessionTitle: sessionTitle
           ) {
            return sessionTitle
        }
        return "\(hotkeyDisplay) · ⌘↩ ask · Esc hide"
    }
}

/// One-line preview for the collapsed thinking disclosure: the tail of the
/// reasoning, whitespace-collapsed.
enum ThinkingPreview {
    static let characterLimit = 80

    static func line(from thinking: String) -> String {
        let collapsed = thinking.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > characterLimit else { return collapsed }
        return "…\(collapsed.suffix(characterLimit))"
    }
}

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
        // The HUD is a fixed dark surface. Force a dark appearance so system
        // controls (TextField, Picker, Toggle) don't fall back to light-mode
        // black text against the dark well fill.
        .environment(\.colorScheme, .dark)
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
        .accessibilityLabel(session.phase == .failed ? "AskDroid failed" : session.compactTitle)
        .accessibilityHint("Click to open AskDroid")
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
    @State private var thinkingExpanded = false
    @State private var fieldFocused = false
    @State private var answerContentHeight: CGFloat = 0
    @State private var answerContentMinY: CGFloat = 0
    @State private var answerViewportHeight: CGFloat = 0

    private var showsConversation: Bool {
        // Any history or a live turn makes the panel the conversation
        // surface; fresh idle state stays composer-only.
        !session.transcript.isEmpty || session.phase == .running
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
            } else if showsConversation {
                conversation
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
        // Top-aligned so the title line sits at a fixed y: the dot tracks it
        // instead of shifting when the secondary line's presence changes the
        // header height (a centered row would move the title, not the dot).
        // The 4 pt optically centers the 8 pt dot on the 13 pt title line.
        HStack(alignment: .top, spacing: 10) {
            StatusDot(phase: session.phase)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(HeaderLines.primary(
                    isSettingsOpen: session.isSettingsOpen,
                    newestQuestion: session.transcript.last?.question,
                    sessionTitle: session.sessionTitle
                ))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(session.transcript.last?.question ?? session.sessionTitle ?? "")
                if let secondary = HeaderLines.secondary(
                    isSettingsOpen: session.isSettingsOpen,
                    phase: session.phase,
                    activity: session.activity,
                    newestQuestion: session.transcript.last?.question,
                    sessionTitle: session.sessionTitle,
                    hotkeyDisplay: session.settings.hotkeyDisplay,
                    engineTitle: session.settings.engine.title
                ) {
                    Text(secondary)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.mute)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
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

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 0) {
            transcriptBlock
            Divider().overlay(Theme.hairline)
            footer
            composer
        }
    }

    /// Collapsed prior-turn rows and the full-size newest turn share one
    /// capped scroll so the panel never grows unbounded with history.
    private var transcriptBlock: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(priorTurns) { turn in
                            if turn.kind == .sessionBreak {
                                SessionBreakRow(notice: turn.question)
                            } else {
                                CollapsedTurnRow(
                                    turn: turn,
                                    isExpanded: session.expandedTurnIDs.contains(turn.id),
                                    onToggle: { session.toggleExpandedRow(turn.id) }
                                )
                            }
                        }
                        if !priorTurns.isEmpty {
                            Divider().overlay(Theme.hairline)
                        }
                        newestTurnContent
                        Color.clear
                            .frame(height: 1)
                            .id(AnswerScrollAnchor.bottom)                    }
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
                .frame(height: Self.transcriptScrollHeight(content: answerContentHeight, cap: 280))
                // Positioning is programmatic: turn start and completion pin
                // the newest question near the top; streaming follows the
                // bottom only while the user hasn't scrolled away (see the
                // answerContentHeight change handler below).
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
            .onChange(of: answerContentHeight) { _, _ in
                // Follow the stream while it grows, but only while the user
                // hasn't scrolled up to detach (answerIsNearBottom).
                guard session.phase == .running, answerIsNearBottom else { return }
                followAnswer(proxy)
            }
            .onChange(of: session.transcript.count) { _, _ in
                // Turn start: lead with the new question, history above the
                // fold. At this point the answer is empty, so the question
                // sits at the top of a short page and streaming can still
                // pin to the bottom seamlessly.
                thinkingExpanded = false
                scrollToQuestion(proxy)
            }
            .onChange(of: session.phase) { _, phase in
                switch phase {
                case .running:
                    activityLogExpanded = false
                case .completed, .interrupted:
                    // The turn settled: bring the question back into view
                    // with its answer below it.
                    scrollToQuestion(proxy)
                case .failed:
                    activityLogExpanded = true
                    scrollToQuestion(proxy)
                default:
                    break
                }
            }
            .onAppear {
                if session.phase == .failed {
                    activityLogExpanded = true
                }
                scrollToQuestion(proxy)
            }
        }
    }

    private var priorTurns: [Turn] {
        Array(session.transcript.dropLast())
    }

    /// Viewport height for the transcript scroll: short conversations hug
    /// their measured content, long ones cap exactly as the old open-ended
    /// `maxHeight` did. The measured height already includes the content's
    /// own vertical padding (the preference is posted from inside the scroll
    /// content's background), so it maps 1:1 onto the viewport and the loop
    /// is stable — the measurement depends on content and fixed width only,
    /// never on the frame this feeds. An unmeasured value (0, first layout
    /// pass only) reserves the cap.
    static func transcriptScrollHeight(content: CGFloat, cap: CGFloat) -> CGFloat {
        content > 0 ? min(content, cap) : cap
    }

    /// The newest turn renders full-size. Its mirrors on the session are kept
    /// in sync with this turn; older turns read their own `Turn` values.
    private var newestTurnContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(newestQuestion)
                .font(.system(size: 13))
                .foregroundStyle(Theme.mute)
                .lineSpacing(2)
                .textSelection(.enabled)
                .id(AnswerScrollAnchor.question)
            if session.phase == .failed, let errorMessage = session.errorMessage {
                failureBlock(errorMessage)
            }
            if let archiveError = session.archiveError {
                Text(archiveError)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dangerText)
                    .textSelection(.enabled)
            }
            if session.phase == .running, !session.thinking.isEmpty {
                // One collapsible line while streaming: a full thinking
                // paragraph pushes the answer below the fold. The reasoning
                // stays on the Turn for the transcript's expanded rows.
                DisclosureGroup(isExpanded: $thinkingExpanded) {
                    Text(session.thinking)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.mute)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Thinking…")
                        Text(ThinkingPreview.line(from: session.thinking))
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.mute)
            }
            if !session.answer.isEmpty {
                Markdown(session.answer)
                    .markdownTheme(AskDroidMarkdown.theme)
                    .lineSpacing(3)
                    .tracking(0.1)
                    .textSelection(.enabled)
            }
            // Live activity copy is deliberately not repeated here: the
            // header's secondary line already streams it (HeaderLines.secondary).
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
        }
    }

    private var newestQuestion: String {
        if let newest = session.transcript.last {
            return newest.question.isEmpty ? "Look at the attached image(s)." : newest.question
        }
        return session.prompt.isEmpty ? "Look at the attached image(s)." : session.prompt
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

            PromptEditor(
                text: $session.prompt,
                placeholder: composerPlaceholder,
                onSubmit: { session.submit() },
                onPasteImages: { session.attachFromPasteboard() },
                onFocusChange: { fieldFocused = $0 }
            )
            .onChange(of: session.prompt) { _, _ in
                // Typing is presence: the idle clock restarts.
                session.touchPresence()
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: Theme.fieldMinHeight, maxHeight: Theme.fieldMaxHeight)
            .contentShape(Rectangle())
            // All of the field's chrome (well fill and focus border) lives in
            // SwiftUI, driven by the focus state the AppKit editor reports up.
            .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.fieldCorner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.fieldCorner, style: .continuous)
                    .stroke(fieldFocused ? Theme.accent.opacity(0.85) : Theme.hairline, lineWidth: 1)
            }

            if !session.pending.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(session.pending) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(entry.mode == .steering ? "Steering…" : "Queued · after this turn")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(entry.mode == .steering ? Theme.accent : Theme.mute)
                            Text(entry.text)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.mute)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .help(entry.mode == .steering
                              ? "Injected into the turn in progress"
                              : "Sends automatically when the current turn finishes")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Pending messages: \(session.pending.map(\.text).joined(separator: ", "))")
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
                if session.phase == .running, session.engine.steersOnWire {
                    Button("Queue") { session.submit(.queue) }
                        .buttonStyle(GhostButtonStyle())
                        .help("Hold this and send it as the next turn")
                }
                Button(primarySendLabel) { session.submit() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!session.canSubmit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(primarySendHelp)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    /// The primary composer action: "Ask" when idle, otherwise the engine
    /// default for input typed mid-turn (steer on wire-steering engines,
    /// queue elsewhere). ⌘↩ triggers this.
    private var primarySendLabel: String {
        switch session.phase {
        case .running:
            session.engine.steersOnWire ? "Steer" : "Queue"
        default:
            "Ask"
        }
    }

    private var primarySendHelp: String {
        switch session.phase {
        case .running:
            session.engine.steersOnWire
                ? "Inject into the turn in progress"
                : "Hold this and send it as the next turn"
        default:
            "Send"
        }
    }

    private var composerPlaceholder: String {
        if session.phase == .running {
            return "Message \(session.settings.engine.title) while it works…"
        }
        return session.images.isEmpty ? "Ask \(session.settings.engine.title) anything" : "Add a note, or just send the image"
    }

    private var answerIsNearBottom: Bool {
        guard answerContentHeight > answerViewportHeight + 8 else { return true }
        return answerContentHeight + answerContentMinY <= answerViewportHeight + 28
    }

    private var answerHasOverflow: Bool {
        answerContentHeight > answerViewportHeight + 8
    }

    private func followAnswer(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(AnswerScrollAnchor.bottom, anchor: .bottom)
        }
    }

    /// Leads with the newest turn's question: history folds above it, the
    /// answer reads below it.
    private func scrollToQuestion(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(AnswerScrollAnchor.question, anchor: .top)
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
                Button("Cancel", action: session.interruptTurn)
                    .buttonStyle(GhostButtonStyle())
                    .help("Stop this turn; the conversation stays open")
            }
            if let durationText = session.durationText {
                MetaLabel(durationText)
            }
            if let tokenSummary = session.tokenSummary {
                MetaLabel(tokenSummary)
            }
            if let stats = session.contextStats {
                MetaLabel(stats.label)
                    .help("Context window fill reported by \(session.settings.engine.title)")
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
                    session.retryFailedTurn()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            if session.phase == .completed || session.phase == .failed || session.phase == .interrupted {
                Button {
                    session.startNewConversation()
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(GhostButtonStyle())
                .help("Start a new conversation")
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

/// A context break in the transcript: the idle-expired session was replaced
/// by a fresh one, so history above this line is no longer in the engine's
/// context. Muted divider idiom — hairlines flanking an 11 pt mute label.
struct SessionBreakRow: View {
    let notice: String

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text(notice)
                .font(.system(size: 11))
                .foregroundStyle(Theme.mute)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(notice)
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notice)
    }
}

/// One prior turn in the transcript: a single collapsed line — status glyph,
/// question, duration — that expands in place to reveal that turn's answer.
/// Repeats the established question-as-a-line row (13 pt, mute).
struct CollapsedTurnRow: View {
    let turn: Turn
    let isExpanded: Bool
    var onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onToggle) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: glyph)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(glyphColor)
                        .frame(width: 12)
                    Text(turn.question.isEmpty ? "Look at the attached image(s)." : turn.question)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.mute)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let duration = turn.durationText {
                        Text(duration)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.mute)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.mute)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(statusWord) turn: \(turn.question)")
            .accessibilityHint(isExpanded ? "Collapse this turn" : "Expand this turn")
            .help(turn.question)
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let error = turn.errorMessage {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.dangerText)
                            .textSelection(.enabled)
                    }
                    if !turn.answer.isEmpty {
                        Markdown(turn.answer)
                            .markdownTheme(AskDroidMarkdown.theme)
                            .lineSpacing(3)
                            .tracking(0.1)
                            .textSelection(.enabled)
                    } else if !turn.thinking.isEmpty {
                        Text(turn.thinking)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.mute)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 22)
                .transition(.opacity)
            }
        }
    }

    private var glyph: String {
        switch turn.status {
        case .completed: "checkmark"
        case .failed: "exclamationmark"
        case .interrupted: "stop.fill"
        case .running: "circle.dotted"
        }
    }

    private var glyphColor: Color {
        switch turn.status {
        case .completed: Theme.success
        case .failed: Theme.danger
        case .interrupted, .running: Theme.mute
        }
    }

    private var statusWord: String {
        switch turn.status {
        case .completed: "Completed"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        case .running: "Running"
        }
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


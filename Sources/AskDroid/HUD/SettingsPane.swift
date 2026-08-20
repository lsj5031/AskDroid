import SwiftUI

struct SettingsPane: View {
    @ObservedObject var session: AskSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeled("Engine") {
                Picker("", selection: $session.settings.engine) {
                    ForEach(Engine.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: session.settings.engine) { _, newEngine in
                    if newEngine == .droid && session.settings.reasoning.droidProtocolValue == nil && session.settings.reasoning != .defaultLevel {
                        session.settings.reasoning = .defaultLevel
                    }
                }
            }
            labeled("Hotkey") {
                HotkeyRecorder(
                    keyCode: $session.settings.hotkeyKeyCode,
                    modifiers: $session.settings.hotkeyModifiers
                )
            }
            Text("Click the field, then hold the modifiers and press a key. Needs ⌘, ⌃, or ⌥.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.mute)
            labeled("Model override") {
                SettingsTextField(placeholder: "Leave blank for \(session.settings.engine.title) default", text: $session.settings.modelOverride)
            }
            HStack(spacing: 12) {
                labeled("Reasoning") {
                    Picker("", selection: $session.settings.reasoning) {
                        ForEach(ReasoningSetting.cases(for: session.settings.engine)) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .padding(Theme.settingsControlPadding)
                    .settingsControlStyle()
                }
                labeled("Autonomy") {
                    Picker("", selection: $session.settings.autonomy) {
                        ForEach(AutonomySetting.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .padding(Theme.settingsControlPadding)
                    .settingsControlStyle()
                    .disabled(session.settings.engine == .pi)
                    .opacity(session.settings.engine == .pi ? 0.5 : 1.0)
                }
            }
            if session.settings.engine == .droid {
                Text("Default is High: Droid can edit files, run commands, and push inside the working directory. Choose Read-only to disable tools.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.mute)
            } else {
                Text("Autonomy is configurable for Droid only. Pi runs tools based on prompt context.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.mute)
            }
            labeled("Working directory") {
                SettingsTextField(placeholder: AppSettings.defaultWorkingDirectory, text: $session.settings.workingDirectory)
            }
            Text("\(session.settings.engine.title) starts in a sandbox, not your home folder. Change this only if a question needs another directory.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.mute)
            labeled("Answers folder") {
                SettingsTextField(placeholder: AppSettings.defaultAnswersDirectory, text: $session.settings.answersDirectory)
            }
            Text("Answers are saved under Application Support, not your home folder.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.mute)
            labeled("\(session.settings.engine.title) binary") {
                if session.settings.engine == .droid {
                    SettingsTextField(placeholder: "Discover automatically", text: $session.settings.droidPath)
                } else {
                    SettingsTextField(placeholder: "Discover automatically", text: $session.settings.piPath)
                }
            }
            Toggle("Launch at login", isOn: $session.settings.launchAtLogin)
                .toggleStyle(.switch)
                .settingsControlStyle(showsWell: false)
                .tint(Theme.accent)
            if session.settings.engine == .droid {
                Link("Droid documentation", destination: URL(string: "https://docs.factory.ai/droid-exec/overview")!)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
            } else {
                Link("Pi documentation", destination: URL(string: "https://pi.dev/docs/latest")!)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            HStack {
                Button("Quit", action: session.quit)
                    .buttonStyle(GhostButtonStyle())
                Spacer()
                Button("Save") {
                    session.saveSettings()
                    session.isSettingsOpen = false
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .foregroundStyle(Theme.ink)
        .font(.system(size: 13))
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.mute)
            content()
        }
    }
}

/// Settings text field styled like the composer: a well fill with a hairline
/// border that brightens on focus, instead of the system focus ring.
private struct SettingsTextField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .focused($focused)
            .padding(Theme.settingsControlPadding)
            .settingsControlStyle(isActive: focused)
    }
}

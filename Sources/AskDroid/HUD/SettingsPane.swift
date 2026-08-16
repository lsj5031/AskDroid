import SwiftUI

struct SettingsPane: View {
    @ObservedObject var session: AskSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                TextField("Leave blank for Droid default", text: $session.settings.modelOverride)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Theme.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack(spacing: 12) {
                labeled("Reasoning") {
                    Picker("", selection: $session.settings.reasoning) {
                        ForEach(ReasoningSetting.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                labeled("Autonomy") {
                    Picker("", selection: $session.settings.autonomy) {
                        ForEach(AutonomySetting.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
            Text("Default is High: Droid can edit files, run commands, and push inside the working directory. Choose Read-only to disable tools.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.mute)
            labeled("Working directory") {
                TextField(AppSettings.defaultWorkingDirectory, text: $session.settings.workingDirectory)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Theme.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text("Droid starts in a sandbox, not your home folder. Change this only if a question needs another directory.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.mute)
            labeled("Answers folder") {
                TextField(AppSettings.defaultAnswersDirectory, text: $session.settings.answersDirectory)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Theme.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text("Answers are saved under Application Support, not your home folder.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.mute)
            labeled("Droid binary") {
                TextField("Discover automatically", text: $session.settings.droidPath)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Theme.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Toggle("Launch at login", isOn: $session.settings.launchAtLogin)
                .toggleStyle(.switch)
                .tint(Theme.accent)
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

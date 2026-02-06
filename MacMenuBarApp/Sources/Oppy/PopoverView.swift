import AppKit
import SwiftUI

struct PopoverView: View {
    @ObservedObject var appState: AppStateStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Oppy")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(appState.state.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if case .recording = appState.state {
                Label(durationText(appState.elapsedSeconds), systemImage: "timer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !appState.progressDetail.isEmpty {
                Text(appState.progressDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text(appState.preflightStatus.summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if case let .error(message) = appState.state {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("Start") {
                    appState.startRecording()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!appState.canStart)

                Button("Stop") {
                    appState.stopRecording()
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(!appState.canStop)
            }

            Divider()

            HStack(spacing: 12) {
                Button("Open Transcripts Folder") {
                    appState.openTranscriptFolder()
                }
                Button("Settings") {
                    openSettingsWindow()
                }
            }

            if case let .error(message) = appState.state, message.localizedCaseInsensitiveContains("token") {
                Button("Add Hugging Face Token") {
                    openSettingsWindow()
                }
                .buttonStyle(.borderedProminent)
            }

            if case let .done(transcriptURL) = appState.state {
                Button("Open Last Transcript") {
                    NSWorkspace.shared.open(transcriptURL)
                }
            }

            Divider()

            Button("Quit Oppy") {
                NSApp.terminate(nil)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .onAppear {
            appState.refreshPreflightStatus()
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func openSettingsWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }
}

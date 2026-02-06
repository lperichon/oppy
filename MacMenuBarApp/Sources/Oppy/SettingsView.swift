import AppKit
import SwiftUI

struct SettingsView: View {
    private enum Field: Hashable {
        case hfToken
        case asrModel
        case diarizationModel
        case languageMode
        case transcriptFolder
    }

    @State private var transcriptFolderPath = SettingsStore.shared.transcriptFolderPath
    @State private var asrModel = SettingsStore.shared.defaultAsrModel
    @State private var diarizationModel = SettingsStore.shared.defaultDiarizationModel
    @State private var languageMode = SettingsStore.shared.languageMode
    @State private var saveJson = SettingsStore.shared.saveJsonMetadata
    @State private var keepWav = SettingsStore.shared.keepWavAfterProcessing
    @State private var hfTokenInput = ""
    @State private var tokenStatus = ""
    @FocusState private var focusedField: Field?

    private let keychain = KeychainService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Hugging Face Token") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Required for downloading and running pyannote diarization models.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        SecureField("hf_...", text: $hfTokenInput)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .hfToken)
                        HStack(spacing: 8) {
                            Button("Save Token") {
                                saveToken()
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Delete Token") {
                                deleteToken()
                            }
                            if !tokenStatus.isEmpty {
                                Text(tokenStatus)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(8)
                }

                GroupBox("Models") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("ASR model", text: $asrModel)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .asrModel)
                        TextField("Diarization model", text: $diarizationModel)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .diarizationModel)
                        TextField("Language mode (auto or code)", text: $languageMode)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .languageMode)
                    }
                    .padding(8)
                }

                GroupBox("Storage") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField("Transcript folder", text: $transcriptFolderPath)
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: .transcriptFolder)
                            Button("Choose") {
                                chooseFolder()
                            }
                        }
                        Toggle("Save JSON metadata", isOn: $saveJson)
                        Toggle("Keep WAV after processing", isOn: $keepWav)
                    }
                    .padding(8)
                }

                HStack {
                    Spacer()
                    Button("Save Settings") {
                        saveSettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            refreshTokenStatus()
            DispatchQueue.main.async {
                focusedField = .hfToken
                NSApp.keyWindow?.makeKeyAndOrderFront(nil)
            }
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func saveSettings() {
        SettingsStore.shared.transcriptFolderPath = transcriptFolderPath
        SettingsStore.shared.defaultAsrModel = asrModel
        SettingsStore.shared.defaultDiarizationModel = diarizationModel
        SettingsStore.shared.languageMode = languageMode.isEmpty ? "auto" : languageMode
        SettingsStore.shared.saveJsonMetadata = saveJson
        SettingsStore.shared.keepWavAfterProcessing = keepWav
        tokenStatus = "Settings saved"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            transcriptFolderPath = url.path
        }
    }

    private func saveToken() {
        let trimmed = hfTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            tokenStatus = "Enter a token first"
            return
        }

        do {
            try keychain.saveToken(trimmed)
            hfTokenInput = ""
            tokenStatus = "Token saved to Keychain"
        } catch {
            tokenStatus = "Could not save token"
        }
    }

    private func deleteToken() {
        do {
            try keychain.deleteToken()
            tokenStatus = "Token deleted"
        } catch {
            tokenStatus = "Could not delete token"
        }
    }

    private func refreshTokenStatus() {
        do {
            let token = try keychain.readToken()
            tokenStatus = token.isEmpty ? "No token stored" : "Token already configured"
        } catch {
            tokenStatus = "Could not read token state"
        }
    }
}

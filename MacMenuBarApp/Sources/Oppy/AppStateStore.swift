import AVFoundation
import AppKit
import Foundation
import SwiftUI

enum SessionState: Equatable {
    case idle
    case recording
    case processing
    case done(URL)
    case error(String)

    var statusText: String {
        switch self {
        case .idle:
            return "Idle"
        case .recording:
            return "Recording"
        case .processing:
            return "Processing"
        case .done:
            return "Done"
        case .error:
            return "Error"
        }
    }
}

@MainActor
final class AppStateStore: ObservableObject {
    @Published var state: SessionState = .idle
    @Published var elapsedSeconds: TimeInterval = 0
    @Published var progressDetail: String = ""
    @Published var latestError: String?

    private let recorder = AudioRecorder()
    private let workerLauncher = WorkerLauncher()
    private let settings = SettingsStore.shared
    private let keychain = KeychainService()
    private var timer: Timer?
    private var sessionStartDate: Date?
    private var currentAudioURL: URL?

    var menuBarIconName: String {
        switch state {
        case .idle:
            return "waveform"
        case .recording:
            return "record.circle.fill"
        case .processing:
            return "gearshape.2.fill"
        case .done:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    var canStart: Bool {
        switch state {
        case .idle, .done, .error:
            return true
        case .recording, .processing:
            return false
        }
    }

    var canStop: Bool {
        if case .recording = state {
            return true
        }
        return false
    }

    func startRecording() {
        Task {
            await startRecordingInternal()
        }
    }

    func stopRecording() {
        Task {
            await stopRecordingInternal()
        }
    }

    func openTranscriptFolder() {
        let expandedPath = (settings.transcriptFolderPath as NSString).expandingTildeInPath
        let baseFolder = URL(fileURLWithPath: expandedPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: baseFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(baseFolder)
    }

    private func makeSessionURLs() throws -> (audio: URL, outputFolder: URL, dateFolder: String) {
        let now = Date()
        let dateFolder = DateFormatter.sessionDateFolder.string(from: now)
        let timestamp = DateFormatter.sessionTimestamp.string(from: now)
        let outputFolder = URL(fileURLWithPath: settings.transcriptFolderPath)
            .appendingPathComponent(dateFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        let audioURL = outputFolder
            .appendingPathComponent("Meeting-\(timestamp)")
            .appendingPathExtension("wav")
        return (audioURL, outputFolder, dateFolder)
    }

    private func startRecordingInternal() async {
        guard canStart else { return }
        latestError = nil
        progressDetail = ""

        let authorized = await requestMicrophoneAccessIfNeeded()
        guard authorized else {
            state = .error("Microphone permission denied. Enable access in System Settings > Privacy & Security > Microphone.")
            return
        }

        do {
            let sessionURLs = try makeSessionURLs()
            try recorder.startRecording(to: sessionURLs.audio)
            currentAudioURL = sessionURLs.audio
            sessionStartDate = Date()
            elapsedSeconds = 0
            startTimer()
            state = .recording
        } catch {
            state = .error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    private func stopRecordingInternal() async {
        guard canStop else { return }
        state = .processing
        stopTimer()
        progressDetail = "Finalizing recording..."

        do {
            try recorder.stopRecording()
            guard let audioURL = currentAudioURL else {
                throw NSError(domain: "Oppy", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Missing recording file URL"])
            }

            let hfToken = try keychain.readToken()
            guard !hfToken.isEmpty else {
                throw NSError(domain: "Oppy", code: 1002, userInfo: [NSLocalizedDescriptionKey: "No Hugging Face token found. Add one in Settings."])
            }

            let sessionID = UUID().uuidString
            let outputDirectory = audioURL.deletingLastPathComponent()
            let config = WorkerConfig(
                sessionID: sessionID,
                inputWavPath: audioURL.path,
                outputDirectory: outputDirectory.path,
                asrModel: settings.defaultAsrModel,
                diarizationModel: settings.defaultDiarizationModel,
                language: settings.languageMode,
                saveJson: settings.saveJsonMetadata,
                keepWav: settings.keepWavAfterProcessing
            )

            let result = try await workerLauncher.run(config: config, hfToken: hfToken) { [weak self] update in
                Task { @MainActor in
                    self?.progressDetail = update
                }
            }

            if result.success, let transcriptPath = result.transcriptPath {
                let transcriptURL = URL(fileURLWithPath: transcriptPath)
                progressDetail = "Saved transcript: \(transcriptURL.lastPathComponent)"
                state = .done(transcriptURL)
            } else {
                let message = result.message ?? "Unknown worker error"
                state = .error(message)
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func requestMicrophoneAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .restricted, .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.sessionStartDate else { return }
                self.elapsedSeconds = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

extension DateFormatter {
    static let sessionDateFolder: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let sessionTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

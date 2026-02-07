import AVFoundation
import AppKit
import CoreGraphics
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

struct PreflightStatus {
    let microphoneReady: Bool
    let screenAudioReady: Bool
    let tokenReady: Bool

    var summaryText: String {
        "Mic: \(flag(microphoneReady))  Screen Audio: \(flag(screenAudioReady))  Token: \(flag(tokenReady))"
    }

    private static func flag(_ value: Bool) -> String {
        value ? "OK" : "Missing"
    }

    private func flag(_ value: Bool) -> String {
        Self.flag(value)
    }
}

@MainActor
final class AppStateStore: ObservableObject {
    @Published var state: SessionState = .idle
    @Published var elapsedSeconds: TimeInterval = 0
    @Published var progressDetail: String = ""
    @Published var bootstrapDetail: String = ""
    @Published var latestError: String?
    @Published var preflightStatus = PreflightStatus(microphoneReady: false, screenAudioReady: false, tokenReady: false)

    private let recorder = AudioRecorder()
    private let workerLauncher = WorkerLauncher()
    private let settings = SettingsStore.shared
    private let keychain = KeychainService()
    private var timer: Timer?
    private var sessionStartDate: Date?
    private var currentAudioURL: URL?
    private var bootstrapTask: Task<Void, Never>?
    private var asrBootstrapObserver: NSObjectProtocol?

    init() {
        refreshPreflightStatus()
        asrBootstrapObserver = NotificationCenter.default.addObserver(
            forName: .oppyASRBootstrapRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleASRBootstrapIfNeeded(force: true)
            }
        }
        scheduleASRBootstrapIfNeeded(force: false)
    }

    deinit {
        if let asrBootstrapObserver {
            NotificationCenter.default.removeObserver(asrBootstrapObserver)
        }
        bootstrapTask?.cancel()
    }

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

    func refreshPreflightStatus() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let microphoneReady = (micStatus == .authorized)
        let screenAudioReady = CGPreflightScreenCaptureAccess()
        let tokenReady: Bool
        do {
            tokenReady = !(try keychain.readToken()).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            tokenReady = false
        }
        preflightStatus = PreflightStatus(
            microphoneReady: microphoneReady,
            screenAudioReady: screenAudioReady,
            tokenReady: tokenReady
        )
    }

    private func scheduleASRBootstrapIfNeeded(force: Bool) {
        guard bootstrapTask == nil else { return }

        let model = settings.defaultAsrModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty {
            bootstrapDetail = "ASR warmup skipped: model is empty"
            return
        }

        if !force, settings.lastBootstrappedAsrModel == model {
            return
        }

        let language = settings.languageMode.isEmpty ? "auto" : settings.languageMode
        bootstrapDetail = "Warming ASR model cache..."

        bootstrapTask = Task { [weak self] in
            guard let self else { return }
            defer { self.bootstrapTask = nil }
            do {
                let result = try await self.workerLauncher.bootstrapASRModel(
                    asrModel: model,
                    language: language
                ) { [weak self] update in
                    Task { @MainActor in
                        self?.bootstrapDetail = update
                    }
                }
                if result.success {
                    self.settings.lastBootstrappedAsrModel = model
                    self.bootstrapDetail = "ASR model ready"
                } else {
                    self.bootstrapDetail = result.message ?? "ASR warmup failed"
                }
            } catch {
                self.bootstrapDetail = "ASR warmup failed: \(error.localizedDescription)"
            }
        }
    }

    private func makeSessionURLs() throws -> (audio: URL, outputFolder: URL, dateFolder: String) {
        let now = Date()
        let dateFolder = DateFormatter.sessionDateFolder.string(from: now)
        let timestamp = DateFormatter.sessionTimestamp.string(from: now)
        let expandedPath = (settings.transcriptFolderPath as NSString).expandingTildeInPath
        let outputFolder = URL(fileURLWithPath: expandedPath)
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
        refreshPreflightStatus()
        guard authorized else {
            state = .error("Microphone permission denied. Enable access in System Settings > Privacy & Security > Microphone.")
            return
        }

        let screenAuthorized = requestScreenCaptureAccessIfNeeded()
        refreshPreflightStatus()
        guard screenAuthorized else {
            state = .error("Screen and system audio capture permission denied. Enable access in System Settings > Privacy & Security > Screen Recording.")
            return
        }

        do {
            let sessionURLs = try makeSessionURLs()
            try await recorder.startRecording(to: sessionURLs.audio)
            currentAudioURL = sessionURLs.audio
            sessionStartDate = Date()
            elapsedSeconds = 0
            startTimer()
            state = .recording
        } catch {
            state = .error("Failed to start recording: \(error.localizedDescription)")
        }
        refreshPreflightStatus()
    }

    private func stopRecordingInternal() async {
        guard canStop else { return }
        state = .processing
        stopTimer()
        progressDetail = "Finalizing recording..."

        do {
            try await recorder.stopRecording()
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
                writeWorkerErrorLog(message)
                state = .error(message)
            }
        } catch {
            writeWorkerErrorLog(error.localizedDescription)
            state = .error(error.localizedDescription)
        }
        refreshPreflightStatus()
    }

    private func writeWorkerErrorLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let body = "[\(timestamp)] \(message)\n"
        let fileURL = URL(fileURLWithPath: "/tmp/oppy-worker-last-error.log")
        do {
            try body.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Oppy: failed to write worker error log: \(error.localizedDescription)")
        }
        NSLog("Oppy worker error: \(message)")
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

    private func requestScreenCaptureAccessIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return CGRequestScreenCaptureAccess()
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

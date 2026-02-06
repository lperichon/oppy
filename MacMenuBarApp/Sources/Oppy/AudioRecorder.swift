import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

final class AudioRecorder: NSObject {
    private enum TargetTrack {
        case system
        case microphone
    }

    private let sampleBufferQueue = DispatchQueue(label: "oppy.audio.recorder.samplebuffers")

    private var stream: SCStream?
    private var systemFile: AVAudioFile?
    private var microphoneFile: AVAudioFile?
    private var outputURL: URL?
    private var microphoneURL: URL?
    private var isRecording = false
    private var streamFailure: Error?
    private var microphoneEngine: AVAudioEngine?
    private var fallbackMicrophoneFile: AVAudioFile?

    func startRecording(to outputURL: URL) async throws {
        guard !isRecording else {
            throw NSError(domain: "Oppy", code: 3001, userInfo: [NSLocalizedDescriptionKey: "Recorder already running"])
        }

        let micURL = outputURL.deletingPathExtension().appendingPathExtension("mic.wav")
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: micURL)

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw NSError(domain: "Oppy", code: 3003, userInfo: [NSLocalizedDescriptionKey: "No available display for system audio capture"])
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.capturesAudio = true
        if #available(macOS 15.0, *) {
            configuration.captureMicrophone = true
        }
        configuration.excludesCurrentProcessAudio = false
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleBufferQueue)
        if #available(macOS 15.0, *) {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleBufferQueue)
        } else {
            try startMicrophoneFallbackCapture(to: micURL)
        }

        self.stream = stream
        self.outputURL = outputURL
        self.microphoneURL = micURL
        self.systemFile = nil
        self.microphoneFile = nil
        self.streamFailure = nil

        try await stream.startCapture()
        isRecording = true
    }

    func stopRecording() async throws {
        guard isRecording else {
            throw NSError(domain: "Oppy", code: 3002, userInfo: [NSLocalizedDescriptionKey: "Recorder is not running"])
        }

        if let stream {
            try await stream.stopCapture()
            self.stream = nil
        }

        stopMicrophoneFallbackCapture()

        sampleBufferQueue.sync {}

        systemFile = nil
        microphoneFile = nil
        isRecording = false

        if let streamFailure {
            throw streamFailure
        }
    }

    private func startMicrophoneFallbackCapture(to microphoneURL: URL) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let file = try AVAudioFile(forWriting: microphoneURL, settings: format.settings)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            do {
                try file.write(from: buffer)
            } catch {
                self?.streamFailure = error
            }
        }

        engine.prepare()
        try engine.start()
        microphoneEngine = engine
        fallbackMicrophoneFile = file
    }

    private func stopMicrophoneFallbackCapture() {
        microphoneEngine?.inputNode.removeTap(onBus: 0)
        microphoneEngine?.stop()
        microphoneEngine = nil
        fallbackMicrophoneFile = nil
    }

    private func writeSampleBuffer(_ sampleBuffer: CMSampleBuffer, to target: TargetTrack) throws {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return }
        guard let format = AVAudioFormat(streamDescription: streamDescription) else { return }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return }

        switch target {
        case .system:
            guard let outputURL else { return }
            if systemFile == nil {
                systemFile = try AVAudioFile(forWriting: outputURL, settings: format.settings)
            }
            guard let systemFile else { return }
            try writeSampleBuffer(sampleBuffer, using: systemFile, format: format, frameCount: frameCount)

        case .microphone:
            guard let microphoneURL else { return }
            if microphoneFile == nil {
                microphoneFile = try AVAudioFile(forWriting: microphoneURL, settings: format.settings)
            }
            guard let microphoneFile else { return }
            try writeSampleBuffer(sampleBuffer, using: microphoneFile, format: format, frameCount: frameCount)
        }
    }

    private func writeSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        using file: AVAudioFile,
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount
    ) throws {
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "Oppy", code: 3004, userInfo: [NSLocalizedDescriptionKey: "Could not allocate audio buffer"])
        }
        pcmBuffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else {
            throw NSError(domain: "Oppy", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to copy audio buffer data"])
        }

        try file.write(from: pcmBuffer)
    }
}

extension AudioRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard isRecording else { return }

        do {
            if outputType == .audio {
                try writeSampleBuffer(sampleBuffer, to: .system)
            } else if #available(macOS 15.0, *), outputType == .microphone {
                try writeSampleBuffer(sampleBuffer, to: .microphone)
            }
        } catch {
            streamFailure = error
        }
    }
}

extension AudioRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        streamFailure = error
    }
}

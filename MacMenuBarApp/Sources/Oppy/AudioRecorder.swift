import AVFoundation
import Foundation

final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var isRecording = false

    func startRecording(to outputURL: URL) throws {
        guard !isRecording else {
            throw NSError(domain: "Oppy", code: 3001, userInfo: [NSLocalizedDescriptionKey: "Recorder already running"])
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        file = try AVAudioFile(forWriting: outputURL, settings: format.settings)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let file = self.file else { return }
            do {
                try file.write(from: buffer)
            } catch {
                NSLog("Oppy recorder write error: \(error.localizedDescription)")
            }
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stopRecording() throws {
        guard isRecording else {
            throw NSError(domain: "Oppy", code: 3002, userInfo: [NSLocalizedDescriptionKey: "Recorder is not running"])
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        isRecording = false
    }
}

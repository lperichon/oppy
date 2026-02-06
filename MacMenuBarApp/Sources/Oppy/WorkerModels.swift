import Foundation

struct WorkerConfig: Codable {
    let sessionID: String
    let inputWavPath: String
    let outputDirectory: String
    let asrModel: String
    let diarizationModel: String
    let language: String
    let saveJson: Bool
    let keepWav: Bool

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case inputWavPath = "input_wav_path"
        case outputDirectory = "output_dir"
        case asrModel = "asr_model"
        case diarizationModel = "diarization_model"
        case language
        case saveJson = "save_json"
        case keepWav = "keep_wav"
    }
}

struct WorkerProgressEvent: Codable {
    let type: String
    let stage: String?
    let message: String?
}

struct WorkerResult: Codable {
    let type: String
    let success: Bool
    let transcriptPath: String?
    let wavPath: String?
    let jsonPath: String?
    let errorCode: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case type
        case success
        case transcriptPath = "transcript_path"
        case wavPath = "wav_path"
        case jsonPath = "json_path"
        case errorCode = "error_code"
        case message
    }
}

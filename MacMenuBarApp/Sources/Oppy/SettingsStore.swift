import Foundation

final class SettingsStore {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let transcriptFolderPath = "settings.transcriptFolderPath"
        static let defaultAsrModel = "settings.defaultAsrModel"
        static let defaultDiarizationModel = "settings.defaultDiarizationModel"
        static let languageMode = "settings.languageMode"
        static let saveJsonMetadata = "settings.saveJsonMetadata"
        static let keepWavAfterProcessing = "settings.keepWavAfterProcessing"
        static let lastBootstrappedAsrModel = "settings.lastBootstrappedAsrModel"
    }

    var transcriptFolderPath: String {
        get {
            defaults.string(forKey: Keys.transcriptFolderPath)
                ?? NSHomeDirectory() + "/Documents/Meeting Transcripts"
        }
        set { defaults.set(newValue, forKey: Keys.transcriptFolderPath) }
    }

    var defaultAsrModel: String {
        get {
            defaults.string(forKey: Keys.defaultAsrModel)
                ?? "mlx-community/whisper-large-v3-turbo-asr-fp16"
        }
        set { defaults.set(newValue, forKey: Keys.defaultAsrModel) }
    }

    var defaultDiarizationModel: String {
        get {
            defaults.string(forKey: Keys.defaultDiarizationModel)
                ?? "pyannote/speaker-diarization-3.1"
        }
        set { defaults.set(newValue, forKey: Keys.defaultDiarizationModel) }
    }

    var languageMode: String {
        get {
            defaults.string(forKey: Keys.languageMode) ?? "auto"
        }
        set { defaults.set(newValue, forKey: Keys.languageMode) }
    }

    var saveJsonMetadata: Bool {
        get {
            defaults.object(forKey: Keys.saveJsonMetadata) as? Bool ?? false
        }
        set { defaults.set(newValue, forKey: Keys.saveJsonMetadata) }
    }

    var keepWavAfterProcessing: Bool {
        get {
            defaults.object(forKey: Keys.keepWavAfterProcessing) as? Bool ?? true
        }
        set { defaults.set(newValue, forKey: Keys.keepWavAfterProcessing) }
    }

    var lastBootstrappedAsrModel: String {
        get {
            defaults.string(forKey: Keys.lastBootstrappedAsrModel) ?? ""
        }
        set { defaults.set(newValue, forKey: Keys.lastBootstrappedAsrModel) }
    }
}

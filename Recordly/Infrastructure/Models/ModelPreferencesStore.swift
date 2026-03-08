import Foundation

final class ModelPreferencesStore {
    private enum Keys {
        static let selectedProfile = "model.selectedProfile"
        static let pendingProfile = "model.pendingProfile"
        static let onboardingSeen = "model.onboardingSeen"
        static let selectedASRModelID = "model.selectedASRModelID"
        static let selectedASRLanguage = "model.selectedASRLanguage"
        static let selectedASRBackend = "model.selectedASRBackend"
        static let selectedDiarizationModelID = "model.selectedDiarizationModelID"
        static let selectedSummarizationModelID = "model.selectedSummarizationModelID"
        static let summarizationContextSize = "model.summarization.contextSize"
        static let summarizationTemperature = "model.summarization.temperature"
        static let summarizationTopP = "model.summarization.topP"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedProfile: ModelProfile {
        get {
            guard let rawValue = defaults.string(forKey: Keys.selectedProfile),
                  let value = ModelProfile(rawValue: rawValue) else {
                return .balanced
            }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.selectedProfile) }
    }

    var pendingProfileSelection: ModelProfile? {
        get {
            guard let rawValue = defaults.string(forKey: Keys.pendingProfile) else { return nil }
            return ModelProfile(rawValue: rawValue)
        }
        set { defaults.set(newValue?.rawValue, forKey: Keys.pendingProfile) }
    }

    var onboardingSeen: Bool {
        get { defaults.bool(forKey: Keys.onboardingSeen) }
        set { defaults.set(newValue, forKey: Keys.onboardingSeen) }
    }

    var selectedASRModelID: String? {
        get { defaults.string(forKey: Keys.selectedASRModelID) }
        set { defaults.set(newValue, forKey: Keys.selectedASRModelID) }
    }

    var selectedASRLanguage: ASRLanguage {
        get {
            guard let rawValue = defaults.string(forKey: Keys.selectedASRLanguage),
                  let value = ASRLanguage(rawValue: rawValue) else {
                return .ru
            }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.selectedASRLanguage) }
    }

    var selectedASRBackend: ASRBackend {
        get {
            guard let rawValue = defaults.string(forKey: Keys.selectedASRBackend),
                  let value = ASRBackend(rawValue: rawValue) else {
                return .whisperCpp
            }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.selectedASRBackend) }
    }

    var selectedDiarizationModelID: String? {
        get { defaults.string(forKey: Keys.selectedDiarizationModelID) }
        set { defaults.set(newValue, forKey: Keys.selectedDiarizationModelID) }
    }

    var selectedSummarizationModelID: String? {
        get { defaults.string(forKey: Keys.selectedSummarizationModelID) }
        set { defaults.set(newValue, forKey: Keys.selectedSummarizationModelID) }
    }

    var summarizationRuntimeSettings: SummarizationRuntimeSettings {
        get {
            let savedContextSize = defaults.object(forKey: Keys.summarizationContextSize) as? NSNumber
            let savedTemperature = defaults.object(forKey: Keys.summarizationTemperature) as? NSNumber
            let savedTopP = defaults.object(forKey: Keys.summarizationTopP) as? NSNumber

            return SummarizationRuntimeSettings(
                contextSize: (savedContextSize?.intValue ?? 0) > 0
                    ? (savedContextSize?.intValue ?? SummarizationRuntimeSettings.default.contextSize)
                    : SummarizationRuntimeSettings.default.contextSize,
                temperature: savedTemperature?.doubleValue ?? SummarizationRuntimeSettings.default.temperature,
                topP: savedTopP?.doubleValue ?? SummarizationRuntimeSettings.default.topP
            )
        }
        set {
            defaults.set(newValue.contextSize, forKey: Keys.summarizationContextSize)
            defaults.set(newValue.temperature, forKey: Keys.summarizationTemperature)
            defaults.set(newValue.topP, forKey: Keys.summarizationTopP)
        }
    }
}

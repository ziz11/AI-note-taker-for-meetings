import Foundation

final class ModelPreferencesStore {
    private enum Keys {
        static let selectedProfile = "model.selectedProfile"
        static let pendingProfile = "model.pendingProfile"
        static let onboardingSeen = "model.onboardingSeen"
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
}

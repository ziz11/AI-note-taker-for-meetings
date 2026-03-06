import Foundation

@MainActor
final class ModelManager: ObservableObject {
    @Published private(set) var installStates: [String: ModelInstallState] = [:]

    private let registry: ModelRegistry
    private let storage: ModelStorage
    private let downloader: ModelDownloader
    private let preferences: ModelPreferencesStore

    init(
        registry: ModelRegistry = ModelRegistry(),
        storage: ModelStorage = ModelStorage(),
        preferences: ModelPreferencesStore = ModelPreferencesStore()
    ) {
        self.registry = registry
        self.storage = storage
        self.preferences = preferences
        self.downloader = ModelDownloader(storage: storage)
    }

    var onboardingSeen: Bool {
        get { preferences.onboardingSeen }
        set { preferences.onboardingSeen = newValue }
    }

    var selectedProfile: ModelProfile {
        get { preferences.selectedProfile }
        set { preferences.selectedProfile = newValue }
    }

    var pendingProfileSelection: ModelProfile? {
        get { preferences.pendingProfileSelection }
        set { preferences.pendingProfileSelection = newValue }
    }

    func install(profile: ModelProfile) async {
        let descriptors = registry.loadModels().filter { $0.profile == profile }
        for descriptor in descriptors {
            await install(modelID: descriptor.id)
        }
    }

    func install(modelID: String) async {
        guard let descriptor = registry.loadModels().first(where: { $0.id == modelID }) else {
            installStates[modelID] = .failed(reason: "Model not found in registry")
            return
        }

        if storage.isInstallationValid(for: descriptor) {
            installStates[modelID] = .installed
            return
        }

        installStates[modelID] = .downloading(progress: 0)

        do {
            _ = try await downloader.downloadAndInstall(descriptor: descriptor) { [weak self] progress in
                Task { @MainActor in
                    self?.installStates[modelID] = .downloading(progress: progress)
                }
            }
            installStates[modelID] = storage.isInstallationValid(for: descriptor) ? .installed : .failed(reason: "Installed model validation failed")
        } catch {
            try? storage.removeModel(modelID: descriptor.id, kind: descriptor.kind)
            installStates[modelID] = .failed(reason: error.localizedDescription)
        }
    }

    func remove(modelID: String) {
        guard let descriptor = registry.loadModels().first(where: { $0.id == modelID }) else { return }
        try? storage.removeModel(modelID: modelID, kind: descriptor.kind)
        installStates[modelID] = .notInstalled
    }

    func installationState(for modelID: String) -> ModelInstallState {
        if let existing = installStates[modelID], case .downloading = existing {
            return existing
        }

        guard let descriptor = registry.loadModels().first(where: { $0.id == modelID }) else {
            return .failed(reason: "Model not found in registry")
        }

        return storage.isInstallationValid(for: descriptor) ? .installed : .notInstalled
    }

    func resolveInstalledModelURL(modelID: String) -> URL? {
        guard let descriptor = registry.loadModels().first(where: { $0.id == modelID }),
              storage.isInstallationValid(for: descriptor) else {
            return nil
        }
        return storage.canonicalModelURL(modelID: descriptor.id, kind: descriptor.kind)
    }

    func availability(for profile: ModelProfile) -> TranscriptionAvailability {
        let profileASR = registry.loadModels().first(where: { $0.profile == profile && $0.kind == .asr })
        guard let profileASR else {
            return .requiresASRModel(profileOptions: ModelProfile.allCases)
        }

        return storage.isInstallationValid(for: profileASR)
            ? .available
            : .requiresASRModel(profileOptions: ModelProfile.allCases)
    }
}

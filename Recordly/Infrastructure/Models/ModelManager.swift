import Foundation

struct ModelDiscoveryPaths {
    let appSupportDirectory: (ModelKind) -> URL?
    let sharedDirectory: (ModelKind) -> URL?
    let userDirectory: (ModelKind) -> URL?
    let projectDirectories: () -> [URL]
    var fluidAudioSDKDirectory: () -> URL? = { nil }

    static func live() -> ModelDiscoveryPaths {
        ModelDiscoveryPaths(
            appSupportDirectory: { kind in
                try? AppPaths.modelsDirectory(kind: kind)
            },
            sharedDirectory: { kind in
                try? AppPaths.sharedModelsDirectory(kind: kind)
            },
            userDirectory: { kind in
                AppPaths.userModelsDirectory(kind: kind)
            },
            projectDirectories: {
                AppPaths.projectLocalModelsDirectories()
            },
            fluidAudioSDKDirectory: {
                AppPaths.fluidAudioSDKModelsDirectory()
            }
        )
    }
}

@MainActor
final class ModelManager: ObservableObject {
    @Published private(set) var installStates: [String: ModelInstallState] = [:]

    private let registry: ModelRegistry
    private let storage: ModelStorage
    private let downloader: ModelDownloader
    private let preferences: ModelPreferencesStore
    private let fileManager: FileManager
    private let discoveryPaths: ModelDiscoveryPaths

    init(
        registry: ModelRegistry = ModelRegistry(),
        storage: ModelStorage = ModelStorage(),
        preferences: ModelPreferencesStore = ModelPreferencesStore(),
        fileManager: FileManager = .default,
        discoveryPaths: ModelDiscoveryPaths? = nil
    ) {
        self.registry = registry
        self.storage = storage
        self.preferences = preferences
        self.downloader = ModelDownloader(storage: storage)
        self.fileManager = fileManager
        self.discoveryPaths = discoveryPaths ?? .live()
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

    var selectedDiarizationModelID: String? {
        get { preferences.selectedDiarizationModelID }
        set { preferences.selectedDiarizationModelID = newValue }
    }

    var selectedSummarizationModelID: String? {
        get { preferences.selectedSummarizationModelID }
        set { preferences.selectedSummarizationModelID = newValue }
    }

    var summarizationRuntimeSettings: SummarizationRuntimeSettings {
        get { preferences.summarizationRuntimeSettings }
        set { preferences.summarizationRuntimeSettings = newValue }
    }

    // MARK: Legacy install flow (kept for onboarding compatibility)

    func install(profile: ModelProfile) async {
        let descriptors = registry.loadModels().filter { $0.profile == profile && $0.kind != .asr }
        if descriptors.isEmpty {
            return
        }

        for descriptor in descriptors {
            await install(modelID: descriptor.id)
        }
    }

    func install(modelID: String) async {
        if let descriptor = registry.loadModels().first(where: { $0.id == modelID }) {
            if descriptor.kind == .asr {
                installStates[modelID] = .installed
                return
            }
            await installRegistryModel(descriptor)
            return
        }

        if fileManager.fileExists(atPath: modelID) {
            installStates[modelID] = .installed
        } else {
            installStates[modelID] = .failed(reason: "Model file not found")
        }
    }

    func retry(modelID: String) async {
        await install(modelID: modelID)
    }

    func remove(modelID: String) {
        if let descriptor = registry.loadModels().first(where: { $0.id == modelID }) {
            if descriptor.kind == .asr {
                installStates[modelID] = .notInstalled
                return
            }
            try? storage.removeModel(modelID: modelID, kind: descriptor.kind)
            installStates[modelID] = .notInstalled
            return
        }

        installStates[modelID] = fileManager.fileExists(atPath: modelID) ? .installed : .notInstalled
    }

    // MARK: Dynamic model catalog

    func listLocalOptions(kind: ModelKind) -> [LocalModelOption] {
        guard kind != .asr else { return [] }
        let options = loadAppSupportOptions(kind: kind)
            + loadSharedOptions(kind: kind)
            + loadUserLocalOptions(kind: kind)
            + loadProjectLocalOptions(kind: kind)
        var seen = Set<String>()
        return options.filter { option in
            seen.insert(modelIdentity(for: option)).inserted
        }
    }

    func selectedLocalOption(kind: ModelKind) -> LocalModelOption? {
        guard kind != .asr else {
            return nil
        }

        let options = listLocalOptions(kind: kind)
        guard !options.isEmpty else {
            setSelectedModelID(nil, for: kind)
            return nil
        }

        if let selectedID = selectedModelID(for: kind),
           let selected = options.first(where: { $0.id == selectedID }) {
            return selected
        }

        return nil
    }

    func setSelectedModelID(_ modelID: String?, for kind: ModelKind) {
        switch kind {
        case .asr:
            return
        case .diarization:
            selectedDiarizationModelID = modelID
        case .summarization:
            selectedSummarizationModelID = modelID
        }
    }

    func selectedModelID(for kind: ModelKind) -> String? {
        switch kind {
        case .asr:
            return nil
        case .diarization:
            return selectedDiarizationModelID
        case .summarization:
            return selectedSummarizationModelID
        }
    }

    func modelsDirectory(kind: ModelKind, source: LocalModelOption.Source) -> URL? {
        switch source {
        case .shared:
            return discoveryPaths.sharedDirectory(kind)
        case .appSupport:
            return discoveryPaths.appSupportDirectory(kind)
        case .userLocal:
            return discoveryPaths.userDirectory(kind)
        case .projectLocal:
            return discoveryPaths.projectDirectories().first
        }
    }

    // MARK: Runtime state and resolution

    func availability(for profile: ModelProfile) -> TranscriptionAvailability {
        if selectedLocalOption(kind: .diarization) == nil {
            return .degradedNoDiarization
        }

        return .ready
    }

    func resolveInstalledModelURL(modelID: String) -> URL? {
        if let descriptor = registry.loadModels().first(where: { $0.id == modelID }),
           storage.isInstallationValid(for: descriptor) {
            return storage.canonicalModelURL(modelID: descriptor.id, kind: descriptor.kind)
        }

        let url = URL(fileURLWithPath: modelID)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func installationState(for modelID: String) -> ModelInstallState {
        if let existing = installStates[modelID], case .downloading = existing {
            return existing
        }

        if let descriptor = registry.loadModels().first(where: { $0.id == modelID }) {
            return storage.isInstallationValid(for: descriptor) ? .installed : .notInstalled
        }

        return fileManager.fileExists(atPath: modelID) ? .installed : .notInstalled
    }

    func installationState(for descriptor: ModelDescriptor) -> ModelInstallState {
        installationState(for: descriptor.id)
    }

    func modelSizeOnDisk(modelID: String) throws -> Int64 {
        if let descriptor = registry.loadModels().first(where: { $0.id == modelID }) {
            return storage.modelSize(modelID: descriptor.id, kind: descriptor.kind) ?? 0
        }

        let attrs = try fileManager.attributesOfItem(atPath: modelID)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    func locationLabel(for modelID: String) -> String {
        if let descriptor = registry.loadModels().first(where: { $0.id == modelID }) {
            return descriptor.locationLabel
        }

        return URL(fileURLWithPath: modelID).deletingLastPathComponent().path
    }

    func listAvailableModels() -> [ModelDescriptor] {
        [ModelKind.diarization, ModelKind.summarization].flatMap { kind in
            listLocalOptions(kind: kind).map { option in
                ModelDescriptor(
                    id: option.id,
                    displayName: option.displayName,
                    kind: option.kind,
                    profile: selectedProfile,
                    version: "local",
                    sizeBytes: option.sizeBytes,
                    checksum: "sha256:local",
                    downloadURL: option.url.absoluteString,
                    locationLabel: option.url.deletingLastPathComponent().path
                )
            }
        }
    }

    func modelStatuses() -> [ModelRuntimeStatus] {
        listAvailableModels().map { descriptor in
            ModelRuntimeStatus(
                model: descriptor,
                state: installationState(for: descriptor.id)
            )
        }
    }

    func switchProfile(_ profile: ModelProfile) {
        selectedProfile = profile
        pendingProfileSelection = profile
    }

    // MARK: Private

    private func installRegistryModel(_ descriptor: ModelDescriptor) async {
        if storage.isInstallationValid(for: descriptor) {
            installStates[descriptor.id] = .installed
            return
        }

        installStates[descriptor.id] = .downloading(progress: 0)

        do {
            _ = try await downloader.downloadAndInstall(descriptor: descriptor) { [weak self] progress in
                Task { @MainActor in
                    self?.installStates[descriptor.id] = .downloading(progress: progress)
                }
            }
            installStates[descriptor.id] = storage.isInstallationValid(for: descriptor)
                ? .installed
                : .failed(reason: "Installed model validation failed")
        } catch {
            try? storage.removeModel(modelID: descriptor.id, kind: descriptor.kind)
            installStates[descriptor.id] = .failed(reason: error.localizedDescription)
        }
    }

    private func loadProjectLocalOptions(kind: ModelKind) -> [LocalModelOption] {
        let directories = discoveryPaths.projectDirectories()
        var results: [LocalModelOption] = []
        var scannedPaths = Set<String>()
        for directory in directories {
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            let resolved = directory.resolvingSymlinksInPath().path
            guard scannedPaths.insert(resolved).inserted else { continue }
            let urls = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for url in urls.sorted(by: modelURLSort) {
                let inferredKind = classifyModelKind(url: url)
                guard inferredKind == kind else { continue }
                if !isModelCandidate(url, kind: kind) {
                    continue
                }

                if let option = buildLocalOption(url: url, kind: kind, source: .projectLocal) {
                    results.append(option)
                }
            }
        }
        return results
    }

    private func classifyModelKind(url: URL) -> ModelKind {
        let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if resourceValues?.isDirectory == true {
            return .summarization
        }

        let ext = url.pathExtension.lowercased()
        if ext == "gguf" {
            return .summarization
        }
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        if name.contains("diarization") {
            return .diarization
        }
        return name.contains("diarization") ? .diarization : .summarization
    }

    private func loadUserLocalOptions(kind: ModelKind) -> [LocalModelOption] {
        guard let directory = discoveryPaths.userDirectory(kind) else {
            return []
        }
        return loadDirectoryOptions(kind: kind, directory: directory, source: .userLocal, recursive: false)
    }

    private func loadSharedOptions(kind: ModelKind) -> [LocalModelOption] {
        guard let directory = discoveryPaths.sharedDirectory(kind) else {
            return []
        }
        return loadDirectoryOptions(kind: kind, directory: directory, source: .shared, recursive: false)
    }

    private func loadAppSupportOptions(kind: ModelKind) -> [LocalModelOption] {
        guard let directory = discoveryPaths.appSupportDirectory(kind) else {
            return []
        }
        return loadDirectoryOptions(kind: kind, directory: directory, source: .appSupport, recursive: true)
    }

    private func loadDirectoryOptions(
        kind: ModelKind,
        directory: URL,
        source: LocalModelOption.Source,
        recursive: Bool
    ) -> [LocalModelOption] {
        let urls: [URL]
        if recursive {
            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
            urls = (enumerator?.allObjects as? [URL]) ?? []
        } else {
            urls = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }

        return urls
            .sorted(by: modelURLSort)
            .filter { isModelCandidate($0, kind: kind) }
            .filter { classifyModelKind(url: $0) == kind }
            .compactMap { buildLocalOption(url: $0, kind: kind, source: source) }
    }

    private func isModelCandidate(_ url: URL, kind: ModelKind) -> Bool {
        switch kind {
        case .asr:
            return false
        case .diarization:
            return isSupportedModelFile(url, extensions: ["bin"])
        case .summarization:
            return isSupportedModelFile(url, extensions: ["gguf", "bin"])
        }
    }

    private func isSupportedModelFile(_ url: URL, extensions: Set<String>? = nil) -> Bool {
        let allowedExtensions = extensions ?? supportedModelExtensions(for: .summarization)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true && allowedExtensions.contains(url.pathExtension.lowercased())
    }

    private func supportedModelExtensions(for kind: ModelKind) -> Set<String> {
        switch kind {
        case .summarization:
            return ["bin", "gguf"]
        case .diarization:
            return ["bin"]
        case .asr:
            return []
        }
    }

    private func buildLocalOption(url: URL, kind: ModelKind, source: LocalModelOption.Source) -> LocalModelOption? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let attrs = try? fileManager.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let baseName = url.deletingPathExtension().lastPathComponent
        let displayName = baseName
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return LocalModelOption(
            id: url.path,
            displayName: displayName.isEmpty ? baseName : displayName.capitalized,
            kind: kind,
            url: url,
            sizeBytes: size,
            source: source
        )
    }

    private func modelIdentity(for option: LocalModelOption) -> String {
        let basename = option.url.deletingPathExtension().lastPathComponent.lowercased()
        return "\(option.kind.rawValue)|\(basename)"
    }

    private func modelURLSort(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveCompare(
            rhs.deletingPathExtension().lastPathComponent
        ) == .orderedAscending
    }
}

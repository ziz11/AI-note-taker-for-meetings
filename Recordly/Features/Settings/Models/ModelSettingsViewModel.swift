import Foundation

@MainActor
final class ModelSettingsViewModel: ObservableObject {
    struct CatalogModel: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String
        let metadata: [String]
        let footnote: String?
        let kind: ModelKind
        let sourceLabel: String
        let isSelected: Bool
        let supportsSelection: Bool
    }

    @Published private(set) var diarizationModels: [LocalModelOption] = []
    @Published private(set) var summarizationModels: [LocalModelOption] = []
    @Published private(set) var localASRModels: [CatalogModel] = []
    @Published private(set) var summarizationCatalogModels: [CatalogModel] = []

    @Published var selectedDiarizationModelID: String?
    @Published var selectedSummarizationModelID: String?

    @Published private(set) var fluidProvisioningState: FluidAudioModelProvisioningState = .needsDownload
    @Published private(set) var fluidDiarizationProvisioningState: FluidAudioModelProvisioningState = .needsDownload

    private let modelManager: ModelManager
    private let fluidAudioModelProvider: any FluidAudioASRModelProviding
    private let fluidAudioDiarizationModelProvider: any FluidAudioDiarizationModelProviding
    private let fileManager: FileManager

    init(
        modelManager: ModelManager,
        fluidAudioModelProvider: any FluidAudioASRModelProviding,
        fluidAudioDiarizationModelProvider: any FluidAudioDiarizationModelProviding,
        fileManager: FileManager = .default
    ) {
        self.modelManager = modelManager
        self.fluidAudioModelProvider = fluidAudioModelProvider
        self.fluidAudioDiarizationModelProvider = fluidAudioDiarizationModelProvider
        self.fileManager = fileManager
        fluidProvisioningState = fluidAudioModelProvider.state
        fluidDiarizationProvisioningState = fluidAudioDiarizationModelProvider.state
    }

    func refresh() {
        diarizationModels = modelManager.listLocalOptions(kind: .diarization)
        summarizationModels = modelManager.listLocalOptions(kind: .summarization)
        localASRModels = discoverLocalASRModels()

        selectedDiarizationModelID = modelManager.selectedLocalOption(kind: .diarization)?.id
        selectedSummarizationModelID = modelManager.selectedLocalOption(kind: .summarization)?.id
        summarizationCatalogModels = summarizationModels.map { option in
            makeCatalogModel(
                option: option,
                kind: .summarization,
                isSelected: option.id == selectedSummarizationModelID,
                supportsSelection: true
            )
        }

        fluidAudioModelProvider.refreshState()
        fluidProvisioningState = fluidAudioModelProvider.state
        fluidAudioDiarizationModelProvider.refreshState()
        fluidDiarizationProvisioningState = fluidAudioDiarizationModelProvider.state
    }

    func selectDiarizationModel(_ modelID: String?) {
        modelManager.setSelectedModelID(modelID, for: .diarization)
        refresh()
    }

    func selectSummarizationModel(_ modelID: String?) {
        modelManager.setSelectedModelID(modelID, for: .summarization)
        refresh()
    }

    func folderURL(for kind: ModelKind, source: LocalModelOption.Source) -> URL? {
        modelManager.modelsDirectory(kind: kind, source: source)
    }

    func sourceLabel(_ source: LocalModelOption.Source) -> String {
        switch source {
        case .shared:
            return "Shared"
        case .appSupport:
            return "App Support"
        case .userLocal:
            return "User"
        case .projectLocal:
            return "Project"
        }
    }

    func modelLabel(for option: LocalModelOption) -> String {
        let size = ByteCountFormatter.string(fromByteCount: option.sizeBytes, countStyle: .file)
        return "\(option.displayName) • \(size)"
    }

    var canDownloadFluidModel: Bool {
        !isDownloadingFluidModel && !isFluidModelReady
    }

    var isDownloadingFluidModel: Bool {
        if case .downloading = fluidProvisioningState {
            return true
        }
        return false
    }

    var isFluidModelReady: Bool {
        if case .ready = fluidProvisioningState {
            return true
        }
        return false
    }

    var canDownloadFluidDiarizationModel: Bool {
        !isDownloadingFluidDiarizationModel && !isFluidDiarizationModelReady
    }

    var isDownloadingFluidDiarizationModel: Bool {
        if case .downloading = fluidDiarizationProvisioningState {
            return true
        }
        return false
    }

    var isFluidDiarizationModelReady: Bool {
        if case .ready = fluidDiarizationProvisioningState {
            return true
        }
        return false
    }

    func downloadFluidAudioModel() {
        Task {
            await fluidAudioModelProvider.downloadDefaultModel()
            fluidProvisioningState = fluidAudioModelProvider.state
            refresh()
        }
    }

    func downloadFluidDiarizationModel() {
        Task {
            await fluidAudioDiarizationModelProvider.downloadDefaultModel()
            fluidDiarizationProvisioningState = fluidAudioDiarizationModelProvider.state
            refresh()
        }
    }

    private func discoverLocalASRModels() -> [CatalogModel] {
        let directories: [(URL, LocalModelOption.Source)] = [
            modelManager.modelsDirectory(kind: .asr, source: .userLocal).map { ($0, .userLocal) },
            modelManager.modelsDirectory(kind: .asr, source: .shared).map { ($0, .shared) },
            modelManager.modelsDirectory(kind: .asr, source: .appSupport).map { ($0, .appSupport) }
        ]
        .compactMap { $0 }

        var seen = Set<String>()
        return directories.flatMap { directory, source in
            loadLocalASRModels(in: directory, source: source)
        }
        .filter { model in
            seen.insert(model.id).inserted
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func loadLocalASRModels(
        in directory: URL,
        source: LocalModelOption.Source
    ) -> [CatalogModel] {
        let urls = ((try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
        .filter { isCustomASRCandidate($0) }

        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = values?.isDirectory == true
            let displayNameSource = isDirectory ? url.deletingPathExtension().lastPathComponent : url.deletingPathExtension().lastPathComponent
            let size = modelSize(at: url)
            return CatalogModel(
                id: url.path,
                title: prettify(displayNameSource),
                subtitle: isDirectory ? "Custom local speech model bundle" : "Custom local speech model",
                metadata: [ByteCountFormatter.string(fromByteCount: size, countStyle: .file), sourceLabel(source)],
                footnote: url.path,
                kind: .asr,
                sourceLabel: sourceLabel(source),
                isSelected: false,
                supportsSelection: false
            )
        }
    }

    private func makeCatalogModel(
        option: LocalModelOption,
        kind: ModelKind,
        isSelected: Bool,
        supportsSelection: Bool
    ) -> CatalogModel {
        CatalogModel(
            id: option.id,
            title: option.displayName,
            subtitle: kind == .summarization
                ? "Local summarization model"
                : "Local model",
            metadata: [
                ByteCountFormatter.string(fromByteCount: option.sizeBytes, countStyle: .file),
                sourceLabel(option.source)
            ],
            footnote: option.url.path,
            kind: kind,
            sourceLabel: sourceLabel(option.source),
            isSelected: isSelected,
            supportsSelection: supportsSelection
        )
    }

    private func isCustomASRCandidate(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values?.isDirectory == true {
            return url.pathExtension.lowercased() == "mlmodelc"
        }
        return values?.isRegularFile == true && ["bin", "mlmodelc"].contains(url.pathExtension.lowercased())
    }

    private func modelSize(at url: URL) -> Int64 {
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true {
            return directorySize(at: url)
        }
        let attrs = try? fileManager.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func directorySize(at directory: URL) -> Int64 {
        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        let urls = (enumerator?.allObjects as? [URL]) ?? []
        return urls.reduce(0) { partial, url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { return partial }
            return partial + Int64(values?.fileSize ?? 0)
        }
    }

    private func prettify(_ rawValue: String) -> String {
        rawValue
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .capitalized
    }
}

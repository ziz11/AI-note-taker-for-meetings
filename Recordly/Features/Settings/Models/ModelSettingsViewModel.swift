import Foundation

@MainActor
final class ModelSettingsViewModel: ObservableObject {
    @Published private(set) var diarizationModels: [LocalModelOption] = []
    @Published private(set) var summarizationModels: [LocalModelOption] = []

    @Published var selectedDiarizationModelID: String?
    @Published var selectedSummarizationModelID: String?

    @Published private(set) var fluidProvisioningState: FluidAudioModelProvisioningState = .needsDownload

    private let modelManager: ModelManager
    private let fluidAudioModelProvider: any FluidAudioModelProviding

    init(
        modelManager: ModelManager,
        fluidAudioModelProvider: any FluidAudioModelProviding
    ) {
        self.modelManager = modelManager
        self.fluidAudioModelProvider = fluidAudioModelProvider
        refresh()
    }

    func refresh() {
        diarizationModels = modelManager.listLocalOptions(kind: .diarization)
        summarizationModels = modelManager.listLocalOptions(kind: .summarization)

        selectedDiarizationModelID = modelManager.selectedLocalOption(kind: .diarization)?.id
        selectedSummarizationModelID = modelManager.selectedLocalOption(kind: .summarization)?.id

        fluidAudioModelProvider.refreshState()
        fluidProvisioningState = fluidAudioModelProvider.state
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

    func downloadFluidAudioModel() {
        Task {
            await fluidAudioModelProvider.downloadDefaultModel()
            fluidProvisioningState = fluidAudioModelProvider.state
            refresh()
        }
    }
}

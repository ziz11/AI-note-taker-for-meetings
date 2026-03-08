import Foundation

@MainActor
final class ModelSettingsViewModel: ObservableObject {
    @Published private(set) var asrModels: [LocalModelOption] = []
    @Published private(set) var diarizationModels: [LocalModelOption] = []
    @Published private(set) var summarizationModels: [LocalModelOption] = []

    @Published var selectedASRModelID: String?
    @Published var selectedASRBackend: ASRBackend = .fluidAudio
    @Published var selectedASRLanguage: ASRLanguage = .ru
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
        let allASRModels = modelManager.listLocalOptions(kind: .asr)
        selectedASRBackend = modelManager.selectedASRBackend
        asrModels = allASRModels.filter { isModelCompatible($0, with: selectedASRBackend) }
        diarizationModels = modelManager.listLocalOptions(kind: .diarization)
        summarizationModels = modelManager.listLocalOptions(kind: .summarization)

        selectedASRModelID = modelManager.selectedLocalOption(kind: .asr)?.id
        selectedASRLanguage = modelManager.selectedASRLanguage
        selectedDiarizationModelID = modelManager.selectedLocalOption(kind: .diarization)?.id
        selectedSummarizationModelID = modelManager.selectedLocalOption(kind: .summarization)?.id

        if selectedASRBackend == .whisperCpp,
           let selectedID = selectedASRModelID,
           !asrModels.contains(where: { $0.id == selectedID }),
           let firstCompatible = asrModels.first {
            modelManager.setSelectedModelID(firstCompatible.id, for: .asr)
            selectedASRModelID = firstCompatible.id
        }

        fluidAudioModelProvider.refreshState()
        fluidProvisioningState = fluidAudioModelProvider.state
    }

    private func isModelCompatible(_ option: LocalModelOption, with backend: ASRBackend) -> Bool {
        switch backend {
        case .fluidAudio:
            return false
        case .whisperCpp:
            let isFile = (try? option.url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            return isFile && option.url.pathExtension.lowercased() == "bin"
        }
    }

    var isASRLanguageEditable: Bool {
        selectedASRBackend == .whisperCpp
    }

    func selectASRModel(_ modelID: String?) {
        modelManager.setSelectedModelID(modelID, for: .asr)
        refresh()
    }

    func selectASRBackend(_ backend: ASRBackend) {
        modelManager.selectedASRBackend = backend
        refresh()
    }

    func selectASRLanguage(_ language: ASRLanguage) {
        modelManager.selectedASRLanguage = language
        refresh()
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
        selectedASRBackend == .fluidAudio && !isDownloadingFluidModel && !isFluidModelReady
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

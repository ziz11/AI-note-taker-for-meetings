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

    private let modelManager: ModelManager

    init(modelManager: ModelManager) {
        self.modelManager = modelManager
        refresh()
    }

    func refresh() {
        asrModels = modelManager.listLocalOptions(kind: .asr)
        diarizationModels = modelManager.listLocalOptions(kind: .diarization)
        summarizationModels = modelManager.listLocalOptions(kind: .summarization)

        selectedASRModelID = modelManager.selectedLocalOption(kind: .asr)?.id
        selectedASRBackend = modelManager.selectedASRBackend
        selectedASRLanguage = modelManager.selectedASRLanguage
        selectedDiarizationModelID = modelManager.selectedLocalOption(kind: .diarization)?.id
        selectedSummarizationModelID = modelManager.selectedLocalOption(kind: .summarization)?.id
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
}

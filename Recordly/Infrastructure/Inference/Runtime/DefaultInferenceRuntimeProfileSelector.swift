import Foundation

enum InferenceRuntimeProfileError: LocalizedError, Equatable {
    case missingFluidAudioModel
    case fluidAudioProvisioningFailed(message: String)
    case missingSummarizationModel
    case invalidFluidAudioModel(modelURL: URL)

    var errorDescription: String? {
        switch self {
        case .missingFluidAudioModel:
            return "No FluidAudio model is provisioned. Download FluidAudio v3 model in Models settings."
        case let .fluidAudioProvisioningFailed(message):
            return "FluidAudio model provisioning failed: \(message)"
        case .missingSummarizationModel:
            return "Select a summarization model before generating summary."
        case let .invalidFluidAudioModel(modelURL):
            return "FluidAudio requires a staged model directory (parakeet_vocab.json + CoreML bundles): \(modelURL.path)"
        }
    }
}

@MainActor
protocol InferenceRuntimeProfileSelecting {
    func transcriptionAvailability(for profile: ModelProfile) -> TranscriptionAvailability
    func resolveTranscriptionProfile(for profile: ModelProfile) throws -> InferenceRuntimeProfile
    func resolveSummarizationProfile(for profile: ModelProfile) throws -> InferenceRuntimeProfile
}

@MainActor
final class DefaultInferenceRuntimeProfileSelector: InferenceRuntimeProfileSelecting {
    private let modelManager: ModelManager
    private let asrModelProvider: any FluidAudioASRModelProviding
    private let diarizationModelProvider: any FluidAudioDiarizationModelProviding
    private let stageSelection: StageRuntimeSelection

    init(
        modelManager: ModelManager,
        asrModelProvider: any FluidAudioASRModelProviding,
        diarizationModelProvider: any FluidAudioDiarizationModelProviding,
        stageSelection: StageRuntimeSelection = .defaultLocal
    ) {
        self.modelManager = modelManager
        self.asrModelProvider = asrModelProvider
        self.diarizationModelProvider = diarizationModelProvider
        self.stageSelection = stageSelection
    }

    convenience init(
        modelManager: ModelManager,
        asrModelProvider: any FluidAudioASRModelProviding,
        stageSelection: StageRuntimeSelection = .defaultLocal
    ) {
        self.init(
            modelManager: modelManager,
            asrModelProvider: asrModelProvider,
            diarizationModelProvider: FluidAudioDiarizationModelProvider(),
            stageSelection: stageSelection
        )
    }

    convenience init(
        modelManager: ModelManager,
        fluidAudioModelProvider: any FluidAudioASRModelProviding,
        stageSelection: StageRuntimeSelection = .defaultLocal
    ) {
        self.init(modelManager: modelManager, asrModelProvider: fluidAudioModelProvider, stageSelection: stageSelection)
    }

    func transcriptionAvailability(for profile: ModelProfile) -> TranscriptionAvailability {
        asrModelProvider.refreshState()
        diarizationModelProvider.refreshState()
        switch asrModelProvider.state {
        case .ready:
            if diarizationModelProvider.state != .ready {
                return .degradedNoDiarization
            }
            return .ready
        case .needsDownload, .downloading:
            return .unavailable(reason: InferenceRuntimeProfileError.missingFluidAudioModel.localizedDescription)
        case let .failed(message):
            return .unavailable(reason: InferenceRuntimeProfileError.fluidAudioProvisioningFailed(message: message).localizedDescription)
        }
    }

    func resolveTranscriptionProfile(for profile: ModelProfile) throws -> InferenceRuntimeProfile {
        let asrModelURL: URL
        do {
            asrModelURL = try asrModelProvider.resolveForRuntime()
        } catch let provisioningError as FluidAudioModelProvisioningError {
            switch provisioningError {
            case .noModelProvisioned:
                throw InferenceRuntimeProfileError.missingFluidAudioModel
            case let .downloadFailed(message):
                throw InferenceRuntimeProfileError.fluidAudioProvisioningFailed(message: message)
            case .sdkUnavailable:
                throw InferenceRuntimeProfileError.fluidAudioProvisioningFailed(message: provisioningError.localizedDescription)
            }
        }

        guard FluidAudioModelValidator.isValidModelDirectory(asrModelURL) else {
            throw InferenceRuntimeProfileError.invalidFluidAudioModel(modelURL: asrModelURL)
        }

        return InferenceRuntimeProfile(
            stageSelection: stageSelection,
            modelArtifacts: InferenceModelArtifacts(
                asrModelURL: asrModelURL,
                diarizationModelURL: nil,
                summarizationModelURL: nil
            ),
            summarizationRuntimeSettings: modelManager.summarizationRuntimeSettings
        )
    }

    func resolveSummarizationProfile(for profile: ModelProfile) throws -> InferenceRuntimeProfile {
        guard let summarizationOption = modelManager.selectedLocalOption(kind: .summarization) else {
            throw InferenceRuntimeProfileError.missingSummarizationModel
        }

        return InferenceRuntimeProfile(
            stageSelection: stageSelection,
            modelArtifacts: InferenceModelArtifacts(
                asrModelURL: nil,
                diarizationModelURL: nil,
                summarizationModelURL: summarizationOption.url
            ),
            summarizationRuntimeSettings: modelManager.summarizationRuntimeSettings
        )
    }
}

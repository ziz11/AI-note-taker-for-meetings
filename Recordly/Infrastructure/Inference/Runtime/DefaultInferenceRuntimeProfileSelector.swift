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
    private let fluidAudioModelProvider: any FluidAudioModelProviding
    private let stageSelection: StageRuntimeSelection

    init(
        modelManager: ModelManager,
        fluidAudioModelProvider: any FluidAudioModelProviding,
        stageSelection: StageRuntimeSelection = .defaultLocal
    ) {
        self.modelManager = modelManager
        self.fluidAudioModelProvider = fluidAudioModelProvider
        self.stageSelection = stageSelection
    }

    func transcriptionAvailability(for profile: ModelProfile) -> TranscriptionAvailability {
        fluidAudioModelProvider.refreshState()
        switch fluidAudioModelProvider.state {
        case .ready:
            if modelManager.selectedLocalOption(kind: .diarization) == nil {
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
            asrModelURL = try fluidAudioModelProvider.resolveForRuntime()
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

        let diarizationOption = modelManager.selectedLocalOption(kind: .diarization)

        return InferenceRuntimeProfile(
            stageSelection: stageSelection,
            modelArtifacts: InferenceModelArtifacts(
                asrModelURL: asrModelURL,
                diarizationModelURL: diarizationOption?.url,
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
                diarizationModelURL: modelManager.selectedLocalOption(kind: .diarization)?.url,
                summarizationModelURL: summarizationOption.url
            ),
            summarizationRuntimeSettings: modelManager.summarizationRuntimeSettings
        )
    }
}

import Foundation

enum InferenceRuntimeProfileError: LocalizedError, Equatable {
    case missingASRModel
    case missingSummarizationModel

    var errorDescription: String? {
        switch self {
        case .missingASRModel:
            return "Select an ASR model before transcribing."
        case .missingSummarizationModel:
            return "Select a summarization model before generating summary."
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
    private let stageSelection: StageRuntimeSelection

    init(
        modelManager: ModelManager,
        stageSelection: StageRuntimeSelection = .defaultLocal
    ) {
        self.modelManager = modelManager
        self.stageSelection = stageSelection
    }

    func transcriptionAvailability(for profile: ModelProfile) -> TranscriptionAvailability {
        modelManager.availability(for: profile)
    }

    func resolveTranscriptionProfile(for profile: ModelProfile) throws -> InferenceRuntimeProfile {
        guard let asrOption = modelManager.selectedLocalOption(kind: .asr) else {
            throw InferenceRuntimeProfileError.missingASRModel
        }

        let diarizationOption = modelManager.selectedLocalOption(kind: .diarization)

        return InferenceRuntimeProfile(
            stageSelection: stageSelection,
            modelArtifacts: InferenceModelArtifacts(
                asrModelURL: asrOption.url,
                diarizationModelURL: diarizationOption?.url,
                summarizationModelURL: nil
            ),
            asrLanguage: modelManager.selectedASRLanguage,
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
                asrModelURL: modelManager.selectedLocalOption(kind: .asr)?.url,
                diarizationModelURL: modelManager.selectedLocalOption(kind: .diarization)?.url,
                summarizationModelURL: summarizationOption.url
            ),
            asrLanguage: modelManager.selectedASRLanguage,
            summarizationRuntimeSettings: modelManager.summarizationRuntimeSettings
        )
    }
}

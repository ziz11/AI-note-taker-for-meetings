import Foundation

enum InferenceRuntimeProfileError: LocalizedError, Equatable {
    case missingASRModel
    case missingSummarizationModel
    case invalidASRBackendModel(backend: ASRBackend, modelURL: URL)

    var errorDescription: String? {
        switch self {
        case .missingASRModel:
            return "Select an ASR model before transcribing."
        case .missingSummarizationModel:
            return "Select a summarization model before generating summary."
        case let .invalidASRBackendModel(backend, modelURL):
            switch backend {
            case .whisperCpp:
                return "WhisperCpp requires a local .bin ASR model file: \(modelURL.path)"
            case .fluidAudio:
                return "FluidAudio requires a staged model directory (parakeet_vocab.json + CoreML bundles): \(modelURL.path)"
            }
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

        let selectedASRBackend = modelManager.selectedASRBackend
        try validateASRSelection(asrOption.url, backend: selectedASRBackend)
        let diarizationOption = modelManager.selectedLocalOption(kind: .diarization)
        var resolvedStageSelection = stageSelection
        resolvedStageSelection.setBackend(inferenceBackend(for: selectedASRBackend), for: .asr)
        let asrLanguage: ASRLanguage = selectedASRBackend == .fluidAudio ? .auto : modelManager.selectedASRLanguage

        return InferenceRuntimeProfile(
            stageSelection: resolvedStageSelection,
            modelArtifacts: InferenceModelArtifacts(
                asrModelURL: asrOption.url,
                diarizationModelURL: diarizationOption?.url,
                summarizationModelURL: nil
            ),
            asrLanguage: asrLanguage,
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

    private func inferenceBackend(for backend: ASRBackend) -> InferenceBackend {
        switch backend {
        case .whisperCpp:
            return .whisperCpp
        case .fluidAudio:
            return .fluidAudio
        }
    }

    private func validateASRSelection(_ modelURL: URL, backend: ASRBackend) throws {
        let fileManager = FileManager.default

        switch backend {
        case .whisperCpp:
            let isRegularFile = (try? modelURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            guard isRegularFile, modelURL.pathExtension.lowercased() == "bin" else {
                throw InferenceRuntimeProfileError.invalidASRBackendModel(backend: backend, modelURL: modelURL)
            }
            guard fileManager.fileExists(atPath: modelURL.path) else {
                throw InferenceRuntimeProfileError.invalidASRBackendModel(backend: backend, modelURL: modelURL)
            }
        case .fluidAudio:
            guard FluidAudioModelValidator.isValidModelDirectory(modelURL, fileManager: fileManager) else {
                throw InferenceRuntimeProfileError.invalidASRBackendModel(backend: backend, modelURL: modelURL)
            }
        }
    }
}

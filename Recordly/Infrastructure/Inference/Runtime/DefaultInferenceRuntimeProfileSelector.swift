import Foundation

enum InferenceRuntimeProfileError: LocalizedError, Equatable {
    case missingASRModel
    case missingFluidAudioModel
    case fluidAudioProvisioningFailed(message: String)
    case missingSummarizationModel
    case invalidASRBackendModel(backend: ASRBackend, modelURL: URL)

    var errorDescription: String? {
        switch self {
        case .missingASRModel:
            return "Select an ASR model before transcribing."
        case .missingFluidAudioModel:
            return "No FluidAudio model is provisioned. Download FluidAudio v3 model in Models settings."
        case let .fluidAudioProvisioningFailed(message):
            return "FluidAudio model provisioning failed: \(message)"
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
        if modelManager.selectedASRBackend == .fluidAudio {
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

        modelManager.availability(for: profile)
    }

    func resolveTranscriptionProfile(for profile: ModelProfile) throws -> InferenceRuntimeProfile {
        let selectedASRBackend = modelManager.selectedASRBackend
        let asrModelURL: URL
        switch selectedASRBackend {
        case .whisperCpp:
            guard let asrOption = modelManager.selectedLocalOption(kind: .asr) else {
                throw InferenceRuntimeProfileError.missingASRModel
            }
            try validateASRSelection(asrOption.url, backend: selectedASRBackend)
            asrModelURL = asrOption.url
        case .fluidAudio:
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
            try validateASRSelection(asrModelURL, backend: selectedASRBackend)
        }

        let diarizationOption = modelManager.selectedLocalOption(kind: .diarization)
        var resolvedStageSelection = stageSelection
        resolvedStageSelection.setBackend(inferenceBackend(for: selectedASRBackend), for: .asr)
        let asrLanguage: ASRLanguage = selectedASRBackend == .fluidAudio ? .auto : modelManager.selectedASRLanguage

        return InferenceRuntimeProfile(
            stageSelection: resolvedStageSelection,
            modelArtifacts: InferenceModelArtifacts(
                asrModelURL: asrModelURL,
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

import Foundation

struct DefaultInferenceEngineFactory: InferenceEngineFactory {
    private let diarizationModelProvider: any FluidAudioDiarizationModelProviding

    @MainActor
    init() {
        self.diarizationModelProvider = FluidAudioDiarizationModelProvider()
    }
    init(diarizationModelProvider: any FluidAudioDiarizationModelProviding) {
        self.diarizationModelProvider = diarizationModelProvider
    }

    @MainActor
    func makeAudioCaptureEngine(for profile: InferenceRuntimeProfile) throws -> any AudioCaptureEngine {
        switch profile.stageSelection.backend(for: .audioCapture) {
        case .nativeCapture:
            return AudioCaptureService()
        case let backend:
            throw InferenceEngineFactoryError.unsupportedBackend(stage: .audioCapture, backend: backend)
        }
    }

    func makeASREngine(for profile: InferenceRuntimeProfile) throws -> any ASREngine {
        switch profile.stageSelection.backend(for: .asr) {
        case .fluidAudio:
            return FluidAudioASREngine()
        case let backend:
            throw InferenceEngineFactoryError.unsupportedBackend(stage: .asr, backend: backend)
        }
    }

    @MainActor
    func makeDiarizationEngine(for profile: InferenceRuntimeProfile) throws -> any DiarizationEngine {
        switch profile.stageSelection.backend(for: .diarization) {
        case .fluidAudio:
            let manager = try diarizationModelProvider.resolveForRuntime()
            return FluidAudioDiarizationEngine(manager: manager)
        case .cliDiarization:
            return CliDiarizationEngine()
        case let backend:
            throw InferenceEngineFactoryError.unsupportedBackend(stage: .diarization, backend: backend)
        }
    }

    func makeSummarizationEngine(for profile: InferenceRuntimeProfile) throws -> any SummarizationEngine {
        switch profile.stageSelection.backend(for: .summarization) {
        case .llamaCpp:
            return LlamaCppSummarizationEngine()
        case let backend:
            throw InferenceEngineFactoryError.unsupportedBackend(stage: .summarization, backend: backend)
        }
    }

    func makeVoiceActivityDetectionEngine(for profile: InferenceRuntimeProfile) throws -> (any VoiceActivityDetectionEngine)? {
        switch profile.stageSelection.backend(for: .vad) {
        case .disabled:
            return nil
        case let backend:
            throw InferenceEngineFactoryError.unsupportedBackend(stage: .vad, backend: backend)
        }
    }

    func transcriptionEngineDisplayName(for stageSelection: StageRuntimeSelection) -> String {
        switch stageSelection.backend(for: .asr) {
        case .fluidAudio:
            return "FluidAudio"
        default:
            return "ASR"
        }
    }
}

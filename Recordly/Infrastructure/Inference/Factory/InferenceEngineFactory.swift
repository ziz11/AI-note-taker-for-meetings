import Foundation

enum InferenceEngineFactoryError: LocalizedError, Equatable {
    case unsupportedBackend(stage: InferenceStage, backend: InferenceBackend)

    var errorDescription: String? {
        switch self {
        case let .unsupportedBackend(stage, backend):
            return "Backend \(backend.rawValue) is not supported for stage \(stage.rawValue)."
        }
    }
}

protocol InferenceEngineFactory {
    @MainActor
    func makeAudioCaptureEngine(for profile: InferenceRuntimeProfile) throws -> any AudioCaptureEngine
    func makeASREngine(for profile: InferenceRuntimeProfile) throws -> any ASREngine
    @MainActor
    func makeDiarizationEngine(for profile: InferenceRuntimeProfile) throws -> any DiarizationEngine
    func makeSummarizationEngine(for profile: InferenceRuntimeProfile) throws -> any SummarizationEngine
    func makeVoiceActivityDetectionEngine(for profile: InferenceRuntimeProfile) throws -> (any VoiceActivityDetectionEngine)?
}

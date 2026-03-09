import Foundation

enum InferenceStage: String, CaseIterable, Sendable {
    case audioCapture
    case asr
    case diarization
    case summarization
    case vad
}

enum InferenceBackend: String, Equatable, Sendable {
    case nativeCapture
    case cliDiarization
    case llamaCpp
    case fluidAudio
    case disabled
}

struct StageRuntimeSelection: Equatable, Sendable {
    private var stageBackends: [InferenceStage: InferenceBackend]

    init(stageBackends: [InferenceStage: InferenceBackend]) {
        var normalized: [InferenceStage: InferenceBackend] = [:]
        InferenceStage.allCases.forEach { stage in
            normalized[stage] = stageBackends[stage] ?? .disabled
        }
        self.stageBackends = normalized
    }

    static var defaultLocal: StageRuntimeSelection {
        StageRuntimeSelection(
            stageBackends: [
                .audioCapture: .nativeCapture,
                .asr: .fluidAudio,
                .diarization: .cliDiarization,
                .summarization: .llamaCpp,
                .vad: .disabled
            ]
        )
    }

    func backend(for stage: InferenceStage) -> InferenceBackend {
        stageBackends[stage] ?? .disabled
    }

    mutating func setBackend(_ backend: InferenceBackend, for stage: InferenceStage) {
        stageBackends[stage] = backend
    }
}

struct InferenceModelArtifacts: Equatable, Sendable {
    var asrModelURL: URL?
    var diarizationModelURL: URL?
    var summarizationModelURL: URL?

    static let empty = InferenceModelArtifacts(
        asrModelURL: nil,
        diarizationModelURL: nil,
        summarizationModelURL: nil
    )
}

struct InferenceRuntimeProfile: Equatable, Sendable {
    var stageSelection: StageRuntimeSelection
    var modelArtifacts: InferenceModelArtifacts
    var summarizationRuntimeSettings: SummarizationRuntimeSettings
}

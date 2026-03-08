import Foundation

@MainActor
struct InferenceComposition {
    let runtimeProfileSelector: any InferenceRuntimeProfileSelecting
    let engineFactory: any InferenceEngineFactory
    let audioCaptureEngine: any AudioCaptureEngine
    let transcriptionEngineDisplayName: String
}

@MainActor
enum DefaultInferenceComposition {
    static func make(
        modelManager: ModelManager,
        fluidAudioModelProvider: any FluidAudioModelProviding
    ) -> InferenceComposition {
        var stageSelection = StageRuntimeSelection.defaultLocal
        stageSelection.setBackend(modelManager.selectedASRBackend == .fluidAudio ? .fluidAudio : .whisperCpp, for: .asr)
        let runtimeProfileSelector = DefaultInferenceRuntimeProfileSelector(
            modelManager: modelManager,
            fluidAudioModelProvider: fluidAudioModelProvider,
            stageSelection: stageSelection
        )
        let engineFactory = DefaultInferenceEngineFactory()
        let bootstrapProfile = InferenceRuntimeProfile(
            stageSelection: stageSelection,
            modelArtifacts: .empty,
            asrLanguage: modelManager.selectedASRLanguage,
            summarizationRuntimeSettings: modelManager.summarizationRuntimeSettings
        )
        let audioCaptureEngine = (try? engineFactory.makeAudioCaptureEngine(for: bootstrapProfile)) ?? AudioCaptureService()

        return InferenceComposition(
            runtimeProfileSelector: runtimeProfileSelector,
            engineFactory: engineFactory,
            audioCaptureEngine: audioCaptureEngine,
            transcriptionEngineDisplayName: engineFactory.transcriptionEngineDisplayName(for: stageSelection)
        )
    }
}

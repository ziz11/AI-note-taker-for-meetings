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
        let stageSelection = StageRuntimeSelection.defaultLocal
        let runtimeProfileSelector = DefaultInferenceRuntimeProfileSelector(
            modelManager: modelManager,
            fluidAudioModelProvider: fluidAudioModelProvider,
            stageSelection: stageSelection
        )
        let engineFactory = DefaultInferenceEngineFactory()
        let bootstrapProfile = InferenceRuntimeProfile(
            stageSelection: stageSelection,
            modelArtifacts: .empty,
            asrLanguage: .auto,
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

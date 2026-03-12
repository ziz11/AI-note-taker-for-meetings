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
        asrModelProvider: any FluidAudioASRModelProviding,
        diarizationModelProvider: any FluidAudioDiarizationModelProviding
    ) -> InferenceComposition {
        let stageSelection = StageRuntimeSelection.defaultLocal
        let runtimeProfileSelector = DefaultInferenceRuntimeProfileSelector(
            modelManager: modelManager,
            asrModelProvider: asrModelProvider,
            diarizationModelProvider: diarizationModelProvider,
            stageSelection: stageSelection
        )
        let engineFactory = DefaultInferenceEngineFactory(diarizationModelProvider: diarizationModelProvider)
        let bootstrapProfile = InferenceRuntimeProfile(
            stageSelection: stageSelection,
            modelArtifacts: .empty,
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

    static func make(
        modelManager: ModelManager,
        asrModelProvider: any FluidAudioASRModelProviding
    ) -> InferenceComposition {
        let diarizationModelProvider = FluidAudioDiarizationModelProvider()
        return make(
            modelManager: modelManager,
            asrModelProvider: asrModelProvider,
            diarizationModelProvider: diarizationModelProvider
        )
    }

    static func make(
        modelManager: ModelManager,
        fluidAudioModelProvider: any FluidAudioASRModelProviding
    ) -> InferenceComposition {
        make(modelManager: modelManager, asrModelProvider: fluidAudioModelProvider)
    }
}

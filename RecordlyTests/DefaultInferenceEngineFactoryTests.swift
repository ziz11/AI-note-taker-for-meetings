import XCTest
@testable import Recordly

final class DefaultInferenceEngineFactoryTests: XCTestCase {
    func testFactoryBuildsExpectedEnginesForDefaultLocalProfile() throws {
        let factory = DefaultInferenceEngineFactory()
        let profile = InferenceRuntimeProfile(
            stageSelection: .defaultLocal,
            modelArtifacts: InferenceModelArtifacts(
                asrModelURL: URL(fileURLWithPath: "/tmp/asr-fluid"),
                diarizationModelURL: URL(fileURLWithPath: "/tmp/diarization.bin"),
                summarizationModelURL: URL(fileURLWithPath: "/tmp/summary.gguf")
            ),
            summarizationRuntimeSettings: .default
        )

        let asrEngine = try factory.makeASREngine(for: profile)
        let diarizationEngine = try factory.makeDiarizationEngine(for: profile)
        let summarizationEngine = try factory.makeSummarizationEngine(for: profile)

        XCTAssertEqual(String(describing: type(of: asrEngine)), "FluidAudioASREngine")
        XCTAssertEqual(String(describing: type(of: diarizationEngine)), "CliDiarizationEngine")
        XCTAssertEqual(String(describing: type(of: summarizationEngine)), "LlamaCppSummarizationEngine")
    }

    func testFactoryThrowsWhenBackendNotSupportedForStage() {
        let factory = DefaultInferenceEngineFactory()
        var selection = StageRuntimeSelection.defaultLocal
        selection.setBackend(.llamaCpp, for: .asr)
        let profile = InferenceRuntimeProfile(
            stageSelection: selection,
            modelArtifacts: InferenceModelArtifacts(
                asrModelURL: URL(fileURLWithPath: "/tmp/asr.bin"),
                diarizationModelURL: nil,
                summarizationModelURL: nil
            ),
            summarizationRuntimeSettings: .default
        )

        XCTAssertThrowsError(try factory.makeASREngine(for: profile)) { error in
            XCTAssertEqual(
                error as? InferenceEngineFactoryError,
                .unsupportedBackend(stage: .asr, backend: .llamaCpp)
            )
        }
    }

    func testFactoryBuildsFluidAudioEngineWhenASRBackendIsFluidAudio() throws {
        let factory = DefaultInferenceEngineFactory()
        var selection = StageRuntimeSelection.defaultLocal
        selection.setBackend(.fluidAudio, for: .asr)
        let profile = InferenceRuntimeProfile(
            stageSelection: selection,
            modelArtifacts: InferenceModelArtifacts(
                asrModelURL: URL(fileURLWithPath: "/tmp/asr-fluid"),
                diarizationModelURL: nil,
                summarizationModelURL: nil
            ),
            summarizationRuntimeSettings: .default
        )

        let asrEngine = try factory.makeASREngine(for: profile)

        XCTAssertEqual(String(describing: type(of: asrEngine)), "FluidAudioASREngine")
        XCTAssertEqual(factory.transcriptionEngineDisplayName(for: selection), "FluidAudio")
    }
}

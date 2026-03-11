import XCTest
@testable import Recordly

#if arch(arm64) && canImport(FluidAudio)
import FluidAudio
#endif

@MainActor
final class DefaultInferenceRuntimeProfileSelectorTests: XCTestCase {
    private var tempDirectory: URL!
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DefaultInferenceRuntimeProfileSelectorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defaultsSuiteName = "DefaultInferenceRuntimeProfileSelectorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        if let defaultsSuiteName {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        defaultsSuiteName = nil
        defaults = nil
    }

    func testResolveTranscriptionProfileUsesExpectedBackendsAndArtifacts() throws {
        let fluidDirectory = try createFluidModelDirectory(named: "fluid-asr-default")
        let manager = makeModelManager()

        let asrProvider = StubFluidAudioASRModelProvider(modelURL: fluidDirectory)
        let diarizationProvider = StubFluidAudioDiarizationModelProvider(state: .ready)
        let selector = DefaultInferenceRuntimeProfileSelector(
            modelManager: manager,
            asrModelProvider: asrProvider,
            diarizationModelProvider: diarizationProvider
        )
        let profile = try selector.resolveTranscriptionProfile(for: .balanced)

        XCTAssertEqual(profile.stageSelection.backend(for: .asr), .fluidAudio)
        XCTAssertEqual(profile.stageSelection.backend(for: .diarization), .fluidAudio)
        XCTAssertEqual(
            profile.modelArtifacts.asrModelURL?.resolvingSymlinksInPath().path,
            fluidDirectory.resolvingSymlinksInPath().path
        )
        XCTAssertNil(profile.modelArtifacts.diarizationModelURL)
    }

    func testResolveTranscriptionProfileInjectsFluidBackendWhenSelected() throws {
        let fluidDirectory = try createFluidModelDirectory(named: "fluid-asr-v3")
        let manager = makeModelManager()

        let asrProvider = StubFluidAudioASRModelProvider(modelURL: fluidDirectory)
        let diarizationProvider = StubFluidAudioDiarizationModelProvider(state: .ready)
        let selector = DefaultInferenceRuntimeProfileSelector(
            modelManager: manager,
            asrModelProvider: asrProvider,
            diarizationModelProvider: diarizationProvider
        )
        let profile = try selector.resolveTranscriptionProfile(for: .balanced)

        XCTAssertEqual(profile.stageSelection.backend(for: .asr), .fluidAudio)
    }

    func testResolveTranscriptionProfileRejectsInvalidModelDirectory() throws {
        let invalidDir = tempDirectory.appendingPathComponent("not-a-fluid-model", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidDir, withIntermediateDirectories: true)
        let manager = makeModelManager()

        let asrProvider = StubFluidAudioASRModelProvider(modelURL: invalidDir)
        let diarizationProvider = StubFluidAudioDiarizationModelProvider(state: .ready)
        let selector = DefaultInferenceRuntimeProfileSelector(
            modelManager: manager,
            asrModelProvider: asrProvider,
            diarizationModelProvider: diarizationProvider
        )

        XCTAssertThrowsError(try selector.resolveTranscriptionProfile(for: .balanced)) { error in
            guard case .invalidFluidAudioModel = error as? InferenceRuntimeProfileError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testResolveSummarizationProfileUsesLlamaCppAndRuntimeSettings() throws {
        _ = try writeModel(named: "summarization-compact-v1.gguf")
        let manager = makeModelManager()
        manager.summarizationRuntimeSettings = SummarizationRuntimeSettings(
            contextSize: 4096,
            temperature: 0.2,
            topP: 0.8
        )
        let summarizationOption = try XCTUnwrap(manager.listLocalOptions(kind: .summarization).first)
        manager.setSelectedModelID(summarizationOption.id, for: .summarization)

        let asrProvider = StubFluidAudioASRModelProvider(modelURL: nil)
        let diarizationProvider = StubFluidAudioDiarizationModelProvider(state: .ready)
        let selector = DefaultInferenceRuntimeProfileSelector(
            modelManager: manager,
            asrModelProvider: asrProvider,
            diarizationModelProvider: diarizationProvider
        )
        let profile = try selector.resolveSummarizationProfile(for: .balanced)

        XCTAssertEqual(profile.stageSelection.backend(for: .summarization), .llamaCpp)
        XCTAssertEqual(
            profile.modelArtifacts.summarizationModelURL?.resolvingSymlinksInPath().path,
            summarizationOption.url.resolvingSymlinksInPath().path
        )
        XCTAssertNil(profile.modelArtifacts.diarizationModelURL)
        XCTAssertEqual(profile.summarizationRuntimeSettings.contextSize, 4096)
    }

    func testTranscriptionAvailabilityReportsNeedsDownload() {
        let manager = makeModelManager()
        let asrProvider = StubFluidAudioASRModelProvider(modelURL: nil)
        let diarizationProvider = StubFluidAudioDiarizationModelProvider(state: .ready)
        let selector = DefaultInferenceRuntimeProfileSelector(
            modelManager: manager,
            asrModelProvider: asrProvider,
            diarizationModelProvider: diarizationProvider
        )

        let availability = selector.transcriptionAvailability(for: .balanced)

        XCTAssertEqual(
            availability,
            .unavailable(reason: InferenceRuntimeProfileError.missingFluidAudioModel.localizedDescription)
        )
    }

    func testTranscriptionAvailabilityDegradesWhenDiarizationProviderIsNotReady() throws {
        let fluidDirectory = try createFluidModelDirectory(named: "fluid-asr-ready")
        let manager = makeModelManager()
        let asrProvider = StubFluidAudioASRModelProvider(modelURL: fluidDirectory)
        let diarizationProvider = StubFluidAudioDiarizationModelProvider(state: .needsDownload)
        let selector = DefaultInferenceRuntimeProfileSelector(
            modelManager: manager,
            asrModelProvider: asrProvider,
            diarizationModelProvider: diarizationProvider
        )

        let availability = selector.transcriptionAvailability(for: .balanced)

        XCTAssertEqual(availability, .degradedNoDiarization)
    }

    // MARK: - Helpers

    private func makeModelManager() -> ModelManager {
        ModelManager(
            preferences: ModelPreferencesStore(defaults: defaults),
            discoveryPaths: ModelDiscoveryPaths(
                appSupportDirectory: { _ in nil },
                sharedDirectory: { _ in nil },
                userDirectory: { _ in nil },
                projectDirectories: { [self.tempDirectory] }
            )
        )
    }

    private func writeModel(named name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try Data("model".utf8).write(to: url)
        return url
    }

    private func createFluidModelDirectory(named name: String) throws -> URL {
        let directory = tempDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for marker in FluidAudioModelValidator.requiredMarkers {
            let markerURL = directory.appendingPathComponent(marker)
            if marker.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: markerURL, withIntermediateDirectories: true)
            } else {
                try Data("marker".utf8).write(to: markerURL)
            }
        }
        return directory
    }

    private final class StubFluidAudioASRModelProvider: FluidAudioASRModelProviding {
        private(set) var state: FluidAudioModelProvisioningState
        private let modelURL: URL?

        init(modelURL: URL?) {
            self.modelURL = modelURL
            self.state = modelURL != nil ? .ready : .needsDownload
        }

        func refreshState() {}
        func downloadDefaultModel() async {}

        func resolveForRuntime() throws -> URL {
            guard let modelURL else {
                throw FluidAudioModelProvisioningError.noModelProvisioned
            }
            return modelURL
        }
    }

    private final class StubFluidAudioDiarizationModelProvider: FluidAudioDiarizationModelProviding {
        private(set) var state: FluidAudioModelProvisioningState
        private let manager = StubOfflineDiarizationManager()

        init(state: FluidAudioModelProvisioningState) {
            self.state = state
        }

        func refreshState() {}
        func downloadDefaultModel() async {}

        func resolveForRuntime() throws -> any OfflineDiarizationManaging {
            switch state {
            case .ready:
                return manager
            case .needsDownload:
                throw FluidAudioModelProvisioningError.noModelProvisioned
            case .downloading:
                throw FluidAudioModelProvisioningError.downloadFailed(message: "Model is currently downloading.")
            case let .failed(message):
                throw FluidAudioModelProvisioningError.downloadFailed(message: message)
            }
        }
    }

    private final class StubOfflineDiarizationManager: OfflineDiarizationManaging, @unchecked Sendable {
        func prepareModels() async throws {}

        func process(audio: [Float]) async throws -> OfflineDiarizationResult {
            OfflineDiarizationResult(segments: [])
        }
    }
}

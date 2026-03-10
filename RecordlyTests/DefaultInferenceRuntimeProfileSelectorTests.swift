import XCTest
@testable import Recordly

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
        _ = try writeModel(named: "diarization-enhanced-v1.bin")
        let manager = makeModelManager()
        let diarizationOption = try XCTUnwrap(manager.listLocalOptions(kind: .diarization).first)
        manager.setSelectedModelID(diarizationOption.id, for: .diarization)

        let provider = StubFluidAudioModelProvider(modelURL: fluidDirectory)
        let selector = DefaultInferenceRuntimeProfileSelector(modelManager: manager, fluidAudioModelProvider: provider)
        let profile = try selector.resolveTranscriptionProfile(for: .balanced)

        XCTAssertEqual(profile.stageSelection.backend(for: .asr), .fluidAudio)
        XCTAssertEqual(profile.stageSelection.backend(for: .diarization), .fluidAudio)
        XCTAssertEqual(
            profile.modelArtifacts.asrModelURL?.resolvingSymlinksInPath().path,
            fluidDirectory.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(
            profile.modelArtifacts.diarizationModelURL?.resolvingSymlinksInPath().path,
            diarizationOption.url.resolvingSymlinksInPath().path
        )
    }

    func testResolveTranscriptionProfileInjectsFluidBackendWhenSelected() throws {
        let fluidDirectory = try createFluidModelDirectory(named: "fluid-asr-v3")
        let manager = makeModelManager()

        let provider = StubFluidAudioModelProvider(modelURL: fluidDirectory)
        let selector = DefaultInferenceRuntimeProfileSelector(modelManager: manager, fluidAudioModelProvider: provider)
        let profile = try selector.resolveTranscriptionProfile(for: .balanced)

        XCTAssertEqual(profile.stageSelection.backend(for: .asr), .fluidAudio)
    }

    func testResolveTranscriptionProfileRejectsInvalidModelDirectory() throws {
        let invalidDir = tempDirectory.appendingPathComponent("not-a-fluid-model", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidDir, withIntermediateDirectories: true)
        let manager = makeModelManager()

        let provider = StubFluidAudioModelProvider(modelURL: invalidDir)
        let selector = DefaultInferenceRuntimeProfileSelector(modelManager: manager, fluidAudioModelProvider: provider)

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

        let provider = StubFluidAudioModelProvider(modelURL: nil)
        let selector = DefaultInferenceRuntimeProfileSelector(modelManager: manager, fluidAudioModelProvider: provider)
        let profile = try selector.resolveSummarizationProfile(for: .balanced)

        XCTAssertEqual(profile.stageSelection.backend(for: .summarization), .llamaCpp)
        XCTAssertEqual(
            profile.modelArtifacts.summarizationModelURL?.resolvingSymlinksInPath().path,
            summarizationOption.url.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(profile.summarizationRuntimeSettings.contextSize, 4096)
    }

    func testTranscriptionAvailabilityReportsNeedsDownload() {
        let manager = makeModelManager()
        let provider = StubFluidAudioModelProvider(modelURL: nil)
        let selector = DefaultInferenceRuntimeProfileSelector(modelManager: manager, fluidAudioModelProvider: provider)

        let availability = selector.transcriptionAvailability(for: .balanced)

        XCTAssertEqual(
            availability,
            .unavailable(reason: InferenceRuntimeProfileError.missingFluidAudioModel.localizedDescription)
        )
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

    private final class StubFluidAudioModelProvider: FluidAudioModelProviding {
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
}

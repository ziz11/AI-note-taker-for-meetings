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
        _ = try writeModel(named: "asr-balanced-v1.bin")
        _ = try writeModel(named: "diarization-enhanced-v1.bin")
        let manager = makeModelManager()
        let asrOption = try XCTUnwrap(manager.listLocalOptions(kind: .asr).first)
        let diarizationOption = try XCTUnwrap(manager.listLocalOptions(kind: .diarization).first)
        manager.setSelectedModelID(asrOption.id, for: .asr)
        manager.setSelectedModelID(diarizationOption.id, for: .diarization)

        let selector = DefaultInferenceRuntimeProfileSelector(modelManager: manager)
        let profile = try selector.resolveTranscriptionProfile(for: .balanced)

        XCTAssertEqual(profile.stageSelection.backend(for: .asr), .whisperCpp)
        XCTAssertEqual(profile.stageSelection.backend(for: .diarization), .cliDiarization)
        XCTAssertEqual(
            profile.modelArtifacts.asrModelURL?.resolvingSymlinksInPath().path,
            asrOption.url.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(
            profile.modelArtifacts.diarizationModelURL?.resolvingSymlinksInPath().path,
            diarizationOption.url.resolvingSymlinksInPath().path
        )
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

        let selector = DefaultInferenceRuntimeProfileSelector(modelManager: manager)
        let profile = try selector.resolveSummarizationProfile(for: .balanced)

        XCTAssertEqual(profile.stageSelection.backend(for: .summarization), .llamaCpp)
        XCTAssertEqual(
            profile.modelArtifacts.summarizationModelURL?.resolvingSymlinksInPath().path,
            summarizationOption.url.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(profile.summarizationRuntimeSettings.contextSize, 4096)
    }

    func testTranscriptionAvailabilityDelegatesToModelManager() {
        let manager = makeModelManager()
        let selector = DefaultInferenceRuntimeProfileSelector(modelManager: manager)

        let availability = selector.transcriptionAvailability(for: .balanced)

        XCTAssertEqual(
            availability,
            .requiresASRModel(profileOptions: ModelProfile.allCases)
        )
    }

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
}

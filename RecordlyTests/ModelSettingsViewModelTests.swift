import XCTest
@testable import Recordly

@MainActor
final class ModelSettingsViewModelTests: XCTestCase {
    private var tempDirectory: URL!
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ModelSettingsViewModelTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defaultsSuiteName = "ModelSettingsViewModelTests.\(UUID().uuidString)"
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

    func testRefreshBuildsCatalogStateForASRAndSummarization() throws {
        let asrDirectory = tempDirectory.appendingPathComponent("asr", isDirectory: true)
        let summarizationDirectory = tempDirectory.appendingPathComponent("summarization", isDirectory: true)
        try FileManager.default.createDirectory(at: asrDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: summarizationDirectory, withIntermediateDirectories: true)

        try Data("asr".utf8).write(to: asrDirectory.appendingPathComponent("podlodka-turbo-v1.bin"))
        try Data("summary".utf8).write(to: summarizationDirectory.appendingPathComponent("meeting-summary.gguf"))

        let manager = makeModelManager(
            asrDirectory: asrDirectory,
            summarizationDirectory: summarizationDirectory
        )
        let selectedSummarization = try XCTUnwrap(manager.listLocalOptions(kind: .summarization).first)
        manager.setSelectedModelID(selectedSummarization.id, for: .summarization)

        let viewModel = ModelSettingsViewModel(
            modelManager: manager,
            fluidAudioModelProvider: StubFluidAudioASRModelProvider(state: .ready),
            fluidAudioDiarizationModelProvider: StubFluidAudioDiarizationModelProvider(state: .failed(message: "offline prepare failed"))
        )

        viewModel.refresh()

        XCTAssertEqual(viewModel.fluidProvisioningState, .ready)
        XCTAssertEqual(viewModel.fluidDiarizationProvisioningState, .failed(message: "offline prepare failed"))
        XCTAssertEqual(viewModel.localASRModels.count, 1)
        XCTAssertEqual(viewModel.localASRModels.first?.sourceLabel, "User")
        XCTAssertFalse(viewModel.localASRModels.first?.supportsSelection ?? true)
        XCTAssertEqual(viewModel.summarizationCatalogModels.count, 1)
        XCTAssertTrue(viewModel.summarizationCatalogModels.first?.isSelected ?? false)
        XCTAssertEqual(viewModel.summarizationCatalogModels.first?.title, "Meeting Summary")
    }

    func testDownloadFluidDiarizationModelUpdatesProvisioningState() async {
        let provider = StubFluidAudioDiarizationModelProvider(state: .needsDownload)
        let viewModel = ModelSettingsViewModel(
            modelManager: makeModelManager(asrDirectory: nil, summarizationDirectory: nil),
            fluidAudioModelProvider: StubFluidAudioASRModelProvider(state: .needsDownload),
            fluidAudioDiarizationModelProvider: provider
        )

        viewModel.downloadFluidDiarizationModel()
        await Task.yield()

        XCTAssertEqual(provider.downloadCallCount, 1)
        XCTAssertEqual(viewModel.fluidDiarizationProvisioningState, .ready)
        XCTAssertTrue(viewModel.isFluidDiarizationModelReady)
    }

    private func makeModelManager(
        asrDirectory: URL?,
        summarizationDirectory: URL?
    ) -> ModelManager {
        ModelManager(
            preferences: ModelPreferencesStore(defaults: defaults),
            discoveryPaths: ModelDiscoveryPaths(
                appSupportDirectory: { _ in nil },
                sharedDirectory: { _ in nil },
                userDirectory: { kind in
                    switch kind {
                    case .asr:
                        return asrDirectory
                    case .summarization:
                        return summarizationDirectory
                    case .diarization:
                        return nil
                    }
                },
                projectDirectories: { [] }
            )
        )
    }
}

private final class StubFluidAudioASRModelProvider: FluidAudioASRModelProviding {
    private(set) var state: FluidAudioModelProvisioningState

    init(state: FluidAudioModelProvisioningState) {
        self.state = state
    }

    func refreshState() {}
    func downloadDefaultModel() async {
        state = .ready
    }

    func resolveForRuntime() throws -> URL {
        throw FluidAudioModelProvisioningError.noModelProvisioned
    }
}

private final class StubFluidAudioDiarizationModelProvider: FluidAudioDiarizationModelProviding {
    private(set) var state: FluidAudioModelProvisioningState
    private(set) var downloadCallCount = 0

    init(state: FluidAudioModelProvisioningState) {
        self.state = state
    }

    func refreshState() {}

    func downloadDefaultModel() async {
        downloadCallCount += 1
        state = .ready
    }

    func resolveForRuntime() throws -> any OfflineDiarizationManaging {
        throw FluidAudioModelProvisioningError.noModelProvisioned
    }
}

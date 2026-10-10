import XCTest
@testable import Recordly

@MainActor
final class FluidAudioDiarizationModelProviderTests: XCTestCase {
    func testUnrelatedModelDirectoryDoesNotClaimOfflineDiarizationReady() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("parakeet-ultra-coreml"), withIntermediateDirectories: true)
        let provider = FluidAudioDiarizationModelProvider(modelsRoot: { root })
        XCTAssertEqual(provider.state, .needsDownload)
        XCTAssertThrowsError(try provider.resolveForRuntime())
    }

    func testOfflineReadinessRequiresPLDAParametersAndAllFourBundles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let offline = root.appendingPathComponent("speaker-diarization")
        for name in ["Segmentation", "FBank", "Embedding", "PldaRho"] {
            try FileManager.default.createDirectory(at: offline.appendingPathComponent("\(name).mlmodelc"), withIntermediateDirectories: true)
            try Data("compiled-layout".utf8).write(to: offline.appendingPathComponent("\(name).mlmodelc/coremldata.bin"))
        }
        let provider = FluidAudioDiarizationModelProvider(modelsRoot: { root })
        XCTAssertEqual(provider.state, .needsDownload)
        try Data("{}".utf8).write(to: offline.appendingPathComponent("plda-parameters.json"))
        provider.refreshState()
        XCTAssertEqual(provider.state, .needsDownload, "Invalid PLDA data must not report ready")
        let psi = [Float](repeating: 1, count: 128).withUnsafeBytes { Data($0).base64EncodedString() }
        let json = ["tensors": ["psi": ["data_base64": psi]]]
        try JSONSerialization.data(withJSONObject: json).write(to: offline.appendingPathComponent("plda-parameters.json"))
        provider.refreshState()
        XCTAssertEqual(provider.state, .ready)
        let partialWeights = offline.appendingPathComponent("Embedding.mlmodelc/weights")
        try FileManager.default.createDirectory(at: partialWeights, withIntermediateDirectories: true)
        let partial = partialWeights.appendingPathComponent("weight.bin.partial")
        try Data("unfinished".utf8).write(to: partial)
        provider.refreshState()
        XCTAssertEqual(provider.state, .needsDownload, "Staged weights must not report ready")
        try FileManager.default.removeItem(at: partial)
        provider.refreshState()
        XCTAssertEqual(provider.state, .ready)
        try FileManager.default.removeItem(at: offline.appendingPathComponent("PldaRho.mlmodelc/coremldata.bin"))
        provider.refreshState()
        XCTAssertEqual(provider.state, .needsDownload, "Interrupted compiled bundle must not report ready")
        try FileManager.default.removeItem(at: offline.appendingPathComponent("Embedding.mlmodelc"))
        provider.refreshState()
        XCTAssertEqual(provider.state, .needsDownload)
    }

    func testResolveBeforeDownloadThrowsNoModelProvisioned() {
        let provider = FluidAudioDiarizationModelProvider(managerFactory: {
            StubOfflineDiarizationManager()
        }, hasInstalledModelOnDisk: {
            false
        })

        XCTAssertEqual(provider.state, .needsDownload)
        XCTAssertThrowsError(try provider.resolveForRuntime()) { error in
            XCTAssertEqual(error as? FluidAudioModelProvisioningError, .noModelProvisioned)
        }
    }

    func testDownloadPreparesManagerAndCachesResolvedInstance() async throws {
        var createdManagers: [StubOfflineDiarizationManager] = []
        let provider = FluidAudioDiarizationModelProvider(managerFactory: {
            let manager = StubOfflineDiarizationManager()
            createdManagers.append(manager)
            return manager
        }, hasInstalledModelOnDisk: {
            false
        })

        await provider.downloadDefaultModel()

        XCTAssertEqual(provider.state, .ready)
        XCTAssertEqual(createdManagers.count, 1)
        XCTAssertEqual(createdManagers[0].prepareModelsCallCount, 1)

        let resolvedFirst = try provider.resolveForRuntime()
        let resolvedSecond = try provider.resolveForRuntime()

        XCTAssertTrue(resolvedFirst === createdManagers[0])
        XCTAssertTrue(resolvedSecond === createdManagers[0])
    }

    func testDownloadWhenAlreadyReadyDoesNotCreateOrPrepareNewManager() async throws {
        let preparedManager = StubOfflineDiarizationManager()
        let provider = FluidAudioDiarizationModelProvider(
            preparedManager: preparedManager,
            managerFactory: {
                XCTFail("managerFactory should not be called when provider is already ready")
                return StubOfflineDiarizationManager()
            },
            hasInstalledModelOnDisk: {
                false
            }
        )

        await provider.downloadDefaultModel()

        XCTAssertEqual(provider.state, .ready)
        XCTAssertEqual(preparedManager.prepareModelsCallCount, 0)

        let resolved = try provider.resolveForRuntime()
        XCTAssertTrue(resolved === preparedManager)
    }

    func testDownloadFailureSetsFailedStateAndResolvePropagatesFailure() async {
        let provider = FluidAudioDiarizationModelProvider(managerFactory: {
            StubOfflineDiarizationManager(prepareError: TestError.prepareFailed)
        }, hasInstalledModelOnDisk: {
            false
        })

        await provider.downloadDefaultModel()

        XCTAssertEqual(
            provider.state,
            .failed(message: TestError.prepareFailed.localizedDescription)
        )
        XCTAssertThrowsError(try provider.resolveForRuntime()) { error in
            XCTAssertEqual(
                error as? FluidAudioModelProvisioningError,
                .downloadFailed(message: TestError.prepareFailed.localizedDescription)
            )
        }
    }

    func testRefreshStateCanUseInstalledModelDetectorWithoutPreparingManager() {
        let provider = FluidAudioDiarizationModelProvider(managerFactory: {
            XCTFail("managerFactory should not be called when checking installed state")
            return StubOfflineDiarizationManager()
        }, hasInstalledModelOnDisk: {
            true
        })

        XCTAssertEqual(provider.state, .ready)
    }
}

private final class StubOfflineDiarizationManager: OfflineDiarizationManaging, @unchecked Sendable {
    private let prepareError: Error?
    private(set) var prepareModelsCallCount = 0

    init(prepareError: Error? = nil) {
        self.prepareError = prepareError
    }

    func prepareModels() async throws {
        prepareModelsCallCount += 1
        if let prepareError {
            throw prepareError
        }
    }

    func process(audio: [Float]) async throws -> OfflineDiarizationResult {
        OfflineDiarizationResult(segments: [])
    }
}

private enum TestError: LocalizedError {
    case prepareFailed

    var errorDescription: String? {
        switch self {
        case .prepareFailed:
            return "prepare failed"
        }
    }
}

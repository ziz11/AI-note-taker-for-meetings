import XCTest
@testable import Recordly

@MainActor
final class FluidAudioDiarizationModelProviderTests: XCTestCase {
    func testResolveBeforeDownloadThrowsNoModelProvisioned() {
        let provider = FluidAudioDiarizationModelProvider(managerFactory: {
            StubOfflineDiarizationManager()
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

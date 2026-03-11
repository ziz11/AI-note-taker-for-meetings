import Foundation

#if arch(arm64) && canImport(FluidAudio)
import FluidAudio
#endif

// MARK: - Protocol wrapper for testability

struct OfflineDiarizationSegment {
    var speakerId: String
    var startTimeSeconds: Float
    var endTimeSeconds: Float
    var qualityScore: Float
}

struct OfflineDiarizationResult {
    var segments: [OfflineDiarizationSegment]
}

protocol OfflineDiarizationManaging: AnyObject, Sendable {
    func prepareModels() async throws
    func process(audio: [Float]) async throws -> OfflineDiarizationResult
}

#if arch(arm64) && canImport(FluidAudio)
final class FluidAudioOfflineDiarizationManagerAdapter: OfflineDiarizationManaging, @unchecked Sendable {
    private let manager: OfflineDiarizerManager

    init() {
        self.manager = OfflineDiarizerManager(config: .default)
    }

    func prepareModels() async throws {
        try await manager.prepareModels(directory: nil)
    }

    func process(audio: [Float]) async throws -> OfflineDiarizationResult {
        let result = try await manager.process(audio: audio)
        return OfflineDiarizationResult(
            segments: result.segments.map { segment in
                OfflineDiarizationSegment(
                    speakerId: segment.speakerId,
                    startTimeSeconds: segment.startTimeSeconds,
                    endTimeSeconds: segment.endTimeSeconds,
                    qualityScore: segment.qualityScore
                )
            }
        )
    }
}
#endif

// MARK: - Provider protocol

@MainActor
protocol FluidAudioDiarizationModelProviding: AnyObject {
    var state: FluidAudioModelProvisioningState { get }
    func refreshState()
    func downloadDefaultModel() async
    func resolveForRuntime() throws -> any OfflineDiarizationManaging
}

private func makeDefaultFluidAudioDiarizationManager() -> any OfflineDiarizationManaging {
#if arch(arm64) && canImport(FluidAudio)
    FluidAudioOfflineDiarizationManagerAdapter()
#else
    UnsupportedOfflineDiarizationManager()
#endif
}

// MARK: - Provider implementation

@MainActor
final class FluidAudioDiarizationModelProvider: ObservableObject, FluidAudioDiarizationModelProviding {
    @Published private(set) var state: FluidAudioModelProvisioningState = .needsDownload

    private var cachedManager: (any OfflineDiarizationManaging)?
    private let managerFactory: () -> any OfflineDiarizationManaging

    init(managerFactory: @escaping () -> any OfflineDiarizationManaging = makeDefaultFluidAudioDiarizationManager) {
        self.managerFactory = managerFactory
        refreshState()
    }

    /// Test/manual override: inject a pre-prepared manager.
    init(
        preparedManager: any OfflineDiarizationManaging,
        managerFactory: @escaping () -> any OfflineDiarizationManaging = makeDefaultFluidAudioDiarizationManager
    ) {
        self.cachedManager = preparedManager
        self.managerFactory = managerFactory
        self.state = .ready
    }

    func refreshState() {
        guard case .downloading = state else {
            state = cachedManager != nil ? .ready : .needsDownload
            return
        }
    }

    func downloadDefaultModel() async {
        guard !isDownloading, cachedManager == nil else { return }

        state = .downloading
        do {
            let manager = makeManager()
            try await manager.prepareModels()
            cachedManager = manager
            state = .ready
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    func resolveForRuntime() throws -> any OfflineDiarizationManaging {
        guard let manager = cachedManager else {
            switch state {
            case .ready, .needsDownload:
                throw FluidAudioModelProvisioningError.noModelProvisioned
            case .downloading:
                throw FluidAudioModelProvisioningError.downloadFailed(message: "Model is currently downloading.")
            case let .failed(message):
                throw FluidAudioModelProvisioningError.downloadFailed(message: message)
            }
        }
        return manager
    }

    private var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    private func makeManager() -> any OfflineDiarizationManaging {
        managerFactory()
    }
}

private final class UnsupportedOfflineDiarizationManager: OfflineDiarizationManaging, @unchecked Sendable {
    func prepareModels() async throws {
        throw FluidAudioModelProvisioningError.sdkUnavailable
    }

    func process(audio: [Float]) async throws -> OfflineDiarizationResult {
        throw FluidAudioModelProvisioningError.sdkUnavailable
    }
}

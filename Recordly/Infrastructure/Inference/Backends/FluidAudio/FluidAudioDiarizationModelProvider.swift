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
    var voiceObservations: [DiarizationVoiceObservation]? = nil
    var embeddingSpace: String? = nil
    var embeddingArtifactFingerprint: String? = nil
}

protocol OfflineDiarizationManaging: AnyObject, Sendable {
    var modelDirectoryURL: URL? { get }
    func prepareModels() async throws
    func process(audio: [Float]) async throws -> OfflineDiarizationResult
}

extension OfflineDiarizationManaging {
    var modelDirectoryURL: URL? { nil }
}

#if arch(arm64) && canImport(FluidAudio)
final class FluidAudioOfflineDiarizationManagerAdapter: OfflineDiarizationManaging, @unchecked Sendable {
    private let manager: OfflineDiarizerManager
    private let modelsRoot: URL?
    let modelDirectoryURL: URL?
    private var loadedArtifactFingerprint: String?

    init(modelsRoot: URL? = AppPaths.fluidAudioSDKModelsDirectory()) {
        let resolvedModelsRoot = modelsRoot ?? OfflineDiarizerModels.defaultModelsDirectory()
        self.modelsRoot = resolvedModelsRoot
        self.modelDirectoryURL = resolvedModelsRoot.appendingPathComponent(FluidAudioRuntimeIdentity.diarizationCacheFolder, isDirectory: true)
        var config = OfflineDiarizerConfig.default
        config.exposeChunkEmbeddings = true
        self.manager = OfflineDiarizerManager(config: config)
    }

    func prepareModels() async throws {
        try await manager.prepareModels(directory: modelsRoot)
        if loadedArtifactFingerprint == nil, let modelDirectoryURL {
            loadedArtifactFingerprint = try InferenceFingerprint.artifact(at: modelDirectoryURL)
        }
    }

    func process(audio: [Float]) async throws -> OfflineDiarizationResult {
        try await prepareModels()
        if let modelDirectoryURL, let loadedArtifactFingerprint {
            guard try InferenceFingerprint.artifact(at: modelDirectoryURL) == loadedArtifactFingerprint else {
                throw FluidAudioModelProvisioningError.downloadFailed(message: "Diarization models changed after loading. Restart the app before processing with the replacement models.")
            }
        }
        let result = try await manager.process(audio: audio)
        let labels = Set(result.segments.map(\.speakerId))
        let observations = (result.chunkEmbeddings ?? []).prefix(128).compactMap { observation -> DiarizationVoiceObservation? in
            guard labels.contains(observation.speakerId), observation.startTimeSeconds.isFinite,
                  observation.endTimeSeconds.isFinite, observation.startTimeSeconds >= 0,
                  observation.endTimeSeconds > observation.startTimeSeconds,
                  observation.endTimeSeconds <= Double(audio.count) / 16_000 + 10,
                  let vector = DiarizationVoiceObservation.normalized(observation.embedding256) else { return nil }
            return .init(speaker: observation.speakerId,
                startMs: Int((observation.startTimeSeconds * 1_000).rounded(.down)),
                endMs: Int((observation.endTimeSeconds * 1_000).rounded(.up)), embedding: vector)
        }
        return OfflineDiarizationResult(
            segments: result.segments.map { segment in
                OfflineDiarizationSegment(
                    speakerId: segment.speakerId,
                    startTimeSeconds: segment.startTimeSeconds,
                    endTimeSeconds: segment.endTimeSeconds,
                    qualityScore: segment.qualityScore
                )
            },
            voiceObservations: observations,
            embeddingSpace: "wespeaker-256-l2;fluidaudio:\(FluidAudioRuntimeIdentity.sdkVersion)",
            embeddingArtifactFingerprint: loadedArtifactFingerprint
        )
    }
}
#endif

// MARK: - Provider protocol

@MainActor
protocol FluidAudioDiarizationModelProviding: AnyObject {
    var state: FluidAudioModelProvisioningState { get }
    var modelURLForRuntime: URL? { get }
    func refreshState()
    func downloadDefaultModel() async
    func resolveForRuntime() throws -> any OfflineDiarizationManaging
}

extension FluidAudioDiarizationModelProviding {
    var modelURLForRuntime: URL? { nil }
}

// MARK: - Provider implementation

@MainActor
final class FluidAudioDiarizationModelProvider: ObservableObject, FluidAudioDiarizationModelProviding {
    @Published private(set) var state: FluidAudioModelProvisioningState = .needsDownload

    private var cachedManager: (any OfflineDiarizationManaging)?
    private let managerFactory: () -> any OfflineDiarizationManaging
    private let installedModelChecker: () -> Bool
    private let modelsRoot: () -> URL?

    var modelURLForRuntime: URL? {
        if let cachedManager { return cachedManager.modelDirectoryURL }
        guard installedModelChecker() else { return nil }
        return modelsRoot()?.appendingPathComponent(FluidAudioRuntimeIdentity.diarizationCacheFolder, isDirectory: true)
    }

    init(
        managerFactory: (() -> any OfflineDiarizationManaging)? = nil,
        hasInstalledModelOnDisk: (() -> Bool)? = nil,
        modelsRoot: @escaping () -> URL? = AppPaths.fluidAudioSDKModelsDirectory
    ) {
        self.modelsRoot = modelsRoot
        self.managerFactory = managerFactory ?? {
#if arch(arm64) && canImport(FluidAudio)
            FluidAudioOfflineDiarizationManagerAdapter(modelsRoot: modelsRoot())
#else
            UnsupportedOfflineDiarizationManager()
#endif
        }
        self.installedModelChecker = hasInstalledModelOnDisk ?? {
            Self.hasInstalledModelOnDisk(modelsRoot: modelsRoot())
        }
        refreshState()
    }

    /// Test/manual override: inject a pre-prepared manager.
    init(
        preparedManager: any OfflineDiarizationManaging,
        managerFactory: (() -> any OfflineDiarizationManaging)? = nil,
        hasInstalledModelOnDisk: (() -> Bool)? = nil,
        modelsRoot: @escaping () -> URL? = AppPaths.fluidAudioSDKModelsDirectory
    ) {
        self.cachedManager = preparedManager
        self.modelsRoot = modelsRoot
        self.managerFactory = managerFactory ?? {
#if arch(arm64) && canImport(FluidAudio)
            FluidAudioOfflineDiarizationManagerAdapter(modelsRoot: modelsRoot())
#else
            UnsupportedOfflineDiarizationManager()
#endif
        }
        self.installedModelChecker = hasInstalledModelOnDisk ?? {
            Self.hasInstalledModelOnDisk(modelsRoot: modelsRoot())
        }
        self.state = .ready
    }

    func refreshState() {
        guard case .downloading = state else {
            state = currentState()
            return
        }
    }

    func downloadDefaultModel() async {
        guard !isDownloading else { return }
        if case .ready = state {
            return
        }

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
        guard cachedManager != nil || installedModelChecker() else {
            switch state {
            case .ready, .needsDownload:
                throw FluidAudioModelProvisioningError.noModelProvisioned
            case .downloading:
                throw FluidAudioModelProvisioningError.downloadFailed(message: "Model is currently downloading.")
            case let .failed(message):
                throw FluidAudioModelProvisioningError.downloadFailed(message: message)
            }
        }

        if let cachedManager {
            return cachedManager
        }

        let manager = makeManager()
        cachedManager = manager
        return manager
    }

    private var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    private func makeManager() -> any OfflineDiarizationManaging {
        managerFactory()
    }

    private func currentState() -> FluidAudioModelProvisioningState {
        if cachedManager != nil || installedModelChecker() {
            return .ready
        }

        if case let .failed(message) = state {
            return .failed(message: message)
        }

        return .needsDownload
    }

    private static func hasInstalledModelOnDisk(modelsRoot: URL?) -> Bool {
        guard let modelsRoot else {
            return false
        }

        let directory = modelsRoot.appendingPathComponent(FluidAudioRuntimeIdentity.diarizationCacheFolder, isDirectory: true)
        let bundles = ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc"]
        guard bundles.allSatisfy({ name in
            FluidAudioModelValidator.isValidCompiledModel(at: directory.appendingPathComponent(name))
        }) else { return false }

        // Offline VBx requires PLDA psi alongside the four compiled models.
        // An online-only install or an interrupted download must not report ready.
        let parameters = directory.appendingPathComponent("plda-parameters.json")
        guard let data = try? Data(contentsOf: parameters),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tensors = json["tensors"] as? [String: Any],
              let psi = tensors["psi"] as? [String: Any],
              let base64 = psi["data_base64"] as? String,
              let decoded = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]),
              !decoded.isEmpty,
              decoded.count.isMultiple(of: MemoryLayout<Float>.size) else { return false }
        return decoded.withUnsafeBytes { bytes in
            (0..<(decoded.count / MemoryLayout<Float>.size)).allSatisfy { index in
                let value = bytes.loadUnaligned(fromByteOffset: index * MemoryLayout<Float>.size, as: Float.self)
                return value.isFinite && value > 0
            }
        }
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

import Combine
import Foundation

#if arch(arm64) && canImport(FluidAudio)
import FluidAudio
#endif

enum FluidAudioModelProvisioningState: Equatable {
    case ready
    case needsDownload
    case downloading
    case failed(message: String)
}

struct FluidAudioModelDownloadProgress: Equatable, Sendable {
    /// The SDK reports each asset separately, rather than a whole-package percentage.
    var fraction: Double
    var detail: String
}

enum FluidAudioModelProvisioningError: LocalizedError, Equatable {
    case noModelProvisioned
    case sdkUnavailable
    case downloadFailed(message: String)
    case modelInUse
    case unsafeDirectory

    var errorDescription: String? {
        switch self {
        case .noModelProvisioned:
            return "Download the selected transcription model in Models settings first."
        case .sdkUnavailable:
            return "FluidAudio SDK is not available on this architecture."
        case let .downloadFailed(message):
            return "FluidAudio model provisioning failed: \(message)"
        case .modelInUse:
            return "Choose another model and wait for transcription to finish before removing this model."
        case .unsafeDirectory:
            return "The model directory must be inside the FluidAudio SDK cache."
        }
    }
}

@MainActor
protocol FluidAudioASRModelProviding: AnyObject {
    var state: FluidAudioModelProvisioningState { get }
    var selectedModel: FluidAudioASRModel { get }
    var changes: AnyPublisher<Void, Never> { get }
    func state(for model: FluidAudioASRModel) -> FluidAudioModelProvisioningState
    func progress(for model: FluidAudioASRModel) -> FluidAudioModelDownloadProgress?
    func refreshState()
    func downloadDefaultModel() async
    func downloadModel(_ model: FluidAudioASRModel) async
    func selectModel(_ model: FluidAudioASRModel) throws
    func removeModel(_ model: FluidAudioASRModel) throws
    func resolveForRuntime() throws -> URL
}

extension FluidAudioASRModelProviding {
    var selectedModel: FluidAudioASRModel { .ultra }
    var changes: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    func state(for model: FluidAudioASRModel) -> FluidAudioModelProvisioningState {
        model == selectedModel ? state : .needsDownload
    }
    func progress(for model: FluidAudioASRModel) -> FluidAudioModelDownloadProgress? { nil }
    func downloadModel(_ model: FluidAudioASRModel) async {
        if model == selectedModel { await downloadDefaultModel() }
    }
    func selectModel(_ model: FluidAudioASRModel) throws {
        throw FluidAudioModelProvisioningError.noModelProvisioned
    }
    func removeModel(_ model: FluidAudioASRModel) throws {
        throw FluidAudioModelProvisioningError.modelInUse
    }
}

/// Owns SDK-managed ASR provisioning and preferences; never loads inference weights for catalog display.
@MainActor
final class FluidAudioASRModelProvider: ObservableObject, FluidAudioASRModelProviding {
    typealias Downloader = (FluidAudioASRModel, URL, @escaping @Sendable (FluidAudioModelDownloadProgress) -> Void) async throws -> Void
    static let selectionKey = "fluidAudio.asr.selectedModel"

    @Published private(set) var selectedModel: FluidAudioASRModel
    @Published private var states: [FluidAudioASRModel: FluidAudioModelProvisioningState] = [:]
    @Published private var progressValues: [FluidAudioASRModel: FluidAudioModelDownloadProgress] = [:]
    var state: FluidAudioModelProvisioningState { state(for: selectedModel) }
    var changes: AnyPublisher<Void, Never> { objectWillChange.eraseToAnyPublisher() }

    private let fileManager: FileManager
    private let modelsRoot: () -> URL?
    private let defaults: UserDefaults
    private let downloader: Downloader
    private var activeDownload: UUID?

    init(
        fileManager: FileManager = .default,
        modelsRoot: @escaping () -> URL? = AppPaths.fluidAudioSDKModelsDirectory,
        defaults: UserDefaults = .standard,
        downloader: Downloader? = nil
    ) {
        self.fileManager = fileManager
        self.modelsRoot = modelsRoot
        self.defaults = defaults
        self.downloader = downloader ?? Self.downloadFromSDK
        selectedModel = defaults.string(forKey: Self.selectionKey).flatMap(FluidAudioASRModel.init(rawValue:)) ?? .ultra
        refreshState()
    }

    func state(for model: FluidAudioASRModel) -> FluidAudioModelProvisioningState {
        states[model] ?? .needsDownload
    }

    func progress(for model: FluidAudioASRModel) -> FluidAudioModelDownloadProgress? { progressValues[model] }

    func refreshState() {
        for model in FluidAudioASRModel.allCases {
            if state(for: model) == .downloading { continue }
            let next: FluidAudioModelProvisioningState
            if let url = try? directory(for: model), FluidAudioModelValidator.isValidModelDirectory(url, fileManager: fileManager) {
                next = .ready
            } else if case .failed = state(for: model) {
                next = state(for: model)
            } else {
                next = .needsDownload
            }
            if states[model] != next { states[model] = next }
        }
    }

    func downloadDefaultModel() async { await downloadModel(selectedModel) }

    func downloadModel(_ model: FluidAudioASRModel) async {
        guard activeDownload == nil else { return }
        refreshState()
        guard state(for: model) != .ready else { return }
        let token = UUID()
        activeDownload = token
        states[model] = .downloading
        progressValues[model] = .init(fraction: 0, detail: "Preparing download…")
        defer {
            activeDownload = nil
            progressValues[model] = nil
        }
        do {
            let url = try directory(for: model)
            try repairIncompleteAssets(in: url)
            try await downloader(model, url) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.activeDownload == token, self.state(for: model) == .downloading else { return }
                    self.progressValues[model] = .init(
                        fraction: min(1, max(0, progress.fraction.isFinite ? progress.fraction : 0)),
                        detail: progress.detail
                    )
                }
            }
            try Task.checkCancellation()
            try FluidAudioModelValidator.validateModelDirectory(url, fileManager: fileManager)
            states[model] = .ready
        } catch {
            states[model] = .failed(message: error.localizedDescription)
        }
    }

    func selectModel(_ model: FluidAudioASRModel) throws {
        let url = try directory(for: model)
        guard state(for: model) != .downloading, FluidAudioModelValidator.isValidModelDirectory(url, fileManager: fileManager) else {
            throw FluidAudioModelProvisioningError.noModelProvisioned
        }
        defaults.set(model.rawValue, forKey: Self.selectionKey)
        selectedModel = model
        refreshState()
    }

    func removeModel(_ model: FluidAudioASRModel) throws {
        guard model != selectedModel, activeDownload == nil else { throw FluidAudioModelProvisioningError.modelInUse }
        let url = try directory(for: model)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        states[model] = .needsDownload
    }

    func resolveForRuntime() throws -> URL {
        guard state != .downloading else {
            throw FluidAudioModelProvisioningError.downloadFailed(message: "Model is currently downloading.")
        }
        let url = try directory(for: selectedModel)
        guard FluidAudioModelValidator.isValidModelDirectory(url, fileManager: fileManager) else {
            throw FluidAudioModelProvisioningError.noModelProvisioned
        }
        return url
    }

    private func directory(for model: FluidAudioASRModel) throws -> URL {
        guard let root = modelsRoot()?.standardizedFileURL.resolvingSymlinksInPath() else {
            throw FluidAudioModelProvisioningError.noModelProvisioned
        }
        let url = root.appendingPathComponent(model.cacheFolder, isDirectory: true)
        guard url.resolvingSymlinksInPath().deletingLastPathComponent() == root,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else {
            throw FluidAudioModelProvisioningError.unsafeDirectory
        }
        return url
    }

    private func repairIncompleteAssets(in directory: URL) throws {
        // SDK 0.17.7's modelsExist only checks component paths. Remove invalid
        // compiled components so Retry cannot short-circuit on an interrupted cache.
        // Keep complete siblings; the SDK can reuse their downloads.
        for marker in FluidAudioModelValidator.requiredMarkers where marker.hasSuffix(".mlmodelc") {
            let item = directory.appendingPathComponent(marker)
            if fileManager.fileExists(atPath: item.path), !FluidAudioModelValidator.isValidCompiledModel(at: item) {
                try fileManager.removeItem(at: item)
            }
        }
    }

    private static func downloadFromSDK(
        model: FluidAudioASRModel, url: URL,
        report: @escaping @Sendable (FluidAudioModelDownloadProgress) -> Void
    ) async throws {
#if arch(arm64) && canImport(FluidAudio)
        _ = try await AsrModels.download(to: url, version: model.sdkVersion, encoderPrecision: .int8) { progress in
            let detail: String
            switch progress.phase {
            case .listing: detail = "Listing model assets…"
            case let .downloading(completed, total): detail = "Current asset: \(completed) of \(total) files"
            case let .compiling(name): detail = "Preparing \(name)…"
            }
            report(.init(fraction: progress.fractionCompleted, detail: detail))
        }
#else
        throw FluidAudioModelProvisioningError.sdkUnavailable
#endif
    }
}

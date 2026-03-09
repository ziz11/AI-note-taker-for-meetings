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

enum FluidAudioModelProvisioningError: LocalizedError, Equatable {
    case noModelProvisioned
    case sdkUnavailable
    case downloadFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .noModelProvisioned:
            return "No FluidAudio model is provisioned. Download FluidAudio v3 model first."
        case .sdkUnavailable:
            return "FluidAudio SDK is not available on this architecture."
        case let .downloadFailed(message):
            return "FluidAudio model provisioning failed: \(message)"
        }
    }
}

@MainActor
protocol FluidAudioModelProviding: AnyObject {
    var state: FluidAudioModelProvisioningState { get }
    func refreshState()
    func downloadDefaultModel() async
    func resolveForRuntime() throws -> URL
}

/// Resolves FluidAudio v3 models from the SDK's local storage directory.
/// Downloads are delegated to `AsrModels.downloadAndLoad` which handles caching internally.
@MainActor
final class FluidAudioModelProvider: ObservableObject, FluidAudioModelProviding {
    @Published private(set) var state: FluidAudioModelProvisioningState = .needsDownload

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        refreshState()
    }

    func refreshState() {
        guard case .downloading = state else {
            state = currentState()
            return
        }
    }

    func downloadDefaultModel() async {
#if arch(arm64) && canImport(FluidAudio)
        guard !isDownloading else { return }

        state = .downloading
        do {
            _ = try await AsrModels.downloadAndLoad(version: .v3)
            state = currentState()
        } catch {
            state = .failed(message: error.localizedDescription)
        }
#else
        state = .failed(message: FluidAudioModelProvisioningError.sdkUnavailable.localizedDescription)
#endif
    }

    func resolveForRuntime() throws -> URL {
        let state = currentState()
        switch state {
        case .ready:
            guard let modelURL = resolveProvisionedModelDirectory() else {
                throw FluidAudioModelProvisioningError.noModelProvisioned
            }
            return modelURL
        case .needsDownload:
            throw FluidAudioModelProvisioningError.noModelProvisioned
        case .downloading:
            throw FluidAudioModelProvisioningError.downloadFailed(message: "Model is currently downloading.")
        case let .failed(message):
            throw FluidAudioModelProvisioningError.downloadFailed(message: message)
        }
    }

    private var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    private func currentState() -> FluidAudioModelProvisioningState {
        if resolveProvisionedModelDirectory() != nil {
            return .ready
        }

        if case let .failed(message) = state {
            return .failed(message: message)
        }

        return .needsDownload
    }

    private func resolveProvisionedModelDirectory() -> URL? {
        guard let modelsRoot = AppPaths.fluidAudioSDKModelsDirectory() else {
            return nil
        }

        let candidateDirectories = (try? fileManager.contentsOfDirectory(
            at: modelsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return candidateDirectories
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .first(where: { FluidAudioModelValidator.isValidModelDirectory($0, fileManager: fileManager) })
    }
}

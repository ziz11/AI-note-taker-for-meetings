import Foundation

enum ModelKind: String, Codable, CaseIterable {
    case asr
    case diarization
    case summarization
}

enum ModelProfile: String, Codable, CaseIterable {
    case compact
    case balanced
    case enhanced

    var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .balanced: return "Balanced"
        case .enhanced: return "Enhanced"
        }
    }

    var summary: String {
        switch self {
        case .compact: return "Fastest install and smallest local footprint."
        case .balanced: return "Recommended quality/performance tradeoff."
        case .enhanced: return "Best quality with optional speaker separation model."
        }
    }
}

struct ModelDescriptor: Codable, Equatable {
    let id: String
    let displayName: String
    let kind: ModelKind
    let profile: ModelProfile
    let version: String
    let sizeBytes: Int64
    let checksum: String
    let downloadURL: String
    let locationLabel: String
}

struct LocalModelOption: Identifiable, Equatable {
    enum Source: String, Codable, Equatable {
        case shared
        case appSupport
        case homeModels
        case projectLocal
        case userLocal
    }

    let id: String
    let displayName: String
    let kind: ModelKind
    let url: URL
    let sizeBytes: Int64
    let source: Source
}

enum ModelInstallState: Equatable {
    case notInstalled
    case downloading(progress: Double)
    case installed
    case failed(reason: String)
}

enum TranscriptionAvailability: Equatable {
    case ready
    case degradedNoDiarization
    case unavailable(reason: String)
}

struct ModelRuntimeStatus: Identifiable, Equatable {
    let model: ModelDescriptor
    let state: ModelInstallState

    var id: String { model.id }
}

struct InstalledModelMetadata: Codable, Equatable {
    let modelID: String
    let kind: ModelKind
    let version: String
    let installedAt: Date
    let checksum: String
    let sizeBytes: Int64
    let installedPath: String
}

struct InstalledModelsMetadataFile: Codable {
    var installedModels: [InstalledModelMetadata]
}

/// Basic container validation only; architecture/weights are validated by the runtime.
enum SummarizationModelArtifactError: LocalizedError, Equatable {
    case missing(URL)
    case invalid(URL)
    case incompatible(URL)

    var errorDescription: String? {
        switch self {
        case let .missing(url): return "Selected summarization model is missing at: \(url.path)"
        case let .invalid(url): return "Invalid GGUF model header at: \(url.path). Choose a complete GGUF file."
        case let .incompatible(url): return "Incompatible summarization model at: \(url.path). Use GGUF for llama.cpp or a supported MLX directory; Whisper/GGML .bin files are not summary models."
        }
    }
}

enum GGUFModelValidator {
    static func validate(_ url: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: url.path) else { throw SummarizationModelArtifactError.missing(url) }
        let ext = url.pathExtension.lowercased()
        guard ["gguf", "bin"].contains(ext) else { throw SummarizationModelArtifactError.incompatible(url) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw SummarizationModelArtifactError.invalid(url) }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 24), header.count == 24,
              Array(header.prefix(4)) == [0x47, 0x47, 0x55, 0x46] else {
            if ext == "bin" { throw SummarizationModelArtifactError.incompatible(url) }
            throw SummarizationModelArtifactError.invalid(url)
        }
        let bytes = Array(header)
        let version = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[4 + $1]) << (8 * $1) }
        let tensorCount = (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[8 + $1]) << (8 * $1) }
        guard [2, 3].contains(version), tensorCount > 0 else { throw SummarizationModelArtifactError.invalid(url) }
    }
}

import Foundation

enum ModelKind: String, Codable, CaseIterable {
    case asr
    case diarization
    case summarization
}

enum ASRLanguage: String, Codable, CaseIterable {
    case auto

    var displayName: String {
        switch self {
        case .auto:
            return "AUTO"
        }
    }
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
    case requiresASRModel(profileOptions: [ModelProfile])
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

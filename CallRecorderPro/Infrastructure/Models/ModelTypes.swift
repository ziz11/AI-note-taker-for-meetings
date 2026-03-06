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

enum ModelInstallState: Equatable {
    case notInstalled
    case downloading(progress: Double)
    case installed
    case failed(reason: String)
}

enum TranscriptionAvailability: Equatable {
    case available
    case requiresASRModel(profileOptions: [ModelProfile])
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

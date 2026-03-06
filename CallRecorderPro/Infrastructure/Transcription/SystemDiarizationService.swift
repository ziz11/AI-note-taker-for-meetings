import Foundation

struct DiarizationServiceConfiguration: Sendable {
    var modelURL: URL
}

protocol SystemDiarizationService {
    func diarize(
        systemAudioURL: URL,
        sessionID: UUID,
        configuration: DiarizationServiceConfiguration
    ) async throws -> DiarizationDocument
}

struct PlaceholderSystemDiarizationService: SystemDiarizationService {
    func diarize(
        systemAudioURL: URL,
        sessionID: UUID,
        configuration: DiarizationServiceConfiguration
    ) async throws -> DiarizationDocument {
        let exists = FileManager.default.fileExists(atPath: systemAudioURL.path)
        guard exists else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard FileManager.default.fileExists(atPath: configuration.modelURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        return DiarizationDocument(
            version: 1,
            sessionID: sessionID,
            createdAt: Date(),
            segments: []
        )
    }
}

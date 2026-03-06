import Foundation

struct ASREngineConfiguration: Sendable {
    var modelURL: URL
}

protocol ASREngine {
    var displayName: String { get }
    func transcribe(
        audioURL: URL,
        channel: TranscriptChannel,
        sessionID: UUID,
        configuration: ASREngineConfiguration
    ) async throws -> ASRDocument
}

struct WhisperCppEngine: ASREngine {
    let displayName: String = "WhisperCpp (RU+EN)"

    func transcribe(
        audioURL: URL,
        channel: TranscriptChannel,
        sessionID: UUID,
        configuration: ASREngineConfiguration
    ) async throws -> ASRDocument {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard FileManager.default.fileExists(atPath: configuration.modelURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        // Placeholder integration point for whisper runtime backed by externally installed model.
        return ASRDocument(
            version: 1,
            sessionID: sessionID,
            channel: channel,
            createdAt: Date(),
            segments: []
        )
    }
}

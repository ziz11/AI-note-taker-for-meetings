import Foundation

protocol RecordingsPersistence: AnyObject {
    func recordingsDirectoryPath() throws -> String
    func loadRecordings() throws -> [RecordingSession]
    func sessionDirectory(for id: UUID) throws -> URL
    func save(_ recording: RecordingSession) throws
    func delete(id: UUID) throws
    func transcriptText(for recording: RecordingSession) -> String?
    func summaryText(for recording: RecordingSession) -> String?
    func copyImportedAudio(from sourceURL: URL, to id: UUID) throws -> String
    func duplicateSessionContents(from sourceID: UUID, to destinationID: UUID) throws
    func playableAudioURL(for recording: RecordingSession) throws -> URL?
}

final class RecordingsRepository: RecordingsPersistence {
    private let fileManager: FileManager
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var transcriptCache: [UUID: String]
    private var summaryCache: [UUID: String]

    init(
        fileManager: FileManager = .default,
        decoder: JSONDecoder? = nil,
        encoder: JSONEncoder? = nil
    ) {
        self.fileManager = fileManager

        if let decoder {
            self.decoder = decoder
        } else {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.decoder = decoder
        }

        if let encoder {
            self.encoder = encoder
        } else {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            self.encoder = encoder
        }

        self.transcriptCache = [:]
        self.summaryCache = [:]
    }

    func recordingsDirectoryPath() throws -> String {
        try AppPaths.recordingsDirectory().path
    }

    func loadRecordings() throws -> [RecordingSession] {
        let recordingsDirectory = try AppPaths.recordingsDirectory()
        let sessionDirectories = try fileManager.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return try sessionDirectories.compactMap { sessionDirectory in
            let metadataURL = sessionDirectory.appendingPathComponent("session.json")
            guard fileManager.fileExists(atPath: metadataURL.path) else {
                return nil
            }

            let data = try Data(contentsOf: metadataURL)
            return try decoder.decode(RecordingSession.self, from: data)
        }
        .sorted(by: { $0.createdAt > $1.createdAt })
    }

    func sessionDirectory(for id: UUID) throws -> URL {
        try AppPaths.sessionDirectory(for: id)
    }

    func save(_ recording: RecordingSession) throws {
        let metadataURL = try AppPaths.sessionMetadataURL(for: recording.id)
        let data = try encoder.encode(recording)
        try data.write(to: metadataURL, options: .atomic)
        transcriptCache[recording.id] = nil
        summaryCache[recording.id] = nil
    }

    func delete(id: UUID) throws {
        let sessionDirectory = try sessionDirectory(for: id)
        if fileManager.fileExists(atPath: sessionDirectory.path) {
            try fileManager.removeItem(at: sessionDirectory)
        }
        transcriptCache[id] = nil
        summaryCache[id] = nil
    }

    func transcriptText(for recording: RecordingSession) -> String? {
        if let cachedTranscript = transcriptCache[recording.id] {
            return cachedTranscript
        }

        guard let sessionDirectory = try? sessionDirectory(for: recording.id) else {
            return nil
        }

        if let transcriptFile = recording.assets.transcriptFile {
            let transcriptURL = sessionDirectory.appendingPathComponent(transcriptFile)
            if let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8) {
                transcriptCache[recording.id] = transcript
                return transcript
            }
        }

        if let transcriptJSONFile = recording.assets.transcriptJSONFile {
            let transcriptURL = sessionDirectory.appendingPathComponent(transcriptJSONFile)
            if let data = try? Data(contentsOf: transcriptURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let document = try? decoder.decode(TranscriptDocument.self, from: data) {
                    let transcript = document.segments
                        .map { "[\($0.displaySpeakerLabel)] \($0.text)" }
                        .joined(separator: "\n")
                    transcriptCache[recording.id] = transcript
                    return transcript
                }
            }
        }

        if let structuredTranscriptTextFile = recording.assets.structuredTranscriptTextFile {
            let structuredTranscriptURL = sessionDirectory.appendingPathComponent(structuredTranscriptTextFile)
            if let transcript = try? String(contentsOf: structuredTranscriptURL, encoding: .utf8) {
                transcriptCache[recording.id] = transcript
                return transcript
            }
        }

        return nil
    }

    func summaryText(for recording: RecordingSession) -> String? {
        if let cachedSummary = summaryCache[recording.id] {
            return cachedSummary
        }

        guard let summaryFile = recording.assets.summaryFile,
              let sessionDirectory = try? sessionDirectory(for: recording.id) else {
            return nil
        }

        let summaryURL = sessionDirectory.appendingPathComponent(summaryFile)
        guard let summary = try? String(contentsOf: summaryURL, encoding: .utf8) else {
            return nil
        }

        summaryCache[recording.id] = summary
        return summary
    }

    func copyImportedAudio(from sourceURL: URL, to id: UUID) throws -> String {
        let sessionDirectory = try sessionDirectory(for: id)
        let preferredExtension = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let destinationFileName = "imported-audio.\(preferredExtension)"
        let destinationURL = sessionDirectory.appendingPathComponent(destinationFileName)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationFileName
    }

    func duplicateSessionContents(from sourceID: UUID, to destinationID: UUID) throws {
        let sourceDirectory = try sessionDirectory(for: sourceID)
        let destinationDirectory = try sessionDirectory(for: destinationID)
        let sourceURLs = try fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for sourceURL in sourceURLs {
            let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
    }

    func playableAudioURL(for recording: RecordingSession) throws -> URL? {
        guard let fileName = recording.playableAudioFileName else {
            return nil
        }

        let url = try sessionDirectory(for: recording.id).appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }
}

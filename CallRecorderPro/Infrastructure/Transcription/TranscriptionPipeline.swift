import Foundation

enum TranscriptionPipelineError: LocalizedError {
    case missingInputAudio
    case modelMissing
    case inferenceFailed(String)
    case unsupportedFormat
    case outputParseFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingInputAudio:
            return "No microphone, system, or imported audio is available for transcription."
        case .modelMissing:
            return "Required ASR model is not installed."
        case .inferenceFailed(let message):
            return "ASR inference failed: \(message)"
        case .unsupportedFormat:
            return "ASR input audio format is not supported."
        case .outputParseFailed:
            return "Failed to parse ASR engine output."
        case .cancelled:
            return "Transcription was cancelled."
        }
    }
}

struct TranscriptionResult {
    var transcriptFile: String?
    var srtFile: String?
    var transcriptJSONFile: String?
    var micASRJSONFile: String?
    var systemASRJSONFile: String?
    var systemDiarizationJSONFile: String?
    var state: TranscriptPipelineState
    var summary: String
}

struct TranscriptionPipeline {
    let asrEngine: ASREngine
    let diarizationService: SystemDiarizationService
    let speakerMappingService: SystemSpeakerMappingService
    let mergeService: TranscriptMergeService
    let renderService: TranscriptRenderService

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        asrEngine: ASREngine = WhisperCppEngine(),
        diarizationService: SystemDiarizationService = PlaceholderSystemDiarizationService(),
        speakerMappingService: SystemSpeakerMappingService = SystemSpeakerMappingService(),
        mergeService: TranscriptMergeService = TranscriptMergeService(),
        renderService: TranscriptRenderService = TranscriptRenderService()
    ) {
        self.asrEngine = asrEngine
        self.diarizationService = diarizationService
        self.speakerMappingService = speakerMappingService
        self.mergeService = mergeService
        self.renderService = renderService

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    var engineDisplayName: String {
        asrEngine.displayName
    }

    func process(
        recording: RecordingSession,
        in sessionDirectory: URL,
        modelResolution: RequiredModelsResolution
    ) async throws -> TranscriptionResult {
        let micURL = resolveAudioURL(fileName: recording.assets.microphoneFile, in: sessionDirectory)
        let systemURL = resolveAudioURL(fileName: recording.assets.systemAudioFile, in: sessionDirectory)
        let importedURL = resolveAudioURL(fileName: recording.assets.importedAudioFile, in: sessionDirectory)

        guard micURL != nil || systemURL != nil || importedURL != nil else {
            throw TranscriptionPipelineError.missingInputAudio
        }

        guard FileManager.default.fileExists(atPath: modelResolution.asrModelURL.path) else {
            throw TranscriptionPipelineError.modelMissing
        }

        let micASRFile = "mic.asr.json"
        let systemASRFile = "system.asr.json"
        let diarizationFile = "system.diarization.json"
        let transcriptJSONFile = "transcript.json"
        let transcriptTXTFile = "transcript.txt"
        let transcriptSRTFile = "transcript.srt"

        let micDoc = try await loadOrRunASR(
            existingFile: micASRFile,
            channel: .mic,
            preferredAudioURL: micURL ?? importedURL,
            sessionID: recording.id,
            sessionDirectory: sessionDirectory,
            configuration: ASREngineConfiguration(modelURL: modelResolution.asrModelURL)
        )

        let systemDoc = try await loadOrRunASR(
            existingFile: systemASRFile,
            channel: .system,
            preferredAudioURL: systemURL,
            sessionID: recording.id,
            sessionDirectory: sessionDirectory,
            configuration: ASREngineConfiguration(modelURL: modelResolution.asrModelURL)
        )

        let diarizationDoc = try await loadOrRunDiarization(
            existingFile: diarizationFile,
            systemAudioURL: systemURL,
            sessionID: recording.id,
            sessionDirectory: sessionDirectory,
            configuration: modelResolution.diarizationModelURL.map { DiarizationServiceConfiguration(modelURL: $0) }
        )

        let micSegments = (micDoc?.segments ?? []).map {
            TranscriptSegment(
                id: $0.id,
                channel: .mic,
                speaker: "You",
                startMs: $0.startMs,
                endMs: $0.endMs,
                text: $0.text,
                confidence: $0.confidence,
                language: $0.language,
                speakerConfidence: nil,
                words: $0.words
            )
        }

        let systemSegments = speakerMappingService.mapSystemSpeakers(
            asrSegments: systemDoc?.segments ?? [],
            diarization: diarizationDoc
        )

        let mergedSegments = mergeService.merge(micSegments: micSegments, systemSegments: systemSegments)
        let transcriptDocument = TranscriptDocument(
            version: 1,
            sessionID: recording.id,
            createdAt: Date(),
            channelsPresent: presentChannels(mic: micDoc, system: systemDoc),
            diarizationApplied: diarizationDoc != nil,
            mergePolicy: .deterministicStartEndChannelID,
            segments: mergedSegments
        )

        try writeJSON(transcriptDocument, to: sessionDirectory.appendingPathComponent(transcriptJSONFile))

        let rendered = renderService.render(document: transcriptDocument)
        try rendered.transcriptText.write(
            to: sessionDirectory.appendingPathComponent(transcriptTXTFile),
            atomically: true,
            encoding: .utf8
        )
        try rendered.srtText.write(
            to: sessionDirectory.appendingPathComponent(transcriptSRTFile),
            atomically: true,
            encoding: .utf8
        )

        let summary = diarizationDoc == nil && systemDoc != nil
            ? "Transcript ready. System diarization unavailable, speaker labels degraded to Remote."
            : "Transcript ready."

        return TranscriptionResult(
            transcriptFile: transcriptTXTFile,
            srtFile: transcriptSRTFile,
            transcriptJSONFile: transcriptJSONFile,
            micASRJSONFile: micDoc != nil ? micASRFile : nil,
            systemASRJSONFile: systemDoc != nil ? systemASRFile : nil,
            systemDiarizationJSONFile: diarizationDoc != nil ? diarizationFile : nil,
            state: .ready,
            summary: summary
        )
    }

    private func loadOrRunASR(
        existingFile: String,
        channel: TranscriptChannel,
        preferredAudioURL: URL?,
        sessionID: UUID,
        sessionDirectory: URL,
        configuration: ASREngineConfiguration
    ) async throws -> ASRDocument? {
        let destination = sessionDirectory.appendingPathComponent(existingFile)

        if let existing: ASRDocument = try readJSONIfExists(from: destination) {
            return existing
        }

        guard let preferredAudioURL else {
            return nil
        }

        do {
            let document = try await asrEngine.transcribe(
                audioURL: preferredAudioURL,
                channel: channel,
                sessionID: sessionID,
                configuration: configuration
            )

            guard !document.segments.isEmpty else {
                throw TranscriptionPipelineError.inferenceFailed("ASR returned empty segments")
            }

            try writeJSON(document, to: destination)
            return document
        } catch let error as WhisperCppError {
            switch error {
            case .modelMissing:
                throw TranscriptionPipelineError.modelMissing
            case .inferenceFailed(let message):
                throw TranscriptionPipelineError.inferenceFailed(message)
            case .unsupportedFormat:
                throw TranscriptionPipelineError.unsupportedFormat
            case .outputParseFailed:
                throw TranscriptionPipelineError.outputParseFailed
            case .cancelled:
                throw TranscriptionPipelineError.cancelled
            }
        }
    }

    private func loadOrRunDiarization(
        existingFile: String,
        systemAudioURL: URL?,
        sessionID: UUID,
        sessionDirectory: URL,
        configuration: DiarizationServiceConfiguration?
    ) async throws -> DiarizationDocument? {
        let destination = sessionDirectory.appendingPathComponent(existingFile)

        if let existing: DiarizationDocument = try readJSONIfExists(from: destination) {
            return existing
        }

        guard let systemAudioURL, let configuration else {
            return nil
        }

        do {
            let document = try await diarizationService.diarize(
                systemAudioURL: systemAudioURL,
                sessionID: sessionID,
                configuration: configuration
            )
            try writeJSON(document, to: destination)
            return document
        } catch {
            return nil
        }
    }

    private func presentChannels(mic: ASRDocument?, system: ASRDocument?) -> [TranscriptChannel] {
        var channels: [TranscriptChannel] = []
        if mic != nil { channels.append(.mic) }
        if system != nil { channels.append(.system) }
        return channels
    }

    private func resolveAudioURL(fileName: String?, in sessionDirectory: URL) -> URL? {
        guard let fileName else {
            return nil
        }

        let url = sessionDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func readJSONIfExists<T: Decodable>(from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try decoder.decode(T.self, from: data)
    }
}

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
    var diarizationApplied: Bool
    var diarizationDegradedReason: String?
    var diarizationModelUsed: String?
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
        diarizationService: SystemDiarizationService = CliSystemDiarizationService(),
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
        modelResolution: RequiredModelsResolution,
        onStateChange: (@MainActor (TranscriptPipelineState) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        await onStateChange?(.queued)
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
        let micASRModelFile = "mic.asr.model.txt"
        let systemASRModelFile = "system.asr.model.txt"
        let diarizationFile = "system.diarization.json"
        let transcriptJSONFile = "transcript.json"
        let transcriptTXTFile = "transcript.txt"
        let transcriptSRTFile = "transcript.srt"

        await onStateChange?(.transcribingMic)
        let micDoc = try await loadOrRunASR(
            existingFile: micASRFile,
            modelFingerprintFile: micASRModelFile,
            channel: .mic,
            preferredAudioURL: micURL ?? importedURL,
            sessionID: recording.id,
            sessionDirectory: sessionDirectory,
            configuration: ASREngineConfiguration(modelURL: modelResolution.asrModelURL)
        )

        await onStateChange?(.transcribingSystem)
        let systemDoc = try await loadOrRunASR(
            existingFile: systemASRFile,
            modelFingerprintFile: systemASRModelFile,
            channel: .system,
            preferredAudioURL: systemURL,
            sessionID: recording.id,
            sessionDirectory: sessionDirectory,
            configuration: ASREngineConfiguration(modelURL: modelResolution.asrModelURL)
        )

        await onStateChange?(.diarizingSystem)
        let diarizationOutcome = try await loadOrRunDiarization(
            existingFile: diarizationFile,
            systemAudioURL: systemURL,
            sessionID: recording.id,
            sessionDirectory: sessionDirectory,
            configuration: modelResolution.diarizationModelURL.map { DiarizationServiceConfiguration(modelURL: $0) }
        )
        let diarizationDoc = diarizationOutcome.document

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

        await onStateChange?(.merging)
        let mergedSegments = mergeService.merge(micSegments: micSegments, systemSegments: systemSegments)
        let transcriptDocument = TranscriptDocument(
            version: 1,
            sessionID: recording.id,
            createdAt: Date(),
            channelsPresent: presentChannels(mic: micDoc, system: systemDoc),
            diarizationApplied: diarizationOutcome.document != nil,
            mergePolicy: .deterministicStartEndChannelID,
            segments: mergedSegments
        )

        try writeJSON(transcriptDocument, to: sessionDirectory.appendingPathComponent(transcriptJSONFile))

        await onStateChange?(.renderingOutputs)
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

        let summary: String
        if let degradedReason = diarizationOutcome.degradedReason, systemDoc != nil {
            summary = "Transcript ready. System diarization degraded: \(degradedReason). Speaker labels fallback to Remote."
        } else {
            summary = "Transcript ready."
        }

        await onStateChange?(.ready)
        return TranscriptionResult(
            transcriptFile: transcriptTXTFile,
            srtFile: transcriptSRTFile,
            transcriptJSONFile: transcriptJSONFile,
            micASRJSONFile: micDoc != nil ? micASRFile : nil,
            systemASRJSONFile: systemDoc != nil ? systemASRFile : nil,
            systemDiarizationJSONFile: diarizationOutcome.document != nil ? diarizationFile : nil,
            diarizationApplied: diarizationOutcome.document != nil,
            diarizationDegradedReason: diarizationOutcome.degradedReason,
            diarizationModelUsed: diarizationOutcome.modelUsed,
            state: .ready,
            summary: summary
        )
    }

    private func loadOrRunASR(
        existingFile: String,
        modelFingerprintFile: String,
        channel: TranscriptChannel,
        preferredAudioURL: URL?,
        sessionID: UUID,
        sessionDirectory: URL,
        configuration: ASREngineConfiguration
    ) async throws -> ASRDocument? {
        let destination = sessionDirectory.appendingPathComponent(existingFile)
        let fingerprintURL = sessionDirectory.appendingPathComponent(modelFingerprintFile)
        let currentFingerprint = asrEngine.cacheFingerprint(configuration: configuration)
        let existing: ASRDocument? = try readJSONIfExists(from: destination)

        if let existing, let storedFingerprint = try readTextIfExists(from: fingerprintURL), storedFingerprint == currentFingerprint {
            return existing
        }

        guard let preferredAudioURL else {
            return existing
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
            try currentFingerprint.write(to: fingerprintURL, atomically: true, encoding: .utf8)
            return document
        } catch let error as WhisperCppError {
            switch error {
            case .modelMissing:
                throw TranscriptionPipelineError.modelMissing
            case .inferenceFailed(let message):
                if channel == .system, isSystemAudioUnavailableError(message) {
                    let emptyDocument = ASRDocument(
                        version: 1,
                        sessionID: sessionID,
                        channel: .system,
                        createdAt: Date(),
                        segments: []
                    )
                    try writeJSON(emptyDocument, to: destination)
                    try currentFingerprint.write(to: fingerprintURL, atomically: true, encoding: .utf8)
                    return emptyDocument
                }
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
    ) async throws -> DiarizationLoadOutcome {
        let destination = sessionDirectory.appendingPathComponent(existingFile)

        if let existing: DiarizationDocument = try readJSONIfExists(from: destination) {
            return DiarizationLoadOutcome(
                document: existing,
                degradedReason: nil,
                modelUsed: configuration?.modelURL.lastPathComponent
            )
        }

        guard let systemAudioURL else {
            return DiarizationLoadOutcome(document: nil, degradedReason: "system audio track missing", modelUsed: nil)
        }

        guard systemAudioURL.lastPathComponent == "system.raw.caf" else {
            return DiarizationLoadOutcome(document: nil, degradedReason: "unsupported system audio source", modelUsed: nil)
        }

        guard let configuration else {
            return DiarizationLoadOutcome(document: nil, degradedReason: "diarization model not selected", modelUsed: nil)
        }

        do {
            let document = try await diarizationService.diarize(
                systemAudioURL: systemAudioURL,
                sessionID: sessionID,
                configuration: configuration
            )
            try writeJSON(document, to: destination)
            return DiarizationLoadOutcome(
                document: document,
                degradedReason: nil,
                modelUsed: configuration.modelURL.lastPathComponent
            )
        } catch let error as DiarizationRuntimeError {
            return DiarizationLoadOutcome(
                document: nil,
                degradedReason: error.errorDescription ?? "runtime error",
                modelUsed: configuration.modelURL.lastPathComponent
            )
        } catch {
            return DiarizationLoadOutcome(
                document: nil,
                degradedReason: error.localizedDescription,
                modelUsed: configuration.modelURL.lastPathComponent
            )
        }
    }

    private struct DiarizationLoadOutcome {
        var document: DiarizationDocument?
        var degradedReason: String?
        var modelUsed: String?
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

    private func readTextIfExists(from url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isSystemAudioUnavailableError(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("failed to read the frames of the audio data")
            || normalized.contains("failed to read audio file")
            || normalized.contains("invalid argument")
    }

}

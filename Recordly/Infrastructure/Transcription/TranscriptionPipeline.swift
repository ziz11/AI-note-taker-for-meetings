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

enum PipelineDegradationReason: String, Codable, Equatable {
    case emptyMicASR
    case emptySystemASR
    case micASRFailedFallbackUsed
    case systemASRFailedFallbackUsed
    case diarizationDegraded
    case summaryFallbackUsed
    case mergeDegraded
    case captureSystemUnavailable
}

private enum ASROutcome {
    case success(ASRDocument?)
    case systemUnavailableRecovered(ASRDocument)
    case failure(Error)
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
    var degradedReasons: [PipelineDegradationReason]
    var state: TranscriptPipelineState
    var summary: String
}

struct TranscriptionPipeline {
    let audioInputAdapter: any AudioInputAdapter
    let speakerMappingService: SystemSpeakerMappingService
    let mergeService: TranscriptMergeService
    let renderService: TranscriptRenderService

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        audioInputAdapter: any AudioInputAdapter = PassthroughAudioInputAdapter(),
        speakerMappingService: SystemSpeakerMappingService = SystemSpeakerMappingService(),
        mergeService: TranscriptMergeService = TranscriptMergeService(),
        renderService: TranscriptRenderService = TranscriptRenderService()
    ) {
        self.audioInputAdapter = audioInputAdapter
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

    func process(
        recording: RecordingSession,
        in sessionDirectory: URL,
        runtimeProfile: InferenceRuntimeProfile,
        engineFactory: any InferenceEngineFactory,
        onStateChange: (@MainActor (TranscriptPipelineState) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        await onStateChange?(.queued)

        let micInput = try prepareInput(
            fileName: recording.assets.microphoneFile,
            channel: .mic,
            in: sessionDirectory
        )
        let systemInput = try prepareInput(
            fileName: recording.assets.systemAudioFile,
            channel: .system,
            in: sessionDirectory
        )
        let importedInput = try prepareImportedInput(
            fileName: recording.assets.importedAudioFile,
            in: sessionDirectory
        )

        guard micInput != nil || systemInput != nil || importedInput != nil else {
            throw TranscriptionPipelineError.missingInputAudio
        }

        guard let asrModelURL = runtimeProfile.modelArtifacts.asrModelURL,
              FileManager.default.fileExists(atPath: asrModelURL.path) else {
            throw TranscriptionPipelineError.modelMissing
        }

        let asrEngine = try engineFactory.makeASREngine(for: runtimeProfile)
        let asrConfiguration = ASREngineConfiguration(
            modelURL: asrModelURL
        )

        let micASRFile = "mic.asr.json"
        let systemASRFile = "system.asr.json"
        let micASRModelFile = "mic.asr.model.txt"
        let systemASRModelFile = "system.asr.model.txt"
        let diarizationFile = "system.diarization.json"
        let transcriptJSONFile = "transcript.json"
        let transcriptTXTFile = "transcript.txt"
        let transcriptSRTFile = "transcript.srt"

        var degradedReasons: [PipelineDegradationReason] = []

        await onStateChange?(.transcribingMic)
        let micASROutcome = await loadOrRunASR(
            asrEngine: asrEngine,
            existingFile: micASRFile,
            modelFingerprintFile: micASRModelFile,
            channel: .mic,
            preferredAudioURL: micInput?.url ?? importedInput?.url,
            sessionID: recording.id,
            sessionDirectory: sessionDirectory,
            configuration: asrConfiguration
        )

        await onStateChange?(.transcribingSystem)
        let systemASROutcome = await loadOrRunASR(
            asrEngine: asrEngine,
            existingFile: systemASRFile,
            modelFingerprintFile: systemASRModelFile,
            channel: .system,
            preferredAudioURL: systemInput?.url,
            sessionID: recording.id,
            sessionDirectory: sessionDirectory,
            configuration: asrConfiguration
        )

        let micDoc: ASRDocument?
        let systemDoc: ASRDocument?

        switch (micASROutcome, systemASROutcome) {
        case let (.success(mic), .success(sys)):
            micDoc = mic
            systemDoc = sys
            appendEmptyASRReason(for: mic, isMic: true, to: &degradedReasons)
            appendEmptyASRReason(for: sys, isMic: false, to: &degradedReasons)

        case let (.success(mic), .systemUnavailableRecovered(sys)):
            guard let mic else {
                throw TranscriptionPipelineError.inferenceFailed("System transcription recovered but microphone transcription unavailable.")
            }
            micDoc = mic
            systemDoc = sys
            degradedReasons.append(.systemASRFailedFallbackUsed)
            appendEmptyASRReason(for: mic, isMic: true, to: &degradedReasons)
            appendEmptyASRReason(for: sys, isMic: false, to: &degradedReasons)

        case let (.success(mic), .failure(sysError)):
            guard let mic else {
                throw sysError
            }
            micDoc = mic
            systemDoc = nil
            degradedReasons.append(.systemASRFailedFallbackUsed)
            appendEmptyASRReason(for: mic, isMic: true, to: &degradedReasons)

        case let (.failure(micError), .success(sys)):
            guard let sys else {
                throw micError
            }
            micDoc = nil
            systemDoc = sys
            degradedReasons.append(.micASRFailedFallbackUsed)
            appendEmptyASRReason(for: sys, isMic: false, to: &degradedReasons)

        case let (.failure(micError), .failure(_)):
            throw micError

        case let (.failure(micError), .systemUnavailableRecovered(_)):
            throw micError

        case (.systemUnavailableRecovered, _):
            throw TranscriptionPipelineError.inferenceFailed("Microphone ASR failed while loading.")
        }

        let diarizationEngine: (any DiarizationEngine)?
        let diarizationBackendError: String?
        do {
            diarizationEngine = try engineFactory.makeDiarizationEngine(for: runtimeProfile)
            diarizationBackendError = nil
        } catch {
            diarizationEngine = nil
            diarizationBackendError = error.localizedDescription
        }

        await onStateChange?(.diarizingSystem)
        let diarizationOutcome = try await loadOrRunDiarization(
            diarizationEngine: diarizationEngine,
            existingFile: diarizationFile,
            systemAudioURL: systemInput?.url,
            sessionID: recording.id,
            sessionDirectory: sessionDirectory,
            configuration: runtimeProfile.modelArtifacts.diarizationModelURL.map {
                DiarizationEngineConfiguration(modelURL: $0)
            },
            backendUnavailableReason: diarizationBackendError
        )
        let diarizationDoc = diarizationOutcome.document

        let micSegments = (micDoc?.segments ?? []).map {
            TranscriptSegment(
                id: $0.id,
                channel: .mic,
                speaker: "You",
                speakerRole: .me,
                speakerId: "me",
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
        if diarizationOutcome.degradedReason != nil {
            degradedReasons.append(.diarizationDegraded)
        }

        if let degradedReason = diarizationOutcome.degradedReason, systemDoc != nil {
            summary = "Transcript ready. System diarization degraded: \(degradedReason). Speaker labels fallback to Remote."
        } else if !degradedReasons.isEmpty {
            summary = "Transcript ready (degraded: \(degradedReasons.map(\.rawValue).joined(separator: ", ")))."
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
            degradedReasons: degradedReasons,
            state: .ready,
            summary: summary
        )
    }

    private func prepareInput(
        fileName: String?,
        channel: TranscriptChannel,
        in sessionDirectory: URL
    ) throws -> PreparedAudioInput? {
        guard let fileName else {
            return nil
        }
        return try audioInputAdapter.prepare(
            .sessionAsset(fileName: fileName, channel: channel),
            in: sessionDirectory
        )
    }

    private func prepareImportedInput(
        fileName: String?,
        in sessionDirectory: URL
    ) throws -> PreparedAudioInput? {
        guard let fileName else {
            return nil
        }
        return try audioInputAdapter.prepare(
            .sessionAsset(fileName: fileName, channel: .mic),
            in: sessionDirectory
        )
    }

    private func loadOrRunASR(
        asrEngine: any ASREngine,
        existingFile: String,
        modelFingerprintFile: String,
        channel: TranscriptChannel,
        preferredAudioURL: URL?,
        sessionID: UUID,
        sessionDirectory: URL,
        configuration: ASREngineConfiguration
    ) async -> ASROutcome {
        let destination = sessionDirectory.appendingPathComponent(existingFile)
        let fingerprintURL = sessionDirectory.appendingPathComponent(modelFingerprintFile)
        let currentFingerprint = asrEngine.cacheFingerprint(configuration: configuration)
        let existing: ASRDocument?
        let storedFingerprint: String?

        do {
            existing = try readJSONIfExists(from: destination)
            storedFingerprint = try readTextIfExists(from: fingerprintURL)
        } catch {
            return .failure(error)
        }

        if let existing, let storedFingerprint, storedFingerprint == currentFingerprint {
            return .success(existing)
        }

        guard let preferredAudioURL else {
            return .success(existing)
        }

        do {
            if channel == .system {
                let isZeroByte = try isZeroByteAudioFile(preferredAudioURL)
                if isZeroByte {
                return attemptSystemRecovery(
                    sessionID: sessionID,
                    channel: channel,
                    destination: destination,
                    modelFingerprintURL: fingerprintURL,
                    currentFingerprint: currentFingerprint
                )
                }
            }

            let document = try await asrEngine.transcribe(
                audioURL: preferredAudioURL,
                channel: channel,
                sessionID: sessionID,
                configuration: configuration
            )

            try writeJSON(document, to: destination)
            try currentFingerprint.write(to: fingerprintURL, atomically: true, encoding: .utf8)
            return .success(document)
        } catch let error as ASREngineRuntimeError {
            if let recovered = recoverableSystemASRFailure(
                error: error,
                channel: channel,
                sessionID: sessionID,
                destination: destination,
                modelFingerprintURL: fingerprintURL,
                currentFingerprint: currentFingerprint
            ) {
                return recovered
            }

            switch error {
            case .modelMissing:
                return .failure(TranscriptionPipelineError.modelMissing)
            case .inferenceFailed(let message):
                return .failure(TranscriptionPipelineError.inferenceFailed(message))
            case .unsupportedFormat:
                return .failure(TranscriptionPipelineError.unsupportedFormat)
            case .outputParseFailed:
                return .failure(TranscriptionPipelineError.outputParseFailed)
            case .cancelled:
                return .failure(TranscriptionPipelineError.cancelled)
            }
        } catch {
            return .failure(error)
        }
    }

    private func appendEmptyASRReason(for document: ASRDocument?, isMic: Bool, to reasons: inout [PipelineDegradationReason]) {
        if document?.segments.isEmpty == true {
            reasons.append(isMic ? .emptyMicASR : .emptySystemASR)
        }
    }

    private func attemptSystemRecovery(
        sessionID: UUID,
        channel: TranscriptChannel,
        destination: URL,
        modelFingerprintURL: URL,
        currentFingerprint: String
    ) -> ASROutcome {
        do {
            let document = try emitRecoveredSystemASR(
                sessionID: sessionID,
                channel: channel,
                destination: destination,
                modelFingerprintURL: modelFingerprintURL,
                currentFingerprint: currentFingerprint
            )
            return .systemUnavailableRecovered(document)
        } catch {
            return .failure(error)
        }
    }

    private func recoverableSystemASRFailure(
        error: ASREngineRuntimeError,
        channel: TranscriptChannel,
        sessionID: UUID,
        destination: URL,
        modelFingerprintURL: URL,
        currentFingerprint: String
    ) -> ASROutcome? {
        switch error {
        case .inferenceFailed(let message) where channel == .system && isRecoverableSystemInferenceFailure(message):
            return attemptSystemRecovery(
                sessionID: sessionID,
                channel: channel,
                destination: destination,
                modelFingerprintURL: modelFingerprintURL,
                currentFingerprint: currentFingerprint
            )
        case .unsupportedFormat where channel == .system:
            return attemptSystemRecovery(
                sessionID: sessionID,
                channel: channel,
                destination: destination,
                modelFingerprintURL: modelFingerprintURL,
                currentFingerprint: currentFingerprint
            )
        default:
            return nil
        }
    }

    private func loadOrRunDiarization(
        diarizationEngine: (any DiarizationEngine)?,
        existingFile: String,
        systemAudioURL: URL?,
        sessionID: UUID,
        sessionDirectory: URL,
        configuration: DiarizationEngineConfiguration?,
        backendUnavailableReason: String?
    ) async throws -> DiarizationLoadOutcome {
        let destination = sessionDirectory.appendingPathComponent(existingFile)

        if let existing: DiarizationDocument = try readJSONIfExists(from: destination) {
            return DiarizationLoadOutcome(
                document: existing,
                degradedReason: nil,
                modelUsed: configuration?.modelURL.lastPathComponent
            )
        }

        if let backendUnavailableReason {
            return DiarizationLoadOutcome(
                document: nil,
                degradedReason: "diarization backend unavailable (\(backendUnavailableReason))",
                modelUsed: configuration?.modelURL.lastPathComponent
            )
        }

        guard let systemAudioURL else {
            return DiarizationLoadOutcome(document: nil, degradedReason: "system audio track missing", modelUsed: nil)
        }

        guard ["system.raw.caf", "system.raw.flac"].contains(systemAudioURL.lastPathComponent) else {
            return DiarizationLoadOutcome(document: nil, degradedReason: "unsupported system audio source", modelUsed: nil)
        }

        guard let configuration else {
            return DiarizationLoadOutcome(document: nil, degradedReason: "diarization model not selected", modelUsed: nil)
        }

        guard let diarizationEngine else {
            return DiarizationLoadOutcome(document: nil, degradedReason: "diarization backend unavailable", modelUsed: nil)
        }

        do {
            let document = try await diarizationEngine.diarize(
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

    private func isRecoverableSystemInferenceFailure(_ message: String) -> Bool {
        if isSystemAudioUnavailableError(message) {
            return true
        }
        return message
            .lowercased()
            .contains("input audio format is not supported")
    }

    private func isZeroByteAudioFile(_ url: URL) throws -> Bool {
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
        return (resourceValues.fileSize ?? 0) == 0
    }

    private func emitRecoveredSystemASR(
        sessionID: UUID,
        channel: TranscriptChannel,
        destination: URL,
        modelFingerprintURL: URL,
        currentFingerprint: String
    ) throws -> ASRDocument {
        let emptyDocument = ASRDocument(
            version: 1,
            sessionID: sessionID,
            channel: channel,
            createdAt: Date(),
            segments: []
        )
        try writeJSON(emptyDocument, to: destination)
        try currentFingerprint.write(to: modelFingerprintURL, atomically: true, encoding: .utf8)
        return emptyDocument
    }
}

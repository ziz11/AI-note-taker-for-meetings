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
    var structuredTranscriptJSONFile: String?
    var structuredTranscriptTextFile: String?
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

enum SystemTranscriptionMode: Sendable {
    case diarizationChunked
    case legacyFullFileDebug
}

struct TranscriptionPipeline {
    let mode: SystemTranscriptionMode
    let audioInputAdapter: any AudioInputAdapter
    let alignmentService: SystemTranscriptAlignmentService
    let systemChunkTranscriptBuilder: SystemChunkTranscriptBuilder
    let mergeService: TranscriptMergeService
    let renderService: TranscriptRenderService

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        mode: SystemTranscriptionMode = .diarizationChunked,
        audioInputAdapter: any AudioInputAdapter = PassthroughAudioInputAdapter(),
        alignmentService: SystemTranscriptAlignmentService = SystemTranscriptAlignmentService(),
        systemChunkTranscriptBuilder: SystemChunkTranscriptBuilder = SystemChunkTranscriptBuilder(),
        mergeService: TranscriptMergeService = TranscriptMergeService(),
        renderService: TranscriptRenderService = TranscriptRenderService()
    ) {
        self.mode = mode
        self.audioInputAdapter = audioInputAdapter
        self.alignmentService = alignmentService
        self.systemChunkTranscriptBuilder = systemChunkTranscriptBuilder
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
        let asrConfiguration = ASREngineConfiguration(modelURL: asrModelURL)

        let micASRFile = "mic.asr.json"
        let systemASRFile = "system.asr.json"
        let diarizationFile = "system.diarization.json"
        let transcriptJSONFile = "transcript.json"
        let transcriptTXTFile = "transcript.txt"
        let transcriptSRTFile = "transcript.srt"

        var degradedReasons: [PipelineDegradationReason] = []

        let micAudioURL = micInput?.url ?? importedInput?.url
        let micDoc: ASRDocument?
        if let micAudioURL {
            await onStateChange?(.transcribingMic)
            let document = try await runMainPathASR(
                asrEngine: asrEngine,
                audioURL: micAudioURL,
                channel: .mic,
                sessionID: recording.id,
                configuration: asrConfiguration
            )
            try writeJSON(document, to: sessionDirectory.appendingPathComponent(micASRFile))
            if document.segments.isEmpty {
                degradedReasons.append(.emptyMicASR)
            }
            micDoc = document
        } else {
            micDoc = nil
        }

        let diarizationOutcome: DiarizationLoadOutcome
        if systemInput != nil {
            await onStateChange?(.diarizingSystem)
            diarizationOutcome = try await loadOrRunDiarization(
                diarizationEngine: await resolveDiarizationEngine(
                    engineFactory: engineFactory,
                    runtimeProfile: runtimeProfile
                ),
                existingFile: diarizationFile,
                systemAudioURL: systemInput?.url,
                sessionID: recording.id,
                sessionDirectory: sessionDirectory,
                configuration: DiarizationEngineConfiguration(
                    modelURL: runtimeProfile.modelArtifacts.diarizationModelURL
                )
            )
            if diarizationOutcome.degradedReason != nil {
                degradedReasons.append(.diarizationDegraded)
            }
        } else {
            diarizationOutcome = DiarizationLoadOutcome(document: nil, degradedReason: nil, modelUsed: nil)
        }

        let systemOutcome = try await processSystemAudio(
            systemInput: systemInput,
            recordingID: recording.id,
            sessionDirectory: sessionDirectory,
            runtimeProfile: runtimeProfile,
            engineFactory: engineFactory,
            asrEngine: asrEngine,
            asrConfiguration: asrConfiguration,
            existingASRFile: systemASRFile,
            diarizationOutcome: diarizationOutcome,
            onStateChange: onStateChange,
            allowMicOnlyDegradation: micDoc != nil
        )
        if let degradationReason = systemOutcome.degradationReason {
            degradedReasons.append(degradationReason)
        }
        if let systemDoc = systemOutcome.document, systemDoc.segments.isEmpty {
            degradedReasons.append(.emptySystemASR)
        }

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

        let systemSegments = systemOutcome.transcriptSegments

        await onStateChange?(.merging)
        let mergedSegments = mergeService.merge(micSegments: micSegments, systemSegments: systemSegments)
        let transcriptDocument = TranscriptDocument(
            version: 1,
            sessionID: recording.id,
            createdAt: Date(),
            channelsPresent: presentChannels(mic: micDoc, system: systemOutcome.document),
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

        await onStateChange?(.ready)
        return TranscriptionResult(
            transcriptFile: transcriptTXTFile,
            srtFile: transcriptSRTFile,
            transcriptJSONFile: transcriptJSONFile,
            structuredTranscriptJSONFile: nil,
            structuredTranscriptTextFile: nil,
            micASRJSONFile: micDoc != nil ? micASRFile : nil,
            systemASRJSONFile: systemOutcome.document != nil ? systemASRFile : nil,
            systemDiarizationJSONFile: diarizationOutcome.document != nil ? diarizationFile : nil,
            diarizationApplied: diarizationOutcome.document != nil,
            diarizationDegradedReason: diarizationOutcome.degradedReason,
            diarizationModelUsed: diarizationOutcome.modelUsed,
            degradedReasons: degradedReasons,
            state: .ready,
            summary: makeReadySummary(
                diarizationDegradedReason: diarizationOutcome.degradedReason,
                degradedReasons: degradedReasons
            )
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

    private func runMainPathASR(
        asrEngine: any ASREngine,
        audioURL: URL,
        channel: TranscriptChannel,
        sessionID: UUID,
        configuration: ASREngineConfiguration
    ) async throws -> ASRDocument {
        do {
            return try await asrEngine.transcribe(
                audioURL: audioURL,
                channel: channel,
                sessionID: sessionID,
                configuration: configuration
            )
        } catch let error as ASREngineRuntimeError {
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

    private func resolveDiarizationEngine(
        engineFactory: any InferenceEngineFactory,
        runtimeProfile: InferenceRuntimeProfile
    ) async -> (engine: (any DiarizationEngine)?, backendUnavailableReason: String?) {
        do {
            let engine = try await MainActor.run {
                try engineFactory.makeDiarizationEngine(for: runtimeProfile)
            }
            return (engine, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func resolveSystemChunkEngine(
        engineFactory: any InferenceEngineFactory,
        runtimeProfile: InferenceRuntimeProfile
    ) -> (engine: (any SystemChunkTranscriptionEngine)?, backendUnavailableReason: String?) {
        do {
            let engine = try engineFactory.makeSystemChunkTranscriptionEngine(for: runtimeProfile)
            return (engine, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func processSystemAudio(
        systemInput: PreparedAudioInput?,
        recordingID: UUID,
        sessionDirectory: URL,
        runtimeProfile: InferenceRuntimeProfile,
        engineFactory: any InferenceEngineFactory,
        asrEngine: any ASREngine,
        asrConfiguration: ASREngineConfiguration,
        existingASRFile: String,
        diarizationOutcome: DiarizationLoadOutcome,
        onStateChange: (@MainActor (TranscriptPipelineState) -> Void)?,
        allowMicOnlyDegradation: Bool
    ) async throws -> SystemTranscriptionOutcome {
        guard let systemAudioURL = systemInput?.url else {
            return SystemTranscriptionOutcome(document: nil, transcriptSegments: [], degradationReason: nil)
        }

        await onStateChange?(.transcribingSystem)

        switch mode {
        case .legacyFullFileDebug:
            return try await processLegacySystemAudio(
                systemAudioURL: systemAudioURL,
                sessionID: recordingID,
                sessionDirectory: sessionDirectory,
                asrEngine: asrEngine,
                asrConfiguration: asrConfiguration,
                existingASRFile: existingASRFile,
                diarization: diarizationOutcome.document,
                allowMicOnlyDegradation: allowMicOnlyDegradation
            )
        case .diarizationChunked:
            return try await processChunkedSystemAudio(
                systemAudioURL: systemAudioURL,
                sessionID: recordingID,
                sessionDirectory: sessionDirectory,
                runtimeProfile: runtimeProfile,
                engineFactory: engineFactory,
                asrConfiguration: asrConfiguration,
                existingASRFile: existingASRFile,
                diarizationOutcome: diarizationOutcome,
                allowMicOnlyDegradation: allowMicOnlyDegradation
            )
        }
    }

    private func processLegacySystemAudio(
        systemAudioURL: URL,
        sessionID: UUID,
        sessionDirectory: URL,
        asrEngine: any ASREngine,
        asrConfiguration: ASREngineConfiguration,
        existingASRFile: String,
        diarization: DiarizationDocument?,
        allowMicOnlyDegradation: Bool
    ) async throws -> SystemTranscriptionOutcome {
        do {
            let document = try await runMainPathASR(
                asrEngine: asrEngine,
                audioURL: systemAudioURL,
                channel: .system,
                sessionID: sessionID,
                configuration: asrConfiguration
            )
            try writeJSON(document, to: sessionDirectory.appendingPathComponent(existingASRFile))
            return SystemTranscriptionOutcome(
                document: document,
                transcriptSegments: alignmentService.align(asrSegments: document.segments, diarization: diarization),
                degradationReason: nil
            )
        } catch {
            guard allowMicOnlyDegradation else {
                throw error
            }
            return SystemTranscriptionOutcome(
                document: nil,
                transcriptSegments: [],
                degradationReason: .systemASRFailedFallbackUsed
            )
        }
    }

    private func processChunkedSystemAudio(
        systemAudioURL: URL,
        sessionID: UUID,
        sessionDirectory: URL,
        runtimeProfile: InferenceRuntimeProfile,
        engineFactory: any InferenceEngineFactory,
        asrConfiguration: ASREngineConfiguration,
        existingASRFile: String,
        diarizationOutcome: DiarizationLoadOutcome,
        allowMicOnlyDegradation: Bool
    ) async throws -> SystemTranscriptionOutcome {
        guard let diarization = diarizationOutcome.document else {
            if allowMicOnlyDegradation {
                return SystemTranscriptionOutcome(document: nil, transcriptSegments: [], degradationReason: nil)
            }
            throw TranscriptionPipelineError.inferenceFailed(
                diarizationOutcome.degradedReason ?? "system diarization is required for chunked system transcription"
            )
        }

        guard !diarization.segments.isEmpty else {
            if allowMicOnlyDegradation {
                return SystemTranscriptionOutcome(document: nil, transcriptSegments: [], degradationReason: .emptySystemASR)
            }
            throw TranscriptionPipelineError.inferenceFailed("system diarization produced no segments")
        }

        let chunkEngineOutcome = resolveSystemChunkEngine(
            engineFactory: engineFactory,
            runtimeProfile: runtimeProfile
        )
        guard let chunkEngine = chunkEngineOutcome.engine else {
            if allowMicOnlyDegradation {
                return SystemTranscriptionOutcome(
                    document: nil,
                    transcriptSegments: [],
                    degradationReason: .systemASRFailedFallbackUsed
                )
            }
            throw TranscriptionPipelineError.inferenceFailed(
                chunkEngineOutcome.backendUnavailableReason ?? "system chunk transcription backend unavailable"
            )
        }

        do {
            let chunkDocument = try await chunkEngine.transcribeSystemChunks(
                systemAudioURL: systemAudioURL,
                diarization: diarization,
                sessionID: sessionID,
                configuration: asrConfiguration
            )
            let asrDocument = ASRDocument(
                version: 1,
                sessionID: sessionID,
                channel: .system,
                createdAt: chunkDocument.createdAt,
                segments: chunkDocument.segments.map {
                    ASRSegment(
                        id: $0.id,
                        startMs: $0.startMs,
                        endMs: $0.endMs,
                        text: $0.text,
                        confidence: $0.confidence,
                        language: $0.language,
                        words: $0.words
                    )
                }
            )
            try writeJSON(asrDocument, to: sessionDirectory.appendingPathComponent(existingASRFile))
            return SystemTranscriptionOutcome(
                document: asrDocument,
                transcriptSegments: systemChunkTranscriptBuilder.build(from: chunkDocument),
                degradationReason: nil
            )
        } catch let error as ASREngineRuntimeError {
            guard allowMicOnlyDegradation else {
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
            return SystemTranscriptionOutcome(
                document: nil,
                transcriptSegments: [],
                degradationReason: .systemASRFailedFallbackUsed
            )
        } catch let error as TranscriptionPipelineError {
            guard allowMicOnlyDegradation else {
                throw error
            }
            return SystemTranscriptionOutcome(
                document: nil,
                transcriptSegments: [],
                degradationReason: .systemASRFailedFallbackUsed
            )
        } catch {
            guard allowMicOnlyDegradation else {
                throw error
            }
            return SystemTranscriptionOutcome(
                document: nil,
                transcriptSegments: [],
                degradationReason: .systemASRFailedFallbackUsed
            )
        }
    }

    private func loadOrRunDiarization(
        diarizationEngine: (engine: (any DiarizationEngine)?, backendUnavailableReason: String?),
        existingFile: String,
        systemAudioURL: URL?,
        sessionID: UUID,
        sessionDirectory: URL,
        configuration: DiarizationEngineConfiguration
    ) async throws -> DiarizationLoadOutcome {
        let destination = sessionDirectory.appendingPathComponent(existingFile)
        let modelUsed = configuration.modelURL?.lastPathComponent ?? "sdk-managed"

        if let existing: DiarizationDocument = try readJSONIfExists(from: destination) {
            return DiarizationLoadOutcome(document: existing, degradedReason: nil, modelUsed: modelUsed)
        }

        if let backendUnavailableReason = diarizationEngine.backendUnavailableReason {
            return DiarizationLoadOutcome(
                document: nil,
                degradedReason: "diarization backend unavailable (\(backendUnavailableReason))",
                modelUsed: modelUsed
            )
        }

        guard let systemAudioURL else {
            return DiarizationLoadOutcome(document: nil, degradedReason: nil, modelUsed: nil)
        }

        guard ["system.raw.caf", "system.raw.flac"].contains(systemAudioURL.lastPathComponent) else {
            return DiarizationLoadOutcome(document: nil, degradedReason: "unsupported system audio source", modelUsed: nil)
        }

        guard let engine = diarizationEngine.engine else {
            return DiarizationLoadOutcome(document: nil, degradedReason: "diarization backend unavailable", modelUsed: nil)
        }

        do {
            let document = try await engine.diarize(
                systemAudioURL: systemAudioURL,
                sessionID: sessionID,
                configuration: configuration
            )
            try writeJSON(document, to: destination)
            return DiarizationLoadOutcome(document: document, degradedReason: nil, modelUsed: modelUsed)
        } catch let error as DiarizationRuntimeError {
            return DiarizationLoadOutcome(
                document: nil,
                degradedReason: error.errorDescription ?? "runtime error",
                modelUsed: modelUsed
            )
        } catch {
            return DiarizationLoadOutcome(
                document: nil,
                degradedReason: error.localizedDescription,
                modelUsed: modelUsed
            )
        }
    }

    private struct DiarizationLoadOutcome {
        var document: DiarizationDocument?
        var degradedReason: String?
        var modelUsed: String?
    }

    private struct SystemTranscriptionOutcome {
        var document: ASRDocument?
        var transcriptSegments: [TranscriptSegment]
        var degradationReason: PipelineDegradationReason?
    }

    private func makeReadySummary(
        diarizationDegradedReason: String?,
        degradedReasons: [PipelineDegradationReason]
    ) -> String {
        if let diarizationDegradedReason {
            return "Transcript ready. System diarization degraded: \(diarizationDegradedReason)."
        }
        if !degradedReasons.isEmpty {
            return "Transcript ready (degraded: \(degradedReasons.map(\.rawValue).joined(separator: ", ")))."
        }
        return "Transcript ready."
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

    // Legacy compatibility/debug path. Keep isolated and out of the default flow.
    private var legacyCompatPath: LegacyCompatPath {
        LegacyCompatPath(encoder: encoder, decoder: decoder)
    }
}

private struct LegacyCompatPath {
    let encoder: JSONEncoder
    let decoder: JSONDecoder

    func loadOrRunASR(
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

    private func isRecoverableSystemInferenceFailure(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("failed to read the frames of the audio data")
            || normalized.contains("failed to read audio file")
            || normalized.contains("invalid argument")
            || normalized.contains("input audio format is not supported")
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

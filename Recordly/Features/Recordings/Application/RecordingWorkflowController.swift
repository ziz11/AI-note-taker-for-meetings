import AVFoundation
import Foundation

enum RecordingWorkflowError: LocalizedError {
    case missingTranscript
    case transcriptionUnavailable(TranscriptionAvailability)

    var errorDescription: String? {
        switch self {
        case .missingTranscript:
            return "No transcript is available for this recording yet."
        case let .transcriptionUnavailable(availability):
            switch availability {
            case .requiresASRModel:
                return "Required ASR model is not installed."
            case .degradedNoDiarization:
                return "Transcription can run, but diarization package is missing."
            case let .unavailable(reason):
                return reason
            case .ready:
                return nil
            }
        }
    }
}

struct RecordingStartResult {
    var recording: RecordingSession
    var systemAudioLabel: String
}

struct RecordingCompletionResult {
    var recording: RecordingSession
    var transcriptionResult: TranscriptionResult?
    var systemAudioLabel: String
    var processingError: Error?
}

struct ImportedRecordingResult {
    var recording: RecordingSession
    var transcriptionResult: TranscriptionResult?
    var processingError: Error?
}

@MainActor
final class RecordingWorkflowController {
    private let audioCaptureEngine: any AudioCaptureEngine
    private let transcriptionPipeline: TranscriptionPipeline
    private let runtimeProfileSelector: any InferenceRuntimeProfileSelecting
    private let inferenceEngineFactory: any InferenceEngineFactory
    private let repository: RecordingsPersistence
    private let summarizationTimeoutSeconds: UInt64
    var selectedModelProfile: ModelProfile

    init(
        audioCaptureEngine: any AudioCaptureEngine,
        transcriptionPipeline: TranscriptionPipeline,
        runtimeProfileSelector: any InferenceRuntimeProfileSelecting,
        inferenceEngineFactory: any InferenceEngineFactory,
        repository: RecordingsPersistence,
        selectedModelProfile: ModelProfile = .balanced,
        summarizationTimeoutSeconds: UInt64 = 180
    ) {
        self.audioCaptureEngine = audioCaptureEngine
        self.transcriptionPipeline = transcriptionPipeline
        self.runtimeProfileSelector = runtimeProfileSelector
        self.inferenceEngineFactory = inferenceEngineFactory
        self.repository = repository
        self.selectedModelProfile = selectedModelProfile
        self.summarizationTimeoutSeconds = max(1, summarizationTimeoutSeconds)
    }

    var currentSystemAudioStatusLabel: String {
        audioCaptureEngine.systemAudioStatusLabel
    }

    func recordingsDirectoryPath() throws -> String {
        try repository.recordingsDirectoryPath()
    }

    func loadRecordings() throws -> [RecordingSession] {
        try repository.loadRecordings()
    }

    func transcriptText(for recording: RecordingSession) -> String? {
        repository.transcriptText(for: recording)
    }

    func summaryText(for recording: RecordingSession) -> String? {
        repository.summaryText(for: recording)
    }

    func save(_ recording: RecordingSession) throws {
        try repository.save(recording)
    }

    func duplicateSessionContents(from sourceID: UUID, to destinationID: UUID) throws {
        try repository.duplicateSessionContents(from: sourceID, to: destinationID)
    }

    func delete(id: UUID) throws {
        try repository.delete(id: id)
    }

    func sessionDirectory(for id: UUID) throws -> URL {
        try repository.sessionDirectory(for: id)
    }

    func playableAudioURL(for recording: RecordingSession) throws -> URL? {
        try repository.playableAudioURL(for: recording)
    }

    func createDraftRecording(index: Int) throws -> RecordingSession {
        var recording = RecordingSession.draft(index: index)
        recording.notes = "Waiting for audio."
        try repository.save(recording)
        return recording
    }

    func startCapture(for recording: RecordingSession) async throws -> RecordingStartResult {
        let sessionDirectory = try repository.sessionDirectory(for: recording.id)
        let captureArtifacts = try await audioCaptureEngine.startCapture(in: sessionDirectory)

        var updatedRecording = recording
        updatedRecording.assets.microphoneFile = captureArtifacts.microphoneFile
        updatedRecording.assets.systemAudioFile = captureArtifacts.systemAudioFile
        updatedRecording.assets.connectorNotesFile = captureArtifacts.connectorNotesFile
        updatedRecording.notes = captureArtifacts.note ?? "Recording in progress."
        try repository.save(updatedRecording)

        return RecordingStartResult(
            recording: updatedRecording,
            systemAudioLabel: audioCaptureEngine.systemAudioStatusLabel
        )
    }

    func failRecording(id: UUID) {
        try? repository.delete(id: id)
    }

    func completeCapture(
        for recording: RecordingSession,
        duration: TimeInterval,
        runTranscription: Bool,
        onTranscriptionStateChange: (@MainActor (TranscriptPipelineState) -> Void)? = nil
    ) async throws -> RecordingCompletionResult {
        let captureArtifacts: CaptureArtifacts
        do {
            captureArtifacts = try await audioCaptureEngine.stopCapture()
        } catch {
            var failedRecording = recording
            failedRecording.duration = duration
            failedRecording.lifecycleState = .failed
            failedRecording.transcriptState = .failed
            failedRecording.notes = "Capture finalization failed: \(error.localizedDescription)"
            try? repository.save(failedRecording)
            return RecordingCompletionResult(
                recording: failedRecording,
                transcriptionResult: nil,
                systemAudioLabel: audioCaptureEngine.systemAudioStatusLabel,
                processingError: error
            )
        }

        var updatedRecording = recording
        updatedRecording.duration = duration
        updatedRecording.lifecycleState = runTranscription ? .processing : .ready
        updatedRecording.transcriptState = runTranscription ? .queued : .idle
        updatedRecording.assets.microphoneFile = captureArtifacts.microphoneFile ?? updatedRecording.assets.microphoneFile
        updatedRecording.assets.systemAudioFile = captureArtifacts.systemAudioFile ?? updatedRecording.assets.systemAudioFile
        updatedRecording.assets.mergedCallFile = captureArtifacts.mergedCallFile
        updatedRecording.assets.connectorNotesFile = captureArtifacts.connectorNotesFile ?? updatedRecording.assets.connectorNotesFile
        updatedRecording.notes = runTranscription ? "Audio saved. Preparing transcript." : "Audio saved."
        try repository.save(updatedRecording)

        var transcriptionResult: TranscriptionResult?
        let processingError: Error?
        if runTranscription {
            do {
                transcriptionResult = try await performTranscription(
                    for: updatedRecording,
                    onStateChange: onTranscriptionStateChange
                )
                if let transcriptionResult {
                    updatedRecording = applyTranscriptionResult(transcriptionResult, to: updatedRecording)
                    try repository.save(updatedRecording)
                }
                processingError = nil
            } catch {
                updatedRecording.transcriptState = .failed
                updatedRecording.lifecycleState = .failed
                updatedRecording.notes = "Transcript failed."
                try? repository.save(updatedRecording)
                transcriptionResult = nil
                processingError = error
            }
        } else {
            transcriptionResult = nil
            processingError = nil
        }

        return RecordingCompletionResult(
            recording: updatedRecording,
            transcriptionResult: transcriptionResult,
            systemAudioLabel: captureArtifacts.systemAudioFile != nil ? "Captured" : audioCaptureEngine.systemAudioStatusLabel,
            processingError: processingError
        )
    }

    func importAudio(
        from sourceURL: URL,
        autoTranscribe: Bool,
        onTranscriptionStateChange: (@MainActor (TranscriptPipelineState) -> Void)? = nil
    ) async throws -> ImportedRecordingResult {
        var recording = RecordingSession(
            id: UUID(),
            title: sourceURL.deletingPathExtension().lastPathComponent,
            createdAt: Date(),
            duration: try await duration(for: sourceURL),
            lifecycleState: autoTranscribe ? .processing : .ready,
            transcriptState: autoTranscribe ? .queued : .idle,
            source: .importedAudio,
            notes: autoTranscribe ? "Imported audio. Preparing transcript." : "Imported audio. Ready to transcribe.",
            assets: RecordingAssets()
        )

        recording.assets.importedAudioFile = try repository.copyImportedAudio(from: sourceURL, to: recording.id)
        try repository.save(recording)

        var transcriptionResult: TranscriptionResult?
        var processingError: Error?
        if autoTranscribe {
            do {
                transcriptionResult = try await performTranscription(
                    for: recording,
                    onStateChange: onTranscriptionStateChange
                )
                if let transcriptionResult {
                    recording = applyTranscriptionResult(transcriptionResult, to: recording)
                    try repository.save(recording)
                }
                processingError = nil
            } catch {
                recording.transcriptState = .failed
                recording.lifecycleState = .failed
                recording.notes = "Transcript failed."
                try? repository.save(recording)
                processingError = error
            }
        } else {
            processingError = nil
        }

        return ImportedRecordingResult(
            recording: recording,
            transcriptionResult: transcriptionResult,
            processingError: processingError
        )
    }

    func transcribe(
        recording: RecordingSession,
        onStateChange: (@MainActor (TranscriptPipelineState) -> Void)? = nil
    ) async throws -> RecordingSession {
        var updatedRecording = recording
        updatedRecording.lifecycleState = .processing
        updatedRecording.transcriptState = .queued
        updatedRecording.notes = "Preparing transcript."
        try repository.save(updatedRecording)

        do {
            let transcriptionResult = try await performTranscription(
                for: updatedRecording,
                onStateChange: onStateChange
            )
            updatedRecording = applyTranscriptionResult(transcriptionResult, to: updatedRecording)
            try repository.save(updatedRecording)
            return updatedRecording
        } catch {
            updatedRecording.transcriptState = .failed
            updatedRecording.lifecycleState = .failed
            updatedRecording.notes = "Transcript failed."
            try? repository.save(updatedRecording)
            throw error
        }
    }

    func summarize(
        recording: RecordingSession,
        onProgress: (@MainActor (Double, String) -> Void)? = nil
    ) async throws -> RecordingSession {
        let sessionDirectory = try repository.sessionDirectory(for: recording.id)
        onProgress?(0.1, "Preparing summary")
        let summarizationStartedAt = Date()
        var logLines: [String] = []
        logLines.append("started_at=\(iso8601Timestamp(summarizationStartedAt))")
        logLines.append("recording_id=\(recording.id.uuidString)")
        logLines.append("recording_title=\(recording.title)")

        let transcript = repository.transcriptText(for: recording)
        logLines.append("transcript_chars=\(transcript?.count ?? 0)")
        let srtText: String?
        if let srtFile = recording.assets.srtFile {
            let srtURL = sessionDirectory.appendingPathComponent(srtFile)
            srtText = try? String(contentsOf: srtURL, encoding: .utf8)
            logLines.append("srt_file=\(srtFile)")
        } else {
            srtText = nil
            logLines.append("srt_file=<none>")
        }
        logLines.append("srt_chars=\(srtText?.count ?? 0)")

        guard transcript != nil || srtText != nil else {
            logLines.append("result=failed")
            logLines.append("reason=missing-transcript-and-srt")
            persistSummarizationLog(lines: logLines, in: sessionDirectory)
            throw RecordingWorkflowError.missingTranscript
        }

        var summary: String?
        var summarySource = "fallback"
        let summarizationProfile: InferenceRuntimeProfile?
        do {
            summarizationProfile = try runtimeProfileSelector.resolveSummarizationProfile(for: selectedModelProfile)
        } catch {
            summarizationProfile = nil
        }

        if let summarizationProfile,
           let modelURL = summarizationProfile.modelArtifacts.summarizationModelURL {
            do {
                let summarizationEngine = try inferenceEngineFactory.makeSummarizationEngine(for: summarizationProfile)
                onProgress?(0.6, "Generating summary")
                logLines.append("llm_engine=enabled")
                logLines.append("model_id=\(modelURL.path)")
                logLines.append("model_path=\(modelURL.path)")
                let runtimeSettings = summarizationProfile.summarizationRuntimeSettings
                logLines.append("ctx_size=\(runtimeSettings.contextSize)")
                logLines.append("temperature=\(runtimeSettings.temperature)")
                logLines.append("top_p=\(runtimeSettings.topP)")
                logLines.append("timeout_seconds=\(summarizationTimeoutSeconds)")
                let config = SummarizationConfiguration(
                    modelURL: modelURL,
                    runtime: runtimeSettings
                )
                let doc = try await summarizeWithTimeout(timeoutSeconds: summarizationTimeoutSeconds) {
                    try await summarizationEngine.summarize(
                        transcript: transcript ?? "",
                        srtText: srtText,
                        recordingTitle: recording.title,
                        configuration: config
                    )
                }
                summary = doc.rawMarkdown
                summarySource = "llm"
                logLines.append("llm_status=success")
                logLines.append("summary_chars=\(doc.rawMarkdown.count)")
            } catch {
                logLines.append("llm_status=failed")
                logLines.append("llm_error=\(summarizationErrorDescription(error))")
                if let summarizationError = error as? SummarizationError {
                    switch summarizationError {
                    case .cancelled:
                        onProgress?(0.7, "Summary model timed out. Switching to fallback")
                    default:
                        onProgress?(0.7, "Summary model failed. Switching to fallback")
                    }
                } else {
                    onProgress?(0.7, "Summary model failed. Switching to fallback")
                }
            }
        } else {
            logLines.append("llm_engine=disabled")
            logLines.append("llm_reason=model-not-selected")
        }

        if summary == nil {
            onProgress?(0.75, "Building fallback summary")
            summary = composeSummary(recording: recording, transcript: transcript, srtText: srtText)
            summarySource = "fallback"
            logLines.append("fallback_status=used")
            logLines.append("summary_chars=\(summary?.count ?? 0)")
        }

        onProgress?(0.92, "Saving summary")
        let summaryFile = "summary.md"
        let summaryURL = sessionDirectory.appendingPathComponent(summaryFile)
        try summary!.write(to: summaryURL, atomically: true, encoding: .utf8)
        logLines.append("summary_file=\(summaryFile)")
        logLines.append("summary_source=\(summarySource)")
        logLines.append("result=success")
        logLines.append("finished_at=\(iso8601Timestamp(Date()))")
        persistSummarizationLog(lines: logLines, in: sessionDirectory)

        var updatedRecording = recording
        updatedRecording.assets.summaryFile = summaryFile
        updatedRecording.notes = "Summary is ready."
        try repository.save(updatedRecording)
        onProgress?(1, "Summary ready")
        return updatedRecording
    }

    func microphoneLevel() -> Double {
        audioCaptureEngine.currentMicrophoneLevel()
    }

    func systemAudioLevel() -> Double {
        audioCaptureEngine.currentSystemAudioLevel()
    }

    func recoverPendingMerges() async {
        guard let recordingsDirectory = try? AppPaths.recordingsDirectory() else {
            return
        }

        await audioCaptureEngine.recoverPendingSessions(in: recordingsDirectory)

        guard var recordings = try? repository.loadRecordings() else {
            return
        }

        for index in recordings.indices {
            let id = recordings[index].id
            guard let sessionDirectory = try? repository.sessionDirectory(for: id) else {
                continue
            }

            let mergedM4A = sessionDirectory.appendingPathComponent("merged-call.m4a")

            if FileManager.default.fileExists(atPath: mergedM4A.path) {
                recordings[index].assets.mergedCallFile = "merged-call.m4a"
                if recordings[index].lifecycleState != .failed {
                    recordings[index].lifecycleState = .ready
                }
                recordings[index].notes = "Offline merge completed."
                try? repository.save(recordings[index])
            }
        }
    }

    func recoverPendingTranscriptions() async {
        guard var recordings = try? repository.loadRecordings() else {
            return
        }

        for index in recordings.indices {
            let recording = recordings[index]
            guard shouldRecoverTranscription(for: recording) else {
                continue
            }

            do {
                let updated = try await transcribe(recording: recording)
                recordings[index] = updated
            } catch {
                continue
            }
        }
    }

    private func performTranscription(
        for recording: RecordingSession,
        onStateChange: (@MainActor (TranscriptPipelineState) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        let sessionDirectory = try repository.sessionDirectory(for: recording.id)
        let availability = runtimeProfileSelector.transcriptionAvailability(for: selectedModelProfile)
        switch availability {
        case .requiresASRModel, .unavailable:
            throw RecordingWorkflowError.transcriptionUnavailable(availability)
        case .ready, .degradedNoDiarization:
            break
        }

        let runtimeProfile: InferenceRuntimeProfile
        do {
            runtimeProfile = try runtimeProfileSelector.resolveTranscriptionProfile(for: selectedModelProfile)
        } catch let error as InferenceRuntimeProfileError {
            switch error {
            case .missingASRModel:
                throw RecordingWorkflowError.transcriptionUnavailable(.requiresASRModel(profileOptions: ModelProfile.allCases))
            case .missingSummarizationModel:
                throw RecordingWorkflowError.transcriptionUnavailable(.unavailable(reason: error.localizedDescription))
            }
        }
        return try await transcriptionPipeline.process(
            recording: recording,
            in: sessionDirectory,
            runtimeProfile: runtimeProfile,
            engineFactory: inferenceEngineFactory,
            onStateChange: onStateChange
        )
    }

    private func applyTranscriptionResult(
        _ result: TranscriptionResult,
        to recording: RecordingSession
    ) -> RecordingSession {
        var updated = recording
        updated.assets.transcriptFile = result.transcriptFile
        updated.assets.srtFile = result.srtFile
        updated.assets.transcriptJSONFile = result.transcriptJSONFile
        updated.assets.micASRJSONFile = result.micASRJSONFile
        updated.assets.systemASRJSONFile = result.systemASRJSONFile
        updated.assets.systemDiarizationJSONFile = result.systemDiarizationJSONFile
        updated.transcriptState = result.state
        updated.lifecycleState = .ready
        updated.notes = result.summary
        if !result.degradedReasons.isEmpty {
            updated.assets.degradedReasons = result.degradedReasons.map(\.rawValue)
        }
        return updated
    }

    private func shouldRecoverTranscription(for recording: RecordingSession) -> Bool {
        switch recording.transcriptState {
        case .queued, .transcribingMic, .transcribingSystem, .diarizingSystem, .merging, .renderingOutputs:
            return true
        case .failed:
            return recording.assets.transcriptJSONFile == nil
        case .idle, .ready:
            return false
        }
    }

    private func composeSummary(
        recording: RecordingSession,
        transcript: String?,
        srtText: String?
    ) -> String {
        let timeline = parseSRTTimeline(srtText)
        let transcriptLines = (transcript ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let executiveBullets: String = {
            if !timeline.isEmpty {
                return timeline.prefix(6).map { "- [\($0.timestamp)] \($0.text)" }.joined(separator: "\n")
            }
            if !transcriptLines.isEmpty {
                return transcriptLines.prefix(6).map { "- \($0)" }.joined(separator: "\n")
            }
            return "- Недостаточно данных для автоматического резюме."
        }()

        let topicsBullets: String = {
            if !timeline.isEmpty {
                return timeline.prefix(4).map { "- \($0.text)" }.joined(separator: "\n")
            }
            if !transcriptLines.isEmpty {
                return transcriptLines.prefix(4).map { "- \($0)" }.joined(separator: "\n")
            }
            return "- Темы не определены."
        }()

        let decisionsBullets = "- Решения и договоренности не выделены автоматически. Требуется ручная проверка."

        let actionItemsBullets: String = {
            if !timeline.isEmpty {
                return timeline.prefix(4).map { "- [Не указан] [Не указан] \($0.text)" }.joined(separator: "\n")
            }
            if !transcriptLines.isEmpty {
                return transcriptLines.prefix(4).map { "- [Не указан] [Не указан] \($0)" }.joined(separator: "\n")
            }
            return "- [Не указан] [Не указан] Action items не найдены."
        }()

        let risksBullets = "- Риски и открытые вопросы не определены автоматически. Требуется ручная проверка."

        return """
        # Summary

        - Recording: \(recording.title)
        - Created: \(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
        - Duration: \(recording.durationLabel)
        - Source: \(recording.transcriptSourceLabel)

        ## Call Summary

        \(executiveBullets)

        ## Topics and Agreements

        \(topicsBullets)

        ## Decisions

        \(decisionsBullets)

        ## Action Items

        \(actionItemsBullets)

        ## Risks

        \(risksBullets)
        """
    }

    private func parseSRTTimeline(_ text: String?) -> [(seconds: Int, timestamp: String, text: String)] {
        guard let text, !text.isEmpty else {
            return []
        }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")

        var timeline: [(seconds: Int, timestamp: String, text: String)] = []
        timeline.reserveCapacity(blocks.count)

        for block in blocks {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)

            guard lines.count >= 3 else {
                continue
            }

            let timestampLine = lines[1]
            let parts = timestampLine.components(separatedBy: " --> ")
            guard let start = parts.first else {
                continue
            }

            let payload = lines.dropFirst(2).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else {
                continue
            }

            let seconds = parseSRTSeconds(start)
            timeline.append((seconds: seconds, timestamp: start, text: payload))
        }

        return timeline.sorted(by: { $0.seconds < $1.seconds })
    }

    private func parseSRTSeconds(_ raw: String) -> Int {
        let cleaned = raw.replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.components(separatedBy: ":")
        guard parts.count == 3 else {
            return Int.max
        }

        let hours = Int(parts[0]) ?? 0
        let minutes = Int(parts[1]) ?? 0
        let secondsPart = parts[2].components(separatedBy: ".").first ?? "0"
        let seconds = Int(secondsPart) ?? 0
        return (hours * 3600) + (minutes * 60) + seconds
    }

    private func duration(for audioURL: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: audioURL)
        let duration = try await asset.load(.duration)
        return duration.isNumeric ? duration.seconds : 0
    }

    private func summarizeWithTimeout<T>(
        timeoutSeconds: UInt64 = 30,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw SummarizationError.cancelled
            }

            guard let first = try await group.next() else {
                throw SummarizationError.cancelled
            }

            group.cancelAll()
            return first
        }
    }

    private func persistSummarizationLog(lines: [String], in sessionDirectory: URL) {
        let logURL = sessionDirectory.appendingPathComponent("summarization.log")
        let body = lines.joined(separator: "\n") + "\n"
        try? body.write(to: logURL, atomically: true, encoding: .utf8)
    }

    private func summarizationErrorDescription(_ error: Error) -> String {
        if let summarizationError = error as? SummarizationError {
            return summarizationError.errorDescription ?? String(describing: summarizationError)
        }

        if let localizedError = error as? LocalizedError, let text = localizedError.errorDescription {
            return text
        }

        return String(describing: error)
    }

    private func iso8601Timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

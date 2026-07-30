import XCTest
@testable import Recordly

@MainActor
final class RecordingsPhaseOneTests: XCTestCase {
    func testCaptureUsableAudioFileNameRejectsEmptyAudioFile() throws {
        let directory = try makeSessionDirectory(named: "RecordlyEmptySystemAudio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let emptyURL = directory.appendingPathComponent("system.m4a")
        try Data().write(to: emptyURL)

        XCTAssertNil(CaptureArtifactValidator.usableAudioFileName("system.m4a", in: directory))
    }

    func testCaptureExistingInvalidDestinationIsNotProtectedFromRewrite() throws {
        let directory = try makeSessionDirectory(named: "RecordlyInvalidDurable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let emptyURL = directory.appendingPathComponent("mic.m4a")
        try Data().write(to: emptyURL)

        XCTAssertTrue(CaptureArtifactValidator.shouldReplaceDestination(at: emptyURL))
    }

    func testCompletingCaptureClearsSystemAudioWhenFinalArtifactIsInvalid() async throws {
        let repository = InMemoryRecordingsRepository()
        let captureEngine = SystemAudioLostOnStopCaptureEngine()
        let store = makeStore(repository: repository, audioCaptureEngine: captureEngine)
        store.viewState.autoTranscribeEnabled = false

        await store.beginRecording()
        let recordingID = try XCTUnwrap(store.viewState.runtime.activeRecordingID)
        await store.endRecording()

        let saved = try XCTUnwrap(repository.recordings.first(where: { $0.id == recordingID }))
        XCTAssertEqual(saved.assets.microphoneFile, "mic.m4a")
        XCTAssertNil(saved.assets.systemAudioFile)
    }

    func testSearchMatchesTitleSummaryAndTranscriptCaseInsensitively() {
        let titleMatch = makeRecording(title: "Design Review")
        let summaryMatch = makeRecording(title: "Call with Alex")
        let transcriptMatch = makeRecording(title: "Sync")
        let repository = InMemoryRecordingsRepository(
            recordings: [titleMatch, summaryMatch, transcriptMatch],
            transcriptBodies: [transcriptMatch.id: "Please FOLLOW the escalation process."],
            summaryBodies: [summaryMatch.id: "Follow up with legal tomorrow."]
        )
        let store = makeStore(repository: repository)

        store.viewState.searchQuery = "follow"

        XCTAssertEqual(
            Set(store.filteredRecordings.map(\.id)),
            Set([summaryMatch.id, transcriptMatch.id])
        )

        store.viewState.searchQuery = "design"

        XCTAssertEqual(store.filteredRecordings.map(\.id), [titleMatch.id])
    }

    func testSearchExcludesNonMatchingRecordings() {
        let first = makeRecording(title: "Roadmap")
        let second = makeRecording(title: "Budget")
        let repository = InMemoryRecordingsRepository(recordings: [first, second])
        let store = makeStore(repository: repository)

        store.viewState.searchQuery = "incident"

        XCTAssertTrue(store.filteredRecordings.isEmpty)
    }

    func testToggleFavoritePersistsToRepository() {
        let recording = makeRecording(title: "Customer call")
        let repository = InMemoryRecordingsRepository(recordings: [recording])
        let store = makeStore(repository: repository)

        store.toggleFavorite(for: recording)

        XCTAssertTrue(store.recordings.first?.isFavorite == true)
        XCTAssertTrue(repository.recordings.first?.isFavorite == true)
    }

    func testDuplicateCreatesCopiedRecordingWithCopiedAssetsAndUniqueTitle() throws {
        let sourceID = UUID()
        let sourceDirectory = try makeSessionDirectory(named: "duplicate-source-\(sourceID.uuidString)")
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }

        try "audio".write(to: sourceDirectory.appendingPathComponent("merged-call.m4a"), atomically: true, encoding: .utf8)
        try "transcript".write(to: sourceDirectory.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)

        let source = makeRecording(
            id: sourceID,
            title: "Weekly Sync",
            createdAt: Date(timeIntervalSince1970: 10),
            assets: RecordingAssets(
                microphoneFile: nil,
                systemAudioFile: nil,
                mergedCallFile: "merged-call.m4a",
                importedAudioFile: nil,
                transcriptFile: "transcript.txt",
                srtFile: nil,
                transcriptJSONFile: nil,
                micASRJSONFile: nil,
                systemASRJSONFile: nil,
                systemDiarizationJSONFile: nil,
                summaryFile: nil,
                connectorNotesFile: nil
            )
        )
        let existingCopy = makeRecording(title: "Weekly Sync Copy", createdAt: Date(timeIntervalSince1970: 5))
        let repository = InMemoryRecordingsRepository(
            recordings: [source, existingCopy],
            sessionDirectories: [sourceID: sourceDirectory]
        )
        let store = makeStore(repository: repository)

        store.duplicate(source)

        XCTAssertEqual(store.recordings.count, 3)
        guard let duplicate = store.recordings.first else {
            return XCTFail("Expected duplicate at top of list.")
        }

        XCTAssertNotEqual(duplicate.id, source.id)
        XCTAssertEqual(duplicate.title, "Weekly Sync Copy 2")
        XCTAssertEqual(duplicate.assets.mergedCallFile, "merged-call.m4a")
        XCTAssertEqual(duplicate.assets.transcriptFile, "transcript.txt")

        let duplicateDirectory = try repository.sessionDirectory(for: duplicate.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicateDirectory.appendingPathComponent("merged-call.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicateDirectory.appendingPathComponent("transcript.txt").path))
    }

    func testOpenModelsFromAlertOpensModelSettingsSheetAndRequestsFocus() {
        let repository = InMemoryRecordingsRepository()
        let store = makeStore(repository: repository)

        store.viewState.alert = RecordingsAlertState(
            message: "Models required",
            primaryAction: .openModels
        )

        store.openModelsFromAlert()

        XCTAssertTrue(store.isModelsSheetPresented)
        XCTAssertNil(store.viewState.alert)
        XCTAssertTrue(store.modelSettingsViewModelProxy.shouldScrollToDiarizationSection)
    }

    func testPlaybackRateCanChangeAndSurvivesSourceSwitch() {
        let repository = InMemoryRecordingsRepository()
        let controller = PlaybackController(repository: repository, previewMode: true)
        let recording = makeRecording(
            title: "Playback",
            assets: RecordingAssets(
                microphoneFile: "microphone.m4a",
                systemAudioFile: "system-audio.caf",
                mergedCallFile: "merged-call.m4a",
                importedAudioFile: nil,
                transcriptFile: nil,
                srtFile: nil,
                transcriptJSONFile: nil,
                micASRJSONFile: nil,
                systemASRJSONFile: nil,
                systemDiarizationJSONFile: nil,
                summaryFile: nil,
                connectorNotesFile: nil
            )
        )

        controller.syncSelection(recording)
        controller.setPlaybackRate(1.5, for: recording)
        controller.selectSource(.microphone, for: recording)

        XCTAssertEqual(controller.state.playbackRate, 1.5)
        XCTAssertEqual(controller.state.selectedSource, .microphone)
    }

    func testStoppingRecordingAllowsNextRecordingWhilePlaybackMixIsPending() async throws {
        let repository = InMemoryRecordingsRepository()
        let captureEngine = PendingMergeCaptureEngine()
        let store = makeStore(repository: repository, audioCaptureEngine: captureEngine)
        store.viewState.autoTranscribeEnabled = false

        await store.beginRecording()
        let firstRecordingID = try XCTUnwrap(store.viewState.runtime.activeRecordingID)
        await store.endRecording()

        XCTAssertFalse(store.viewState.runtime.isRecording)
        XCTAssertFalse(store.viewState.runtime.isCaptureTransitionInFlight)
        XCTAssertTrue(store.processingJobs.contains { $0.kind == .playbackMix && $0.recordingID == firstRecordingID })

        await store.beginRecording()

        XCTAssertTrue(store.viewState.runtime.isRecording)
        XCTAssertNotEqual(store.viewState.runtime.activeRecordingID, firstRecordingID)

        for _ in 0..<10 where !captureEngine.isMergePending {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        captureEngine.finishMerge()
    }

    func testStopCaptureTimeoutClearsRecordingRuntimeState() async throws {
        let repository = InMemoryRecordingsRepository()
        let captureEngine = HangingStopCaptureEngine()
        let store = makeStore(
            repository: repository,
            audioCaptureEngine: captureEngine,
            captureFinalizationTimeoutNanoseconds: 20_000_000
        )
        store.viewState.autoTranscribeEnabled = false

        await store.beginRecording()
        let recordingID = try XCTUnwrap(store.viewState.runtime.activeRecordingID)

        await store.endRecording()

        XCTAssertFalse(store.viewState.runtime.isRecording)
        XCTAssertFalse(store.viewState.runtime.isCaptureTransitionInFlight)
        let saved = try XCTUnwrap(repository.recordings.first(where: { $0.id == recordingID }))
        XCTAssertEqual(saved.lifecycleState, .failed)
        XCTAssertTrue(saved.notes.contains("Capture finalization failed"))
    }

    func testStorePublishesRecoveringCaptureHealth() async throws {
        let repository = InMemoryRecordingsRepository()
        let captureEngine = MutableHealthCaptureEngine()
        let store = makeStore(repository: repository, audioCaptureEngine: captureEngine)

        await store.beginRecording()
        captureEngine.captureHealth = CaptureHealthSnapshot(
            phase: .recovering(attempt: 2),
            affectedChannels: [.system],
            statusLabel: "Restoring audio…"
        )
        store.refreshCaptureHealth()

        XCTAssertEqual(store.viewState.runtime.captureHealth, captureEngine.captureHealth)
    }

    func testStorePublishesFailedCaptureHealth() async throws {
        let repository = InMemoryRecordingsRepository()
        let captureEngine = MutableHealthCaptureEngine()
        let store = makeStore(repository: repository, audioCaptureEngine: captureEngine)

        await store.beginRecording()
        captureEngine.captureHealth = CaptureHealthSnapshot(
            phase: .failed(message: "Audio capture could not be restored."),
            affectedChannels: [.system],
            statusLabel: "Not recording"
        )
        store.refreshCaptureHealth()

        XCTAssertEqual(store.viewState.runtime.captureHealth, captureEngine.captureHealth)
    }

    func testStoreAlertsOnceWhenRecoveryEpisodeFails() async throws {
        let repository = InMemoryRecordingsRepository()
        let captureEngine = MutableHealthCaptureEngine()
        var alertCount = 0
        let store = makeStore(
            repository: repository,
            audioCaptureEngine: captureEngine,
            captureFailureNotifier: { alertCount += 1 }
        )

        await store.beginRecording()
        captureEngine.captureHealth = CaptureHealthSnapshot(
            phase: .failed(message: "Audio capture could not be restored."),
            affectedChannels: [.system],
            statusLabel: "Not recording"
        )
        store.refreshCaptureHealth()
        store.refreshCaptureHealth()

        XCTAssertEqual(alertCount, 1)
    }

    func testStoreDoesNotAlertWhileRecovering() async throws {
        let repository = InMemoryRecordingsRepository()
        let captureEngine = MutableHealthCaptureEngine()
        var alertCount = 0
        let store = makeStore(
            repository: repository,
            audioCaptureEngine: captureEngine,
            captureFailureNotifier: { alertCount += 1 }
        )

        await store.beginRecording()
        captureEngine.captureHealth = CaptureHealthSnapshot(
            phase: .recovering(attempt: 1),
            affectedChannels: [.system],
            statusLabel: "Restoring audio…"
        )
        store.refreshCaptureHealth()

        XCTAssertEqual(alertCount, 0)
    }

    func testStoreCanRequestManualCaptureRetry() async throws {
        let repository = InMemoryRecordingsRepository()
        let captureEngine = MutableHealthCaptureEngine()
        let store = makeStore(repository: repository, audioCaptureEngine: captureEngine)

        await store.beginRecording()
        captureEngine.captureHealth = CaptureHealthSnapshot(
            phase: .failed(message: "Audio capture could not be restored."),
            affectedChannels: [.system],
            statusLabel: "Not recording"
        )
        store.refreshCaptureHealth()

        store.retryCaptureNow()
        try await Task.sleep(nanoseconds: 50_000_000)
        store.refreshCaptureHealth()

        XCTAssertEqual(captureEngine.retryCount, 1)
        XCTAssertEqual(store.viewState.runtime.captureHealth.phase, .recovering(attempt: 1))
    }

    func testSecondFailureAfterRecoveryAlertsAgain() async throws {
        let repository = InMemoryRecordingsRepository()
        let captureEngine = MutableHealthCaptureEngine()
        var alertCount = 0
        let store = makeStore(
            repository: repository,
            audioCaptureEngine: captureEngine,
            captureFailureNotifier: { alertCount += 1 }
        )

        await store.beginRecording()
        captureEngine.captureHealth = CaptureHealthSnapshot(
            phase: .failed(message: "First failure."),
            affectedChannels: [.system],
            statusLabel: "Not recording"
        )
        store.refreshCaptureHealth()
        captureEngine.captureHealth = CaptureHealthSnapshot(
            phase: .healthy,
            affectedChannels: [],
            statusLabel: "Captured"
        )
        store.refreshCaptureHealth()
        captureEngine.captureHealth = CaptureHealthSnapshot(
            phase: .failed(message: "Second failure."),
            affectedChannels: [.system],
            statusLabel: "Not recording"
        )
        store.refreshCaptureHealth()

        XCTAssertEqual(alertCount, 2)
    }

    func testManualRetryDoesNotAlertAgainWithoutSuccessfulRecovery() async throws {
        let repository = InMemoryRecordingsRepository()
        let captureEngine = MutableHealthCaptureEngine()
        var alertCount = 0
        let store = makeStore(
            repository: repository,
            audioCaptureEngine: captureEngine,
            captureFailureNotifier: { alertCount += 1 }
        )

        await store.beginRecording()
        captureEngine.captureHealth = CaptureHealthSnapshot(
            phase: .failed(message: "First failure."),
            affectedChannels: [.system],
            statusLabel: "Not recording"
        )
        store.refreshCaptureHealth()

        store.retryCaptureNow()
        try await Task.sleep(nanoseconds: 50_000_000)
        store.refreshCaptureHealth()
        captureEngine.captureHealth = CaptureHealthSnapshot(
            phase: .failed(message: "Retry failed."),
            affectedChannels: [.system],
            statusLabel: "Not recording"
        )
        store.refreshCaptureHealth()

        XCTAssertEqual(alertCount, 1)
    }

    private func makeStore(repository: InMemoryRecordingsRepository) -> RecordingsStore {
        let modelManager = ModelManager()
        let fluidProvider = FluidAudioASRModelProvider()
        let diarizationProvider = FluidAudioDiarizationModelProvider()
        let composition = DefaultInferenceComposition.make(
            modelManager: modelManager,
            asrModelProvider: fluidProvider,
            diarizationModelProvider: diarizationProvider
        )
        return makeStore(
            repository: repository,
            audioCaptureEngine: composition.audioCaptureEngine,
            runtimeProfileSelector: composition.runtimeProfileSelector,
            inferenceEngineFactory: composition.engineFactory,
            transcriptionEngineDisplayName: composition.transcriptionEngineDisplayName,
            modelManager: modelManager,
            fluidProvider: fluidProvider,
            diarizationProvider: diarizationProvider
        )
    }

    private func makeStore(
        repository: InMemoryRecordingsRepository,
        audioCaptureEngine: any AudioCaptureEngine,
        captureFinalizationTimeoutNanoseconds: UInt64 = 60_000_000_000,
        captureFailureNotifier: @escaping @MainActor () -> Void = {}
    ) -> RecordingsStore {
        let modelManager = ModelManager()
        let fluidProvider = FluidAudioASRModelProvider()
        let diarizationProvider = FluidAudioDiarizationModelProvider()
        let composition = DefaultInferenceComposition.make(
            modelManager: modelManager,
            asrModelProvider: fluidProvider,
            diarizationModelProvider: diarizationProvider
        )
        return makeStore(
            repository: repository,
            audioCaptureEngine: audioCaptureEngine,
            runtimeProfileSelector: composition.runtimeProfileSelector,
            inferenceEngineFactory: composition.engineFactory,
            transcriptionEngineDisplayName: composition.transcriptionEngineDisplayName,
            modelManager: modelManager,
            fluidProvider: fluidProvider,
            diarizationProvider: diarizationProvider,
            captureFinalizationTimeoutNanoseconds: captureFinalizationTimeoutNanoseconds,
            captureFailureNotifier: captureFailureNotifier
        )
    }

    private func makeStore(
        repository: InMemoryRecordingsRepository,
        audioCaptureEngine: any AudioCaptureEngine,
        runtimeProfileSelector: any InferenceRuntimeProfileSelecting,
        inferenceEngineFactory: any InferenceEngineFactory,
        transcriptionEngineDisplayName: String,
        modelManager: ModelManager,
        fluidProvider: any FluidAudioASRModelProviding,
        diarizationProvider: any FluidAudioDiarizationModelProviding,
        captureFinalizationTimeoutNanoseconds: UInt64 = 60_000_000_000,
        captureFailureNotifier: @escaping @MainActor () -> Void = {}
    ) -> RecordingsStore {
        return RecordingsStore(
            audioCaptureEngine: audioCaptureEngine,
            transcriptionPipeline: TranscriptionPipeline(),
            runtimeProfileSelector: runtimeProfileSelector,
            inferenceEngineFactory: inferenceEngineFactory,
            transcriptionEngineDisplayName: transcriptionEngineDisplayName,
            modelManager: modelManager,
            fluidAudioModelProvider: fluidProvider,
            fluidAudioDiarizationModelProvider: diarizationProvider,
            repository: repository,
            previewMode: false,
            captureFinalizationTimeoutNanoseconds: captureFinalizationTimeoutNanoseconds,
            captureFailureNotifier: captureFailureNotifier
        )
    }

    private func makeRecording(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        assets: RecordingAssets = RecordingAssets()
    ) -> RecordingSession {
        RecordingSession(
            id: id,
            title: title,
            createdAt: createdAt,
            duration: 90,
            lifecycleState: .ready,
            transcriptState: .ready,
            source: .liveCapture,
            notes: "",
            assets: assets
        )
    }

    private func makeSessionDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private final class PendingMergeCaptureEngine: AudioCaptureEngine {
        var systemAudioStatusLabel: String { "Captured" }
        private(set) var isMergePending = false
        private var shouldBlockMerge = true

        func startCapture(in sessionDirectory: URL) async throws -> CaptureArtifacts {
            CaptureArtifacts(
                microphoneFile: "mic.m4a",
                systemAudioFile: "system.m4a",
                mergedCallFile: nil,
                connectorNotesFile: "capture-session.json",
                note: "Recording."
            )
        }

        func stopCapture() async throws -> CaptureArtifacts {
            CaptureArtifacts(
                microphoneFile: "mic.m4a",
                systemAudioFile: "system.m4a",
                mergedCallFile: nil,
                connectorNotesFile: "capture-session.json",
                note: "Audio saved. Mixed playback is being prepared."
            )
        }

        func mergeCompletedSession(in sessionDirectory: URL) async throws -> CaptureArtifacts {
            isMergePending = true
            while shouldBlockMerge && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            isMergePending = false
            return CaptureArtifacts(
                microphoneFile: "mic.m4a",
                systemAudioFile: "system.m4a",
                mergedCallFile: nil,
                connectorNotesFile: "capture-session.json",
                note: "Mixed playback unavailable."
            )
        }

        func finishMerge() {
            shouldBlockMerge = false
        }

        func currentMicrophoneLevel() -> Double { 0 }
        func currentSystemAudioLevel() -> Double { 0 }
        func recoverPendingSessions(in recordingsDirectory: URL) async {}
    }

    @MainActor
    private final class SystemAudioLostOnStopCaptureEngine: AudioCaptureEngine {
        var systemAudioStatusLabel: String { "System silent" }

        func startCapture(in sessionDirectory: URL) async throws -> CaptureArtifacts {
            CaptureArtifacts(
                microphoneFile: "mic.m4a",
                systemAudioFile: "system.m4a",
                mergedCallFile: nil,
                connectorNotesFile: "capture-session.json",
                note: "Recording."
            )
        }

        func stopCapture() async throws -> CaptureArtifacts {
            CaptureArtifacts(
                microphoneFile: "mic.m4a",
                systemAudioFile: nil,
                mergedCallFile: nil,
                connectorNotesFile: "capture-session.json",
                note: "Audio saved. System audio was not captured."
            )
        }

        func mergeCompletedSession(in sessionDirectory: URL) async throws -> CaptureArtifacts {
            CaptureArtifacts(
                microphoneFile: "mic.m4a",
                systemAudioFile: nil,
                mergedCallFile: nil,
                connectorNotesFile: "capture-session.json",
                note: "Mixed playback unavailable."
            )
        }

        func currentMicrophoneLevel() -> Double { 0 }
        func currentSystemAudioLevel() -> Double { 0 }
        func recoverPendingSessions(in recordingsDirectory: URL) async {}
    }

    @MainActor
    private final class HangingStopCaptureEngine: AudioCaptureEngine {
        var systemAudioStatusLabel: String { "Captured" }

        func startCapture(in sessionDirectory: URL) async throws -> CaptureArtifacts {
            CaptureArtifacts(
                microphoneFile: "mic.m4a",
                systemAudioFile: nil,
                mergedCallFile: nil,
                connectorNotesFile: "capture-session.json",
                note: "Recording."
            )
        }

        func stopCapture() async throws -> CaptureArtifacts {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CancellationError()
        }

        func mergeCompletedSession(in sessionDirectory: URL) async throws -> CaptureArtifacts {
            CaptureArtifacts()
        }

        func currentMicrophoneLevel() -> Double { 0 }
        func currentSystemAudioLevel() -> Double { 0 }
        func recoverPendingSessions(in recordingsDirectory: URL) async {}
    }

    @MainActor
    private final class MutableHealthCaptureEngine: AudioCaptureEngine {
        var systemAudioStatusLabel: String { captureHealth.statusLabel }
        var captureHealth = CaptureHealthSnapshot(
            phase: .healthy,
            affectedChannels: [],
            statusLabel: "Captured"
        )
        private(set) var retryCount = 0

        func startCapture(in sessionDirectory: URL) async throws -> CaptureArtifacts {
            CaptureArtifacts(
                microphoneFile: "mic.m4a",
                systemAudioFile: "system.m4a",
                mergedCallFile: nil,
                connectorNotesFile: "capture-session.json",
                note: "Recording."
            )
        }

        func stopCapture() async throws -> CaptureArtifacts {
            CaptureArtifacts(
                microphoneFile: "mic.m4a",
                systemAudioFile: "system.m4a",
                mergedCallFile: nil,
                connectorNotesFile: "capture-session.json",
                note: "Audio saved."
            )
        }

        func mergeCompletedSession(in sessionDirectory: URL) async throws -> CaptureArtifacts {
            CaptureArtifacts()
        }

        func currentMicrophoneLevel() -> Double { 0 }
        func currentSystemAudioLevel() -> Double { 0 }

        func retryCaptureNow() async {
            retryCount += 1
            captureHealth = CaptureHealthSnapshot(
                phase: .recovering(attempt: 1),
                affectedChannels: [.microphone, .system],
                statusLabel: "Restoring audio…"
            )
        }

        func recoverPendingSessions(in recordingsDirectory: URL) async {}
    }
}

final class RecordingRuntimeStateProcessingTests: XCTestCase {
    func testBackgroundProcessingLabelIsReadyWhenNoJobs() {
        let state = RecordingRuntimeState()

        XCTAssertEqual(state.backgroundProcessingLabel, "Ready")
        XCTAssertEqual(state.activeProcessingCount, 0)
    }

    func testBackgroundProcessingLabelForSingleTranscriptionJob() {
        var state = RecordingRuntimeState()
        state.processingJobs = [
            RecordingProcessingJob(
                recordingID: UUID(),
                recordingTitle: "Call 1",
                kind: .transcription,
                progress: 0.42,
                stageLabel: "Transcribing system",
                startedAt: Date()
            )
        ]

        XCTAssertEqual(state.backgroundProcessingLabel, "Transcribing 1 recording")
        XCTAssertEqual(state.activeProcessingCount, 1)
    }

    func testBackgroundProcessingLabelForMultipleJobs() {
        var state = RecordingRuntimeState()
        state.processingJobs = [
            RecordingProcessingJob(
                recordingID: UUID(),
                recordingTitle: "Call 1",
                kind: .transcription,
                progress: 0.5,
                stageLabel: "Merging transcript",
                startedAt: Date()
            ),
            RecordingProcessingJob(
                recordingID: UUID(),
                recordingTitle: "Call 2",
                kind: .summarization,
                progress: 0.2,
                stageLabel: "Generating summary",
                startedAt: Date()
            )
        ]

        XCTAssertEqual(state.backgroundProcessingLabel, "Processing 2 jobs")
        XCTAssertEqual(state.activeProcessingCount, 2)
    }
}

final class RecordingCaptureHealthPresentationTests: XCTestCase {
    func testRecoveringPresentationIsAmberAndNonFatal() throws {
        let snapshot = CaptureHealthSnapshot(
            phase: .recovering(attempt: 2),
            affectedChannels: [.system],
            statusLabel: "Restoring audio…"
        )

        let presentation = try XCTUnwrap(RecordingCaptureHealthPresentation(snapshot: snapshot))

        XCTAssertEqual(presentation.severity, .warning)
        XCTAssertEqual(presentation.title, "Restoring audio…")
        XCTAssertTrue(presentation.showsProgress)
        XCTAssertFalse(presentation.isRetryable)
    }

    func testFailedPresentationIsRedPersistentAndRetryable() throws {
        let snapshot = CaptureHealthSnapshot(
            phase: .failed(message: "Audio capture could not be restored."),
            affectedChannels: [.system],
            statusLabel: "Not recording"
        )

        let presentation = try XCTUnwrap(RecordingCaptureHealthPresentation(snapshot: snapshot))

        XCTAssertEqual(presentation.severity, .critical)
        XCTAssertTrue(presentation.isPersistent)
        XCTAssertTrue(presentation.isRetryable)
        XCTAssertFalse(presentation.showsProgress)
    }

    func testHealthyPresentationHasNoBanner() {
        let snapshot = CaptureHealthSnapshot(
            phase: .healthy,
            affectedChannels: [],
            statusLabel: "Captured"
        )

        XCTAssertNil(RecordingCaptureHealthPresentation(snapshot: snapshot))
    }

    func testFailureCopyNamesAffectedSystemChannel() throws {
        let snapshot = CaptureHealthSnapshot(
            phase: .failed(message: "Audio capture could not be restored."),
            affectedChannels: [.system],
            statusLabel: "Not recording"
        )

        let presentation = try XCTUnwrap(RecordingCaptureHealthPresentation(snapshot: snapshot))

        XCTAssertEqual(presentation.message, "System audio is not being recorded.")
        XCTAssertTrue(presentation.accessibilityLabel.lowercased().contains("system audio"))
    }

    func testFailureCopyNamesWholeAudioStreamWhenBothChannelsAreAffected() throws {
        let snapshot = CaptureHealthSnapshot(
            phase: .failed(message: "Audio capture could not be restored."),
            affectedChannels: [.microphone, .system],
            statusLabel: "Not recording"
        )

        let presentation = try XCTUnwrap(RecordingCaptureHealthPresentation(snapshot: snapshot))

        XCTAssertEqual(presentation.message, "Microphone and system audio are not being recorded.")
        XCTAssertTrue(presentation.accessibilityLabel.lowercased().contains("microphone and system audio"))
    }
}

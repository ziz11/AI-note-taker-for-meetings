import XCTest
@testable import Recordly

@MainActor
final class RecordingsPhaseOneTests: XCTestCase {
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
        audioCaptureEngine: any AudioCaptureEngine
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
            diarizationProvider: diarizationProvider
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
        diarizationProvider: any FluidAudioDiarizationModelProviding
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
            previewMode: false
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

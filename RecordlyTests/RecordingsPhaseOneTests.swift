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

    private func makeStore(repository: InMemoryRecordingsRepository) -> RecordingsStore {
        let modelManager = ModelManager()
        let fluidProvider = FluidAudioASRModelProvider()
        let diarizationProvider = FluidAudioDiarizationModelProvider()
        let composition = DefaultInferenceComposition.make(
            modelManager: modelManager,
            asrModelProvider: fluidProvider,
            diarizationModelProvider: diarizationProvider
        )
        return RecordingsStore(
            audioCaptureEngine: composition.audioCaptureEngine,
            transcriptionPipeline: TranscriptionPipeline(),
            runtimeProfileSelector: composition.runtimeProfileSelector,
            inferenceEngineFactory: composition.engineFactory,
            transcriptionEngineDisplayName: composition.transcriptionEngineDisplayName,
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

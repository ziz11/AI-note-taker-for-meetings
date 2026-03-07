import AppKit
import Foundation
import UniformTypeIdentifiers

enum RecordingActionError: LocalizedError {
    case noSelectedRecording
    case noAudioToExport
    case noTranscriptToExport
    case sourceFileMissing

    var errorDescription: String? {
        switch self {
        case .noSelectedRecording:
            return "No recording is selected."
        case .noAudioToExport:
            return "No audio file is available to export."
        case .noTranscriptToExport:
            return "No transcript file is available to export."
        case .sourceFileMissing:
            return "The source file is missing from the recording folder."
        }
    }
}

@MainActor
final class RecordingsStore: ObservableObject {
    @Published private(set) var recordings: [RecordingSession] = []
    @Published var selectedRecordingID: UUID? {
        didSet {
            guard selectedRecordingID != oldValue else { return }
            playbackController.syncSelection(selectedRecording)
        }
    }
    @Published var viewState: RecordingsViewState
    @Published private(set) var playbackState = PlaybackState()
    @Published private(set) var modelOnboardingCoordinator: ModelOnboardingCoordinator
    @Published var isModelsSheetPresented = false

    private let previewMode: Bool
    private let workflow: RecordingWorkflowController
    private let playbackController: PlaybackController
    private let modelManager: ModelManager
    private let modelSettingsViewModel: ModelSettingsViewModel
    private var meterTimer: Timer?
    private var lastPublishedRecordingSecond = -1
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    private var summarizationTasks: [UUID: Task<Void, Never>] = [:]

    init(
        audioCaptureService: AudioCaptureService,
        transcriptionPipeline: TranscriptionPipeline,
        modelManager: ModelManager,
        repository: RecordingsPersistence = RecordingsRepository(),
        previewMode: Bool = false
    ) {
        self.previewMode = previewMode
        self.modelManager = modelManager
        self.modelSettingsViewModel = ModelSettingsViewModel(modelManager: modelManager)
        self.modelOnboardingCoordinator = ModelOnboardingCoordinator(modelManager: modelManager)
        var initialViewState = RecordingsViewState(activeEngineName: transcriptionPipeline.engineDisplayName)
        initialViewState.selectedModelProfile = modelManager.selectedProfile
        self.viewState = initialViewState
        self.workflow = RecordingWorkflowController(
            audioCaptureService: audioCaptureService,
            transcriptionPipeline: transcriptionPipeline,
            repository: repository,
            modelManager: modelManager,
            summaryEngine: LlamaCppSummaryEngine(),
            selectedModelProfile: initialViewState.selectedModelProfile
        )
        self.playbackController = PlaybackController(repository: repository, previewMode: previewMode)
        self.playbackController.onStateChange = { [weak self] state in
            self?.playbackState = state
        }

        if previewMode {
            recordings = Self.previewRecordings
            selectedRecordingID = recordings.first?.id
            viewState.storageLocationPath = "/Users/you/Library/Application Support/Recordly/recordings"
            viewState.runtime.activityStatus = "Preview"
            viewState.runtime.sidebarStatus = "Preview"
            viewState.runtime.meterLevels.microphoneLevel = 0.42
            playbackController.syncSelection(recordings.first)
            return
        }

        do {
            viewState.storageLocationPath = try workflow.recordingsDirectoryPath()
            loadRecordings()
            Task { [weak self] in
                await self?.recoverPendingPostProcessing()
            }
        } catch {
            present(error)
        }
    }

    convenience init(previewMode: Bool = false) {
        self.init(
            audioCaptureService: AudioCaptureService(),
            transcriptionPipeline: TranscriptionPipeline(),
            modelManager: ModelManager(),
            previewMode: previewMode
        )
    }

    deinit {
        transcriptionTasks.values.forEach { $0.cancel() }
        summarizationTasks.values.forEach { $0.cancel() }
    }

    var availableModels: [ModelDescriptor] {
        modelManager.listAvailableModels()
    }

    var modelManagerProxy: ModelManager {
        modelManager
    }

    var modelSettingsViewModelProxy: ModelSettingsViewModel {
        modelSettingsViewModel
    }

    func installModel(id: String) async {
        await modelManager.install(modelID: id)
        objectWillChange.send()
    }

    func removeModel(id: String) {
        modelManager.remove(modelID: id)
        objectWillChange.send()
    }

    func installationState(for descriptor: ModelDescriptor) -> ModelInstallState {
        modelManager.installationState(for: descriptor)
    }

    func installedSize(for descriptor: ModelDescriptor) -> Int64 {
        (try? modelManager.modelSizeOnDisk(modelID: descriptor.id)) ?? 0
    }

    func setModelProfile(_ profile: ModelProfile) {
        viewState.selectedModelProfile = profile
        workflow.selectedModelProfile = profile
        modelManager.switchProfile(profile)
    }

    var isRecording: Bool {
        viewState.runtime.isRecording
    }

    var processingJobs: [RecordingProcessingJob] {
        viewState.runtime.processingJobs.sorted { lhs, rhs in
            if lhs.startedAt == rhs.startedAt {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            return lhs.startedAt < rhs.startedAt
        }
    }

    var filteredRecordings: [RecordingSession] {
        let query = viewState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return recordings
        }

        return recordings.filter { recording in
            matchesSearchQuery(query, for: recording)
        }
    }

    var selectedRecording: RecordingSession? {
        guard let selectedRecordingID else {
            return recordings.first
        }

        return recordings.first(where: { $0.id == selectedRecordingID })
    }

    var activeTranscriptText: String? {
        guard let recording = selectedRecording else {
            return nil
        }

        return workflow.transcriptText(for: recording)
    }

    func processingJobs(for recordingID: UUID) -> [RecordingProcessingJob] {
        processingJobs.filter { $0.recordingID == recordingID }
    }

    func isProcessing(_ kind: RecordingProcessingKind, for recordingID: UUID) -> Bool {
        viewState.runtime.processingJobs.contains {
            $0.recordingID == recordingID && $0.kind == kind
        }
    }

    func processingBadgeText(for recording: RecordingSession) -> String? {
        let jobs = processingJobs(for: recording.id)
        guard !jobs.isEmpty else {
            return nil
        }

        if jobs.count == 1, let job = jobs.first {
            return "\(job.kind.label): \(job.stageLabel)"
        }

        let kinds = Set(jobs.map(\.kind))
        if kinds.count > 1 {
            return "Transcribing + summarizing"
        }

        return "\(jobs.first?.kind.label ?? "Processing"): \(jobs.count) jobs"
    }

    func beginRecording() async {
        guard !previewMode else { return }
        guard !viewState.runtime.isRecording else { return }
        guard !viewState.runtime.isCaptureTransitionInFlight else { return }
        playbackController.stop(resetPosition: true)
        var draftRecordingID: UUID?

        do {
            viewState.runtime.isCaptureTransitionInFlight = true
            let recording = try workflow.createDraftRecording(index: recordings.count + 1)
            draftRecordingID = recording.id
            recordings.insert(recording, at: 0)
            selectedRecordingID = recording.id

            let startResult = try await workflow.startCapture(for: recording)
            replaceRecording(startResult.recording)

            viewState.runtime.isRecording = true
            viewState.runtime.activeRecordingID = recording.id
            viewState.runtime.recordingStartedAt = Date()
            viewState.runtime.activeDuration = 0
            viewState.runtime.activityStatus = "Recording"
            viewState.runtime.sidebarStatus = "Recording"
            viewState.runtime.meterLevels.systemAudioLabel = startResult.systemAudioLabel
            startMeterTimer()
            viewState.runtime.isCaptureTransitionInFlight = false
        } catch {
            viewState.runtime.isCaptureTransitionInFlight = false
            if let draftID = draftRecordingID {
                removeRecording(id: draftID)
                workflow.failRecording(id: draftID)
            }
            present(error)
        }
    }

    func endRecording() async {
        guard !viewState.runtime.isCaptureTransitionInFlight else { return }
        await completeCapture(
            runTranscription: viewState.autoTranscribeEnabled,
            runSummarization: viewState.autoTranscribeEnabled && viewState.autoSummarizeEnabled,
            statusWhenSaved: "Saving"
        )
    }

    func finalizeActiveRecordingBeforeTermination() async {
        guard viewState.runtime.isRecording else { return }
        await completeCapture(runTranscription: false, runSummarization: false, statusWhenSaved: "Saved before quit")
    }

    func importAudio() async {
        guard !previewMode else { return }
        guard !viewState.runtime.isRecording else { return }

        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.allowedContentTypes = Self.supportedImportTypes
        openPanel.prompt = "Import"
        openPanel.title = "Import Audio"

        guard openPanel.runModal() == .OK, let sourceURL = openPanel.url else {
            return
        }

        do {
            viewState.runtime.sidebarStatus = "Importing"
            viewState.runtime.activityStatus = "Importing"
            let result = try await workflow.importAudio(
                from: sourceURL,
                autoTranscribe: false
            )
            let importedRecording = result.recording

            recordings.insert(importedRecording, at: 0)
            selectedRecordingID = importedRecording.id
            playbackController.syncSelection(selectedRecording)

            if viewState.autoTranscribeEnabled {
                enqueueTranscription(for: importedRecording.id, summarizeAfterCompletion: viewState.autoSummarizeEnabled)
            } else {
                viewState.runtime.sidebarStatus = "Ready to transcribe"
                viewState.runtime.activityStatus = "Ready"
            }
        } catch {
            present(error)
        }
    }

    func dismissError() {
        viewState.alert = nil
    }

    func transcriptText(for recording: RecordingSession) -> String? {
        workflow.transcriptText(for: recording)
    }

    func summaryText(for recording: RecordingSession) -> String? {
        workflow.summaryText(for: recording)
    }

    func togglePlayback(for recording: RecordingSession) {
        guard !viewState.runtime.isRecording else { return }
        do {
            try playbackController.togglePlayback(for: recording)
        } catch {
            handleTranscriptionError(error)
        }
    }

    func selectPlaybackSource(_ source: PlaybackAudioSource, for recording: RecordingSession) {
        playbackController.selectSource(source, for: recording)
    }

    func setPlaybackRate(_ rate: Float, for recording: RecordingSession) {
        playbackController.setPlaybackRate(rate, for: recording)
    }

    func seekPlayback(for recording: RecordingSession, to progress: Double) {
        do {
            try playbackController.seek(for: recording, to: progress)
        } catch {
            present(error)
        }
    }

    func skipPlayback(for recording: RecordingSession, by offset: TimeInterval) {
        do {
            try playbackController.skip(for: recording, by: offset)
        } catch {
            present(error)
        }
    }

    func openFolder(for recording: RecordingSession) {
        guard let sessionDirectory = try? workflow.sessionDirectory(for: recording.id) else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([sessionDirectory])
    }

    func copyTranscript(for recording: RecordingSession) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcriptText(for: recording) ?? "", forType: .string)
    }

    func copySummary(for recording: RecordingSession) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(summaryText(for: recording) ?? "", forType: .string)
    }

    func transcribeSelectedRecording() async {
        guard !previewMode else { return }
        guard !viewState.runtime.isRecording else { return }
        guard let selectedRecording else {
            present(RecordingActionError.noSelectedRecording)
            return
        }

        enqueueTranscription(for: selectedRecording.id, summarizeAfterCompletion: false)
    }

    func summarizeSelectedRecording() async {
        guard !previewMode else { return }
        guard !viewState.runtime.isRecording else { return }
        guard let selectedRecording else {
            present(RecordingActionError.noSelectedRecording)
            return
        }

        enqueueSummarization(for: selectedRecording.id)
    }

    func exportAudio(for recording: RecordingSession) {
        guard !previewMode else { return }

        do {
            guard let fileName = recording.playableAudioFileName else {
                throw RecordingActionError.noAudioToExport
            }

            let sessionDirectory = try workflow.sessionDirectory(for: recording.id)
            let sourceURL = sessionDirectory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw RecordingActionError.sourceFileMissing
            }

            let ext = sourceURL.pathExtension
            let savePanel = NSSavePanel()
            savePanel.title = "Export Audio"
            savePanel.prompt = "Export"
            savePanel.nameFieldStringValue = "\(sanitizedFileName(recording.title)).\(ext.isEmpty ? "m4a" : ext)"
            if let type = UTType(filenameExtension: ext) {
                savePanel.allowedContentTypes = [type]
            }

            guard savePanel.runModal() == .OK, let destinationURL = savePanel.url else {
                return
            }

            try copyItemReplacingIfNeeded(from: sourceURL, to: destinationURL)
        } catch {
            present(error)
        }
    }

    func exportTranscript(for recording: RecordingSession) {
        guard !previewMode else { return }

        do {
            guard let transcriptFile = recording.assets.transcriptFile else {
                throw RecordingActionError.noTranscriptToExport
            }

            let sessionDirectory = try workflow.sessionDirectory(for: recording.id)
            let sourceURL = sessionDirectory.appendingPathComponent(transcriptFile)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw RecordingActionError.sourceFileMissing
            }

            let ext = sourceURL.pathExtension.isEmpty ? "txt" : sourceURL.pathExtension
            let savePanel = NSSavePanel()
            savePanel.title = "Export Transcript"
            savePanel.prompt = "Export"
            savePanel.nameFieldStringValue = "\(sanitizedFileName(recording.title))-transcript.\(ext)"
            if let type = UTType(filenameExtension: ext) {
                savePanel.allowedContentTypes = [type]
            }

            guard savePanel.runModal() == .OK, let destinationURL = savePanel.url else {
                return
            }

            try copyItemReplacingIfNeeded(from: sourceURL, to: destinationURL)
        } catch {
            present(error)
        }
    }

    func renameSelectedRecording(to title: String) {
        guard let selectedRecordingID,
              let index = recordings.firstIndex(where: { $0.id == selectedRecordingID }) else {
            return
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return
        }

        recordings[index].title = trimmedTitle
        try? workflow.save(recordings[index])
    }

    func toggleFavorite(for recording: RecordingSession) {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else {
            return
        }

        recordings[index].isFavorite.toggle()
        try? workflow.save(recordings[index])
    }

    func duplicate(_ recording: RecordingSession) {
        let duplicated = RecordingSession(
            id: UUID(),
            title: nextDuplicateTitle(for: recording.title),
            createdAt: Date(),
            duration: recording.duration,
            isFavorite: recording.isFavorite,
            lifecycleState: .ready,
            transcriptState: recording.transcriptState,
            source: recording.source,
            notes: recording.notes,
            assets: recording.assets
        )

        do {
            try workflow.duplicateSessionContents(from: recording.id, to: duplicated.id)
            try workflow.save(duplicated)
            recordings.insert(duplicated, at: 0)
            selectedRecordingID = duplicated.id
            playbackController.syncSelection(duplicated)
        } catch {
            present(error)
        }
    }

    func shareableAudioURL(for recording: RecordingSession) -> URL? {
        try? workflow.playableAudioURL(for: recording)
    }

    func deleteSelectedRecording() {
        guard let selectedRecording = selectedRecording,
              let index = recordings.firstIndex(where: { $0.id == selectedRecording.id }) else {
            return
        }

        if viewState.runtime.isRecording, selectedRecording.id == viewState.runtime.activeRecordingID {
            return
        }

        do {
            if playbackState.recordingID == selectedRecording.id {
                playbackController.stop(resetPosition: true)
            }

            cancelProcessing(for: selectedRecording.id)
            try workflow.delete(id: selectedRecording.id)
            recordings.remove(at: index)
            selectedRecordingID = recordings.first?.id
            playbackController.syncSelection(selectedRecording)
        } catch {
            present(error)
        }
    }

    func delete(_ recording: RecordingSession) {
        selectedRecordingID = recording.id
        deleteSelectedRecording()
    }

    private func completeCapture(runTranscription: Bool, runSummarization: Bool, statusWhenSaved: String) async {
        guard viewState.runtime.isRecording,
              let activeRecordingID = viewState.runtime.activeRecordingID,
              let recording = recordings.first(where: { $0.id == activeRecordingID }) else {
            return
        }

        do {
            viewState.runtime.isCaptureTransitionInFlight = true
            stopMeterTimer()
            viewState.runtime.sidebarStatus = statusWhenSaved
            viewState.runtime.activityStatus = "Processing"
            let result = try await workflow.completeCapture(
                for: recording,
                duration: viewState.runtime.activeDuration,
                runTranscription: false
            )

            replaceRecording(result.recording)
            resetRuntimeState()
            viewState.runtime.isCaptureTransitionInFlight = false
            viewState.runtime.meterLevels.systemAudioLabel = result.systemAudioLabel
            playbackController.syncSelection(selectedRecording)
            refreshRuntimeStatusFromJobs()

            if runTranscription {
                enqueueTranscription(
                    for: result.recording.id,
                    summarizeAfterCompletion: runSummarization
                )
            } else {
                viewState.runtime.sidebarStatus = "Ready to transcribe"
                viewState.runtime.activityStatus = "Ready"
            }

            if result.recording.source == .liveCapture,
               result.recording.assets.mergedCallFile == nil {
                scheduleMergeProgressRefresh(recordingID: result.recording.id)
            }
            if let processingError = result.processingError {
                handleTranscriptionError(processingError, isBackground: true)
            }
        } catch {
            if let index = recordings.firstIndex(where: { $0.id == activeRecordingID }) {
                recordings[index].lifecycleState = .failed
                recordings[index].notes = "Recording was interrupted while finalizing tracks."
                try? workflow.save(recordings[index])
            }
            resetRuntimeState()
            viewState.runtime.isCaptureTransitionInFlight = false
            stopMeterTimer()
            present(error)
        }
    }

    private func loadRecordings() {
        loadRecordings(preserveSelection: false)
    }

    private func loadRecordings(preserveSelection: Bool) {
        let previousSelection = selectedRecordingID
        do {
            recordings = try workflow.loadRecordings().map(normalizeRecoveredRecording)
            let existingIDs = Set(recordings.map(\.id))
            viewState.runtime.processingJobs.removeAll { !existingIDs.contains($0.recordingID) }
            if preserveSelection,
               let previousSelection,
               recordings.contains(where: { $0.id == previousSelection }) {
                selectedRecordingID = previousSelection
            } else {
                selectedRecordingID = recordings.first?.id
            }
            playbackController.syncSelection(selectedRecording)
            refreshRuntimeStatusFromJobs()
        } catch {
            present(error)
        }
    }

    private func recoverPendingPostProcessing() async {
        await workflow.recoverPendingMerges()
        loadRecordings(preserveSelection: true)
        enqueueRecoverableTranscriptions()
    }

    private func replaceRecording(_ recording: RecordingSession) {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else {
            return
        }

        recordings[index] = recording
        if selectedRecordingID == recording.id {
            playbackController.syncSelection(recording)
        }
    }

    private func removeRecording(id: UUID) {
        cancelProcessing(for: id)
        recordings.removeAll(where: { $0.id == id })
        selectedRecordingID = recordings.first?.id
        playbackController.syncSelection(selectedRecording)
    }

    private func normalizeRecoveredRecording(_ recording: RecordingSession) -> RecordingSession {
        guard recording.lifecycleState == .recording else {
            return recording
        }

        var normalized = recording
        normalized.lifecycleState = .failed
        normalized.transcriptState = .failed
        normalized.notes = "Recording was interrupted before the app finished saving the file."
        return normalized
    }

    private func startMeterTimer() {
        stopMeterTimer()
        lastPublishedRecordingSecond = -1
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                if let recordingStartedAt = self.viewState.runtime.recordingStartedAt {
                    let duration = Date().timeIntervalSince(recordingStartedAt)
                    let currentSecond = Int(duration.rounded(.down))
                    self.viewState.runtime.activeDuration = duration

                    if currentSecond != self.lastPublishedRecordingSecond,
                       let activeRecordingID = self.viewState.runtime.activeRecordingID,
                       let index = self.recordings.firstIndex(where: { $0.id == activeRecordingID }) {
                        self.recordings[index].duration = duration
                        self.lastPublishedRecordingSecond = currentSecond
                    }
                }

                self.viewState.runtime.meterLevels.microphoneLevel = self.workflow.microphoneLevel()
                self.viewState.runtime.meterLevels.systemAudioLevel = self.workflow.systemAudioLevel()
                self.viewState.runtime.meterLevels.systemAudioLabel = self.workflow.currentSystemAudioStatusLabel
            }
        }
    }

    private func stopMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
        viewState.runtime.meterLevels.microphoneLevel = 0
        viewState.runtime.meterLevels.systemAudioLevel = 0
        lastPublishedRecordingSecond = -1
    }

    private func resetRuntimeState() {
        viewState.runtime.isRecording = false
        viewState.runtime.activeRecordingID = nil
        viewState.runtime.activeDuration = 0
        viewState.runtime.recordingStartedAt = nil
        viewState.runtime.meterLevels = RecordingMeterLevels()
        viewState.runtime.transcriptionProgress = nil
        viewState.runtime.transcriptionStageLabel = nil
        viewState.runtime.summarizationProgress = nil
        viewState.runtime.summarizationStageLabel = nil
    }

    private func present(_ error: Error, shouldSetRuntimeErrorState: Bool = true) {
        viewState.alert = RecordingsAlertState(message: readableMessage(for: error))
        if shouldSetRuntimeErrorState {
            viewState.runtime.activityStatus = "Error"
            viewState.runtime.sidebarStatus = "Error"
            stopMeterTimer()
        }
    }

    private func enqueueRecoverableTranscriptions() {
        for recording in recordings where shouldRecoverTranscription(for: recording) {
            enqueueTranscription(for: recording.id, summarizeAfterCompletion: false)
        }
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

    private func enqueueTranscription(for recordingID: UUID, summarizeAfterCompletion: Bool) {
        guard transcriptionTasks[recordingID] == nil else {
            return
        }
        guard let recording = recordings.first(where: { $0.id == recordingID }) else {
            return
        }

        upsertProcessingJob(
            recordingID: recording.id,
            recordingTitle: recording.title,
            kind: .transcription,
            progress: 0.08,
            stageLabel: "Queued"
        )

        if let index = recordings.firstIndex(where: { $0.id == recordingID }) {
            recordings[index].lifecycleState = .processing
            recordings[index].transcriptState = .queued
            recordings[index].notes = "Queued for transcription."
            try? workflow.save(recordings[index])
        }

        refreshRuntimeStatusFromJobs()
        transcriptionTasks[recordingID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runTranscriptionJob(
                recordingID: recordingID,
                summarizeAfterCompletion: summarizeAfterCompletion
            )
        }
    }

    private func runTranscriptionJob(recordingID: UUID, summarizeAfterCompletion: Bool) async {
        defer {
            transcriptionTasks[recordingID] = nil
            removeProcessingJob(recordingID: recordingID, kind: .transcription)
            refreshRuntimeStatusFromJobs()
        }

        guard let recording = recordings.first(where: { $0.id == recordingID }) else {
            return
        }

        do {
            let updatedRecording = try await workflow.transcribe(
                recording: recording,
                onStateChange: { [weak self] state in
                    self?.applyTranscriptionProgress(state: state, recordingID: recordingID)
                }
            )
            replaceRecording(updatedRecording)
            playbackController.syncSelection(selectedRecording)

            if summarizeAfterCompletion {
                enqueueSummarization(for: recordingID)
            }
        } catch {
            if !Task.isCancelled {
                handleTranscriptionError(error, isBackground: true)
            }
        }
    }

    private func enqueueSummarization(for recordingID: UUID) {
        guard summarizationTasks[recordingID] == nil else {
            return
        }
        guard let recording = recordings.first(where: { $0.id == recordingID }) else {
            return
        }

        upsertProcessingJob(
            recordingID: recording.id,
            recordingTitle: recording.title,
            kind: .summarization,
            progress: 0.05,
            stageLabel: "Queued"
        )
        refreshRuntimeStatusFromJobs()

        summarizationTasks[recordingID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runSummarizationJob(recordingID: recordingID)
        }
    }

    private func runSummarizationJob(recordingID: UUID) async {
        defer {
            summarizationTasks[recordingID] = nil
            removeProcessingJob(recordingID: recordingID, kind: .summarization)
            refreshRuntimeStatusFromJobs()
        }

        guard let recording = recordings.first(where: { $0.id == recordingID }) else {
            return
        }

        do {
            let updatedRecording = try await workflow.summarize(
                recording: recording,
                onProgress: { [weak self] progress, label in
                    self?.applySummarizationProgress(
                        recordingID: recordingID,
                        progress: progress,
                        stageLabel: label
                    )
                }
            )
            replaceRecording(updatedRecording)
        } catch {
            if !Task.isCancelled {
                present(error, shouldSetRuntimeErrorState: false)
            }
        }
    }

    private func applyTranscriptionProgress(state: TranscriptPipelineState, recordingID: UUID) {
        if let index = recordings.firstIndex(where: { $0.id == recordingID }) {
            recordings[index].transcriptState = state
        }

        if let job = viewState.runtime.processingJobs.first(where: {
            $0.recordingID == recordingID && $0.kind == .transcription
        }) {
            upsertProcessingJob(
                recordingID: recordingID,
                recordingTitle: job.recordingTitle,
                kind: .transcription,
                progress: progress(for: state) ?? job.progress,
                stageLabel: state.label
            )
        } else if let recording = recordings.first(where: { $0.id == recordingID }) {
            upsertProcessingJob(
                recordingID: recordingID,
                recordingTitle: recording.title,
                kind: .transcription,
                progress: progress(for: state) ?? 0.08,
                stageLabel: state.label
            )
        }

        if selectedRecordingID == recordingID {
            viewState.runtime.transcriptionProgress = progress(for: state)
            viewState.runtime.transcriptionStageLabel = state.label
        }
        refreshRuntimeStatusFromJobs()
    }

    private func applySummarizationProgress(recordingID: UUID, progress: Double, stageLabel: String) {
        if let job = viewState.runtime.processingJobs.first(where: {
            $0.recordingID == recordingID && $0.kind == .summarization
        }) {
            upsertProcessingJob(
                recordingID: recordingID,
                recordingTitle: job.recordingTitle,
                kind: .summarization,
                progress: progress,
                stageLabel: stageLabel
            )
        } else if let recording = recordings.first(where: { $0.id == recordingID }) {
            upsertProcessingJob(
                recordingID: recordingID,
                recordingTitle: recording.title,
                kind: .summarization,
                progress: progress,
                stageLabel: stageLabel
            )
        }

        if selectedRecordingID == recordingID {
            viewState.runtime.summarizationProgress = progress
            viewState.runtime.summarizationStageLabel = stageLabel
        }
        refreshRuntimeStatusFromJobs()
    }

    private func upsertProcessingJob(
        recordingID: UUID,
        recordingTitle: String,
        kind: RecordingProcessingKind,
        progress: Double,
        stageLabel: String
    ) {
        let clampedProgress = min(max(progress, 0), 1)
        if let index = viewState.runtime.processingJobs.firstIndex(where: {
            $0.recordingID == recordingID && $0.kind == kind
        }) {
            viewState.runtime.processingJobs[index].recordingTitle = recordingTitle
            viewState.runtime.processingJobs[index].progress = clampedProgress
            viewState.runtime.processingJobs[index].stageLabel = stageLabel
            return
        }

        viewState.runtime.processingJobs.append(
            RecordingProcessingJob(
                recordingID: recordingID,
                recordingTitle: recordingTitle,
                kind: kind,
                progress: clampedProgress,
                stageLabel: stageLabel,
                startedAt: Date()
            )
        )
    }

    private func removeProcessingJob(recordingID: UUID, kind: RecordingProcessingKind) {
        viewState.runtime.processingJobs.removeAll {
            $0.recordingID == recordingID && $0.kind == kind
        }

        if selectedRecordingID == recordingID {
            switch kind {
            case .transcription:
                viewState.runtime.transcriptionProgress = nil
                viewState.runtime.transcriptionStageLabel = nil
            case .summarization:
                viewState.runtime.summarizationProgress = nil
                viewState.runtime.summarizationStageLabel = nil
            }
        }
    }

    private func refreshRuntimeStatusFromJobs() {
        guard !viewState.runtime.isRecording else {
            return
        }

        if viewState.runtime.processingJobs.isEmpty {
            if viewState.runtime.activityStatus != "Error" {
                viewState.runtime.activityStatus = "Ready"
                viewState.runtime.sidebarStatus = "Ready"
            }
            return
        }

        viewState.runtime.activityStatus = "Processing"
        viewState.runtime.sidebarStatus = viewState.runtime.backgroundProcessingLabel
    }

    private func progress(for state: TranscriptPipelineState) -> Double? {
        switch state {
        case .idle, .failed:
            return nil
        case .queued:
            return 0.08
        case .transcribingMic:
            return 0.24
        case .transcribingSystem:
            return 0.46
        case .diarizingSystem:
            return 0.64
        case .merging:
            return 0.82
        case .renderingOutputs:
            return 0.94
        case .ready:
            return 1
        }
    }

    private func cancelProcessing(for recordingID: UUID) {
        transcriptionTasks[recordingID]?.cancel()
        transcriptionTasks[recordingID] = nil
        summarizationTasks[recordingID]?.cancel()
        summarizationTasks[recordingID] = nil
        removeProcessingJob(recordingID: recordingID, kind: .transcription)
        removeProcessingJob(recordingID: recordingID, kind: .summarization)
        refreshRuntimeStatusFromJobs()
    }

    private func handleTranscriptionError(_ error: Error, isBackground: Bool = false) {
        if case let RecordingWorkflowError.transcriptionUnavailable(availability) = error {
            if case .requiresASRModel = availability {
                isModelsSheetPresented = true
                return
            }
            return
        }
        present(error, shouldSetRuntimeErrorState: !isBackground)
    }

    private func scheduleMergeProgressRefresh(recordingID: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard self.recordings.contains(where: { $0.id == recordingID }) else {
                    return
                }

                await self.workflow.recoverPendingMerges()
                self.loadRecordings(preserveSelection: true)

                if let refreshed = self.recordings.first(where: { $0.id == recordingID }),
                   refreshed.assets.mergedCallFile != nil {
                    return
                }
            }
        }
    }

    private func readableMessage(for error: Error) -> String {
        if let captureError = error as? AudioCaptureError {
            return captureError.localizedDescription
        }

        let nsError = error as NSError
        let rawMessage = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)

        if rawMessage == "The operation couldn’t be completed. (Foundation._GenericObjCError error 0.)" {
            return "The audio file could not be finalized correctly. Try stopping the recording once more."
        }

        return rawMessage
    }

    private func copyItemReplacingIfNeeded(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func sanitizedFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let sanitized = raw
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return sanitized.isEmpty ? "recording" : sanitized
    }

    private func matchesSearchQuery(_ query: String, for recording: RecordingSession) -> Bool {
        let fields = [
            recording.title,
            workflow.summaryText(for: recording),
            workflow.transcriptText(for: recording)
        ]

        return fields
            .compactMap { $0?.localizedLowercase }
            .contains(where: { $0.contains(query.localizedLowercase) })
    }

    private func nextDuplicateTitle(for baseTitle: String) -> String {
        let existingTitles = Set(recordings.map(\.title))
        let firstCandidate = "\(baseTitle) Copy"
        guard existingTitles.contains(firstCandidate) else {
            return firstCandidate
        }

        var copyIndex = 2
        while existingTitles.contains("\(baseTitle) Copy \(copyIndex)") {
            copyIndex += 1
        }

        return "\(baseTitle) Copy \(copyIndex)"
    }
}

private extension RecordingsStore {
    static let supportedImportTypes: [UTType] = [
        .mpeg4Audio,
        .mp3,
        .wav,
        .aiff,
        .audio,
        UTType(filenameExtension: "caf")
    ]
    .compactMap { $0 }

    static var previewRecordings: [RecordingSession] {
        [
            RecordingSession(
                id: UUID(),
                title: "6 марта 01:31",
                createdAt: .now.addingTimeInterval(-7_200),
                duration: 128,
                isFavorite: true,
                lifecycleState: .ready,
                transcriptState: .ready,
                source: .liveCapture,
                notes: "Transcript ready.",
                assets: RecordingAssets(
                    microphoneFile: "microphone.m4a",
                    systemAudioFile: nil,
                    mergedCallFile: nil,
                    importedAudioFile: nil,
                    transcriptFile: "transcript.txt",
                    srtFile: "transcript.srt",
                    summaryFile: "summary.md",
                    connectorNotesFile: "system-audio-connector.txt"
                )
            ),
            RecordingSession(
                id: UUID(),
                title: "Demo import",
                createdAt: .now.addingTimeInterval(-86_400),
                duration: 342,
                isFavorite: false,
                lifecycleState: .ready,
                transcriptState: .idle,
                source: .importedAudio,
                notes: "Imported audio. Ready to transcribe.",
                assets: RecordingAssets(
                    microphoneFile: nil,
                    systemAudioFile: nil,
                    mergedCallFile: nil,
                    importedAudioFile: "imported-audio.mp3",
                    transcriptFile: nil,
                    srtFile: nil,
                    summaryFile: nil,
                    connectorNotesFile: nil
                )
            )
        ]
    }
}

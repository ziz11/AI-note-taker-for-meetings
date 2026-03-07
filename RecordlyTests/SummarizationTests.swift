import XCTest
@testable import Recordly

// MARK: - Mocks

final class MockLlamaCppRunner: LlamaCppRunner {
    var result: Result<String, Error>

    init(result: Result<String, Error> = .success("")) {
        self.result = result
    }

    func generate(prompt: String, configuration: SummarizationConfiguration) async throws -> String {
        try result.get()
    }
}

final class MockSummaryEngine: SummarizationEngine {
    var result: Result<SummaryDocument, Error>

    init(result: Result<SummaryDocument, Error> = .success(SummaryDocument(
        topics: [], decisions: [], actionItems: [], risks: [], rawMarkdown: ""
    ))) {
        self.result = result
    }

    func summarize(
        transcript: String,
        srtText: String?,
        recordingTitle: String,
        configuration: SummarizationConfiguration
    ) async throws -> SummaryDocument {
        try result.get()
    }
}

final class DelayedSummaryEngine: SummarizationEngine {
    private let delayNanoseconds: UInt64
    private let document: SummaryDocument

    init(delayNanoseconds: UInt64, document: SummaryDocument) {
        self.delayNanoseconds = delayNanoseconds
        self.document = document
    }

    func summarize(
        transcript: String,
        srtText: String?,
        recordingTitle: String,
        configuration: SummarizationConfiguration
    ) async throws -> SummaryDocument {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return document
    }
}

final class MockLlamaProcessExecutor: LlamaProcessExecutor {
    var result: Result<LlamaProcessResult, Error>

    init(result: Result<LlamaProcessResult, Error> = .success(LlamaProcessResult(exitCode: 0, stdout: "", stderr: ""))) {
        self.result = result
    }

    func run(executableURL: URL, arguments: [String], stdinData: Data?) async throws -> LlamaProcessResult {
        try result.get()
    }
}

final class CapturingLlamaProcessExecutor: LlamaProcessExecutor {
    var capturedExecutableURL: URL?
    var capturedArguments: [String] = []
    var result: LlamaProcessResult

    init(result: LlamaProcessResult = LlamaProcessResult(exitCode: 0, stdout: "output", stderr: "")) {
        self.result = result
    }

    func run(executableURL: URL, arguments: [String], stdinData: Data?) async throws -> LlamaProcessResult {
        capturedExecutableURL = executableURL
        capturedArguments = arguments
        return result
    }
}

final class SequencedLlamaProcessExecutor: LlamaProcessExecutor {
    var results: [LlamaProcessResult]
    var invocations: [[String]] = []

    init(results: [LlamaProcessResult]) {
        self.results = results
    }

    func run(executableURL: URL, arguments: [String], stdinData: Data?) async throws -> LlamaProcessResult {
        invocations.append(arguments)
        guard !results.isEmpty else {
            return LlamaProcessResult(exitCode: 1, stdout: "", stderr: "No more results")
        }
        return results.removeFirst()
    }
}

struct TestInferenceEngineFactory: InferenceEngineFactory {
    let summarizationEngine: any SummarizationEngine

    @MainActor
    func makeAudioCaptureEngine(for profile: InferenceRuntimeProfile) throws -> any AudioCaptureEngine {
        AudioCaptureService()
    }

    func makeASREngine(for profile: InferenceRuntimeProfile) throws -> any ASREngine {
        NoopASREngine()
    }

    func makeDiarizationEngine(for profile: InferenceRuntimeProfile) throws -> any DiarizationEngine {
        NoopDiarizationEngine()
    }

    func makeSummarizationEngine(for profile: InferenceRuntimeProfile) throws -> any SummarizationEngine {
        summarizationEngine
    }

    func makeVoiceActivityDetectionEngine(for profile: InferenceRuntimeProfile) throws -> (any VoiceActivityDetectionEngine)? {
        nil
    }
}

struct NoopASREngine: ASREngine {
    var displayName: String { "noop-asr" }

    func transcribe(
        audioURL: URL,
        channel: TranscriptChannel,
        sessionID: UUID,
        configuration: ASREngineConfiguration
    ) async throws -> ASRDocument {
        ASRDocument(
            version: 1,
            sessionID: sessionID,
            channel: channel,
            createdAt: Date(),
            segments: []
        )
    }
}

struct NoopDiarizationEngine: DiarizationEngine {
    func diarize(
        systemAudioURL: URL,
        sessionID: UUID,
        configuration: DiarizationEngineConfiguration
    ) async throws -> DiarizationDocument {
        DiarizationDocument(version: 1, sessionID: sessionID, createdAt: Date(), segments: [])
    }
}

final class InMemoryRecordingsRepository: RecordingsPersistence {
    var recordings: [RecordingSession]
    var sessionDirectories: [UUID: URL]
    var transcriptBodies: [UUID: String]
    var summaryBodies: [UUID: String]

    init(
        recordings: [RecordingSession] = [],
        sessionDirectories: [UUID: URL] = [:],
        transcriptBodies: [UUID: String] = [:],
        summaryBodies: [UUID: String] = [:]
    ) {
        self.recordings = recordings
        self.sessionDirectories = sessionDirectories
        self.transcriptBodies = transcriptBodies
        self.summaryBodies = summaryBodies
    }

    func recordingsDirectoryPath() throws -> String {
        FileManager.default.temporaryDirectory.path
    }

    func loadRecordings() throws -> [RecordingSession] {
        recordings.sorted(by: { $0.createdAt > $1.createdAt })
    }

    func sessionDirectory(for id: UUID) throws -> URL {
        if let existing = sessionDirectories[id] {
            return existing
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sessionDirectories[id] = directory
        return directory
    }

    func save(_ recording: RecordingSession) throws {
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index] = recording
        } else {
            recordings.append(recording)
        }
    }

    func delete(id: UUID) throws {
        recordings.removeAll(where: { $0.id == id })
        if let directory = sessionDirectories[id] {
            try? FileManager.default.removeItem(at: directory)
        }
        sessionDirectories[id] = nil
        transcriptBodies[id] = nil
    }

    func transcriptText(for recording: RecordingSession) -> String? {
        if let cached = transcriptBodies[recording.id] {
            return cached
        }

        guard let transcriptFile = recording.assets.transcriptFile,
              let directory = sessionDirectories[recording.id] else {
            return nil
        }

        let url = directory.appendingPathComponent(transcriptFile)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func summaryText(for recording: RecordingSession) -> String? {
        if let cached = summaryBodies[recording.id] {
            return cached
        }

        guard let summaryFile = recording.assets.summaryFile,
              let directory = sessionDirectories[recording.id] else {
            return nil
        }

        let url = directory.appendingPathComponent(summaryFile)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func copyImportedAudio(from sourceURL: URL, to id: UUID) throws -> String {
        let directory = try sessionDirectory(for: id)
        let filename = sourceURL.lastPathComponent
        let destination = directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return filename
    }

    func duplicateSessionContents(from sourceID: UUID, to destinationID: UUID) throws {
        let sourceDirectory = try sessionDirectory(for: sourceID)
        let destinationDirectory = try sessionDirectory(for: destinationID)
        let fileManager = FileManager.default
        let urls = try fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for url in urls {
            try fileManager.copyItem(at: url, to: destinationDirectory.appendingPathComponent(url.lastPathComponent))
        }

        transcriptBodies[destinationID] = transcriptBodies[sourceID]
        summaryBodies[destinationID] = summaryBodies[sourceID]
    }

    func playableAudioURL(for recording: RecordingSession) throws -> URL? {
        guard let fileName = recording.playableAudioFileName else {
            return nil
        }
        let directory = try sessionDirectory(for: recording.id)
        let url = directory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// MARK: - SummaryPromptBuilder Tests

final class SummaryPromptBuilderTests: XCTestCase {
    func testPromptContainsCallStructuredInstructions() {
        let result = SummaryPromptBuilder.build(
            transcript: "Sample transcript",
            srtText: nil,
            recordingTitle: "Meeting"
        )

        XCTAssertTrue(result.contains("You are an expert call analyst."))
        XCTAssertTrue(result.contains("Return structured markdown using the exact sections below."))
        XCTAssertTrue(result.contains("Answer in Russian by default."))
        XCTAssertTrue(result.contains("Rules:"))
        XCTAssertTrue(result.contains("If a section has no items write: None"))
        XCTAssertTrue(result.contains("Return ONLY markdown."))
        XCTAssertTrue(result.contains("## Call Summary"))
        XCTAssertTrue(result.contains("## Topics"))
        XCTAssertTrue(result.contains("## Decisions"))
        XCTAssertTrue(result.contains("## Action Items"))
        XCTAssertTrue(result.contains("## Risks"))
        XCTAssertTrue(result.contains("For each topic include related agreements if present."))
        XCTAssertTrue(result.contains("Ignore obvious noise artifacts"))
        XCTAssertTrue(result.contains("If the transcript is incomplete, summarize the available information."))
        XCTAssertTrue(result.contains("Transcript:"))
        XCTAssertTrue(result.contains("Write the summary now."))
    }

    func testBuildWithSRT() {
        let result = SummaryPromptBuilder.build(
            transcript: "plain text",
            srtText: "1\n00:00:00,000 --> 00:00:05,000\nHello world",
            recordingTitle: "Test Call"
        )
        XCTAssertTrue(result.contains("Hello world"))
        XCTAssertTrue(result.contains("Test Call"))
        XCTAssertFalse(result.contains("plain text"))
    }

    func testBuildWithPlainTranscript() {
        let result = SummaryPromptBuilder.build(
            transcript: "This is a plain transcript",
            srtText: nil,
            recordingTitle: "Meeting"
        )
        XCTAssertTrue(result.contains("This is a plain transcript"))
    }

    func testTrimsLongTranscript() {
        let longText = String(repeating: "A", count: 20_000)
        let result = SummaryPromptBuilder.build(
            transcript: longText,
            srtText: nil,
            recordingTitle: "Long"
        )
        let maxLen = SummaryPromptBuilder.maxContextCharacters
        XCTAssertFalse(result.contains(longText))
        XCTAssertTrue(result.contains(String(repeating: "A", count: maxLen)))
    }

    func testEmptyTranscriptProducesValidPrompt() {
        let result = SummaryPromptBuilder.build(
            transcript: "",
            srtText: nil,
            recordingTitle: "Empty"
        )
        XCTAssertTrue(result.contains("## Topics"))
        XCTAssertTrue(result.contains("Transcript:"))
        XCTAssertTrue(result.contains("Write the summary now."))
    }
}

// MARK: - SummaryOutputParser Tests

final class SummaryOutputParserTests: XCTestCase {
    func testParsesWellFormedMarkdown() throws {
        let markdown = """
        ## Topics
        - Topic one
        - Topic two

        ## Decisions
        - Decision one

        ## Action Items
        - Action one
        - Action two

        ## Risks
        - Risk one
        """

        let doc = try SummaryOutputParser.parse(markdown)
        XCTAssertEqual(doc.topics, ["Topic one", "Topic two"])
        XCTAssertEqual(doc.decisions, ["Decision one"])
        XCTAssertEqual(doc.actionItems, ["Action one", "Action two"])
        XCTAssertEqual(doc.risks, ["Risk one"])
    }

    func testMissingSectionsReturnEmptyArrays() throws {
        let markdown = "## Topics\n- Only topics here"
        let doc = try SummaryOutputParser.parse(markdown)
        XCTAssertEqual(doc.topics, ["Only topics here"])
        XCTAssertEqual(doc.decisions, [])
        XCTAssertEqual(doc.actionItems, [])
        XCTAssertEqual(doc.risks, [])
    }

    func testEmptyInputThrowsEmptyOutput() {
        XCTAssertThrowsError(try SummaryOutputParser.parse("")) { error in
            XCTAssertEqual(error as? SummarizationError, .emptyOutput)
        }
    }

    func testParsesRussianNumberedSections() throws {
        let markdown = """
        1. Ключевые темы
        - Рост конверсии

        2. Основные решения
        - Запустить пилот в апреле

        3. Следующие шаги
        - [Иван] [2026-04-10] Подготовить план запуска

        4. Риски и открытые вопросы
        - Задержка интеграции
        """

        let doc = try SummaryOutputParser.parse(markdown)
        XCTAssertEqual(doc.topics, ["Рост конверсии"])
        XCTAssertEqual(doc.decisions, ["Запустить пилот в апреле"])
        XCTAssertEqual(doc.actionItems, ["[Иван] [2026-04-10] Подготовить план запуска"])
        XCTAssertEqual(doc.risks, ["Задержка интеграции"])
    }

    func testParsesCallStyleRussianHeadings() throws {
        let markdown = """
        ## Саммари звонка
        - Короткое описание созвона.

        ## Темы и договоренности
        - Интеграция API: подтвердили дедлайн на пятницу.

        ## Решения и договоренности
        - Запускать пилот на 100 пользователей.

        ## Следующие шаги
        - [Анна] [2026-03-12] Подготовить rollout-план.

        ## Риски и открытые вопросы
        - Возможна задержка по backend.
        """

        let doc = try SummaryOutputParser.parse(markdown)
        XCTAssertEqual(doc.topics, ["Интеграция API: подтвердили дедлайн на пятницу."])
        XCTAssertEqual(doc.decisions, ["Запускать пилот на 100 пользователей."])
        XCTAssertEqual(doc.actionItems, ["[Анна] [2026-03-12] Подготовить rollout-план."])
        XCTAssertEqual(doc.risks, ["Возможна задержка по backend."])
    }
}

// MARK: - LlamaCppSummarizationEngine Tests

final class LlamaCppSummarizationEngineTests: XCTestCase {
    private let tempModelURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-model-\(UUID().uuidString).bin")

    override func setUp() {
        super.setUp()
        FileManager.default.createFile(atPath: tempModelURL.path, contents: Data("fake".utf8))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempModelURL)
        super.tearDown()
    }

    func testTranscriptTooShortThrows() async {
        let runner = MockLlamaCppRunner()
        let engine = LlamaCppSummarizationEngine(runner: runner)
        let config = SummarizationConfiguration(modelURL: tempModelURL)

        do {
            _ = try await engine.summarize(
                transcript: "short",
                srtText: nil,
                recordingTitle: "Test",
                configuration: config
            )
            XCTFail("Should throw")
        } catch {
            XCTAssertEqual(error as? SummarizationError, .transcriptTooShort)
        }
    }

    func testModelMissingThrows() async {
        let runner = MockLlamaCppRunner()
        let engine = LlamaCppSummarizationEngine(runner: runner)
        let missingURL = URL(fileURLWithPath: "/nonexistent/model.bin")
        let config = SummarizationConfiguration(modelURL: missingURL)
        let transcript = String(repeating: "word ", count: 20)

        do {
            _ = try await engine.summarize(
                transcript: transcript,
                srtText: nil,
                recordingTitle: "Test",
                configuration: config
            )
            XCTFail("Should throw")
        } catch {
            XCTAssertEqual(error as? SummarizationError, .modelMissing(missingURL))
        }
    }

    func testSuccessfulSummarization() async throws {
        let markdown = """
        ## Topics
        - Project update

        ## Decisions
        - Use new framework

        ## Action Items
        - Write docs

        ## Risks
        - Timeline tight
        """
        let runner = MockLlamaCppRunner(result: .success(markdown))
        let engine = LlamaCppSummarizationEngine(runner: runner)
        let config = SummarizationConfiguration(modelURL: tempModelURL)
        let transcript = String(repeating: "word ", count: 20)

        let doc = try await engine.summarize(
            transcript: transcript,
            srtText: nil,
            recordingTitle: "Test",
            configuration: config
        )

        XCTAssertEqual(doc.topics, ["Project update"])
        XCTAssertEqual(doc.decisions, ["Use new framework"])
        XCTAssertEqual(doc.actionItems, ["Write docs"])
        XCTAssertEqual(doc.risks, ["Timeline tight"])
    }

    func testUsesSRTContextWhenTranscriptIsEmpty() async throws {
        let markdown = """
        ## Topics
        - Budget review

        ## Decisions
        - Keep monthly cadence

        ## Action Items
        - Prepare board update

        ## Risks
        - Scope creep
        """
        let runner = MockLlamaCppRunner(result: .success(markdown))
        let engine = LlamaCppSummarizationEngine(runner: runner)
        let config = SummarizationConfiguration(modelURL: tempModelURL)
        let srt = """
        1
        00:00:00,000 --> 00:00:03,000
        We reviewed budget and planning details.

        2
        00:00:03,100 --> 00:00:06,500
        Action item owners confirmed timelines.
        """

        let doc = try await engine.summarize(
            transcript: "",
            srtText: srt,
            recordingTitle: "Sync",
            configuration: config
        )

        XCTAssertEqual(doc.topics, ["Budget review"])
    }

    func testRunnerFailurePropagates() async {
        let runner = MockLlamaCppRunner(result: .failure(SummarizationError.inferenceFailed(message: "boom")))
        let engine = LlamaCppSummarizationEngine(runner: runner)
        let config = SummarizationConfiguration(modelURL: tempModelURL)
        let transcript = String(repeating: "word ", count: 20)

        do {
            _ = try await engine.summarize(
                transcript: transcript,
                srtText: nil,
                recordingTitle: "Test",
                configuration: config
            )
            XCTFail("Should throw")
        } catch {
            XCTAssertEqual(error as? SummarizationError, .inferenceFailed(message: "boom"))
        }
    }

    func testUnstructuredOutputThrowsOutputParseFailed() async {
        let runner = MockLlamaCppRunner(result: .success("plain text without expected markdown sections"))
        let engine = LlamaCppSummarizationEngine(runner: runner)
        let config = SummarizationConfiguration(modelURL: tempModelURL)
        let transcript = String(repeating: "word ", count: 20)

        do {
            _ = try await engine.summarize(
                transcript: transcript,
                srtText: nil,
                recordingTitle: "Test",
                configuration: config
            )
            XCTFail("Should throw")
        } catch {
            XCTAssertEqual(error as? SummarizationError, .outputParseFailed)
        }
    }
}

// MARK: - RecordingsStore Summarization Tests

@MainActor
final class RecordingsStoreSummarizationTests: XCTestCase {
    func testSummarizeSelectedRecordingClearsProgressAfterCompletion() async throws {
        let fileManager = FileManager.default
        let recordingID = UUID()
        let sessionDirectory = fileManager.temporaryDirectory.appendingPathComponent("summary-store-\(recordingID.uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: sessionDirectory) }

        let transcriptFile = "transcript.txt"
        try "Caller: schedule the follow-up.\nCallee: send notes tomorrow.".write(
            to: sessionDirectory.appendingPathComponent(transcriptFile),
            atomically: true,
            encoding: .utf8
        )

        let recording = RecordingSession(
            id: recordingID,
            title: "Imported call",
            createdAt: Date(),
            duration: 126,
            lifecycleState: .ready,
            transcriptState: .ready,
            source: .importedAudio,
            notes: "Transcript ready.",
            assets: RecordingAssets(
                microphoneFile: nil,
                systemAudioFile: nil,
                mergedCallFile: nil,
                importedAudioFile: "imported-audio.m4a",
                transcriptFile: transcriptFile,
                srtFile: nil,
                transcriptJSONFile: nil,
                micASRJSONFile: nil,
                systemASRJSONFile: nil,
                systemDiarizationJSONFile: nil,
                summaryFile: nil,
                connectorNotesFile: nil
            )
        )

        let repository = InMemoryRecordingsRepository(
            recordings: [recording],
            sessionDirectories: [recordingID: sessionDirectory]
        )
        let modelManager = ModelManager(
            discoveryPaths: ModelDiscoveryPaths(
                appSupportDirectory: { _ in nil },
                sharedDirectory: { _ in nil },
                userDirectory: { _ in nil },
                projectDirectories: { [] }
            )
        )
        let composition = DefaultInferenceComposition.make(modelManager: modelManager)
        let store = RecordingsStore(
            audioCaptureEngine: composition.audioCaptureEngine,
            transcriptionPipeline: TranscriptionPipeline(),
            runtimeProfileSelector: composition.runtimeProfileSelector,
            inferenceEngineFactory: composition.engineFactory,
            transcriptionEngineDisplayName: composition.transcriptionEngineDisplayName,
            modelManager: modelManager,
            repository: repository,
            previewMode: false
        )

        await store.summarizeSelectedRecording()
        for _ in 0..<80 {
            if store.selectedRecording?.assets.summaryFile == "summary.md" {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNil(store.viewState.runtime.summarizationProgress)
        XCTAssertNil(store.viewState.runtime.summarizationStageLabel)
        XCTAssertEqual(store.viewState.runtime.activityStatus, "Ready")
        XCTAssertEqual(store.viewState.runtime.sidebarStatus, "Ready")
        XCTAssertEqual(store.selectedRecording?.assets.summaryFile, "summary.md")
        XCTAssertEqual(store.selectedRecording?.notes, "Summary is ready.")
    }
}

@MainActor
final class RecordingWorkflowControllerSummarizationTimeoutTests: XCTestCase {
    private var tempDirectory: URL!
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RecordingWorkflowControllerSummarizationTimeoutTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        defaultsSuiteName = "RecordingWorkflowControllerSummarizationTimeoutTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        if let defaultsSuiteName {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        defaults = nil
        defaultsSuiteName = nil
        tempDirectory = nil
    }

    func testSummarizeUsesFallbackWhenSummaryGenerationExceedsTimeout() async throws {
        let recordingID = UUID()
        let sessionDirectory = tempDirectory.appendingPathComponent(recordingID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let recording = RecordingSession(
            id: recordingID,
            title: "Timeout case",
            createdAt: Date(),
            duration: 90,
            lifecycleState: .ready,
            transcriptState: .ready,
            source: .importedAudio,
            notes: "Transcript ready.",
            assets: RecordingAssets(importedAudioFile: "call.m4a")
        )
        let repository = InMemoryRecordingsRepository(
            recordings: [recording],
            sessionDirectories: [recordingID: sessionDirectory],
            transcriptBodies: [recordingID: String(repeating: "word ", count: 120)]
        )

        let modelURL = try makeSummarizationModel(named: "timeout-model.gguf")
        let modelManager = makeModelManager(modelURL: modelURL)
        let llmMarkdown = """
        ## Topics
        - Should not be used

        ## Decisions
        - None

        ## Action Items
        - None

        ## Risks
        - None
        """
        let summaryEngine = DelayedSummaryEngine(
            delayNanoseconds: 2_000_000_000,
            document: SummaryDocument(
                topics: ["Should not be used"],
                decisions: [],
                actionItems: [],
                risks: [],
                rawMarkdown: llmMarkdown
            )
        )

        let workflow = makeWorkflow(
            repository: repository,
            modelManager: modelManager,
            summarizationEngine: summaryEngine,
            summarizationTimeoutSeconds: 1
        )

        let updated = try await workflow.summarize(recording: recording)
        XCTAssertEqual(updated.assets.summaryFile, "summary.md")

        let summaryURL = sessionDirectory.appendingPathComponent("summary.md")
        let summaryText = try String(contentsOf: summaryURL, encoding: .utf8)
        XCTAssertTrue(summaryText.contains("# Summary"))

        let logURL = sessionDirectory.appendingPathComponent("summarization.log")
        let logText = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(logText.contains("llm_status=failed"))
        XCTAssertTrue(logText.contains("summary_source=fallback"))
    }

    func testSummarizePreservesLLMOutputWhenTimeoutAllowsCompletion() async throws {
        let recordingID = UUID()
        let sessionDirectory = tempDirectory.appendingPathComponent(recordingID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let recording = RecordingSession(
            id: recordingID,
            title: "LLM success",
            createdAt: Date(),
            duration: 90,
            lifecycleState: .ready,
            transcriptState: .ready,
            source: .importedAudio,
            notes: "Transcript ready.",
            assets: RecordingAssets(importedAudioFile: "call.m4a")
        )
        let repository = InMemoryRecordingsRepository(
            recordings: [recording],
            sessionDirectories: [recordingID: sessionDirectory],
            transcriptBodies: [recordingID: String(repeating: "word ", count: 120)]
        )

        let modelURL = try makeSummarizationModel(named: "success-model.gguf")
        let modelManager = makeModelManager(modelURL: modelURL)
        let llmMarkdown = """
        ## Topics
        - Quarterly planning

        ## Decisions
        - Keep roadmap

        ## Action Items
        - Publish notes

        ## Risks
        - None
        """
        let summaryEngine = DelayedSummaryEngine(
            delayNanoseconds: 1_000_000_000,
            document: SummaryDocument(
                topics: ["Quarterly planning"],
                decisions: ["Keep roadmap"],
                actionItems: ["Publish notes"],
                risks: ["None"],
                rawMarkdown: llmMarkdown
            )
        )

        let workflow = makeWorkflow(
            repository: repository,
            modelManager: modelManager,
            summarizationEngine: summaryEngine,
            summarizationTimeoutSeconds: 3
        )

        _ = try await workflow.summarize(recording: recording)

        let summaryURL = sessionDirectory.appendingPathComponent("summary.md")
        let summaryText = try String(contentsOf: summaryURL, encoding: .utf8)
        XCTAssertEqual(summaryText.trimmingCharacters(in: .whitespacesAndNewlines), llmMarkdown)

        let logURL = sessionDirectory.appendingPathComponent("summarization.log")
        let logText = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(logText.contains("llm_status=success"))
        XCTAssertTrue(logText.contains("summary_source=llm"))
    }

    private func makeSummarizationModel(named name: String) throws -> URL {
        let modelsDirectory = tempDirectory.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let modelURL = modelsDirectory.appendingPathComponent(name, isDirectory: false)
        try Data("model".utf8).write(to: modelURL)
        return modelURL
    }

    private func makeModelManager(modelURL: URL) -> ModelManager {
        let discoveryPaths = ModelDiscoveryPaths(
            appSupportDirectory: { _ in nil },
            sharedDirectory: { _ in nil },
            userDirectory: { _ in nil },
            projectDirectories: { [modelURL.deletingLastPathComponent()] }
        )
        let manager = ModelManager(
            preferences: ModelPreferencesStore(defaults: defaults),
            discoveryPaths: discoveryPaths
        )

        let options = manager.listLocalOptions(kind: .summarization)
        let selected = options.first(where: { $0.url.path == modelURL.path }) ?? options.first
        manager.setSelectedModelID(selected?.id, for: .summarization)
        return manager
    }

    private func makeWorkflow(
        repository: InMemoryRecordingsRepository,
        modelManager: ModelManager,
        summarizationEngine: any SummarizationEngine,
        summarizationTimeoutSeconds: UInt64
    ) -> RecordingWorkflowController {
        let runtimeProfileSelector = DefaultInferenceRuntimeProfileSelector(modelManager: modelManager)
        let engineFactory = TestInferenceEngineFactory(summarizationEngine: summarizationEngine)
        return RecordingWorkflowController(
            audioCaptureEngine: AudioCaptureService(),
            transcriptionPipeline: TranscriptionPipeline(),
            runtimeProfileSelector: runtimeProfileSelector,
            inferenceEngineFactory: engineFactory,
            repository: repository,
            selectedModelProfile: .balanced,
            summarizationTimeoutSeconds: summarizationTimeoutSeconds
        )
    }
}

// MARK: - ProcessLlamaCppRunner Tests

final class ProcessLlamaCppRunnerTests: XCTestCase {
    func testCapturesExpectedArguments() async throws {
        let executor = CapturingLlamaProcessExecutor(
            result: LlamaProcessResult(exitCode: 0, stdout: "summary output", stderr: "")
        )
        let fakeBinary = URL(fileURLWithPath: "/usr/bin/true")
        let modelURL = URL(fileURLWithPath: "/tmp/model.bin")

        let runner = ProcessLlamaCppRunner(
            processExecutor: executor,
            resolveBinaryURL: { fakeBinary },
            temporaryDirectory: FileManager.default.temporaryDirectory
        )

        let output = try await runner.generate(
            prompt: "test prompt",
            configuration: SummarizationConfiguration(
                modelURL: modelURL,
                runtime: SummarizationRuntimeSettings(
                    contextSize: 8_192,
                    temperature: 0.3,
                    topP: 0.9
                )
            )
        )
        XCTAssertEqual(output, "summary output")

        XCTAssertEqual(executor.capturedExecutableURL, fakeBinary)
        XCTAssertTrue(executor.capturedArguments.contains("-m"))
        XCTAssertTrue(executor.capturedArguments.contains(modelURL.path))
        XCTAssertTrue(executor.capturedArguments.contains("--file"))
        XCTAssertTrue(executor.capturedArguments.contains("--no-display-prompt"))
        XCTAssertTrue(executor.capturedArguments.contains("--ctx-size"))
        XCTAssertTrue(executor.capturedArguments.contains("8192"))
        XCTAssertTrue(executor.capturedArguments.contains("--temp"))
        XCTAssertTrue(executor.capturedArguments.contains("0.3"))
        XCTAssertTrue(executor.capturedArguments.contains("--top-p"))
        XCTAssertTrue(executor.capturedArguments.contains("0.9"))
        XCTAssertTrue(executor.capturedArguments.contains("-n"))
        XCTAssertTrue(executor.capturedArguments.contains("1024"))
    }

    func testNonZeroExitThrowsInferenceFailed() async {
        let executor = MockLlamaProcessExecutor(
            result: .success(LlamaProcessResult(exitCode: 1, stdout: "", stderr: "segfault"))
        )
        let fakeBinary = URL(fileURLWithPath: "/usr/bin/true")
        let modelURL = URL(fileURLWithPath: "/tmp/model.bin")

        let runner = ProcessLlamaCppRunner(
            processExecutor: executor,
            resolveBinaryURL: { fakeBinary },
            temporaryDirectory: FileManager.default.temporaryDirectory
        )

        do {
            _ = try await runner.generate(
                prompt: "test",
                configuration: SummarizationConfiguration(
                    modelURL: modelURL,
                    runtime: .default
                )
            )
            XCTFail("Should throw")
        } catch {
            XCTAssertEqual(error as? SummarizationError, .inferenceFailed(message: "segfault"))
        }
    }

    func testChatTemplateFailureRetriesWithCompatibilityFlags() async throws {
        let chatTemplateError = """
        common_chat_templates_init: failed to initialize chat template
        srv init: please consider disabling jinja via --no-jinja
        """
        let executor = SequencedLlamaProcessExecutor(results: [
            LlamaProcessResult(exitCode: 1, stdout: "", stderr: chatTemplateError),
            LlamaProcessResult(exitCode: 0, stdout: "summary output", stderr: "")
        ])
        let fakeBinary = URL(fileURLWithPath: "/usr/bin/true")
        let modelURL = URL(fileURLWithPath: "/tmp/model.bin")

        let runner = ProcessLlamaCppRunner(
            processExecutor: executor,
            resolveBinaryURL: { fakeBinary },
            temporaryDirectory: FileManager.default.temporaryDirectory
        )

        let output = try await runner.generate(
            prompt: "test",
            configuration: SummarizationConfiguration(modelURL: modelURL, runtime: .default)
        )

        XCTAssertEqual(output, "summary output")
        XCTAssertEqual(executor.invocations.count, 2)
        XCTAssertTrue(executor.invocations[1].contains("--no-jinja"))
        XCTAssertTrue(executor.invocations[1].contains("--chat-template"))
        XCTAssertTrue(executor.invocations[1].contains("chatml"))
    }
}

final class ResolveLlamaBinaryURLTests: XCTestCase {
    func testPrefersLlamaCliOverMainInCurrentDirectory() throws {
        let fileManager = FileManager.default
        let originalDirectory = fileManager.currentDirectoryPath
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent("resolve-llama-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            _ = fileManager.changeCurrentDirectoryPath(originalDirectory)
            try? fileManager.removeItem(at: tempDirectory)
        }

        let mainURL = tempDirectory.appendingPathComponent("main")
        let llamaCliURL = tempDirectory.appendingPathComponent("llama-cli")
        fileManager.createFile(atPath: mainURL.path, contents: Data("main".utf8))
        fileManager.createFile(atPath: llamaCliURL.path, contents: Data("llama-cli".utf8))
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mainURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: llamaCliURL.path)

        XCTAssertTrue(fileManager.changeCurrentDirectoryPath(tempDirectory.path))

        let resolved = try resolveLlamaBinaryURL(fileManager: fileManager, environment: [:])
        XCTAssertEqual(resolved.lastPathComponent, "llama-cli")
        XCTAssertEqual(resolved.standardizedFileURL.path, llamaCliURL.standardizedFileURL.path)
    }
}

final class ModelPreferencesStoreTests: XCTestCase {
    func testDefaultSummarizationRuntimeSettings() {
        let suiteName = "ModelPreferencesStoreTests-default-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = ModelPreferencesStore(defaults: defaults)

        XCTAssertEqual(store.summarizationRuntimeSettings, .default)
    }

    func testPersistsSummarizationRuntimeSettings() {
        let suiteName = "ModelPreferencesStoreTests-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = ModelPreferencesStore(defaults: defaults)
        let expected = SummarizationRuntimeSettings(contextSize: 16_384, temperature: 0.2, topP: 0.85)

        store.summarizationRuntimeSettings = expected

        let reloadedStore = ModelPreferencesStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.summarizationRuntimeSettings, expected)
    }
}

final class FoundationLlamaProcessExecutorTests: XCTestCase {
    func testRunDrainsLargeStdoutWithoutHanging() async throws {
        let executor = FoundationLlamaProcessExecutor()
        let shellURL = URL(fileURLWithPath: "/bin/zsh")
        let payloadSize = 1_000_000
        let command = "python3 -c \"print('x' * \(payloadSize))\""

        let result = try await runWithTimeout(seconds: 5) {
            try await executor.run(executableURL: shellURL, arguments: ["-lc", command], stdinData: nil)
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.count >= payloadSize)
    }

    func testRunTimesOutUsingConfiguredTimeout() async {
        let executor = FoundationLlamaProcessExecutor(processTimeoutSeconds: 0.1)
        let shellURL = URL(fileURLWithPath: "/bin/zsh")

        do {
            _ = try await executor.run(executableURL: shellURL, arguments: ["-lc", "sleep 1"], stdinData: nil)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? SummarizationError, .cancelled)
        }
    }

    func testRunCompletesWhenConfiguredTimeoutIsSufficient() async throws {
        let executor = FoundationLlamaProcessExecutor(processTimeoutSeconds: 2.0)
        let shellURL = URL(fileURLWithPath: "/bin/zsh")

        let result = try await executor.run(
            executableURL: shellURL,
            arguments: ["-lc", "sleep 0.2; printf done"],
            stdinData: nil
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "done")
    }

    private func runWithTimeout<T>(
        seconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw SummarizationError.cancelled
            }

            guard let first = try await group.next() else {
                throw SummarizationError.cancelled
            }

            group.cancelAll()
            return first
        }
    }
}

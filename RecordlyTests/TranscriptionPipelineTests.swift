import XCTest
@testable import Recordly

final class TranscriptionPipelineTests: XCTestCase {
    func testPipelineRebuildsASRWhenModelChanges() async throws {
        let asrEngine = RecordingASREngine()
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(asrEngine: asrEngine, diarizationEngine: FailingDiarizationEngine())

        let sessionID = UUID()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(sessionID.uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        FileManager.default.createFile(atPath: temp.appendingPathComponent("mic.raw.caf").path, contents: Data())
        FileManager.default.createFile(atPath: temp.appendingPathComponent("system.raw.caf").path, contents: Data())

        let recording = RecordingSession(
            id: sessionID,
            title: "t",
            createdAt: Date(),
            duration: 10,
            lifecycleState: .ready,
            transcriptState: .queued,
            source: .liveCapture,
            notes: "",
            assets: RecordingAssets(microphoneFile: "mic.raw.caf", systemAudioFile: "system.raw.caf")
        )

        let modelA = temp.appendingPathComponent("model-a.bin")
        let modelB = temp.appendingPathComponent("model-b.bin")
        try Data("a".utf8).write(to: modelA)
        try Data("b".utf8).write(to: modelB)

        _ = try await pipeline.process(
            recording: recording,
            in: temp,
            runtimeProfile: makeRuntimeProfile(asrModelURL: modelA, diarizationModelURL: nil),
            engineFactory: factory
        )

        _ = try await pipeline.process(
            recording: recording,
            in: temp,
            runtimeProfile: makeRuntimeProfile(asrModelURL: modelB, diarizationModelURL: nil),
            engineFactory: factory
        )

        let calls = asrEngine.calls
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls.map(\.modelName), ["model-a.bin", "model-a.bin", "model-b.bin", "model-b.bin"])
    }

    func testPipelineRebuildsASRWhenLanguageFingerprintChanges() async throws {
        let asrEngine = RecordingASREngine()
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(asrEngine: asrEngine, diarizationEngine: FailingDiarizationEngine())

        let sessionID = UUID()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(sessionID.uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: temp.appendingPathComponent("mic.raw.caf").path, contents: Data())
        FileManager.default.createFile(atPath: temp.appendingPathComponent("system.raw.caf").path, contents: Data())

        let recording = RecordingSession(
            id: sessionID,
            title: "t",
            createdAt: Date(),
            duration: 10,
            lifecycleState: .ready,
            transcriptState: .queued,
            source: .liveCapture,
            notes: "",
            assets: RecordingAssets(microphoneFile: "mic.raw.caf", systemAudioFile: "system.raw.caf")
        )

        let model = temp.appendingPathComponent("model.bin")
        try Data("same-model".utf8).write(to: model)

        asrEngine.setFingerprintTag("ru")
        _ = try await pipeline.process(
            recording: recording,
            in: temp,
            runtimeProfile: makeRuntimeProfile(asrModelURL: model, diarizationModelURL: nil, asrLanguage: .ru),
            engineFactory: factory
        )

        asrEngine.setFingerprintTag("en")
        _ = try await pipeline.process(
            recording: recording,
            in: temp,
            runtimeProfile: makeRuntimeProfile(asrModelURL: model, diarizationModelURL: nil, asrLanguage: .en),
            engineFactory: factory
        )

        let calls = asrEngine.calls
        XCTAssertEqual(calls.count, 4)
    }

    func testPipelineNoDiarizationModelFallsBackToRemote() async throws {
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(asrEngine: MockASREngine(), diarizationEngine: FailingDiarizationEngine())

        let sessionID = UUID()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(sessionID.uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let micFile = temp.appendingPathComponent("mic.raw.caf")
        let systemFile = temp.appendingPathComponent("system.raw.caf")
        FileManager.default.createFile(atPath: micFile.path, contents: Data())
        FileManager.default.createFile(atPath: systemFile.path, contents: Data())

        let recording = RecordingSession(
            id: sessionID,
            title: "t",
            createdAt: Date(),
            duration: 10,
            lifecycleState: .ready,
            transcriptState: .queued,
            source: .liveCapture,
            notes: "",
            assets: RecordingAssets(microphoneFile: "mic.raw.caf", systemAudioFile: "system.raw.caf")
        )

        let modelData = Data("model:asr-balanced-v1:1.0.0".utf8)
        let modelURL = temp.appendingPathComponent("model.bin")
        try modelData.write(to: modelURL)

        let result = try await pipeline.process(
            recording: recording,
            in: temp,
            runtimeProfile: makeRuntimeProfile(asrModelURL: modelURL, diarizationModelURL: nil),
            engineFactory: factory
        )

        XCTAssertEqual(result.state, .ready)
        XCTAssertFalse(result.diarizationApplied)
        XCTAssertEqual(result.diarizationDegradedReason, "diarization model not selected")
        XCTAssertNil(result.systemDiarizationJSONFile)

        let transcriptURL = temp.appendingPathComponent("transcript.json")
        let data = try Data(contentsOf: transcriptURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(TranscriptDocument.self, from: data)
        XCTAssertTrue(doc.segments.contains(where: { $0.channel == .system && $0.speaker == "Remote" }))
    }

    func testPipelineDiarizationFailureFallsBackToRemote() async throws {
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(asrEngine: MockASREngine(), diarizationEngine: FailingDiarizationEngine())

        let sessionID = UUID()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(sessionID.uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let micFile = temp.appendingPathComponent("mic.raw.caf")
        let systemFile = temp.appendingPathComponent("system.raw.caf")
        let diarizationModel = temp.appendingPathComponent("diarization.bin")
        FileManager.default.createFile(atPath: micFile.path, contents: Data())
        FileManager.default.createFile(atPath: systemFile.path, contents: Data())
        FileManager.default.createFile(atPath: diarizationModel.path, contents: Data("dmodel".utf8))

        let recording = RecordingSession(
            id: sessionID,
            title: "t",
            createdAt: Date(),
            duration: 10,
            lifecycleState: .ready,
            transcriptState: .queued,
            source: .liveCapture,
            notes: "",
            assets: RecordingAssets(microphoneFile: "mic.raw.caf", systemAudioFile: "system.raw.caf")
        )

        let asrModelURL = temp.appendingPathComponent("model.bin")
        try Data("asr-model".utf8).write(to: asrModelURL)

        let result = try await pipeline.process(
            recording: recording,
            in: temp,
            runtimeProfile: makeRuntimeProfile(asrModelURL: asrModelURL, diarizationModelURL: diarizationModel),
            engineFactory: factory
        )

        XCTAssertEqual(result.state, .ready)
        XCTAssertFalse(result.diarizationApplied)
        XCTAssertNotNil(result.diarizationDegradedReason)
        XCTAssertNil(result.systemDiarizationJSONFile)
    }

    func testPipelineSuccessfulDiarizationWritesArtifact() async throws {
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(asrEngine: MockASREngine(), diarizationEngine: SuccessfulDiarizationEngine())

        let sessionID = UUID()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(sessionID.uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        FileManager.default.createFile(atPath: temp.appendingPathComponent("mic.raw.caf").path, contents: Data())
        FileManager.default.createFile(atPath: temp.appendingPathComponent("system.raw.caf").path, contents: Data())
        FileManager.default.createFile(atPath: temp.appendingPathComponent("diarization.bin").path, contents: Data("dmodel".utf8))
        try Data("asr-model".utf8).write(to: temp.appendingPathComponent("asr.bin"))

        let recording = RecordingSession(
            id: sessionID,
            title: "t",
            createdAt: Date(),
            duration: 10,
            lifecycleState: .ready,
            transcriptState: .queued,
            source: .liveCapture,
            notes: "",
            assets: RecordingAssets(microphoneFile: "mic.raw.caf", systemAudioFile: "system.raw.caf")
        )

        let result = try await pipeline.process(
            recording: recording,
            in: temp,
            runtimeProfile: makeRuntimeProfile(
                asrModelURL: temp.appendingPathComponent("asr.bin"),
                diarizationModelURL: temp.appendingPathComponent("diarization.bin")
            ),
            engineFactory: factory
        )

        XCTAssertTrue(result.diarizationApplied)
        XCTAssertNil(result.diarizationDegradedReason)
        XCTAssertEqual(result.systemDiarizationJSONFile, "system.diarization.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent("system.diarization.json").path))
    }

    func testPipelineCreatesEmptySystemASRWhenSystemAudioUnavailable() async throws {
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(asrEngine: SystemUnavailableASREngine(), diarizationEngine: FailingDiarizationEngine())

        let sessionID = UUID()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(sessionID.uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let micFile = temp.appendingPathComponent("mic.raw.caf")
        let systemFile = temp.appendingPathComponent("system.raw.caf")
        FileManager.default.createFile(atPath: micFile.path, contents: Data("mic".utf8))
        FileManager.default.createFile(atPath: systemFile.path, contents: Data())
        try Data("asr-model".utf8).write(to: temp.appendingPathComponent("asr.bin"))

        let recording = RecordingSession(
            id: sessionID,
            title: "t",
            createdAt: Date(),
            duration: 10,
            lifecycleState: .ready,
            transcriptState: .queued,
            source: .liveCapture,
            notes: "",
            assets: RecordingAssets(microphoneFile: "mic.raw.caf", systemAudioFile: "system.raw.caf")
        )

        let result = try await pipeline.process(
            recording: recording,
            in: temp,
            runtimeProfile: makeRuntimeProfile(
                asrModelURL: temp.appendingPathComponent("asr.bin"),
                diarizationModelURL: nil
            ),
            engineFactory: factory
        )

        XCTAssertEqual(result.state, .ready)
        XCTAssertEqual(result.systemASRJSONFile, "system.asr.json")
        let systemASRURL = temp.appendingPathComponent("system.asr.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemASRURL.path))
        let data = try Data(contentsOf: systemASRURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(ASRDocument.self, from: data)
        XCTAssertEqual(doc.channel, .system)
        XCTAssertTrue(doc.segments.isEmpty)
    }

    func testProcessDiarizationRunnerParsesValidJSON() async throws {
        let executor = MockDiarizationProcessExecutor(result: DiarizationProcessResult(
            exitCode: 0,
            stdout: "{\"segments\":[{\"startMs\":0,\"endMs\":1200,\"speakerId\":\"S1\"}]}",
            stderr: ""
        ))

        let runner = ProcessDiarizationRunner(
            processExecutor: executor,
            resolveBinaryURL: { URL(fileURLWithPath: "/tmp/diarization-main") }
        )

        let output = try await runner.diarize(
            audioURL: URL(fileURLWithPath: "/tmp/system.raw.caf"),
            modelURL: URL(fileURLWithPath: "/tmp/model.bin")
        )

        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0].speakerID, "S1")
        XCTAssertEqual(output[0].startMs, 0)
        XCTAssertEqual(output[0].endMs, 1200)
    }

    func testProcessDiarizationRunnerMalformedJSONThrows() async throws {
        let executor = MockDiarizationProcessExecutor(result: DiarizationProcessResult(
            exitCode: 0,
            stdout: "{bad-json}",
            stderr: ""
        ))

        let runner = ProcessDiarizationRunner(
            processExecutor: executor,
            resolveBinaryURL: { URL(fileURLWithPath: "/tmp/diarization-main") }
        )

        await XCTAssertThrowsErrorAsync(try await runner.diarize(
            audioURL: URL(fileURLWithPath: "/tmp/system.raw.caf"),
            modelURL: URL(fileURLWithPath: "/tmp/model.bin")
        )) { error in
            XCTAssertEqual(error as? DiarizationRuntimeError, .malformedOutput)
        }
    }

    func testProcessDiarizationRunnerEmptySegmentsThrows() async throws {
        let executor = MockDiarizationProcessExecutor(result: DiarizationProcessResult(
            exitCode: 0,
            stdout: "{\"segments\":[]}",
            stderr: ""
        ))

        let runner = ProcessDiarizationRunner(
            processExecutor: executor,
            resolveBinaryURL: { URL(fileURLWithPath: "/tmp/diarization-main") }
        )

        await XCTAssertThrowsErrorAsync(try await runner.diarize(
            audioURL: URL(fileURLWithPath: "/tmp/system.raw.caf"),
            modelURL: URL(fileURLWithPath: "/tmp/model.bin")
        )) { error in
            XCTAssertEqual(error as? DiarizationRuntimeError, .emptySegments)
        }
    }

    func testProcessDiarizationRunnerNonZeroExitThrows() async throws {
        let executor = MockDiarizationProcessExecutor(result: DiarizationProcessResult(
            exitCode: 13,
            stdout: "",
            stderr: "boom"
        ))

        let runner = ProcessDiarizationRunner(
            processExecutor: executor,
            resolveBinaryURL: { URL(fileURLWithPath: "/tmp/diarization-main") }
        )

        await XCTAssertThrowsErrorAsync(try await runner.diarize(
            audioURL: URL(fileURLWithPath: "/tmp/system.raw.caf"),
            modelURL: URL(fileURLWithPath: "/tmp/model.bin")
        )) { error in
            guard case let DiarizationRuntimeError.nonZeroExit(code, stderr) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(code, 13)
            XCTAssertEqual(stderr, "boom")
        }
    }

    func testProcessDiarizationRunnerBinaryMissingThrows() async throws {
        let executor = MockDiarizationProcessExecutor(result: DiarizationProcessResult(exitCode: 0, stdout: "", stderr: ""))
        let runner = ProcessDiarizationRunner(
            processExecutor: executor,
            resolveBinaryURL: { throw DiarizationRuntimeError.binaryMissing }
        )

        await XCTAssertThrowsErrorAsync(try await runner.diarize(
            audioURL: URL(fileURLWithPath: "/tmp/system.raw.caf"),
            modelURL: URL(fileURLWithPath: "/tmp/model.bin")
        )) { error in
            XCTAssertEqual(error as? DiarizationRuntimeError, .binaryMissing)
        }
    }

    func testProcessWhisperCppRunnerUsesInjectedBinaryResolver() async throws {
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-output-\(UUID().uuidString)")
        let jsonURL = outputBase.appendingPathExtension("json")
        let json = """
        {
          "result": { "language": "en" },
          "transcription": [
            {
              "text": "hello",
              "offsets": { "from": 0, "to": 1000 }
            }
          ]
        }
        """
        try XCTUnwrap(json.data(using: .utf8)).write(to: jsonURL)

        let executor = CapturingWhisperProcessExecutor(
            result: WhisperProcessResult(exitCode: 0, stdout: "", stderr: "")
        )
        let expectedBinaryURL = URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli")
        let runner = ProcessWhisperCppRunner(
            processExecutor: executor,
            temporaryDirectory: FileManager.default.temporaryDirectory,
            environment: [:],
            resolveBinaryURL: { expectedBinaryURL },
            outputBaseURLFactory: { outputBase }
        )

        let output = try await runner.transcribe(
            audioURL: URL(fileURLWithPath: "/tmp/audio.wav"),
            modelURL: URL(fileURLWithPath: "/tmp/model.bin")
        )

        XCTAssertEqual(output.language, "en")
        XCTAssertEqual(output.segments.count, 1)
        XCTAssertEqual(executor.capturedExecutableURL, expectedBinaryURL)
        XCTAssertTrue(executor.capturedArguments.contains("--language"))
        guard let languageIndex = executor.capturedArguments.firstIndex(of: "--language"),
              executor.capturedArguments.indices.contains(languageIndex + 1) else {
            XCTFail("Expected --language argument")
            return
        }
        XCTAssertEqual(executor.capturedArguments[languageIndex + 1], "ru")
    }

    func testProcessWhisperCppRunnerUsesConfiguredLanguageEN() async throws {
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-output-\(UUID().uuidString)")
        let jsonURL = outputBase.appendingPathExtension("json")
        let json = """
        {
          "result": { "language": "en" },
          "transcription": [
            {
              "text": "hello",
              "offsets": { "from": 0, "to": 1000 }
            }
          ]
        }
        """
        try XCTUnwrap(json.data(using: .utf8)).write(to: jsonURL)

        let executor = CapturingWhisperProcessExecutor(
            result: WhisperProcessResult(exitCode: 0, stdout: "", stderr: "")
        )
        let runner = ProcessWhisperCppRunner(
            processExecutor: executor,
            temporaryDirectory: FileManager.default.temporaryDirectory,
            environment: [:],
            languageCode: "en",
            resolveBinaryURL: { URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli") },
            outputBaseURLFactory: { outputBase }
        )

        _ = try await runner.transcribe(
            audioURL: URL(fileURLWithPath: "/tmp/audio.wav"),
            modelURL: URL(fileURLWithPath: "/tmp/model.bin")
        )

        guard let languageIndex = executor.capturedArguments.firstIndex(of: "--language"),
              executor.capturedArguments.indices.contains(languageIndex + 1) else {
            XCTFail("Expected --language argument")
            return
        }
        XCTAssertEqual(executor.capturedArguments[languageIndex + 1], "en")
    }

    func testProcessWhisperCppRunnerUsesConfiguredLanguageAuto() async throws {
        let outputBase = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-output-\(UUID().uuidString)")
        let jsonURL = outputBase.appendingPathExtension("json")
        let json = """
        {
          "result": { "language": "ru" },
          "transcription": [
            {
              "text": "privet",
              "offsets": { "from": 0, "to": 1000 }
            }
          ]
        }
        """
        try XCTUnwrap(json.data(using: .utf8)).write(to: jsonURL)

        let executor = CapturingWhisperProcessExecutor(
            result: WhisperProcessResult(exitCode: 0, stdout: "", stderr: "")
        )
        let runner = ProcessWhisperCppRunner(
            processExecutor: executor,
            temporaryDirectory: FileManager.default.temporaryDirectory,
            environment: [:],
            languageCode: "auto",
            resolveBinaryURL: { URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli") },
            outputBaseURLFactory: { outputBase }
        )

        _ = try await runner.transcribe(
            audioURL: URL(fileURLWithPath: "/tmp/audio.wav"),
            modelURL: URL(fileURLWithPath: "/tmp/model.bin")
        )

        guard let languageIndex = executor.capturedArguments.firstIndex(of: "--language"),
              executor.capturedArguments.indices.contains(languageIndex + 1) else {
            XCTFail("Expected --language argument")
            return
        }
        XCTAssertEqual(executor.capturedArguments[languageIndex + 1], "auto")
    }

    func testDefaultWhisperBinaryResolverFindsWhisperCLIInPATH() throws {
        let expected = URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli")
        let runner = ProcessWhisperCppRunner(
            fileManager: FakeWhisperBinaryFileManager(executablePaths: [expected.path]),
            processExecutor: MockWhisperProcessExecutor(result: WhisperProcessResult(exitCode: 0, stdout: "", stderr: "")),
            temporaryDirectory: FileManager.default.temporaryDirectory,
            environment: ["PATH": "/usr/bin:/opt/homebrew/bin:/bin"]
        )

        let resolved = try runner.defaultResolveWhisperBinaryURL()

        XCTAssertEqual(resolved, expected)
    }

    func testCliDiarizationEngineModelMissingThrows() async throws {
        let service = CliDiarizationEngine(
            runnerFactory: {
                ProcessDiarizationRunner(
                    processExecutor: MockDiarizationProcessExecutor(result: DiarizationProcessResult(exitCode: 0, stdout: "", stderr: "")),
                    resolveBinaryURL: { URL(fileURLWithPath: "/tmp/diarization-main") }
                )
            }
        )

        let sessionID = UUID()
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("system.raw.caf")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data())

        let missingModelURL = FileManager.default.temporaryDirectory.appendingPathComponent("missing-model.bin")

        await XCTAssertThrowsErrorAsync(try await service.diarize(
            systemAudioURL: audioURL,
            sessionID: sessionID,
            configuration: DiarizationEngineConfiguration(modelURL: missingModelURL)
        )) { error in
            guard case DiarizationRuntimeError.modelMissing = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    private func makeRuntimeProfile(
        asrModelURL: URL,
        diarizationModelURL: URL?,
        asrLanguage: ASRLanguage = .ru
    ) -> InferenceRuntimeProfile {
        InferenceRuntimeProfile(
            stageSelection: .defaultLocal,
            modelArtifacts: InferenceModelArtifacts(
                asrModelURL: asrModelURL,
                diarizationModelURL: diarizationModelURL,
                summarizationModelURL: nil
            ),
            asrLanguage: asrLanguage,
            summarizationRuntimeSettings: .default
        )
    }

    private struct MockASREngine: ASREngine {
        var displayName: String { "mock" }

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
                segments: [
                    ASRSegment(id: "\(channel.rawValue)-1", startMs: 0, endMs: 1000, text: "hello", confidence: nil, language: "ru", words: nil)
                ]
            )
        }
    }

    private struct SystemUnavailableASREngine: ASREngine {
        var displayName: String { "system-unavailable-mock" }

        func transcribe(
            audioURL: URL,
            channel: TranscriptChannel,
            sessionID: UUID,
            configuration: ASREngineConfiguration
        ) async throws -> ASRDocument {
            if channel == .system {
                throw ASREngineRuntimeError.inferenceFailed(
                    message: "whisper-cli produced no output file. stderr: error: failed to read the frames of the audio data (Invalid argument)"
                )
            }

            return ASRDocument(
                version: 1,
                sessionID: sessionID,
                channel: channel,
                createdAt: Date(),
                segments: [
                    ASRSegment(id: "mic-1", startMs: 0, endMs: 1000, text: "hello", confidence: nil, language: "ru", words: nil)
                ]
            )
        }
    }

    private final class RecordingASREngine: ASREngine, @unchecked Sendable {
        struct Call: Equatable {
            let channel: TranscriptChannel
            let modelName: String
        }

        private let lock = NSLock()
        private var storedCalls: [Call] = []
        private var fingerprintTag: String = "ru"

        var calls: [Call] {
            lock.lock()
            defer { lock.unlock() }
            return storedCalls
        }

        func setFingerprintTag(_ value: String) {
            lock.lock()
            defer { lock.unlock() }
            fingerprintTag = value
        }

        func cacheFingerprint(configuration: ASREngineConfiguration) -> String {
            lock.lock()
            let tag = fingerprintTag
            lock.unlock()
            return "\(configuration.modelURL.standardizedFileURL.path)|lang:\(tag)"
        }

        var displayName: String { "recording-mock" }

        func transcribe(
            audioURL: URL,
            channel: TranscriptChannel,
            sessionID: UUID,
            configuration: ASREngineConfiguration
        ) async throws -> ASRDocument {
            lock.lock()
            storedCalls.append(Call(channel: channel, modelName: configuration.modelURL.lastPathComponent))
            lock.unlock()
            return ASRDocument(
                version: 1,
                sessionID: sessionID,
                channel: channel,
                createdAt: Date(),
                segments: [
                    ASRSegment(
                        id: "\(channel.rawValue)-1",
                        startMs: 0,
                        endMs: 1000,
                        text: configuration.modelURL.lastPathComponent,
                        confidence: nil,
                        language: "ru",
                        words: nil
                    )
                ]
            )
        }
    }

    private struct FailingDiarizationEngine: DiarizationEngine {
        func diarize(
            systemAudioURL: URL,
            sessionID: UUID,
            configuration: DiarizationEngineConfiguration
        ) async throws -> DiarizationDocument {
            throw DiarizationRuntimeError.nonZeroExit(code: 1, stderr: "mock failure")
        }
    }

    private struct SuccessfulDiarizationEngine: DiarizationEngine {
        func diarize(
            systemAudioURL: URL,
            sessionID: UUID,
            configuration: DiarizationEngineConfiguration
        ) async throws -> DiarizationDocument {
            DiarizationDocument(
                version: 1,
                sessionID: sessionID,
                createdAt: Date(),
                segments: [
                    DiarizationSegment(id: "d1", speaker: "Speaker A", startMs: 0, endMs: 1000, confidence: 0.9)
                ]
            )
        }
    }

    private struct StaticInferenceEngineFactory: InferenceEngineFactory {
        let asrEngine: any ASREngine
        let diarizationEngine: any DiarizationEngine

        @MainActor
        func makeAudioCaptureEngine(for profile: InferenceRuntimeProfile) throws -> any AudioCaptureEngine {
            AudioCaptureService()
        }

        func makeASREngine(for profile: InferenceRuntimeProfile) throws -> any ASREngine {
            asrEngine
        }

        func makeDiarizationEngine(for profile: InferenceRuntimeProfile) throws -> any DiarizationEngine {
            diarizationEngine
        }

        func makeSummarizationEngine(for profile: InferenceRuntimeProfile) throws -> any SummarizationEngine {
            LlamaCppSummarizationEngine()
        }

        func makeVoiceActivityDetectionEngine(for profile: InferenceRuntimeProfile) throws -> (any VoiceActivityDetectionEngine)? {
            nil
        }
    }

    private final class MockDiarizationProcessExecutor: DiarizationProcessExecutor {
        private let result: DiarizationProcessResult

        init(result: DiarizationProcessResult) {
            self.result = result
        }

        func run(executableURL: URL, arguments: [String], stdinData: Data?) async throws -> DiarizationProcessResult {
            result
        }
    }

    private final class CapturingWhisperProcessExecutor: WhisperProcessExecutor {
        private(set) var capturedExecutableURL: URL?
        private(set) var capturedArguments: [String] = []
        private let result: WhisperProcessResult

        init(result: WhisperProcessResult) {
            self.result = result
        }

        func run(executableURL: URL, arguments: [String]) async throws -> WhisperProcessResult {
            capturedExecutableURL = executableURL
            capturedArguments = arguments
            return result
        }
    }

    private struct MockWhisperProcessExecutor: WhisperProcessExecutor {
        let result: WhisperProcessResult

        func run(executableURL: URL, arguments: [String]) async throws -> WhisperProcessResult {
            result
        }
    }

    private final class FakeWhisperBinaryFileManager: FileManager {
        private let executablePaths: Set<String>

        init(executablePaths: Set<String>) {
            self.executablePaths = executablePaths
            super.init()
        }

        override func isExecutableFile(atPath path: String) -> Bool {
            executablePaths.contains(path)
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown. \(message)", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

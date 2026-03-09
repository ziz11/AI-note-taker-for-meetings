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

    func testPipelineRebuildsASRWhenFingerprintChanges() async throws {
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
            runtimeProfile: makeRuntimeProfile(asrModelURL: model, diarizationModelURL: nil),
            engineFactory: factory
        )

        asrEngine.setFingerprintTag("en")
        _ = try await pipeline.process(
            recording: recording,
            in: temp,
            runtimeProfile: makeRuntimeProfile(asrModelURL: model, diarizationModelURL: nil),
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

    // MARK: - Phase 1 reliability tests

    func testEmptyASROnOneChannelReturnsDegradedResult() async throws {
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(asrEngine: EmptySystemASREngine(), diarizationEngine: FailingDiarizationEngine())

        let sessionID = UUID()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(sessionID.uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        FileManager.default.createFile(atPath: temp.appendingPathComponent("mic.raw.caf").path, contents: Data())
        FileManager.default.createFile(atPath: temp.appendingPathComponent("system.raw.caf").path, contents: Data())
        try Data("model".utf8).write(to: temp.appendingPathComponent("asr.bin"))

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
            runtimeProfile: makeRuntimeProfile(asrModelURL: temp.appendingPathComponent("asr.bin"), diarizationModelURL: nil),
            engineFactory: factory
        )

        XCTAssertEqual(result.state, .ready)
        XCTAssertTrue(result.degradedReasons.contains(.emptySystemASR))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent("transcript.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent("transcript.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent("transcript.srt").path))
    }

    func testOneChannelRuntimeFailureOtherUsableProducesTranscript() async throws {
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(asrEngine: SystemFailingASREngine(), diarizationEngine: FailingDiarizationEngine())

        let sessionID = UUID()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(sessionID.uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        FileManager.default.createFile(atPath: temp.appendingPathComponent("mic.raw.caf").path, contents: Data())
        FileManager.default.createFile(atPath: temp.appendingPathComponent("system.raw.caf").path, contents: Data())
        try Data("model".utf8).write(to: temp.appendingPathComponent("asr.bin"))

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
            runtimeProfile: makeRuntimeProfile(asrModelURL: temp.appendingPathComponent("asr.bin"), diarizationModelURL: nil),
            engineFactory: factory
        )

        XCTAssertEqual(result.state, .ready)
        XCTAssertTrue(result.degradedReasons.contains(.systemASRFailedFallbackUsed))
        XCTAssertNotNil(result.transcriptFile)
        XCTAssertNotNil(result.transcriptJSONFile)
    }

    func testBothChannelsUnusableFails() async throws {
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(asrEngine: AllFailingASREngine(), diarizationEngine: FailingDiarizationEngine())

        let sessionID = UUID()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(sessionID.uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        FileManager.default.createFile(atPath: temp.appendingPathComponent("mic.raw.caf").path, contents: Data())
        FileManager.default.createFile(atPath: temp.appendingPathComponent("system.raw.caf").path, contents: Data())
        try Data("model".utf8).write(to: temp.appendingPathComponent("asr.bin"))

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

        await XCTAssertThrowsErrorAsync(
            try await pipeline.process(
                recording: recording,
                in: temp,
                runtimeProfile: makeRuntimeProfile(asrModelURL: temp.appendingPathComponent("asr.bin"), diarizationModelURL: nil),
                engineFactory: factory
            )
        )
    }

    func testDegradedReasonsPersistedInResult() async throws {
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(asrEngine: EmptyBothASREngine(), diarizationEngine: FailingDiarizationEngine())

        let sessionID = UUID()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(sessionID.uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        FileManager.default.createFile(atPath: temp.appendingPathComponent("mic.raw.caf").path, contents: Data())
        FileManager.default.createFile(atPath: temp.appendingPathComponent("system.raw.caf").path, contents: Data())
        try Data("model".utf8).write(to: temp.appendingPathComponent("asr.bin"))
        FileManager.default.createFile(atPath: temp.appendingPathComponent("diarization.bin").path, contents: Data("dmodel".utf8))

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

        XCTAssertEqual(result.state, .ready)
        XCTAssertTrue(result.degradedReasons.contains(.emptyMicASR))
        XCTAssertTrue(result.degradedReasons.contains(.emptySystemASR))
        XCTAssertTrue(result.degradedReasons.contains(.diarizationDegraded))
    }

    func testMicOnlyInputProducesTranscriptWithoutSystemASR() async throws {
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(asrEngine: MockASREngine(), diarizationEngine: FailingDiarizationEngine())

        let sessionID = UUID()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(sessionID.uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        FileManager.default.createFile(atPath: temp.appendingPathComponent("mic.raw.caf").path, contents: Data())
        try Data("model".utf8).write(to: temp.appendingPathComponent("asr.bin"))

        let recording = RecordingSession(
            id: sessionID,
            title: "t",
            createdAt: Date(),
            duration: 10,
            lifecycleState: .ready,
            transcriptState: .queued,
            source: .liveCapture,
            notes: "",
            assets: RecordingAssets(microphoneFile: "mic.raw.caf", systemAudioFile: nil)
        )

        let result = try await pipeline.process(
            recording: recording,
            in: temp,
            runtimeProfile: makeRuntimeProfile(asrModelURL: temp.appendingPathComponent("asr.bin"), diarizationModelURL: nil),
            engineFactory: factory
        )

        XCTAssertEqual(result.state, .ready)
        XCTAssertNotNil(result.micASRJSONFile)
        XCTAssertNil(result.systemASRJSONFile)
        XCTAssertNotNil(result.transcriptFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent("transcript.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent("transcript.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent("transcript.srt").path))
    }

    func testSystemOnlyInputProducesTranscriptWithoutMicASR() async throws {
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(asrEngine: MockASREngine(), diarizationEngine: FailingDiarizationEngine())

        let sessionID = UUID()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(sessionID.uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        FileManager.default.createFile(atPath: temp.appendingPathComponent("system.raw.caf").path, contents: Data())
        try Data("model".utf8).write(to: temp.appendingPathComponent("asr.bin"))

        let recording = RecordingSession(
            id: sessionID,
            title: "t",
            createdAt: Date(),
            duration: 10,
            lifecycleState: .ready,
            transcriptState: .queued,
            source: .liveCapture,
            notes: "",
            assets: RecordingAssets(microphoneFile: nil, systemAudioFile: "system.raw.caf")
        )

        let result = try await pipeline.process(
            recording: recording,
            in: temp,
            runtimeProfile: makeRuntimeProfile(asrModelURL: temp.appendingPathComponent("asr.bin"), diarizationModelURL: nil),
            engineFactory: factory
        )

        XCTAssertEqual(result.state, .ready)
        XCTAssertNil(result.micASRJSONFile)
        XCTAssertNotNil(result.systemASRJSONFile)
        XCTAssertNotNil(result.transcriptFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent("transcript.json").path))
    }

    func testMicFailsSystemSucceedsProducesDegradedTranscript() async throws {
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(asrEngine: MicFailingASREngine(), diarizationEngine: FailingDiarizationEngine())

        let sessionID = UUID()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(sessionID.uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        FileManager.default.createFile(atPath: temp.appendingPathComponent("mic.raw.caf").path, contents: Data())
        FileManager.default.createFile(atPath: temp.appendingPathComponent("system.raw.caf").path, contents: Data())
        try Data("model".utf8).write(to: temp.appendingPathComponent("asr.bin"))

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
            runtimeProfile: makeRuntimeProfile(asrModelURL: temp.appendingPathComponent("asr.bin"), diarizationModelURL: nil),
            engineFactory: factory
        )

        XCTAssertEqual(result.state, .ready)
        XCTAssertTrue(result.degradedReasons.contains(.micASRFailedFallbackUsed))
        XCTAssertNil(result.micASRJSONFile)
        XCTAssertNotNil(result.systemASRJSONFile)
        XCTAssertNotNil(result.transcriptFile)
    }

    func testPipelineProducesAllExpectedArtifacts() async throws {
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(asrEngine: MockASREngine(), diarizationEngine: SuccessfulDiarizationEngine())

        let sessionID = UUID()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(sessionID.uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        FileManager.default.createFile(atPath: temp.appendingPathComponent("mic.raw.caf").path, contents: Data())
        FileManager.default.createFile(atPath: temp.appendingPathComponent("system.raw.caf").path, contents: Data())
        FileManager.default.createFile(atPath: temp.appendingPathComponent("diarization.bin").path, contents: Data("dmodel".utf8))
        try Data("model".utf8).write(to: temp.appendingPathComponent("asr.bin"))

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

        XCTAssertEqual(result.micASRJSONFile, "mic.asr.json")
        XCTAssertEqual(result.systemASRJSONFile, "system.asr.json")
        XCTAssertEqual(result.transcriptJSONFile, "transcript.json")
        XCTAssertEqual(result.transcriptFile, "transcript.txt")
        XCTAssertEqual(result.srtFile, "transcript.srt")
        XCTAssertEqual(result.systemDiarizationJSONFile, "system.diarization.json")

        let expectedFiles = ["mic.asr.json", "system.asr.json", "transcript.json", "transcript.txt", "transcript.srt", "system.diarization.json"]
        for file in expectedFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent(file).path), "Missing artifact: \(file)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let micData = try Data(contentsOf: temp.appendingPathComponent("mic.asr.json"))
        let micDoc = try decoder.decode(ASRDocument.self, from: micData)
        XCTAssertEqual(micDoc.channel, .mic)
        XCTAssertFalse(micDoc.segments.isEmpty)

        let sysData = try Data(contentsOf: temp.appendingPathComponent("system.asr.json"))
        let sysDoc = try decoder.decode(ASRDocument.self, from: sysData)
        XCTAssertEqual(sysDoc.channel, .system)
        XCTAssertFalse(sysDoc.segments.isEmpty)

        let transcriptData = try Data(contentsOf: temp.appendingPathComponent("transcript.json"))
        let transcriptDoc = try decoder.decode(TranscriptDocument.self, from: transcriptData)
        XCTAssertFalse(transcriptDoc.segments.isEmpty)
        XCTAssertTrue(transcriptDoc.diarizationApplied)
    }

    func testPipelineWithFluidAudioBackendUsesFluidFingerprint() async throws {
        let asrEngine = RecordingASREngine()
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(asrEngine: asrEngine, diarizationEngine: FailingDiarizationEngine())

        let sessionID = UUID()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(sessionID.uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        FileManager.default.createFile(atPath: temp.appendingPathComponent("mic.raw.caf").path, contents: Data())
        FileManager.default.createFile(atPath: temp.appendingPathComponent("system.raw.caf").path, contents: Data())
        let model = temp.appendingPathComponent("model.bin")
        try Data("model".utf8).write(to: model)

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

        _ = try await pipeline.process(
            recording: recording,
            in: temp,
            runtimeProfile: makeRuntimeProfile(asrModelURL: model, diarizationModelURL: nil),
            engineFactory: factory
        )

        let micFingerprint = try String(contentsOf: temp.appendingPathComponent("mic.asr.model.txt"), encoding: .utf8)
        XCTAssertFalse(micFingerprint.isEmpty)

        let systemFingerprint = try String(contentsOf: temp.appendingPathComponent("system.asr.model.txt"), encoding: .utf8)
        XCTAssertFalse(systemFingerprint.isEmpty)
    }

    // MARK: - Phase 1 mock engines

    private struct EmptySystemASREngine: ASREngine {
        var displayName: String { "empty-system-mock" }

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
                segments: channel == .system ? [] : [
                    ASRSegment(id: "mic-1", startMs: 0, endMs: 1000, text: "hello", confidence: nil, language: "ru", words: nil)
                ]
            )
        }
    }

    private struct SystemFailingASREngine: ASREngine {
        var displayName: String { "system-failing-mock" }

        func transcribe(
            audioURL: URL,
            channel: TranscriptChannel,
            sessionID: UUID,
            configuration: ASREngineConfiguration
        ) async throws -> ASRDocument {
            if channel == .system {
                throw ASREngineRuntimeError.inferenceFailed(message: "system audio corrupt")
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

    private struct AllFailingASREngine: ASREngine {
        var displayName: String { "all-failing-mock" }

        func transcribe(
            audioURL: URL,
            channel: TranscriptChannel,
            sessionID: UUID,
            configuration: ASREngineConfiguration
        ) async throws -> ASRDocument {
            throw ASREngineRuntimeError.inferenceFailed(message: "\(channel.rawValue) failed")
        }
    }

    private struct MicFailingASREngine: ASREngine {
        var displayName: String { "mic-failing-mock" }

        func transcribe(
            audioURL: URL,
            channel: TranscriptChannel,
            sessionID: UUID,
            configuration: ASREngineConfiguration
        ) async throws -> ASRDocument {
            if channel == .mic {
                throw ASREngineRuntimeError.inferenceFailed(message: "mic audio corrupt")
            }
            return ASRDocument(
                version: 1,
                sessionID: sessionID,
                channel: channel,
                createdAt: Date(),
                segments: [
                    ASRSegment(id: "system-1", startMs: 0, endMs: 1000, text: "hello", confidence: nil, language: "ru", words: nil)
                ]
            )
        }
    }

    private struct EmptyBothASREngine: ASREngine {
        var displayName: String { "empty-both-mock" }

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

    private func makeRuntimeProfile(
        asrModelURL: URL,
        diarizationModelURL: URL?,
    ) -> InferenceRuntimeProfile {
        InferenceRuntimeProfile(
            stageSelection: .defaultLocal,
            modelArtifacts: InferenceModelArtifacts(
                asrModelURL: asrModelURL,
                diarizationModelURL: diarizationModelURL,
                summarizationModelURL: nil
            ),
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
                    message: "ASR backend failed to read the frames of the audio data (Invalid argument)"
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

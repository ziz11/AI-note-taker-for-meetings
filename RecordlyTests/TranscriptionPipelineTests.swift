import XCTest
@testable import Recordly

final class TranscriptionPipelineTests: XCTestCase {
    func testPipelineMicSegmentsPersistExplicitMeRole() async throws {
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(
            asrEngine: ClosureASREngine { channel, sessionID in
                ASRDocument(
                    version: 1,
                    sessionID: sessionID,
                    channel: channel,
                    createdAt: Date(),
                    segments: [
                        ASRSegment(id: "\(channel.rawValue)-1", startMs: 0, endMs: 1000, text: "hello", confidence: nil, language: "ru", words: nil)
                    ]
                )
            },
            diarizationEngine: FailingDiarizationEngine()
        )

        let fixture = try makeFixture(includeMic: true, includeSystem: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await pipeline.process(
            recording: fixture.recording,
            in: fixture.directory,
            runtimeProfile: makeRuntimeProfile(asrModelURL: fixture.asrModelURL, diarizationModelURL: nil),
            engineFactory: factory
        )

        let doc = try decodeTranscriptDocument(in: fixture.directory)
        let micSegment = try XCTUnwrap(doc.segments.first(where: { $0.channel == .mic }))
        XCTAssertEqual(micSegment.speaker, "You")
        XCTAssertEqual(micSegment.speakerRole, .me)
        XCTAssertEqual(micSegment.speakerId, "me")
    }

    func testPipelineSuccessfulDiarizationWritesArtifactAndUsesBestOverlapSpeaker() async throws {
        let pipeline = TranscriptionPipeline(mode: .legacyFullFileDebug)
        let factory = StaticInferenceEngineFactory(
            asrEngine: ClosureASREngine { channel, sessionID in
                switch channel {
                case .mic:
                    return ASRDocument(
                        version: 1,
                        sessionID: sessionID,
                        channel: channel,
                        createdAt: Date(),
                        segments: [
                            ASRSegment(id: "mic-1", startMs: 0, endMs: 800, text: "me", confidence: nil, language: "ru", words: nil)
                        ]
                    )
                case .system:
                    return ASRDocument(
                        version: 1,
                        sessionID: sessionID,
                        channel: channel,
                        createdAt: Date(),
                        segments: [
                            ASRSegment(id: "system-1", startMs: 1000, endMs: 2000, text: "them", confidence: nil, language: "ru", words: nil)
                        ]
                    )
                }
            },
            diarizationEngine: OverlappingDiarizationEngine()
        )

        let fixture = try makeFixture(includeMic: true, includeSystem: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try await pipeline.process(
            recording: fixture.recording,
            in: fixture.directory,
            runtimeProfile: makeRuntimeProfile(asrModelURL: fixture.asrModelURL, diarizationModelURL: fixture.diarizationModelURL),
            engineFactory: factory
        )

        XCTAssertTrue(result.diarizationApplied)
        XCTAssertNil(result.diarizationDegradedReason)
        XCTAssertEqual(result.systemDiarizationJSONFile, "system.diarization.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("system.diarization.json").path))

        let doc = try decodeTranscriptDocument(in: fixture.directory)
        let systemSegment = try XCTUnwrap(doc.segments.first(where: { $0.channel == .system }))
        XCTAssertEqual(systemSegment.speaker, "Speaker 1")
        XCTAssertEqual(systemSegment.speakerRole, .remote)
        XCTAssertEqual(systemSegment.speakerId, "remote_1")
    }

    func testPipelineChunkedSystemPathAggregatesChunkASRAndNormalizesSpeakers() async throws {
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(
            asrEngine: ClosureASREngine { channel, sessionID in
                ASRDocument(
                    version: 1,
                    sessionID: sessionID,
                    channel: channel,
                    createdAt: Date(),
                    segments: [
                        ASRSegment(id: "mic-1", startMs: 0, endMs: 900, text: "me", confidence: nil, language: "ru", words: nil)
                    ]
                )
            },
            diarizationEngine: OverlappingDiarizationEngine(),
            systemChunkEngine: StubSystemChunkTranscriptionEngine { sessionID in
                SystemChunkTranscriptionDocument(
                    version: 1,
                    sessionID: sessionID,
                    createdAt: Date(),
                    segments: [
                        SystemChunkTranscriptSegment(
                            id: "chunk-1",
                            speakerKey: "speaker-b",
                            startMs: 1000,
                            endMs: 1500,
                            text: "first",
                            confidence: 0.91,
                            language: "ru",
                            speakerConfidence: 0.95,
                            words: [
                                ASRWord(word: "first", startMs: 1000, endMs: 1500, confidence: 0.91)
                            ]
                        ),
                        SystemChunkTranscriptSegment(
                            id: "chunk-2",
                            speakerKey: "speaker-a",
                            startMs: 1600,
                            endMs: 2100,
                            text: "second",
                            confidence: 0.87,
                            language: "ru",
                            speakerConfidence: 0.9,
                            words: [
                                ASRWord(word: "second", startMs: 1600, endMs: 2100, confidence: 0.87)
                            ]
                        )
                    ]
                )
            }
        )

        let fixture = try makeFixture(includeMic: true, includeSystem: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try await pipeline.process(
            recording: fixture.recording,
            in: fixture.directory,
            runtimeProfile: makeRuntimeProfile(asrModelURL: fixture.asrModelURL, diarizationModelURL: fixture.diarizationModelURL),
            engineFactory: factory
        )

        XCTAssertEqual(result.systemASRJSONFile, "system.asr.json")
        let systemASR = try decodeASRDocument(
            from: fixture.directory.appendingPathComponent("system.asr.json")
        )
        XCTAssertEqual(systemASR.channel, .system)
        XCTAssertEqual(systemASR.segments.map(\.text), ["first", "second"])

        let doc = try decodeTranscriptDocument(in: fixture.directory)
        let systemSegments = doc.segments.filter { $0.channel == .system }
        XCTAssertEqual(systemSegments.map(\.speaker), ["SPEAKER_01", "SPEAKER_02"])
        XCTAssertEqual(systemSegments.map(\.speakerId), ["remote_1", "remote_2"])
        XCTAssertEqual(systemSegments.map(\.speakerRole), [.remote, .remote])
    }

    func testPipelineDiarizationFailureDegradesToMicOnlyAndKeepsObservability() async throws {
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(
            asrEngine: ClosureASREngine { channel, sessionID in
                ASRDocument(
                    version: 1,
                    sessionID: sessionID,
                    channel: channel,
                    createdAt: Date(),
                    segments: [
                        ASRSegment(id: "\(channel.rawValue)-1", startMs: 0, endMs: 1000, text: "hello", confidence: nil, language: "ru", words: nil)
                    ]
                )
            },
            diarizationEngine: FailingDiarizationEngine()
        )

        let fixture = try makeFixture(includeMic: true, includeSystem: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try await pipeline.process(
            recording: fixture.recording,
            in: fixture.directory,
            runtimeProfile: makeRuntimeProfile(asrModelURL: fixture.asrModelURL, diarizationModelURL: fixture.diarizationModelURL),
            engineFactory: factory
        )

        XCTAssertFalse(result.diarizationApplied)
        XCTAssertNotNil(result.diarizationDegradedReason)
        XCTAssertTrue(result.degradedReasons.contains(.diarizationDegraded))

        let doc = try decodeTranscriptDocument(in: fixture.directory)
        XCTAssertEqual(doc.segments.map(\.channel), [.mic])
    }

    func testPipelineRunsDiarizationWithNilModelURLWhenEngineIsAvailable() async throws {
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(
            asrEngine: ClosureASREngine { channel, sessionID in
                ASRDocument(
                    version: 1,
                    sessionID: sessionID,
                    channel: channel,
                    createdAt: Date(),
                    segments: [
                        ASRSegment(id: "\(channel.rawValue)-1", startMs: 0, endMs: 1000, text: "hello", confidence: nil, language: "ru", words: nil)
                    ]
                )
            },
            diarizationEngine: SimpleDiarizationEngine()
        )

        let fixture = try makeFixture(includeMic: true, includeSystem: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try await pipeline.process(
            recording: fixture.recording,
            in: fixture.directory,
            runtimeProfile: makeRuntimeProfile(asrModelURL: fixture.asrModelURL, diarizationModelURL: nil),
            engineFactory: factory
        )

        XCTAssertTrue(result.diarizationApplied)
        XCTAssertEqual(result.diarizationModelUsed, "sdk-managed")
    }

    func testPipelineSystemASRFailureDegradesToMicOnlyTranscript() async throws {
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(
            asrEngine: ClosureASREngine { channel, sessionID in
                return ASRDocument(
                    version: 1,
                    sessionID: sessionID,
                    channel: channel,
                    createdAt: Date(),
                    segments: [
                        ASRSegment(id: "mic-1", startMs: 0, endMs: 1000, text: "hello", confidence: nil, language: "ru", words: nil)
                    ]
                )
            },
            diarizationEngine: SimpleDiarizationEngine(),
            systemChunkEngine: ThrowingSystemChunkTranscriptionEngine()
        )

        let fixture = try makeFixture(includeMic: true, includeSystem: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try await pipeline.process(
            recording: fixture.recording,
            in: fixture.directory,
            runtimeProfile: makeRuntimeProfile(asrModelURL: fixture.asrModelURL, diarizationModelURL: nil),
            engineFactory: factory
        )

        XCTAssertEqual(result.micASRJSONFile, "mic.asr.json")
        XCTAssertNil(result.systemASRJSONFile)
        XCTAssertTrue(result.degradedReasons.contains(.systemASRFailedFallbackUsed))

        let doc = try decodeTranscriptDocument(in: fixture.directory)
        XCTAssertEqual(doc.segments.map(\.channel), [.mic])
    }

    func testPipelineChunkedSystemModeDoesNotInvokeFullFileSystemASR() async throws {
        let asrEngine = RecordingASREngine { channel, sessionID in
            ASRDocument(
                version: 1,
                sessionID: sessionID,
                channel: channel,
                createdAt: Date(),
                segments: [
                    ASRSegment(id: "\(channel.rawValue)-1", startMs: 0, endMs: 1000, text: channel.rawValue, confidence: nil, language: "ru", words: nil)
                ]
            )
        }
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(
            asrEngine: asrEngine,
            diarizationEngine: SimpleDiarizationEngine(),
            systemChunkEngine: StubSystemChunkTranscriptionEngine { sessionID in
                SystemChunkTranscriptionDocument(
                    version: 1,
                    sessionID: sessionID,
                    createdAt: Date(),
                    segments: [
                        SystemChunkTranscriptSegment(
                            id: "chunk-1",
                            speakerKey: "speaker-a",
                            startMs: 0,
                            endMs: 1000,
                            text: "remote",
                            confidence: 0.8,
                            language: "ru",
                            speakerConfidence: 0.9,
                            words: nil
                        )
                    ]
                )
            }
        )

        let fixture = try makeFixture(includeMic: true, includeSystem: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await pipeline.process(
            recording: fixture.recording,
            in: fixture.directory,
            runtimeProfile: makeRuntimeProfile(asrModelURL: fixture.asrModelURL, diarizationModelURL: fixture.diarizationModelURL),
            engineFactory: factory
        )

        XCTAssertEqual(asrEngine.recordedChannels, [.mic])
    }

    func testPipelineLegacySystemModeUsesFullFileSystemASRAndOverlapAlignment() async throws {
        let asrEngine = RecordingASREngine { channel, sessionID in
            switch channel {
            case .mic:
                return ASRDocument(
                    version: 1,
                    sessionID: sessionID,
                    channel: channel,
                    createdAt: Date(),
                    segments: [
                        ASRSegment(id: "mic-1", startMs: 0, endMs: 1000, text: "me", confidence: nil, language: "ru", words: nil)
                    ]
                )
            case .system:
                return ASRDocument(
                    version: 1,
                    sessionID: sessionID,
                    channel: channel,
                    createdAt: Date(),
                    segments: [
                        ASRSegment(id: "system-1", startMs: 1000, endMs: 2200, text: "them", confidence: nil, language: "ru", words: nil)
                    ]
                )
            }
        }
        let pipeline = TranscriptionPipeline(mode: .legacyFullFileDebug)
        let factory = StaticInferenceEngineFactory(
            asrEngine: asrEngine,
            diarizationEngine: OverlappingDiarizationEngine()
        )

        let fixture = try makeFixture(includeMic: true, includeSystem: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await pipeline.process(
            recording: fixture.recording,
            in: fixture.directory,
            runtimeProfile: makeRuntimeProfile(asrModelURL: fixture.asrModelURL, diarizationModelURL: fixture.diarizationModelURL),
            engineFactory: factory
        )

        XCTAssertEqual(asrEngine.recordedChannels, [.mic, .system])

        let doc = try decodeTranscriptDocument(in: fixture.directory)
        let systemSegment = try XCTUnwrap(doc.segments.first(where: { $0.channel == .system }))
        XCTAssertEqual(systemSegment.speaker, "Speaker 1")
        XCTAssertEqual(systemSegment.speakerId, "remote_1")
    }

    func testMicOnlyInputProducesTranscriptWithoutSystemArtifacts() async throws {
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(
            asrEngine: ClosureASREngine { channel, sessionID in
                ASRDocument(
                    version: 1,
                    sessionID: sessionID,
                    channel: channel,
                    createdAt: Date(),
                    segments: [
                        ASRSegment(id: "\(channel.rawValue)-1", startMs: 0, endMs: 1000, text: "hello", confidence: nil, language: "ru", words: nil)
                    ]
                )
            },
            diarizationEngine: SimpleDiarizationEngine()
        )

        let fixture = try makeFixture(includeMic: true, includeSystem: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try await pipeline.process(
            recording: fixture.recording,
            in: fixture.directory,
            runtimeProfile: makeRuntimeProfile(asrModelURL: fixture.asrModelURL, diarizationModelURL: nil),
            engineFactory: factory
        )

        XCTAssertEqual(result.micASRJSONFile, "mic.asr.json")
        XCTAssertNil(result.systemASRJSONFile)
        XCTAssertNil(result.systemDiarizationJSONFile)
    }

    func testSystemOnlyInputProducesTranscriptWithoutMicASR() async throws {
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(
            asrEngine: ClosureASREngine { channel, sessionID in
                ASRDocument(
                    version: 1,
                    sessionID: sessionID,
                    channel: channel,
                    createdAt: Date(),
                    segments: [
                        ASRSegment(id: "\(channel.rawValue)-1", startMs: 0, endMs: 1000, text: "hello", confidence: nil, language: "ru", words: nil)
                    ]
                )
            },
            diarizationEngine: SimpleDiarizationEngine(),
            systemChunkEngine: StubSystemChunkTranscriptionEngine { sessionID in
                SystemChunkTranscriptionDocument(
                    version: 1,
                    sessionID: sessionID,
                    createdAt: Date(),
                    segments: [
                        SystemChunkTranscriptSegment(
                            id: "chunk-1",
                            speakerKey: "speaker-a",
                            startMs: 0,
                            endMs: 1000,
                            text: "hello",
                            confidence: 0.9,
                            language: "ru",
                            speakerConfidence: 0.9,
                            words: nil
                        )
                    ]
                )
            }
        )

        let fixture = try makeFixture(includeMic: false, includeSystem: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try await pipeline.process(
            recording: fixture.recording,
            in: fixture.directory,
            runtimeProfile: makeRuntimeProfile(asrModelURL: fixture.asrModelURL, diarizationModelURL: nil),
            engineFactory: factory
        )

        XCTAssertNil(result.micASRJSONFile)
        XCTAssertEqual(result.systemASRJSONFile, "system.asr.json")
    }

    func testMicFailureStillFailsWhenSystemSucceeds() async throws {
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(
            asrEngine: ClosureASREngine { channel, sessionID in
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
            },
            diarizationEngine: FailingDiarizationEngine()
        )

        let fixture = try makeFixture(includeMic: true, includeSystem: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        await XCTAssertThrowsErrorAsync(
            try await pipeline.process(
                recording: fixture.recording,
                in: fixture.directory,
                runtimeProfile: makeRuntimeProfile(asrModelURL: fixture.asrModelURL, diarizationModelURL: nil),
                engineFactory: factory
            )
        )
    }

    func testPipelineProducesMinimalArtifactsWithoutStructuredTranscriptOutputs() async throws {
        let pipeline = TranscriptionPipeline()
        let factory = StaticInferenceEngineFactory(
            asrEngine: ClosureASREngine { channel, sessionID in
                ASRDocument(
                    version: 1,
                    sessionID: sessionID,
                    channel: channel,
                    createdAt: Date(),
                    segments: [
                        ASRSegment(id: "\(channel.rawValue)-1", startMs: 0, endMs: 1000, text: "hello", confidence: nil, language: "ru", words: nil)
                    ]
                )
            },
            diarizationEngine: SimpleDiarizationEngine(),
            systemChunkEngine: StubSystemChunkTranscriptionEngine { sessionID in
                SystemChunkTranscriptionDocument(
                    version: 1,
                    sessionID: sessionID,
                    createdAt: Date(),
                    segments: [
                        SystemChunkTranscriptSegment(
                            id: "chunk-1",
                            speakerKey: "speaker-a",
                            startMs: 0,
                            endMs: 1000,
                            text: "remote",
                            confidence: 0.8,
                            language: "ru",
                            speakerConfidence: 0.9,
                            words: nil
                        )
                    ]
                )
            }
        )

        let fixture = try makeFixture(includeMic: true, includeSystem: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try await pipeline.process(
            recording: fixture.recording,
            in: fixture.directory,
            runtimeProfile: makeRuntimeProfile(asrModelURL: fixture.asrModelURL, diarizationModelURL: fixture.diarizationModelURL),
            engineFactory: factory
        )

        XCTAssertEqual(result.transcriptFile, "transcript.txt")
        XCTAssertEqual(result.srtFile, "transcript.srt")
        XCTAssertEqual(result.transcriptJSONFile, "transcript.json")
        XCTAssertEqual(result.micASRJSONFile, "mic.asr.json")
        XCTAssertEqual(result.systemASRJSONFile, "system.asr.json")
        XCTAssertEqual(result.systemDiarizationJSONFile, "system.diarization.json")
        XCTAssertNil(result.structuredTranscriptJSONFile)
        XCTAssertNil(result.structuredTranscriptTextFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("structured-transcript.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("structured-transcript.txt").path))
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

    func testCliDiarizationEngineNilModelURLThrows() async throws {
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

        await XCTAssertThrowsErrorAsync(try await service.diarize(
            systemAudioURL: audioURL,
            sessionID: sessionID,
            configuration: DiarizationEngineConfiguration(modelURL: nil)
        )) { error in
            guard case DiarizationRuntimeError.modelMissing = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    private func makeFixture(includeMic: Bool, includeSystem: Bool) throws -> (directory: URL, recording: RecordingSession, asrModelURL: URL, diarizationModelURL: URL) {
        let sessionID = UUID()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        if includeMic {
            FileManager.default.createFile(atPath: temp.appendingPathComponent("mic.raw.flac").path, contents: Data("mic".utf8))
        }
        if includeSystem {
            FileManager.default.createFile(atPath: temp.appendingPathComponent("system.raw.flac").path, contents: Data("system".utf8))
        }

        let asrModelURL = temp.appendingPathComponent("asr.bin")
        let diarizationModelURL = temp.appendingPathComponent("diarization.bin")
        try Data("asr".utf8).write(to: asrModelURL)
        try Data("diarization".utf8).write(to: diarizationModelURL)

        let recording = RecordingSession(
            id: sessionID,
            title: "test",
            createdAt: Date(),
            duration: 10,
            lifecycleState: .ready,
            transcriptState: .queued,
            source: .liveCapture,
            notes: "",
            assets: RecordingAssets(
                microphoneFile: includeMic ? "mic.raw.flac" : nil,
                systemAudioFile: includeSystem ? "system.raw.flac" : nil
            )
        )

        return (temp, recording, asrModelURL, diarizationModelURL)
    }

    private func decodeTranscriptDocument(in directory: URL) throws -> TranscriptDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: directory.appendingPathComponent("transcript.json"))
        return try decoder.decode(TranscriptDocument.self, from: data)
    }

    private func decodeASRDocument(from url: URL) throws -> ASRDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: url)
        return try decoder.decode(ASRDocument.self, from: data)
    }

    private func makeRuntimeProfile(
        asrModelURL: URL,
        diarizationModelURL: URL?
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

    private struct ClosureASREngine: ASREngine {
        let handler: @Sendable (TranscriptChannel, UUID) throws -> ASRDocument

        var displayName: String { "closure-asr" }

        func transcribe(
            audioURL: URL,
            channel: TranscriptChannel,
            sessionID: UUID,
            configuration: ASREngineConfiguration
        ) async throws -> ASRDocument {
            try handler(channel, sessionID)
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

    private struct SimpleDiarizationEngine: DiarizationEngine {
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
                    DiarizationSegment(id: "d1", speaker: "speaker-a", startMs: 0, endMs: 1000, confidence: 0.9)
                ]
            )
        }
    }

    private struct OverlappingDiarizationEngine: DiarizationEngine {
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
                    DiarizationSegment(id: "d1", speaker: "speaker-a", startMs: 900, endMs: 2100, confidence: 0.9),
                    DiarizationSegment(id: "d2", speaker: "speaker-b", startMs: 1400, endMs: 1700, confidence: 0.95)
                ]
            )
        }
    }

    private struct StaticInferenceEngineFactory: InferenceEngineFactory {
        let asrEngine: any ASREngine
        let diarizationEngine: any DiarizationEngine
        var systemChunkEngine: (any SystemChunkTranscriptionEngine)? = nil

        @MainActor
        func makeAudioCaptureEngine(for profile: InferenceRuntimeProfile) throws -> any AudioCaptureEngine {
            AudioCaptureService()
        }

        func makeASREngine(for profile: InferenceRuntimeProfile) throws -> any ASREngine {
            asrEngine
        }

        @MainActor
        func makeDiarizationEngine(for profile: InferenceRuntimeProfile) throws -> any DiarizationEngine {
            diarizationEngine
        }

        func makeSummarizationEngine(for profile: InferenceRuntimeProfile) throws -> any SummarizationEngine {
            LlamaCppSummarizationEngine()
        }

        func makeVoiceActivityDetectionEngine(for profile: InferenceRuntimeProfile) throws -> (any VoiceActivityDetectionEngine)? {
            nil
        }

        func makeSystemChunkTranscriptionEngine(for profile: InferenceRuntimeProfile) throws -> (any SystemChunkTranscriptionEngine)? {
            systemChunkEngine
        }
    }

    private final class RecordingASREngine: ASREngine, @unchecked Sendable {
        let handler: @Sendable (TranscriptChannel, UUID) throws -> ASRDocument
        private(set) var recordedChannels: [TranscriptChannel] = []

        init(handler: @escaping @Sendable (TranscriptChannel, UUID) throws -> ASRDocument) {
            self.handler = handler
        }

        var displayName: String { "recording-asr" }

        func transcribe(
            audioURL: URL,
            channel: TranscriptChannel,
            sessionID: UUID,
            configuration: ASREngineConfiguration
        ) async throws -> ASRDocument {
            recordedChannels.append(channel)
            return try handler(channel, sessionID)
        }
    }

    private struct StubSystemChunkTranscriptionEngine: SystemChunkTranscriptionEngine {
        let handler: @Sendable (UUID) throws -> SystemChunkTranscriptionDocument

        func transcribeSystemChunks(
            systemAudioURL: URL,
            diarization: DiarizationDocument,
            sessionID: UUID,
            configuration: ASREngineConfiguration
        ) async throws -> SystemChunkTranscriptionDocument {
            try handler(sessionID)
        }
    }

    private struct ThrowingSystemChunkTranscriptionEngine: SystemChunkTranscriptionEngine {
        func transcribeSystemChunks(
            systemAudioURL: URL,
            diarization: DiarizationDocument,
            sessionID: UUID,
            configuration: ASREngineConfiguration
        ) async throws -> SystemChunkTranscriptionDocument {
            throw ASREngineRuntimeError.inferenceFailed(message: "system chunk transcription failed")
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

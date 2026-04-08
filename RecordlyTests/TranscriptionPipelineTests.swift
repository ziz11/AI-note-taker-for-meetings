import AVFoundation
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
        XCTAssertEqual(
            asrEngine.recordedAudioFileNames,
            ["mic.raw.flac", "system.raw.flac"]
        )

        let doc = try decodeTranscriptDocument(in: fixture.directory)
        let systemSegment = try XCTUnwrap(doc.segments.first(where: { $0.channel == .system }))
        XCTAssertEqual(systemSegment.speaker, "Speaker 1")
        XCTAssertEqual(systemSegment.speakerId, "remote_1")
    }

    func testLiveCaptureImmediatePathPrefersCAFSourceTracksOverDurableM4A() async throws {
        let asrEngine = RecordingASREngine { channel, sessionID in
            ASRDocument(
                version: 1,
                sessionID: sessionID,
                channel: channel,
                createdAt: Date(),
                segments: [
                    ASRSegment(id: "\(channel.rawValue)-1", startMs: 0, endMs: 1000, text: channel.rawValue, confidence: nil, language: "en", words: nil)
                ]
            )
        }
        let pipeline = TranscriptionPipeline(mode: .legacyFullFileDebug)
        let factory = StaticInferenceEngineFactory(
            asrEngine: asrEngine,
            diarizationEngine: SimpleDiarizationEngine()
        )

        let fixture = try makeLiveCaptureSelectionFixture(
            microphoneAsset: "mic.m4a",
            systemAsset: "system.m4a",
            files: [
                "mic.raw.caf": "mic-caf",
                "system.raw.caf": "system-caf",
                "mic.m4a": "mic-m4a",
                "system.m4a": "system-m4a"
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await pipeline.process(
            recording: fixture.recording,
            in: fixture.directory,
            runtimeProfile: makeRuntimeProfile(asrModelURL: fixture.asrModelURL, diarizationModelURL: fixture.diarizationModelURL),
            engineFactory: factory
        )

        XCTAssertEqual(
            asrEngine.recordedAudioFileNames,
            ["mic.raw.caf", "system.raw.caf"]
        )
    }

    func testLiveCaptureRecoveryFallsBackToDurableM4AWhenCAFSourceTracksMissing() async throws {
        let asrEngine = RecordingASREngine { channel, sessionID in
            ASRDocument(
                version: 1,
                sessionID: sessionID,
                channel: channel,
                createdAt: Date(),
                segments: [
                    ASRSegment(id: "\(channel.rawValue)-1", startMs: 0, endMs: 1000, text: channel.rawValue, confidence: nil, language: "en", words: nil)
                ]
            )
        }
        let pipeline = TranscriptionPipeline(mode: .legacyFullFileDebug)
        let factory = StaticInferenceEngineFactory(
            asrEngine: asrEngine,
            diarizationEngine: SimpleDiarizationEngine()
        )

        let fixture = try makeLiveCaptureSelectionFixture(
            microphoneAsset: "mic.m4a",
            systemAsset: "system.m4a",
            files: [
                "mic.m4a": "mic-m4a",
                "system.m4a": "system-m4a"
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await pipeline.process(
            recording: fixture.recording,
            in: fixture.directory,
            runtimeProfile: makeRuntimeProfile(asrModelURL: fixture.asrModelURL, diarizationModelURL: fixture.diarizationModelURL),
            engineFactory: factory
        )

        XCTAssertEqual(
            asrEngine.recordedAudioFileNames,
            ["mic.m4a", "system.m4a"]
        )
    }

    func testLiveCaptureSourceSelectionNeverUsesMergedPlaybackTrackWhenSourceTracksExist() async throws {
        let asrEngine = RecordingASREngine { channel, sessionID in
            ASRDocument(
                version: 1,
                sessionID: sessionID,
                channel: channel,
                createdAt: Date(),
                segments: [
                    ASRSegment(id: "\(channel.rawValue)-1", startMs: 0, endMs: 1000, text: channel.rawValue, confidence: nil, language: "en", words: nil)
                ]
            )
        }
        let pipeline = TranscriptionPipeline(mode: .legacyFullFileDebug)
        let factory = StaticInferenceEngineFactory(
            asrEngine: asrEngine,
            diarizationEngine: SimpleDiarizationEngine()
        )

        let fixture = try makeLiveCaptureSelectionFixture(
            microphoneAsset: "mic.m4a",
            systemAsset: "merged-call.m4a",
            files: [
                "mic.raw.caf": "mic-caf",
                "system.raw.caf": "system-caf",
                "mic.m4a": "mic-m4a",
                "system.m4a": "system-m4a",
                "merged-call.m4a": "mixed"
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await pipeline.process(
            recording: fixture.recording,
            in: fixture.directory,
            runtimeProfile: makeRuntimeProfile(asrModelURL: fixture.asrModelURL, diarizationModelURL: fixture.diarizationModelURL),
            engineFactory: factory
        )

        XCTAssertEqual(
            asrEngine.recordedAudioFileNames,
            ["mic.raw.caf", "system.raw.caf"]
        )
        XCTAssertFalse(asrEngine.recordedAudioFileNames.contains("merged-call.m4a"))
    }

    func testRecordingSessionPersistsTranscriptionAudioProvenance() throws {
        let session = RecordingSession(
            id: UUID(),
            title: "provenance",
            createdAt: Date(),
            duration: 10,
            lifecycleState: .ready,
            transcriptState: .ready,
            source: .liveCapture,
            notes: "",
            assets: RecordingAssets(
                microphoneFile: "mic.m4a",
                systemAudioFile: "system.m4a",
                transcriptionAudioProvenance: .m4aRecovery
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RecordingSession.self, from: data)

        XCTAssertEqual(decoded.assets.transcriptionAudioProvenance, .m4aRecovery)
    }

    func testPCMTrackWriterUsesAACSettingsForDurableM4A() throws {
        let settings = PCMTrackWriter.fileSettings(
            for: URL(filePath: "/tmp/mic.m4a")
        )

        XCTAssertEqual(settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        XCTAssertEqual(settings[AVSampleRateKey] as? Double, PCMTrackWriter.canonicalSampleRate)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, Int(PCMTrackWriter.canonicalChannels))
        XCTAssertEqual(settings[AVEncoderBitRateKey] as? Int, 96_000)
    }

    func testMirroredTrackWriterCreatesTemporaryCAFAndDurableM4A() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var writer: MirroredTrackWriter? = try MirroredTrackWriter(
            temporary: PCMTrackWriter(
                kind: .microphone,
                fileName: "mic.raw.caf",
                fileURL: directory.appendingPathComponent("mic.raw.caf")
            ),
            durable: PCMTrackWriter(
                kind: .microphone,
                fileName: "mic.m4a",
                fileURL: directory.appendingPathComponent("mic.m4a")
            )
        )

        try await writer?.append(pcmBuffer: makeCapturePCMBuffer(frameCount: 4_800))
        let stats = await writer?.finalize() ?? []
        writer = nil

        XCTAssertEqual(stats.map(\.fileName), ["mic.raw.caf", "mic.m4a"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("mic.raw.caf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("mic.m4a").path))
        XCTAssertNoThrow(try AVAudioFile(forReading: directory.appendingPathComponent("mic.raw.caf")))
        XCTAssertNoThrow(try AVAudioFile(forReading: directory.appendingPathComponent("mic.m4a")))
    }

    @MainActor
    func testWorkflowRetainsTemporaryCAFDuringProcessingAndCleansThemAfterReady() async throws {
        let asrEngine = RecordingASREngine { channel, sessionID in
            ASRDocument(
                version: 1,
                sessionID: sessionID,
                channel: channel,
                createdAt: Date(),
                segments: [
                    ASRSegment(id: "\(channel.rawValue)-1", startMs: 0, endMs: 1_000, text: channel.rawValue, confidence: nil, language: "en", words: nil)
                ]
            )
        }
        let fixture = try makeLiveCaptureSelectionFixture(
            microphoneAsset: "mic.m4a",
            systemAsset: "system.m4a",
            files: [
                "mic.raw.caf": "mic-caf",
                "system.raw.caf": "system-caf",
                "mic.m4a": "mic-m4a",
                "system.m4a": "system-m4a"
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let repository = InMemoryRecordingsRepository(
            recordings: [fixture.recording],
            sessionDirectories: [fixture.recording.id: fixture.directory]
        )
        let controller = RecordingWorkflowController(
            audioCaptureEngine: UnusedAudioCaptureEngine(),
            transcriptionPipeline: TranscriptionPipeline(mode: .legacyFullFileDebug),
            runtimeProfileSelector: WorkflowRuntimeProfileSelector(
                transcriptionProfile: makeRuntimeProfile(
                    asrModelURL: fixture.asrModelURL,
                    diarizationModelURL: fixture.diarizationModelURL
                )
            ),
            inferenceEngineFactory: StaticInferenceEngineFactory(
                asrEngine: asrEngine,
                diarizationEngine: SimpleDiarizationEngine()
            ),
            repository: repository
        )

        let micRawURL = fixture.directory.appendingPathComponent("mic.raw.caf")
        let systemRawURL = fixture.directory.appendingPathComponent("system.raw.caf")
        var observedPreTerminalState = false

        let updated = try await controller.transcribe(recording: fixture.recording) { state in
            guard state != .ready, state != .failed else { return }
            observedPreTerminalState = true
            XCTAssertTrue(FileManager.default.fileExists(atPath: micRawURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: systemRawURL.path))
        }

        XCTAssertTrue(observedPreTerminalState)
        XCTAssertFalse(FileManager.default.fileExists(atPath: micRawURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemRawURL.path))
        XCTAssertEqual(updated.assets.transcriptionAudioProvenance, .cafPcmFastPath)
    }

    @MainActor
    func testWorkflowCleansTemporaryCAFAfterFailedTranscription() async throws {
        let fixture = try makeLiveCaptureSelectionFixture(
            microphoneAsset: "mic.m4a",
            systemAsset: "system.m4a",
            files: [
                "mic.raw.caf": "mic-caf",
                "system.raw.caf": "system-caf",
                "mic.m4a": "mic-m4a",
                "system.m4a": "system-m4a"
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let repository = InMemoryRecordingsRepository(
            recordings: [fixture.recording],
            sessionDirectories: [fixture.recording.id: fixture.directory]
        )
        let controller = RecordingWorkflowController(
            audioCaptureEngine: UnusedAudioCaptureEngine(),
            transcriptionPipeline: TranscriptionPipeline(mode: .legacyFullFileDebug),
            runtimeProfileSelector: WorkflowRuntimeProfileSelector(
                transcriptionProfile: makeRuntimeProfile(
                    asrModelURL: fixture.asrModelURL,
                    diarizationModelURL: fixture.diarizationModelURL
                )
            ),
            inferenceEngineFactory: StaticInferenceEngineFactory(
                asrEngine: ClosureASREngine { _, _ in
                    throw ASREngineRuntimeError.inferenceFailed(message: "boom")
                },
                diarizationEngine: SimpleDiarizationEngine()
            ),
            repository: repository
        )

        let micRawURL = fixture.directory.appendingPathComponent("mic.raw.caf")
        let systemRawURL = fixture.directory.appendingPathComponent("system.raw.caf")
        var observedPreTerminalState = false

        await XCTAssertThrowsErrorAsync(
            try await controller.transcribe(recording: fixture.recording) { state in
                guard state != .ready, state != .failed else { return }
                observedPreTerminalState = true
                XCTAssertTrue(FileManager.default.fileExists(atPath: micRawURL.path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: systemRawURL.path))
            }
        )

        XCTAssertTrue(observedPreTerminalState)
        XCTAssertFalse(FileManager.default.fileExists(atPath: micRawURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemRawURL.path))
        XCTAssertEqual(repository.recordings.first?.transcriptState, .failed)
    }

    @MainActor
    func testManualRetranscriptionAfterTemporaryCleanupUsesDurableM4AFiles() async throws {
        let sessionID = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeAudioFile(
            named: "mic.m4a",
            in: directory,
            sampleRate: PCMTrackWriter.canonicalSampleRate,
            channels: PCMTrackWriter.canonicalChannels
        )
        try writeAudioFile(
            named: "system.m4a",
            in: directory,
            sampleRate: PCMTrackWriter.canonicalSampleRate,
            channels: PCMTrackWriter.canonicalChannels
        )

        let asrModelURL = directory.appendingPathComponent("asr.bin")
        let diarizationModelURL = directory.appendingPathComponent("diarization.bin")
        try Data("asr".utf8).write(to: asrModelURL)
        try Data("diarization".utf8).write(to: diarizationModelURL)

        let recording = RecordingSession(
            id: sessionID,
            title: "cleanup-retranscribe",
            createdAt: Date(),
            duration: 10,
            lifecycleState: .ready,
            transcriptState: .idle,
            source: .liveCapture,
            notes: "",
            assets: RecordingAssets(
                microphoneFile: "mic.m4a",
                systemAudioFile: "system.m4a"
            )
        )
        let repository = InMemoryRecordingsRepository(
            recordings: [recording],
            sessionDirectories: [recording.id: directory]
        )
        let asrEngine = DecodingRecordingASREngine()
        let systemChunkEngine = DecodingSystemChunkEngine()
        let controller = RecordingWorkflowController(
            audioCaptureEngine: UnusedAudioCaptureEngine(),
            transcriptionPipeline: TranscriptionPipeline(),
            runtimeProfileSelector: WorkflowRuntimeProfileSelector(
                transcriptionProfile: makeRuntimeProfile(
                    asrModelURL: asrModelURL,
                    diarizationModelURL: diarizationModelURL
                )
            ),
            inferenceEngineFactory: StaticInferenceEngineFactory(
                asrEngine: asrEngine,
                diarizationEngine: SimpleDiarizationEngine(),
                systemChunkEngine: systemChunkEngine
            ),
            repository: repository
        )

        let updated = try await controller.transcribe(recording: recording)

        XCTAssertEqual(asrEngine.recordedAudioFileNames, ["mic.m4a"])
        XCTAssertEqual(systemChunkEngine.recordedAudioFileNames, ["system.m4a"])
        XCTAssertEqual(updated.assets.transcriptionAudioProvenance, .m4aRecovery)
        XCTAssertEqual(updated.transcriptState, .ready)
    }

    @MainActor
    func testManualRetranscriptionSkipsUnreadableTemporaryCAFAndFallsBackToDurableM4A() async throws {
        let sessionID = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("corrupt".utf8).write(to: directory.appendingPathComponent("mic.raw.caf"))
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent("system.raw.caf"))
        try writeAudioFile(
            named: "mic.m4a",
            in: directory,
            sampleRate: PCMTrackWriter.canonicalSampleRate,
            channels: PCMTrackWriter.canonicalChannels
        )
        try writeAudioFile(
            named: "system.m4a",
            in: directory,
            sampleRate: PCMTrackWriter.canonicalSampleRate,
            channels: PCMTrackWriter.canonicalChannels
        )

        let asrModelURL = directory.appendingPathComponent("asr.bin")
        let diarizationModelURL = directory.appendingPathComponent("diarization.bin")
        try Data("asr".utf8).write(to: asrModelURL)
        try Data("diarization".utf8).write(to: diarizationModelURL)

        let recording = RecordingSession(
            id: sessionID,
            title: "caf-fallback",
            createdAt: Date(),
            duration: 10,
            lifecycleState: .ready,
            transcriptState: .idle,
            source: .liveCapture,
            notes: "",
            assets: RecordingAssets(
                microphoneFile: "mic.m4a",
                systemAudioFile: "system.m4a"
            )
        )
        let repository = InMemoryRecordingsRepository(
            recordings: [recording],
            sessionDirectories: [recording.id: directory]
        )
        let asrEngine = DecodingRecordingASREngine()
        let systemChunkEngine = DecodingSystemChunkEngine()
        let controller = RecordingWorkflowController(
            audioCaptureEngine: UnusedAudioCaptureEngine(),
            transcriptionPipeline: TranscriptionPipeline(),
            runtimeProfileSelector: WorkflowRuntimeProfileSelector(
                transcriptionProfile: makeRuntimeProfile(
                    asrModelURL: asrModelURL,
                    diarizationModelURL: diarizationModelURL
                )
            ),
            inferenceEngineFactory: StaticInferenceEngineFactory(
                asrEngine: asrEngine,
                diarizationEngine: SimpleDiarizationEngine(),
                systemChunkEngine: systemChunkEngine
            ),
            repository: repository
        )

        let updated = try await controller.transcribe(recording: recording)

        XCTAssertEqual(asrEngine.recordedAudioFileNames, ["mic.m4a"])
        XCTAssertEqual(systemChunkEngine.recordedAudioFileNames, ["system.m4a"])
        XCTAssertEqual(updated.assets.transcriptionAudioProvenance, .m4aRecovery)
        XCTAssertEqual(updated.transcriptState, .ready)
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

    func testTranscriptRenderSplitsMicSegmentIntoMultipleTimestampedLinesUsingWordTimings() {
        let service = TranscriptRenderService()
        let sessionID = UUID()
        let document = TranscriptDocument(
            version: 1,
            sessionID: sessionID,
            createdAt: Date(),
            channelsPresent: [.mic],
            diarizationApplied: false,
            mergePolicy: .deterministicStartEndChannelID,
            segments: [
                TranscriptSegment(
                    id: "mic-1",
                    channel: .mic,
                    speaker: "You",
                    speakerRole: .me,
                    speakerId: "me",
                    startMs: 12_000,
                    endMs: 55_280,
                    text: "Hello there. This is a second sentence.",
                    confidence: 0.95,
                    language: "en",
                    speakerConfidence: nil,
                    words: [
                        ASRWord(word: "Hello", startMs: 12_000, endMs: 12_400, confidence: 0.9),
                        ASRWord(word: "there.", startMs: 12_450, endMs: 13_100, confidence: 0.9),
                        ASRWord(word: "This", startMs: 13_900, endMs: 14_200, confidence: 0.9),
                        ASRWord(word: "is", startMs: 14_250, endMs: 14_450, confidence: 0.9),
                        ASRWord(word: "a", startMs: 14_500, endMs: 14_600, confidence: 0.9),
                        ASRWord(word: "second", startMs: 14_650, endMs: 15_050, confidence: 0.9),
                        ASRWord(word: "sentence.", startMs: 15_100, endMs: 15_700, confidence: 0.9)
                    ]
                )
            ]
        )

        let rendered = service.render(document: document)

        XCTAssertEqual(
            rendered.transcriptText,
            """
            [00:12 - 00:13] [You] Hello there.
            [00:13 - 00:15] [You] This is a second sentence.
            """
        )
        XCTAssertEqual(
            rendered.srtText,
            """
            1
            00:00:12,000 --> 00:00:13,100
            [You] Hello there.

            2
            00:00:13,900 --> 00:00:15,700
            [You] This is a second sentence.
            """
        )
    }

    func testTranscriptRenderFallsBackToSegmentTextWhenWordTokensLookSyllabified() {
        let service = TranscriptRenderService()
        let sessionID = UUID()
        let document = TranscriptDocument(
            version: 1,
            sessionID: sessionID,
            createdAt: Date(),
            channelsPresent: [.system],
            diarizationApplied: true,
            mergePolicy: .deterministicStartEndChannelID,
            segments: [
                TranscriptSegment(
                    id: "system-ru-1",
                    channel: .system,
                    speaker: "Speaker 1",
                    speakerRole: .remote,
                    speakerId: "remote_1",
                    startMs: 3_035_229,
                    endMs: 3_045_389,
                    text: "Ну, типа, вначале сказал про это, что типа эти муж тогда что делают с улучшением качества бы. Это как будто против того, что он выделок пойдет",
                    confidence: 0.95,
                    language: "ru",
                    speakerConfidence: 0.8,
                    words: [
                        ASRWord(word: "Ну", startMs: 3_035_229, endMs: 3_035_349, confidence: 0.9),
                        ASRWord(word: "ти", startMs: 3_035_349, endMs: 3_035_469, confidence: 0.9),
                        ASRWord(word: "па", startMs: 3_035_469, endMs: 3_035_589, confidence: 0.9),
                        ASRWord(word: "в", startMs: 3_035_589, endMs: 3_035_649, confidence: 0.9),
                        ASRWord(word: "на", startMs: 3_035_649, endMs: 3_035_769, confidence: 0.9),
                        ASRWord(word: "ча", startMs: 3_035_769, endMs: 3_035_889, confidence: 0.9),
                        ASRWord(word: "ле", startMs: 3_035_889, endMs: 3_036_009, confidence: 0.9),
                        ASRWord(word: "сказа", startMs: 3_036_009, endMs: 3_036_249, confidence: 0.9),
                        ASRWord(word: "л", startMs: 3_036_249, endMs: 3_036_309, confidence: 0.9),
                        ASRWord(word: "про", startMs: 3_036_309, endMs: 3_036_429, confidence: 0.9),
                        ASRWord(word: "это", startMs: 3_036_429, endMs: 3_036_609, confidence: 0.9),
                        ASRWord(word: "что", startMs: 3_036_609, endMs: 3_036_729, confidence: 0.9),
                        ASRWord(word: "ти", startMs: 3_036_729, endMs: 3_036_849, confidence: 0.9),
                        ASRWord(word: "па", startMs: 3_036_849, endMs: 3_036_969, confidence: 0.9),
                        ASRWord(word: "эти", startMs: 3_036_969, endMs: 3_037_149, confidence: 0.9),
                        ASRWord(word: "му", startMs: 3_037_149, endMs: 3_037_269, confidence: 0.9),
                        ASRWord(word: "ж", startMs: 3_037_269, endMs: 3_037_329, confidence: 0.9),
                        ASRWord(word: "то", startMs: 3_037_329, endMs: 3_037_449, confidence: 0.9),
                        ASRWord(word: "гда", startMs: 3_037_449, endMs: 3_037_629, confidence: 0.9),
                        ASRWord(word: "что", startMs: 3_037_629, endMs: 3_037_749, confidence: 0.9),
                        ASRWord(word: "дела", startMs: 3_037_749, endMs: 3_037_989, confidence: 0.9),
                        ASRWord(word: "ют", startMs: 3_037_989, endMs: 3_038_109, confidence: 0.9),
                        ASRWord(word: "с", startMs: 3_038_109, endMs: 3_038_169, confidence: 0.9),
                        ASRWord(word: "у", startMs: 3_038_169, endMs: 3_038_229, confidence: 0.9),
                        ASRWord(word: "лу", startMs: 3_038_229, endMs: 3_038_349, confidence: 0.9),
                        ASRWord(word: "ч", startMs: 3_038_349, endMs: 3_038_409, confidence: 0.9),
                        ASRWord(word: "шение", startMs: 3_038_409, endMs: 3_038_709, confidence: 0.9),
                        ASRWord(word: "м", startMs: 3_038_709, endMs: 3_038_769, confidence: 0.9),
                        ASRWord(word: "ка", startMs: 3_038_769, endMs: 3_038_889, confidence: 0.9),
                        ASRWord(word: "че", startMs: 3_038_889, endMs: 3_039_009, confidence: 0.9),
                        ASRWord(word: "ства", startMs: 3_039_009, endMs: 3_039_249, confidence: 0.9),
                        ASRWord(word: "бы", startMs: 3_039_249, endMs: 3_039_369, confidence: 0.9),
                        ASRWord(word: "Это", startMs: 3_039_369, endMs: 3_039_549, confidence: 0.9),
                        ASRWord(word: "как", startMs: 3_039_549, endMs: 3_039_729, confidence: 0.9),
                        ASRWord(word: "бу", startMs: 3_039_729, endMs: 3_039_849, confidence: 0.9),
                        ASRWord(word: "д", startMs: 3_039_849, endMs: 3_039_909, confidence: 0.9),
                        ASRWord(word: "то", startMs: 3_039_909, endMs: 3_040_029, confidence: 0.9),
                        ASRWord(word: "про", startMs: 3_040_029, endMs: 3_040_149, confidence: 0.9),
                        ASRWord(word: "тив", startMs: 3_040_149, endMs: 3_040_329, confidence: 0.9),
                        ASRWord(word: "того", startMs: 3_040_329, endMs: 3_040_569, confidence: 0.9),
                        ASRWord(word: "что", startMs: 3_040_569, endMs: 3_040_689, confidence: 0.9),
                        ASRWord(word: "он", startMs: 3_040_689, endMs: 3_040_809, confidence: 0.9),
                        ASRWord(word: "вы", startMs: 3_040_809, endMs: 3_040_929, confidence: 0.9),
                        ASRWord(word: "де", startMs: 3_040_929, endMs: 3_041_049, confidence: 0.9),
                        ASRWord(word: "ло", startMs: 3_041_049, endMs: 3_041_169, confidence: 0.9),
                        ASRWord(word: "к", startMs: 3_041_169, endMs: 3_041_229, confidence: 0.9),
                        ASRWord(word: "по", startMs: 3_041_229, endMs: 3_041_349, confidence: 0.9),
                        ASRWord(word: "й", startMs: 3_041_349, endMs: 3_041_409, confidence: 0.9),
                        ASRWord(word: "де", startMs: 3_041_409, endMs: 3_041_529, confidence: 0.9),
                        ASRWord(word: "т", startMs: 3_041_529, endMs: 3_041_589, confidence: 0.9)
                    ]
                )
            ]
        )

        let rendered = service.render(document: document)

        XCTAssertEqual(
            rendered.transcriptText,
            """
            [50:35 - 50:45] [Speaker 1] Ну, типа, вначале сказал про это, что типа эти муж тогда что делают с улучшением качества бы. Это как будто против того, что он выделок пойдет
            """
        )
        XCTAssertEqual(
            rendered.srtText,
            """
            1
            00:50:35,229 --> 00:50:45,389
            [Speaker 1] Ну, типа, вначале сказал про это, что типа эти муж тогда что делают с улучшением качества бы. Это как будто против того, что он выделок пойдет
            """
        )
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

    private func makeLiveCaptureSelectionFixture(
        microphoneAsset: String?,
        systemAsset: String?,
        files: [String: String]
    ) throws -> (directory: URL, recording: RecordingSession, asrModelURL: URL, diarizationModelURL: URL) {
        let sessionID = UUID()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        for (name, contents) in files {
            let fileURL = temp.appendingPathComponent(name)
            if name.hasSuffix(".raw.caf") || name.hasSuffix(".m4a") {
                try writeAudioFile(
                    named: name,
                    in: temp,
                    sampleRate: PCMTrackWriter.canonicalSampleRate,
                    channels: PCMTrackWriter.canonicalChannels
                )
            } else {
                FileManager.default.createFile(
                    atPath: fileURL.path,
                    contents: Data(contents.utf8)
                )
            }
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
                microphoneFile: microphoneAsset,
                systemAudioFile: systemAsset,
                mergedCallFile: files.keys.contains("merged-call.m4a") ? "merged-call.m4a" : nil
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

    private func makeCapturePCMBuffer(frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: PCMTrackWriter.canonicalSampleRate,
                channels: PCMTrackWriter.canonicalChannels,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount

        if let channel = buffer.floatChannelData?[0] {
            for index in 0 ..< Int(frameCount) {
                channel[index] = sin(Float(index) * 0.01)
            }
        }

        return buffer
    }

    private func writeAudioFile(
        named fileName: String,
        in directory: URL,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        frameCount: AVAudioFrameCount = 48_000
    ) throws {
        let url = directory.appendingPathComponent(fileName)
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount

        if let channel = buffer.floatChannelData?[0] {
            for index in 0 ..< Int(frameCount) {
                channel[index] = sin(Float(index) * 0.01)
            }
        }

        let audioFile = try AVAudioFile(
            forWriting: url,
            settings: PCMTrackWriter.fileSettings(for: url),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try audioFile.write(from: buffer)
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

    @MainActor
    private struct WorkflowRuntimeProfileSelector: InferenceRuntimeProfileSelecting {
        let transcriptionProfile: InferenceRuntimeProfile

        func transcriptionAvailability(for profile: ModelProfile) -> TranscriptionAvailability {
            .ready
        }

        func resolveTranscriptionProfile(for profile: ModelProfile) throws -> InferenceRuntimeProfile {
            transcriptionProfile
        }

        func resolveSummarizationProfile(for profile: ModelProfile) throws -> InferenceRuntimeProfile {
            transcriptionProfile
        }
    }

    @MainActor
    private final class UnusedAudioCaptureEngine: AudioCaptureEngine {
        var systemAudioStatusLabel: String { "Captured" }

        func startCapture(in sessionDirectory: URL) async throws -> CaptureArtifacts {
            XCTFail("startCapture should not be called in transcription cleanup tests")
            return CaptureArtifacts()
        }

        func stopCapture() async throws -> CaptureArtifacts {
            XCTFail("stopCapture should not be called in transcription cleanup tests")
            return CaptureArtifacts()
        }

        func currentMicrophoneLevel() -> Double { 0 }
        func currentSystemAudioLevel() -> Double { 0 }
        func recoverPendingSessions(in recordingsDirectory: URL) async {}
    }

    private final class RecordingASREngine: ASREngine, @unchecked Sendable {
        let handler: @Sendable (TranscriptChannel, UUID) throws -> ASRDocument
        private(set) var recordedChannels: [TranscriptChannel] = []
        private(set) var recordedAudioFileNames: [String] = []

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
            recordedAudioFileNames.append(audioURL.lastPathComponent)
            return try handler(channel, sessionID)
        }
    }

    private final class DecodingRecordingASREngine: ASREngine, @unchecked Sendable {
        private let loader = FluidAudioSessionAudioLoader()
        private(set) var recordedAudioFileNames: [String] = []

        var displayName: String { "decoding-recording-asr" }

        func transcribe(
            audioURL: URL,
            channel: TranscriptChannel,
            sessionID: UUID,
            configuration: ASREngineConfiguration
        ) async throws -> ASRDocument {
            _ = try loader.loadAudio(from: audioURL)
            recordedAudioFileNames.append(audioURL.lastPathComponent)
            return ASRDocument(
                version: 1,
                sessionID: sessionID,
                channel: channel,
                createdAt: Date(),
                segments: [
                    ASRSegment(
                        id: "\(channel.rawValue)-1",
                        startMs: 0,
                        endMs: 1_000,
                        text: channel.rawValue,
                        confidence: nil,
                        language: "en",
                        words: nil
                    )
                ]
            )
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

    private final class DecodingSystemChunkEngine: SystemChunkTranscriptionEngine, @unchecked Sendable {
        private let loader = FluidAudioSessionAudioLoader()
        private(set) var recordedAudioFileNames: [String] = []

        func transcribeSystemChunks(
            systemAudioURL: URL,
            diarization: DiarizationDocument,
            sessionID: UUID,
            configuration: ASREngineConfiguration
        ) async throws -> SystemChunkTranscriptionDocument {
            _ = try loader.loadAudio(from: systemAudioURL)
            recordedAudioFileNames.append(systemAudioURL.lastPathComponent)
            return SystemChunkTranscriptionDocument(
                version: 1,
                sessionID: sessionID,
                createdAt: Date(),
                segments: [
                    SystemChunkTranscriptSegment(
                        id: "system-1",
                        speakerKey: diarization.segments.first?.speaker ?? "speaker-a",
                        startMs: 0,
                        endMs: 1_000,
                        text: "system",
                        confidence: nil,
                        language: "en",
                        speakerConfidence: diarization.segments.first?.confidence,
                        words: nil
                    )
                ]
            )
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

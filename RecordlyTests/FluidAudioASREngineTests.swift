import AVFoundation
import XCTest
@testable import Recordly

final class FluidAudioASREngineTests: XCTestCase {
    private var tempDirectory: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        suite = "Recordly.UltraTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FluidAudioASREngineTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        tempDirectory = nil
    }

    @MainActor
    func testProviderDefaultsToUltraWhenBothModelsAreInstalled() throws {
        _ = try createFluidModelDirectory(named: "parakeet-tdt-0.6b-v3")
        let ultra = try createFluidModelDirectory(named: "parakeet-ultra")
        let provider = FluidAudioASRModelProvider(modelsRoot: { self.tempDirectory }, defaults: defaults)
        XCTAssertEqual(try provider.resolveForRuntime().resolvingSymlinksInPath(), ultra.resolvingSymlinksInPath())
    }

    func testCacheFingerprintIdentifiesUltraRatherThanV3() throws {
        let ultra = try createFluidModelDirectory(named: "parakeet-ultra")
        let fingerprint = FluidAudioASREngine().cacheFingerprint(configuration: .init(modelURL: ultra))
        XCTAssertTrue(fingerprint.contains("model:parakeet-ultra-int8"))
        XCTAssertFalse(fingerprint.contains("model:parakeet-v3-int8"))
    }

    @MainActor
    func testProviderUsesSDKCacheFolderRatherThanRepositorySlug() throws {
        defaults.set("v3", forKey: FluidAudioASRModelProvider.selectionKey)
        _ = try createFluidModelDirectory(named: "parakeet-tdt-0.6b-v3-coreml")
        let actualSDKCache = try createFluidModelDirectory(named: "parakeet-tdt-0.6b-v3")
        let provider = FluidAudioASRModelProvider(modelsRoot: { self.tempDirectory }, defaults: defaults)
        XCTAssertEqual(try provider.resolveForRuntime().resolvingSymlinksInPath(), actualSDKCache.resolvingSymlinksInPath())
        try FileManager.default.removeItem(at: actualSDKCache)
        provider.refreshState()
        XCTAssertEqual(provider.state, .needsDownload, "Repository slug decoy must not count as SDK-managed v3")
    }

    @MainActor
    func testProviderResolvesCanonicalV3RatherThanFirstAlphabeticalModel() throws {
        defaults.set("v3", forKey: FluidAudioASRModelProvider.selectionKey)
        _ = try createFluidModelDirectory(named: "aaa-parakeet-ultra")
        let v3 = try createFluidModelDirectory(named: "parakeet-tdt-0.6b-v3")
        let provider = FluidAudioASRModelProvider(modelsRoot: { self.tempDirectory }, defaults: defaults)
        XCTAssertEqual(try provider.resolveForRuntime().resolvingSymlinksInPath(), v3.resolvingSymlinksInPath())
    }

    @MainActor
    func testProviderRejectsUltraWhenV3IsMissing() throws {
        defaults.set("v3", forKey: FluidAudioASRModelProvider.selectionKey)
        _ = try createFluidModelDirectory(named: "parakeet-ultra-coreml")
        let provider = FluidAudioASRModelProvider(modelsRoot: { self.tempDirectory }, defaults: defaults)
        XCTAssertEqual(provider.state, .needsDownload)
        XCTAssertThrowsError(try provider.resolveForRuntime())
    }

    func testCacheFingerprintInvalidatesPreviousSDKResults() throws {
        let model = try createFluidModelDirectory(named: "fingerprint")
        let fingerprint = FluidAudioASREngine().cacheFingerprint(configuration: .init(modelURL: model))
        XCTAssertTrue(fingerprint.contains("sdk:0.17.7"))
        XCTAssertNotEqual(fingerprint, "\(model.standardizedFileURL.path)|backend:fluidaudio|v3")
    }

    @MainActor
    func testProviderRejectsStagedWeightsInsideCompletedLookingV3Bundle() throws {
        defaults.set("v3", forKey: FluidAudioASRModelProvider.selectionKey)
        let directory = try createFluidModelDirectory(named: "parakeet-tdt-0.6b-v3")
        let weights = directory.appendingPathComponent("Encoder.mlmodelc/weights")
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data("unfinished".utf8).write(to: weights.appendingPathComponent("weight.bin.partial"))
        let provider = FluidAudioASRModelProvider(modelsRoot: { self.tempDirectory }, defaults: defaults)
        XCTAssertEqual(provider.state, .needsDownload)
        XCTAssertThrowsError(try provider.resolveForRuntime())
    }

    func testModelValidatorRejectsEmptyCompiledMarker() throws {
        let directory = try createFluidModelDirectory(named: "empty-compiled-marker")
        try Data().write(to: directory.appendingPathComponent("Decoder.mlmodelc/coremldata.bin"))
        XCTAssertFalse(FluidAudioModelValidator.isValidModelDirectory(directory))
    }

    func testModelValidatorRejectsInterruptedCompiledBundle() throws {
        let directory = try createFluidModelDirectory(named: "interrupted-v3")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("Encoder.mlmodelc/coremldata.bin"))
        XCTAssertFalse(FluidAudioModelValidator.isValidModelDirectory(directory))
    }

    func testModelValidatorAcceptsCompleteStagedDirectory() throws {
        let modelDirectory = try createFluidModelDirectory(named: "fluid-v3")
        XCTAssertTrue(FluidAudioModelValidator.isValidModelDirectory(modelDirectory))
    }

    func testModelValidatorRejectsDirectoryWithMissingMarkers() throws {
        let modelDirectory = tempDirectory.appendingPathComponent("fluid-invalid", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try Data("vocab".utf8).write(to: modelDirectory.appendingPathComponent("parakeet_vocab.json"))
        XCTAssertFalse(FluidAudioModelValidator.isValidModelDirectory(modelDirectory))
    }

    func testModelValidatorRejectsNonexistentDirectory() {
        let nonexistent = tempDirectory.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertFalse(FluidAudioModelValidator.isValidModelDirectory(nonexistent))
    }

    func testModelValidatorRejectsRegularFile() throws {
        let file = tempDirectory.appendingPathComponent("not-a-directory.bin")
        try Data("model".utf8).write(to: file)
        XCTAssertFalse(FluidAudioModelValidator.isValidModelDirectory(file))
    }

    func testValidateModelDirectoryThrowsForInvalidDirectory() throws {
        let invalid = tempDirectory.appendingPathComponent("bad-model", isDirectory: true)
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)

        XCTAssertThrowsError(try FluidAudioModelValidator.validateModelDirectory(invalid)) { error in
            guard case ASREngineRuntimeError.inferenceFailed(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("FluidAudio model directory is invalid"))
        }
    }

    func testEngineThrowsWhenModelDirectoryMissing() async throws {
        let audioURL = try createAudioFile(named: "input.wav")
        let missingModel = tempDirectory.appendingPathComponent("missing-model", isDirectory: true)

        let engine = FluidAudioASREngine(transcriber: StubFluidAudioTranscriber(
            output: FluidAudioRunnerOutput(language: nil, segments: [])
        ))

        do {
            _ = try await engine.transcribe(
                audioURL: audioURL,
                channel: .mic,
                sessionID: UUID(),
                configuration: ASREngineConfiguration(modelURL: missingModel)
            )
            XCTFail("Expected error")
        } catch let error as ASREngineRuntimeError {
            guard case .modelMissing = error else {
                return XCTFail("Expected modelMissing, got \(error)")
            }
        }
    }

    func testEngineThrowsWhenModelDirectoryInvalid() async throws {
        let audioURL = try createAudioFile(named: "input.wav")
        let invalidModel = tempDirectory.appendingPathComponent("invalid-model", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidModel, withIntermediateDirectories: true)
        try Data("vocab".utf8).write(to: invalidModel.appendingPathComponent("parakeet_vocab.json"))

        let engine = FluidAudioASREngine(transcriber: StubFluidAudioTranscriber(
            output: FluidAudioRunnerOutput(language: nil, segments: [])
        ))

        do {
            _ = try await engine.transcribe(
                audioURL: audioURL,
                channel: .mic,
                sessionID: UUID(),
                configuration: ASREngineConfiguration(modelURL: invalidModel)
            )
            XCTFail("Expected error")
        } catch let error as ASREngineRuntimeError {
            guard case .inferenceFailed(let message) = error else {
                return XCTFail("Expected inferenceFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("FluidAudio model directory is invalid"))
        }
    }

    func testEngineThrowsForCorruptAudioInput() async throws {
        let audioURL = tempDirectory.appendingPathComponent("input.aiff")
        try Data("not-audio".utf8).write(to: audioURL)
        let modelDirectory = try createFluidModelDirectory(named: "fluid-v3-format")

        let engine = FluidAudioASREngine(
            transcriber: ThrowingFluidAudioTranscriber(
                error: ASREngineRuntimeError.unsupportedFormat(audioURL)
            )
        )

        do {
            _ = try await engine.transcribe(
                audioURL: audioURL,
                channel: .mic,
                sessionID: UUID(),
                configuration: ASREngineConfiguration(modelURL: modelDirectory)
            )
            XCTFail("Expected error")
        } catch let error as ASREngineRuntimeError {
            guard case .unsupportedFormat = error else {
                return XCTFail("Expected unsupportedFormat, got \(error)")
            }
        }
    }

    func testEngineAcceptsAIFFWhenFileTranscriberSucceeds() async throws {
        let audioURL = tempDirectory.appendingPathComponent("input.aiff")
        try Data("placeholder".utf8).write(to: audioURL)
        let modelDirectory = try createFluidModelDirectory(named: "fluid-v3-aiff")
        let transcriber = RecordingFluidAudioTranscriber(
            output: FluidAudioRunnerOutput(
                language: "en",
                segments: [
                    FluidAudioSegment(id: "seg-1", startMs: 0, endMs: 1000, text: "ok", confidence: nil, words: nil)
                ]
            )
        )
        let engine = FluidAudioASREngine(transcriber: transcriber)

        let document = try await engine.transcribe(
            audioURL: audioURL,
            channel: .mic,
            sessionID: UUID(),
            configuration: ASREngineConfiguration(modelURL: modelDirectory)
        )

        XCTAssertEqual(document.segments.first?.text, "ok")
        XCTAssertEqual(transcriber.callCount, 1)
        XCTAssertEqual(transcriber.lastAudioURL, audioURL)
        XCTAssertEqual(transcriber.lastChannel, .mic)
    }

    func testEngineUsesFileBasedFluidAudioTranscriberWhenAvailable() async throws {
        let audioURL = try createAudioFile(named: "merged-call.m4a")
        let modelDirectory = try createFluidModelDirectory(named: "fluid-v3-file")
        let transcriber = RecordingFluidAudioFileTranscriber(
            output: FluidAudioRunnerOutput(
                language: "ru",
                segments: [
                    FluidAudioSegment(
                        id: "seg-1",
                        startMs: 0,
                        endMs: 1_000,
                        text: "привет",
                        confidence: 0.9,
                        words: nil
                    )
                ]
            )
        )
        let engine = FluidAudioASREngine(transcriber: transcriber)

        let document = try await engine.transcribe(
            audioURL: audioURL,
            channel: .mic,
            sessionID: UUID(),
            configuration: ASREngineConfiguration(modelURL: modelDirectory)
        )

        XCTAssertEqual(document.segments.first?.text, "привет")
        XCTAssertEqual(transcriber.lastAudioURL, audioURL)
        XCTAssertEqual(transcriber.lastChannel, .mic)
    }

    func testEngineDoesNotLoadFullAudioIntoMemoryForASR() async throws {
        let audioURL = tempDirectory.appendingPathComponent("long-call.m4a")
        try Data("not-decodable-audio".utf8).write(to: audioURL)
        let modelDirectory = try createFluidModelDirectory(named: "fluid-v3-long")
        let transcriber = RecordingFluidAudioFileTranscriber(
            output: FluidAudioRunnerOutput(language: "ru", segments: [])
        )
        let engine = FluidAudioASREngine(transcriber: transcriber)

        XCTAssertThrowsError(try FluidAudioInputPreparer().prepareInput(from: audioURL)) { error in
            guard case ASREngineRuntimeError.unsupportedFormat(let failedURL) = error else {
                return XCTFail("Expected unsupportedFormat from in-memory preparation, got \(error)")
            }
            XCTAssertEqual(failedURL, audioURL)
        }

        _ = try await engine.transcribe(
            audioURL: audioURL,
            channel: .system,
            sessionID: UUID(),
            configuration: ASREngineConfiguration(modelURL: modelDirectory)
        )

        XCTAssertEqual(transcriber.lastAudioURL, audioURL)
    }

    func testEngineThrowsWhenAudioFileMissing() async throws {
        let audioURL = tempDirectory.appendingPathComponent("nonexistent.wav")
        let modelDirectory = try createFluidModelDirectory(named: "fluid-v3-noaudio")

        let engine = FluidAudioASREngine(transcriber: StubFluidAudioTranscriber(
            output: FluidAudioRunnerOutput(language: nil, segments: [])
        ))

        do {
            _ = try await engine.transcribe(
                audioURL: audioURL,
                channel: .mic,
                sessionID: UUID(),
                configuration: ASREngineConfiguration(modelURL: modelDirectory)
            )
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue(error is CocoaError)
        }
    }

    func testEngineCacheFingerprintIncludesFluidAudioTag() throws {
        let modelDirectory = try createFluidModelDirectory(named: "fluid-v3-fp")
        let engine = FluidAudioASREngine()
        let config = ASREngineConfiguration(modelURL: modelDirectory)
        let fingerprint = engine.cacheFingerprint(configuration: config)

        XCTAssertTrue(fingerprint.contains("backend:fluidaudio"))
        XCTAssertTrue(fingerprint.contains("v3"))
        XCTAssertTrue(fingerprint.contains("backend:fluidaudio"))
    }

    func testEngineProducesEmptyDocumentForEmptyTranscriberOutput() async throws {
        let audioURL = try createAudioFile(named: "silence.wav")
        let modelDirectory = try createFluidModelDirectory(named: "fluid-v3-empty")

        let transcriber = StubFluidAudioTranscriber(output: FluidAudioRunnerOutput(
            language: "ru",
            segments: []
        ))
        let engine = FluidAudioASREngine(transcriber: transcriber)

        let document = try await engine.transcribe(
            audioURL: audioURL,
            channel: .system,
            sessionID: UUID(),
            configuration: ASREngineConfiguration(modelURL: modelDirectory)
        )

        XCTAssertTrue(document.segments.isEmpty)
        XCTAssertEqual(document.channel, .system)
    }

    func testEngineMapsBothChannels() async throws {
        let audioURL = try createAudioFile(named: "input.caf")
        let modelDirectory = try createFluidModelDirectory(named: "fluid-v3-channels")

        let transcriber = StubFluidAudioTranscriber(output: FluidAudioRunnerOutput(
            language: "en",
            segments: [
                FluidAudioSegment(id: "seg-1", startMs: 0, endMs: 500, text: "test", confidence: 0.8, words: nil)
            ]
        ))
        let engine = FluidAudioASREngine(transcriber: transcriber)

        let micDoc = try await engine.transcribe(
            audioURL: audioURL,
            channel: .mic,
            sessionID: UUID(),
            configuration: ASREngineConfiguration(modelURL: modelDirectory)
        )
        let systemDoc = try await engine.transcribe(
            audioURL: audioURL,
            channel: .system,
            sessionID: UUID(),
            configuration: ASREngineConfiguration(modelURL: modelDirectory)
        )

        XCTAssertEqual(micDoc.channel, .mic)
        XCTAssertEqual(systemDoc.channel, .system)
        XCTAssertEqual(micDoc.segments.count, 1)
        XCTAssertEqual(systemDoc.segments.count, 1)
    }

    func testEngineMapsTranscriberOutputToASRDocument() async throws {
        let audioURL = try createAudioFile(named: "input.wav")
        let modelDirectory = try createFluidModelDirectory(named: "fluid-v3")

        let transcriber = StubFluidAudioTranscriber(output: FluidAudioRunnerOutput(
            language: "en",
            segments: [
                FluidAudioSegment(
                    id: "seg-1",
                    startMs: 120,
                    endMs: 980,
                    text: "hello world",
                    confidence: 0.91,
                    words: [
                        ASRWord(word: "hello", startMs: 120, endMs: 420, confidence: 0.95),
                        ASRWord(word: "world", startMs: 430, endMs: 980, confidence: 0.89)
                    ]
                )
            ]
        ))
        let engine = FluidAudioASREngine(transcriber: transcriber)

        let document = try await engine.transcribe(
            audioURL: audioURL,
            channel: .mic,
            sessionID: UUID(),
            configuration: ASREngineConfiguration(modelURL: modelDirectory)
        )

        XCTAssertEqual(document.segments.count, 1)
        XCTAssertEqual(document.segments.first?.text, "hello world")
        XCTAssertEqual(document.segments.first?.language, "en")
        XCTAssertEqual(document.segments.first?.words?.count, 2)
    }

    func testInputPreparerDecodesToFloat32NonInterleavedPCM() throws {
        let sourceURL = try createAudioFile(
            named: "decode-source.caf",
            sampleRate: 44_100,
            channels: 1,
            frameCount: 2_048
        )
        let preparer = FluidAudioInputPreparer()

        let prepared = try preparer.prepareInput(from: sourceURL)

        XCTAssertEqual(prepared.frameLength, 2_048)
        XCTAssertEqual(prepared.format.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(prepared.format.isInterleaved)
    }

    func testInputPreparerRejectsCorruptFileAsUnsupportedFormat() throws {
        let sourceURL = tempDirectory.appendingPathComponent("corrupt.caf")
        try Data("not-a-real-audio-file".utf8).write(to: sourceURL)
        let preparer = FluidAudioInputPreparer()

        XCTAssertThrowsError(try preparer.prepareInput(from: sourceURL)) { error in
            guard case ASREngineRuntimeError.unsupportedFormat(let failedURL) = error else {
                return XCTFail("Expected unsupportedFormat, got \(error)")
            }
            XCTAssertEqual(failedURL, sourceURL)
        }
    }

    func testInputPreparerRejectsEmptyAudioFileAsUnsupportedFormat() throws {
        let sourceURL = tempDirectory.appendingPathComponent("empty.caf")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        _ = try AVAudioFile(forWriting: sourceURL, settings: format.settings)
        let preparer = FluidAudioInputPreparer()

        XCTAssertThrowsError(try preparer.prepareInput(from: sourceURL)) { error in
            guard case ASREngineRuntimeError.unsupportedFormat(let failedURL) = error else {
                return XCTFail("Expected unsupportedFormat, got \(error)")
            }
            XCTAssertEqual(failedURL, sourceURL)
        }
    }

    func testSessionAudioLoaderDecodesFlacAndPreservesPreparedSampleRate() throws {
        let sourceURL = try createFLACAudioFile(
            named: "system.raw.flac",
            sampleRate: 22_050,
            channels: 1
        )
        let loader = FluidAudioSessionAudioLoader()

        let prepared = try loader.loadAudio(from: sourceURL)

        XCTAssertEqual(prepared.sourceURL, sourceURL)
        XCTAssertEqual(prepared.sampleRate, 22_050)
        XCTAssertFalse(prepared.samples.isEmpty)
        XCTAssertGreaterThan(prepared.durationMs, 0)
    }

    func testTranscriptionServiceMaterializesPreparedFullInputBeforeFileTranscription() async throws {
        let originalURL = try createAudioFile(named: "original.caf", frameCount: 16_000)
        let modelDirectory = try createFluidModelDirectory(named: "fluid-v3-prepared-input")
        let transcriber = InspectingFluidAudioFileTranscriber(
            output: FluidAudioRunnerOutput(
                language: "en",
                segments: [
                    FluidAudioSegment(id: "seg-1", startMs: 0, endMs: 250, text: "chunk", confidence: nil, words: nil)
                ]
            )
        )
        let service = FluidAudioTranscriptionService(
            transcriber: transcriber,
            vadService: StubFluidAudioVADService(result: nil)
        )
        let preparedAudio = PreparedSessionAudio(
            samples: Array(repeating: 0.1, count: 4_000),
            sampleRate: 16_000,
            durationMs: 250,
            sourceURL: originalURL
        )

        let output = try await service.transcribe(
            preparedAudio: preparedAudio,
            modelDirectoryURL: modelDirectory,
            channel: .system
        )

        XCTAssertEqual(output.segments.first?.text, "chunk")
        XCTAssertNotEqual(transcriber.lastAudioURL, originalURL)
        XCTAssertEqual(transcriber.lastFrameLength, 4_000)
        XCTAssertEqual(transcriber.lastSampleRate, 16_000)
    }

    func testEngineTranscribesInputThroughFileTranscriberOnce() async throws {
        let audioURL = tempDirectory.appendingPathComponent("long-input.caf")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8))
        let modelDirectory = try createFluidModelDirectory(named: "fluid-v3-windowed-fallback")
        let transcriber = SequencedFluidAudioTranscriber(outputs: [
            FluidAudioRunnerOutput(
                language: "ru",
                segments: [
                    FluidAudioSegment(id: "seg-1", startMs: 0, endMs: 1_200, text: "chunk-1", confidence: 0.9, words: nil)
                ]
            ),
            FluidAudioRunnerOutput(
                language: "ru",
                segments: [
                    FluidAudioSegment(id: "seg-1", startMs: 0, endMs: 1_400, text: "chunk-2", confidence: 0.9, words: nil)
                ]
            ),
            FluidAudioRunnerOutput(
                language: "ru",
                segments: [
                    FluidAudioSegment(id: "seg-1", startMs: 0, endMs: 1_600, text: "chunk-3", confidence: 0.9, words: nil)
                ]
            )
        ])
        let engine = FluidAudioASREngine(transcriber: transcriber)

        let document = try await engine.transcribe(
            audioURL: audioURL,
            channel: .mic,
            sessionID: UUID(),
            configuration: ASREngineConfiguration(modelURL: modelDirectory)
        )

        XCTAssertEqual(document.segments.count, 1)
        XCTAssertEqual(transcriber.callCount, 1)
        XCTAssertEqual(document.segments.first?.text, "chunk-1")
        XCTAssertEqual(transcriber.lastAudioURL, audioURL)
    }

    @MainActor
    func testSelectionPersistsAndAJobProfileKeepsItsOriginalModel() throws {
        let ultra = try createFluidModelDirectory(named: FluidAudioASRModel.ultra.cacheFolder)
        let v3 = try createFluidModelDirectory(named: FluidAudioASRModel.v3.cacheFolder)
        let provider = FluidAudioASRModelProvider(modelsRoot: { self.tempDirectory }, defaults: defaults)
        let frozenJobModel = try provider.resolveForRuntime()
        try provider.selectModel(.v3)
        XCTAssertEqual(frozenJobModel.resolvingSymlinksInPath(), ultra.resolvingSymlinksInPath())
        XCTAssertEqual(try provider.resolveForRuntime().resolvingSymlinksInPath(), v3.resolvingSymlinksInPath())
        let reopened = FluidAudioASRModelProvider(modelsRoot: { self.tempDirectory }, defaults: defaults)
        XCTAssertEqual(reopened.selectedModel, .v3)
        XCTAssertNotEqual(FluidAudioASREngine().cacheFingerprint(configuration: .init(modelURL: ultra)),
                          FluidAudioASREngine().cacheFingerprint(configuration: .init(modelURL: v3)))
    }

    @MainActor
    func testIncompleteUltraDoesNotSilentlyFallBackToInstalledV3() throws {
        _ = try createFluidModelDirectory(named: FluidAudioASRModel.v3.cacheFolder)
        let provider = FluidAudioASRModelProvider(modelsRoot: { self.tempDirectory }, defaults: defaults)
        XCTAssertEqual(provider.state, .needsDownload)
        XCTAssertEqual(provider.state(for: .v3), .ready)
        XCTAssertThrowsError(try provider.resolveForRuntime())
        XCTAssertThrowsError(try provider.selectModel(.ultra))
        try provider.selectModel(.v3)
        XCTAssertEqual(provider.state, .ready)
    }

    @MainActor
    func testDownloadingInactiveModelDoesNotSelectItAndCanRetryFailure() async throws {
        _ = try createFluidModelDirectory(named: FluidAudioASRModel.ultra.cacheFolder)
        var attempts = 0
        let provider = FluidAudioASRModelProvider(modelsRoot: { self.tempDirectory }, defaults: defaults,
            downloader: { model, target, report in
                attempts += 1
                XCTAssertEqual(model, .v3)
                XCTAssertEqual(target.lastPathComponent, model.cacheFolder)
                if attempts == 1 { throw CocoaError(.fileReadNoPermission) }
                report(.init(fraction: 0.4, detail: "Downloading encoder"))
                _ = try self.createFluidModelDirectory(named: model.cacheFolder)
            })
        await provider.downloadModel(.v3)
        guard case .failed = provider.state(for: .v3) else { return XCTFail("Expected recoverable error") }
        XCTAssertEqual(provider.selectedModel, .ultra)
        await provider.downloadModel(.v3)
        XCTAssertEqual(provider.state(for: .v3), .ready)
        XCTAssertEqual(provider.selectedModel, .ultra)
        XCTAssertNil(provider.progress(for: .v3), "Late callbacks must not resurrect finished progress")
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testRetryRemovesInvalidCompiledComponentBeforeCallingSDKDownloader() async throws {
        let root = try createFluidModelDirectory(named: FluidAudioASRModel.ultra.cacheFolder)
        let marker = root.appendingPathComponent("Encoder.mlmodelc/coremldata.bin")
        try Data().write(to: marker)
        let completeSibling = root.appendingPathComponent("Decoder.mlmodelc/coremldata.bin")
        let saved = try Data(contentsOf: completeSibling)
        let provider = FluidAudioASRModelProvider(modelsRoot: { self.tempDirectory }, defaults: defaults,
            downloader: { model, url, _ in
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("Encoder.mlmodelc").path),
                               "Retry must bypass SDK's existence-only early return")
                XCTAssertEqual(try Data(contentsOf: completeSibling), saved)
                _ = try self.createFluidModelDirectory(named: model.cacheFolder)
            })
        await provider.downloadModel(.ultra)
        XCTAssertEqual(provider.state, .ready)
    }

    @MainActor
    func testDownloadCannotReportReadyWithoutCompleteAssets() async throws {
        let provider = FluidAudioASRModelProvider(modelsRoot: { self.tempDirectory }, defaults: defaults,
            downloader: { _, _, _ in })
        await provider.downloadModel(.ultra)
        guard case .failed = provider.state else { return XCTFail("Missing assets must fail validation") }
        XCTAssertThrowsError(try provider.resolveForRuntime())
    }

    @MainActor
    func testRemovalProtectsSelectedModelAndRejectsCacheSymlink() throws {
        let ultra = try createFluidModelDirectory(named: FluidAudioASRModel.ultra.cacheFolder)
        let v3 = try createFluidModelDirectory(named: FluidAudioASRModel.v3.cacheFolder)
        let provider = FluidAudioASRModelProvider(modelsRoot: { self.tempDirectory }, defaults: defaults)
        XCTAssertThrowsError(try provider.removeModel(.ultra))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ultra.path))
        try provider.removeModel(.v3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: v3.path))
        let other = try createFluidModelDirectory(named: "outside-cache-model")
        try FileManager.default.createSymbolicLink(at: v3, withDestinationURL: other)
        XCTAssertThrowsError(try provider.removeModel(.v3))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    @MainActor
    func testNativeUltraAndV3OnBoundedAudioExcerpt() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["RECORDLY_ULTRA_SMOKE_AUDIO"],
              let root = env["RECORDLY_ULTRA_SMOKE_MODELS"],
              let output = env["RECORDLY_ULTRA_SMOKE_OUTPUT"] else {
            throw XCTSkip("Opt-in installed-model acceptance; never modifies source recordings")
        }
        let source = try AVAudioFile(forReading: URL(fileURLWithPath: input))
        let count = AVAudioFrameCount(min(source.length, Int64(source.processingFormat.sampleRate * 30)))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: count))
        try source.read(into: buffer, frameCount: count)
        let clip = tempDirectory.appendingPathComponent("bounded-30s.wav")
        do {
            let writer = try AVAudioFile(forWriting: clip, settings: buffer.format.settings)
            try writer.write(from: buffer)
        }
        let provider = FluidAudioASRModelProvider(modelsRoot: { URL(fileURLWithPath: root, isDirectory: true) }, defaults: defaults)
        XCTAssertEqual(provider.selectedModel, .ultra)
        var reports: [[String: Any]] = []
        let engine = FluidAudioASREngine()
        for model in FluidAudioASRModel.allCases {
            try provider.selectModel(model)
            let configuration = ASREngineConfiguration(modelURL: try provider.resolveForRuntime())
            let start = Date()
            let document = try await engine.transcribe(audioURL: clip, channel: .mic, sessionID: UUID(), configuration: configuration)
            let seconds = Date().timeIntervalSince(start)
            XCTAssertFalse(document.segments.isEmpty)
            XCTAssertTrue(document.segments.contains { !($0.words ?? []).isEmpty })
            XCTAssertTrue(document.segments.allSatisfy { $0.startMs >= 0 && $0.endMs > $0.startMs })
            let text = document.segments.map(\.text).joined(separator: " ")
            XCTAssertFalse(text.contains("▁"))
            for segment in document.segments {
                let words = segment.words ?? []
                let timedText = ASRTimedText(text: segment.text, words: words)
                XCTAssertTrue(timedText.isAligned, "Native tokens must preserve decoded word boundaries for \(model.title)")
                XCTAssertEqual(timedText.text(for: words), segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            reports.append(["model": model.rawValue, "fingerprint": engine.cacheFingerprint(configuration: configuration),
                            "seconds": seconds, "text": text,
                            "words": document.segments.reduce(0) { $0 + ($1.words?.count ?? 0) }])
        }
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }

    private func createFluidModelDirectory(named name: String) throws -> URL {
        let directory = tempDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for marker in FluidAudioModelValidator.requiredMarkers {
            let markerURL = directory.appendingPathComponent(marker)
            if marker.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: markerURL, withIntermediateDirectories: true)
                try Data("compiled-layout".utf8).write(to: markerURL.appendingPathComponent("coremldata.bin"))
            } else {
                try Data("marker".utf8).write(to: markerURL)
            }
        }
        return directory
    }

    private func createAudioFile(
        named fileName: String,
        commonFormat: AVAudioCommonFormat = .pcmFormatFloat32,
        sampleRate: Double = 16_000,
        channels: AVAudioChannelCount = 1,
        interleaved: Bool = false,
        frameCount: AVAudioFrameCount = 16_000
    ) throws -> URL {
        let url = tempDirectory.appendingPathComponent(fileName)
        let format = AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: interleaved
        )!
        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try makePCMBuffer(
            frameCount: frameCount,
            sampleRate: sampleRate,
            channels: channels,
            commonFormat: commonFormat,
            interleaved: interleaved
        )
        try audioFile.write(from: buffer)
        return url
    }

    private func createFLACAudioFile(
        named fileName: String,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        frameCount: AVAudioFrameCount = 4_096
    ) throws -> URL {
        let flacURL = tempDirectory.appendingPathComponent(fileName)
        XCTAssertEqual(Int(sampleRate), 22_050)
        XCTAssertEqual(channels, 1)
        _ = frameCount
        let base64 = "ZkxhQwAAACIQABAAAAQYAAQYBWIg8AAACJ1wB/cbkBQZ5C04UD9AQMbvhAAAKCAAAAByZWZlcmVuY2UgbGliRkxBQyAxLjQuMyAyMDIzMDYyMwAAAAD/+HYIAAicJBgAAATNCYcOGwCiRoyQZRuNxJiTJUikOy/3vV6+va6f6TVkpEzIhqRGiEU1rO3Xdb3wqF/qqhU901bZqNzQ0NEMptU3Z9HuLeVCrC2PfvU+SJGbY2RkJWM4nSaxWfxf1pcdBUVd7LtITicjQTmJzJoa1p0XOhYtf/qse33s7cjjKRMyIbiZERKbxl0XPi4sV73wpC+IclkasmxtjQiJiVk7WSLlvW968Ljoq776tI0JkZEZoRqZRHEKR2X58KQfc+50eFI92UlRIhuJTImNTc121lnvr4Vj149pzHm6fNcSNiZkbGpIibk9Rbat5cpc62vllqdJmjQiNDYlNs02m6LbHveP/1XHZ87WpTOJMRMxlCVCUkhF0y2f/ug6P3ix5Z4nJ22JkQ3ESGpuSRJ9egrP1hatLioWW5SOTVkbjRkRmzURSSpFYqL6tLO64+eV29jfEqNiUZQlRicmjWs6eFY86rSoKh0Kj7opOkJERCZCQ2gnaN8jpXY8r+ljw6PVRZUU3zZqJTJBKakSJSKn1XFR3Q9X/vlVFkuTsmyGpEQmxqZTci7exZ3jw+frHt+XVLmrZkxGomRMbokkyo6Fx2PV/eL13+8SpMSm41JjU2xOaxLlRbf18FQtVc98n03EVicSkJxo2bNUS1nRYsVb3qrVv6kOykVq2amSGglZkhK12s+X51ilQ9/7ov1u1RuRETCczRiVGqTW5c86rjws5ctXKzsojsiZszYiZmjRuRdv8tWrBUd8dHVjpZUkTErNjcaIyJs3a7zFR7S4tfCoXPZ94lRKyNCIjYRRKbk7WSfoW/0+V71q5bvq1TYkZCUSEhEjTJazoVi4tr/vi+3qnukbs1IiI2E5Cc1bVOz7zvi485cfLVqFb6N2xOJCQ2Qmgik3J6ixUPKWP6//jzo7dKTm4nG5szJBFNE5F2WV0dfh2Fz1fnqLMik0JRKxEhs2RuZWn0dj5aq/rBUXrq5Ha7Q3NTZsaMhFG6apPI6FxZzoX+vaqOniTQkaEQnCciIiTNZWeR8/w7FW97DkLvspKRRKzIiEhExJs3Sy2LaXPSxe8WLZ0+0ak2YlM1MmbbN8jpf4+LV616se5anSwQomxITCKNSZMk01txULi38uOhfP87W4jmhOIlEShHGpKjKRzHIdi5Xir+vrxZF1SpWbiU0JiJmTNWkmVOue/vC2lt65ZM4niGcakTEaGpqStKyxC7/+nQv63uwpHRSKmTYkZkRCZobkrdIuxZeVHKh4rodHkt0yVm43EpsyI0QitNZ0OQq5+vpbVWeep8lTEmNGNzJjXElIqX6lYvhYWFQXLausuTm7NkQ3GpEzJWRSLsVn8Xvi/re+66yVE5NiZGRsRMiMojtPvY9h0FQVhZ1izhV3"
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        try data.write(to: flacURL)
        return flacURL
    }

    private func makePCMBuffer(
        frameCount: AVAudioFrameCount,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        commonFormat: AVAudioCommonFormat = .pcmFormatFloat32,
        interleaved: Bool = false
    ) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: interleaved
        ) else {
            throw NSError(domain: "FluidAudioASREngineTests", code: 1)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "FluidAudioASREngineTests", code: 2)
        }
        buffer.frameLength = frameCount

        switch commonFormat {
        case .pcmFormatFloat32:
            if let channelData = buffer.floatChannelData {
                if format.isInterleaved {
                    let sampleCount = Int(frameCount) * Int(channels)
                    for sample in 0..<sampleCount {
                        channelData[0][sample] = Float(sample % 64) / 64.0
                    }
                } else {
                    for channel in 0..<Int(channels) {
                        for frame in 0..<Int(frameCount) {
                            channelData[channel][frame] = Float(frame % 64) / 64.0
                        }
                    }
                }
            }
        case .pcmFormatInt16:
            if let channelData = buffer.int16ChannelData {
                if format.isInterleaved {
                    let sampleCount = Int(frameCount) * Int(channels)
                    for sample in 0..<sampleCount {
                        channelData[0][sample] = Int16(sample % 128)
                    }
                } else {
                    for channel in 0..<Int(channels) {
                        for frame in 0..<Int(frameCount) {
                            channelData[channel][frame] = Int16(frame % 128)
                        }
                    }
                }
            }
        default:
            break
        }

        return buffer
    }
}

private struct StubFluidAudioTranscriber: FluidAudioTranscribing {
    let output: FluidAudioRunnerOutput

    func transcribe(
        audioURL: URL,
        modelDirectoryURL: URL,
        channel: TranscriptChannel
    ) async throws -> FluidAudioRunnerOutput {
        output
    }
}

private struct ThrowingFluidAudioTranscriber: FluidAudioTranscribing {
    let error: Error

    func transcribe(
        audioURL: URL,
        modelDirectoryURL: URL,
        channel: TranscriptChannel
    ) async throws -> FluidAudioRunnerOutput {
        throw error
    }
}

private final class RecordingFluidAudioTranscriber: FluidAudioTranscribing, @unchecked Sendable {
    let output: FluidAudioRunnerOutput
    private(set) var callCount: Int = 0
    private(set) var lastAudioURL: URL?
    private(set) var lastChannel: TranscriptChannel?

    init(output: FluidAudioRunnerOutput) {
        self.output = output
    }

    func transcribe(
        audioURL: URL,
        modelDirectoryURL: URL,
        channel: TranscriptChannel
    ) async throws -> FluidAudioRunnerOutput {
        callCount += 1
        lastAudioURL = audioURL
        lastChannel = channel
        return output
    }
}

private final class RecordingFluidAudioFileTranscriber: FluidAudioTranscribing {
    var output: FluidAudioRunnerOutput
    var lastAudioURL: URL?
    var lastChannel: TranscriptChannel?

    init(output: FluidAudioRunnerOutput) {
        self.output = output
    }

    func transcribe(
        audioURL: URL,
        modelDirectoryURL: URL,
        channel: TranscriptChannel
    ) async throws -> FluidAudioRunnerOutput {
        lastAudioURL = audioURL
        lastChannel = channel
        return output
    }
}

private final class InspectingFluidAudioFileTranscriber: FluidAudioTranscribing {
    let output: FluidAudioRunnerOutput
    private(set) var lastAudioURL: URL?
    private(set) var lastFrameLength: AVAudioFramePosition?
    private(set) var lastSampleRate: Double?

    init(output: FluidAudioRunnerOutput) {
        self.output = output
    }

    func transcribe(
        audioURL: URL,
        modelDirectoryURL: URL,
        channel: TranscriptChannel
    ) async throws -> FluidAudioRunnerOutput {
        lastAudioURL = audioURL
        let audioFile = try AVAudioFile(forReading: audioURL)
        lastFrameLength = audioFile.length
        lastSampleRate = audioFile.processingFormat.sampleRate
        return output
    }
}

private struct StubFluidAudioVADService: FluidAudioVoiceActivityDetecting {
    let result: [FluidAudioSpeechRegion]?

    func detectSpeechRegions(in audio: PreparedSessionAudio) async -> [FluidAudioSpeechRegion]? {
        result
    }
}

private final class SequencedFluidAudioTranscriber: FluidAudioTranscribing, @unchecked Sendable {
    private var outputs: [FluidAudioRunnerOutput]
    private(set) var callCount: Int = 0
    private(set) var lastAudioURL: URL?

    init(outputs: [FluidAudioRunnerOutput]) {
        self.outputs = outputs
    }

    func transcribe(
        audioURL: URL,
        modelDirectoryURL: URL,
        channel: TranscriptChannel
    ) async throws -> FluidAudioRunnerOutput {
        callCount += 1
        lastAudioURL = audioURL
        guard !outputs.isEmpty else {
            return FluidAudioRunnerOutput(language: nil, segments: [])
        }
        return outputs.removeFirst()
    }
}

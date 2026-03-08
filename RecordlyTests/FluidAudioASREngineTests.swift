import XCTest
@testable import Recordly

final class FluidAudioASREngineTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
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
        tempDirectory = nil
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
        let audioURL = tempDirectory.appendingPathComponent("input.wav")
        try Data("audio".utf8).write(to: audioURL)
        let missingModel = tempDirectory.appendingPathComponent("missing-model", isDirectory: true)

        let engine = FluidAudioASREngine(transcriber: StubFluidAudioTranscriber(
            output: FluidAudioRunnerOutput(language: nil, segments: [])
        ))

        do {
            _ = try await engine.transcribe(
                audioURL: audioURL,
                channel: .mic,
                sessionID: UUID(),
                configuration: ASREngineConfiguration(modelURL: missingModel, language: .auto)
            )
            XCTFail("Expected error")
        } catch let error as ASREngineRuntimeError {
            guard case .modelMissing = error else {
                return XCTFail("Expected modelMissing, got \(error)")
            }
        }
    }

    func testEngineThrowsWhenModelDirectoryInvalid() async throws {
        let audioURL = tempDirectory.appendingPathComponent("input.wav")
        try Data("audio".utf8).write(to: audioURL)
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
                configuration: ASREngineConfiguration(modelURL: invalidModel, language: .auto)
            )
            XCTFail("Expected error")
        } catch let error as ASREngineRuntimeError {
            guard case .inferenceFailed(let message) = error else {
                return XCTFail("Expected inferenceFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("FluidAudio model directory is invalid"))
        }
    }

    func testEngineThrowsForUnsupportedAudioFormat() async throws {
        let audioURL = tempDirectory.appendingPathComponent("input.aiff")
        try Data("audio".utf8).write(to: audioURL)
        let modelDirectory = try createFluidModelDirectory(named: "fluid-v3-format")

        let engine = FluidAudioASREngine(transcriber: StubFluidAudioTranscriber(
            output: FluidAudioRunnerOutput(language: nil, segments: [])
        ))

        do {
            _ = try await engine.transcribe(
                audioURL: audioURL,
                channel: .mic,
                sessionID: UUID(),
                configuration: ASREngineConfiguration(modelURL: modelDirectory, language: .auto)
            )
            XCTFail("Expected error")
        } catch let error as ASREngineRuntimeError {
            guard case .unsupportedFormat = error else {
                return XCTFail("Expected unsupportedFormat, got \(error)")
            }
        }
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
                configuration: ASREngineConfiguration(modelURL: modelDirectory, language: .auto)
            )
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue(error is CocoaError)
        }
    }

    func testEngineCacheFingerprintIncludesFluidAudioTag() throws {
        let modelDirectory = try createFluidModelDirectory(named: "fluid-v3-fp")
        let engine = FluidAudioASREngine()
        let config = ASREngineConfiguration(modelURL: modelDirectory, language: .auto)
        let fingerprint = engine.cacheFingerprint(configuration: config)

        XCTAssertTrue(fingerprint.contains("backend:fluidaudio"))
        XCTAssertTrue(fingerprint.contains("v3"))
        XCTAssertTrue(fingerprint.contains("lang:auto"))
    }

    func testEngineProducesEmptyDocumentForEmptyTranscriberOutput() async throws {
        let audioURL = tempDirectory.appendingPathComponent("silence.wav")
        try Data("audio".utf8).write(to: audioURL)
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
            configuration: ASREngineConfiguration(modelURL: modelDirectory, language: .auto)
        )

        XCTAssertTrue(document.segments.isEmpty)
        XCTAssertEqual(document.channel, .system)
    }

    func testEngineMapsBothChannels() async throws {
        let audioURL = tempDirectory.appendingPathComponent("input.caf")
        try Data("audio".utf8).write(to: audioURL)
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
            configuration: ASREngineConfiguration(modelURL: modelDirectory, language: .auto)
        )
        let systemDoc = try await engine.transcribe(
            audioURL: audioURL,
            channel: .system,
            sessionID: UUID(),
            configuration: ASREngineConfiguration(modelURL: modelDirectory, language: .auto)
        )

        XCTAssertEqual(micDoc.channel, .mic)
        XCTAssertEqual(systemDoc.channel, .system)
        XCTAssertEqual(micDoc.segments.count, 1)
        XCTAssertEqual(systemDoc.segments.count, 1)
    }

    func testEngineMapsTranscriberOutputToASRDocument() async throws {
        let audioURL = tempDirectory.appendingPathComponent("input.wav")
        try Data("audio".utf8).write(to: audioURL)
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
            configuration: ASREngineConfiguration(modelURL: modelDirectory, language: .auto)
        )

        XCTAssertEqual(document.segments.count, 1)
        XCTAssertEqual(document.segments.first?.text, "hello world")
        XCTAssertEqual(document.segments.first?.language, "en")
        XCTAssertEqual(document.segments.first?.words?.count, 2)
    }

    private func createFluidModelDirectory(named name: String) throws -> URL {
        let directory = tempDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for marker in FluidAudioModelValidator.requiredMarkers {
            let markerURL = directory.appendingPathComponent(marker)
            if marker.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: markerURL, withIntermediateDirectories: true)
            } else {
                try Data("marker".utf8).write(to: markerURL)
            }
        }
        return directory
    }
}

private struct StubFluidAudioTranscriber: FluidAudioTranscribing {
    let output: FluidAudioRunnerOutput

    func transcribe(
        audioURL: URL,
        modelDirectoryURL: URL,
        channel: TranscriptChannel,
        languageCode: String?
    ) async throws -> FluidAudioRunnerOutput {
        output
    }
}

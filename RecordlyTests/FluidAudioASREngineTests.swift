import AVFoundation
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
        } catch let error as ASREngineRuntimeError {
            guard case .unsupportedFormat = error else {
                return XCTFail("Expected unsupportedFormat, got \(error)")
            }
        }
    }

    func testEngineAcceptsAIFFWhenInputPreparerSucceeds() async throws {
        let audioURL = tempDirectory.appendingPathComponent("input.aiff")
        try Data("placeholder".utf8).write(to: audioURL)
        let modelDirectory = try createFluidModelDirectory(named: "fluid-v3-aiff")
        let expectedBuffer = try makePCMBuffer(frameCount: 16_000, sampleRate: 48_000, channels: 2)
        let transcriber = RecordingFluidAudioTranscriber(
            output: FluidAudioRunnerOutput(
                language: "en",
                segments: [
                    FluidAudioSegment(id: "seg-1", startMs: 0, endMs: 1000, text: "ok", confidence: nil, words: nil)
                ]
            )
        )
        let preparer = StubFluidAudioInputPreparer(buffer: expectedBuffer)
        let engine = FluidAudioASREngine(transcriber: transcriber, inputPreparer: preparer)

        let document = try await engine.transcribe(
            audioURL: audioURL,
            channel: .mic,
            sessionID: UUID(),
            configuration: ASREngineConfiguration(modelURL: modelDirectory)
        )

        XCTAssertEqual(document.segments.first?.text, "ok")
        XCTAssertEqual(preparer.preparedURLs, [audioURL])
        XCTAssertEqual(transcriber.callCount, 1)
        XCTAssertEqual(transcriber.lastBufferFrameLength, expectedBuffer.frameLength)
        XCTAssertEqual(transcriber.lastBufferSampleRate, expectedBuffer.format.sampleRate)
        XCTAssertEqual(transcriber.lastBufferChannelCount, expectedBuffer.format.channelCount)
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
        audioBuffer: AVAudioPCMBuffer,
        modelDirectoryURL: URL,
        channel: TranscriptChannel
    ) async throws -> FluidAudioRunnerOutput {
        output
    }
}

private final class RecordingFluidAudioTranscriber: FluidAudioTranscribing, @unchecked Sendable {
    let output: FluidAudioRunnerOutput
    private(set) var callCount: Int = 0
    private(set) var lastBufferFrameLength: AVAudioFrameCount = 0
    private(set) var lastBufferSampleRate: Double = 0
    private(set) var lastBufferChannelCount: AVAudioChannelCount = 0

    init(output: FluidAudioRunnerOutput) {
        self.output = output
    }

    func transcribe(
        audioBuffer: AVAudioPCMBuffer,
        modelDirectoryURL: URL,
        channel: TranscriptChannel
    ) async throws -> FluidAudioRunnerOutput {
        callCount += 1
        lastBufferFrameLength = audioBuffer.frameLength
        lastBufferSampleRate = audioBuffer.format.sampleRate
        lastBufferChannelCount = audioBuffer.format.channelCount
        return output
    }
}

private final class StubFluidAudioInputPreparer: FluidAudioInputPreparing {
    let buffer: AVAudioPCMBuffer
    private(set) var preparedURLs: [URL] = []

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func prepareInput(from audioURL: URL) throws -> AVAudioPCMBuffer {
        preparedURLs.append(audioURL)
        return buffer
    }
}

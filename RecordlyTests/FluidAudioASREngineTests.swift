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
        XCTAssertEqual(transcriber.lastBufferChannelCount, 1)
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

    func testEngineFallsBackToFullInputWhenVADReturnsNoUsableRegions() async throws {
        let audioURL = try createAudioFile(named: "input.caf", sampleRate: 16_000, channels: 1, frameCount: 16_000)
        let modelDirectory = try createFluidModelDirectory(named: "fluid-v3-vad-fallback")
        let transcriber = RecordingFluidAudioTranscriber(
            output: FluidAudioRunnerOutput(
                language: "en",
                segments: [
                    FluidAudioSegment(id: "seg-1", startMs: 0, endMs: 1000, text: "fallback", confidence: 0.9, words: nil)
                ]
            )
        )
        let engine = FluidAudioASREngine(
            transcriber: transcriber,
            sessionAudioLoader: FluidAudioSessionAudioLoader(),
            vadService: StubFluidAudioVADService(result: [])
        )

        let document = try await engine.transcribe(
            audioURL: audioURL,
            channel: .mic,
            sessionID: UUID(),
            configuration: ASREngineConfiguration(modelURL: modelDirectory)
        )

        XCTAssertEqual(document.segments.map(\.text), ["fallback"])
        XCTAssertEqual(transcriber.callCount, 1)
        XCTAssertGreaterThan(transcriber.lastBufferFrameLength, 0)
    }

    func testDiarizationServiceRejectsLegacyCliModelFile() async throws {
        let audioURL = try createAudioFile(named: "system.raw.caf", sampleRate: 16_000, channels: 1, frameCount: 16_000)
        let loader = FluidAudioSessionAudioLoader()
        let prepared = try loader.loadAudio(from: audioURL)
        let legacyModel = tempDirectory.appendingPathComponent("diarization.bin")
        try Data("legacy".utf8).write(to: legacyModel)
        let service = FluidAudioDiarizationService(runner: StubFluidAudioDiarizationRunner(result: .success([])))

        do {
            _ = try await service.diarize(preparedAudio: prepared, sessionID: UUID(), modelDirectoryURL: legacyModel)
            XCTFail("Expected error")
        } catch let error as DiarizationRuntimeError {
            guard case .modelMissing(let failedURL) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(failedURL, legacyModel)
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

private struct StubFluidAudioVADService: FluidAudioVoiceActivityDetecting {
    let result: [FluidAudioSpeechRegion]?

    func detectSpeechRegions(in audio: PreparedSessionAudio) async -> [FluidAudioSpeechRegion]? {
        result
    }
}

private struct StubFluidAudioDiarizationRunner: FluidAudioOfflineDiarizationRunning {
    let result: Result<[FluidAudioDiarizationSegment], Error>

    func diarize(preparedAudio: PreparedSessionAudio, modelDirectoryURL: URL) async throws -> [FluidAudioDiarizationSegment] {
        try result.get()
    }
}

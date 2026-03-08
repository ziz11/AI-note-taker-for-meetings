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

import Foundation
import XCTest
@testable import Recordly

final class FluidAudioSystemChunkTranscriptionEngineTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FluidAudioSystemChunkTranscriptionEngineTests-\(UUID().uuidString)",
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

    func testChunkEngineRebasesSegmentAndWordTimestampsFromChunkToSession() async throws {
        let systemAudioURL = tempDirectory.appendingPathComponent("system.raw.flac")
        FileManager.default.createFile(atPath: systemAudioURL.path, contents: Data("audio".utf8))
        let modelDirectory = try createFluidModelDirectory(named: "fluid-v3")
        let transcriptionService = RecordingChunkTranscriptionService(
            outputs: [
                FluidAudioRunnerOutput(
                    language: "ru",
                    segments: [
                        FluidAudioSegment(
                            id: "seg-1",
                            startMs: 120,
                            endMs: 480,
                            text: "hello",
                            confidence: 0.9,
                            words: [
                                ASRWord(word: "hello", startMs: 120, endMs: 480, confidence: 0.9)
                            ]
                        )
                    ]
                )
            ]
        )
        let engine = FluidAudioSystemChunkTranscriptionEngine(
            sessionAudioLoader: StubSessionAudioLoader(
                preparedAudio: PreparedSessionAudio(
                    samples: Array(repeating: 0.1, count: 80_000),
                    sampleRate: 16_000,
                    durationMs: 5_000,
                    sourceURL: systemAudioURL
                )
            ),
            transcriptionService: transcriptionService
        )

        let result = try await engine.transcribeSystemChunks(
            systemAudioURL: systemAudioURL,
            diarization: DiarizationDocument(
                version: 1,
                sessionID: UUID(),
                createdAt: Date(),
                segments: [
                    DiarizationSegment(id: "d1", speaker: "speaker-a", startMs: 1_000, endMs: 3_000, confidence: 0.88)
                ]
            ),
            sessionID: UUID(),
            configuration: ASREngineConfiguration(modelURL: modelDirectory)
        )

        XCTAssertEqual(transcriptionService.recordedChunkDurations, [2_000])
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].speakerKey, "speaker-a")
        XCTAssertEqual(result.segments[0].startMs, 1_120)
        XCTAssertEqual(result.segments[0].endMs, 1_480)
        XCTAssertEqual(result.segments[0].words?.first?.startMs, 1_120)
        XCTAssertEqual(result.segments[0].words?.first?.endMs, 1_480)
    }

    func testChunkEngineSkipsInvalidOrOutOfBoundsDiarizationSegments() async throws {
        let systemAudioURL = tempDirectory.appendingPathComponent("system.raw.flac")
        FileManager.default.createFile(atPath: systemAudioURL.path, contents: Data("audio".utf8))
        let modelDirectory = try createFluidModelDirectory(named: "fluid-v3-invalid")
        let transcriptionService = RecordingChunkTranscriptionService(outputs: [])
        let engine = FluidAudioSystemChunkTranscriptionEngine(
            sessionAudioLoader: StubSessionAudioLoader(
                preparedAudio: PreparedSessionAudio(
                    samples: Array(repeating: 0.1, count: 16_000),
                    sampleRate: 16_000,
                    durationMs: 1_000,
                    sourceURL: systemAudioURL
                )
            ),
            transcriptionService: transcriptionService
        )

        let result = try await engine.transcribeSystemChunks(
            systemAudioURL: systemAudioURL,
            diarization: DiarizationDocument(
                version: 1,
                sessionID: UUID(),
                createdAt: Date(),
                segments: [
                    DiarizationSegment(id: "d1", speaker: "speaker-a", startMs: 1_500, endMs: 2_000, confidence: 0.88),
                    DiarizationSegment(id: "d2", speaker: "speaker-b", startMs: 700, endMs: 700, confidence: 0.91)
                ]
            ),
            sessionID: UUID(),
            configuration: ASREngineConfiguration(modelURL: modelDirectory)
        )

        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertTrue(transcriptionService.recordedChunkDurations.isEmpty)
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

private struct StubSessionAudioLoader: FluidAudioSessionAudioLoading {
    let preparedAudio: PreparedSessionAudio

    func loadAudio(from audioURL: URL) throws -> PreparedSessionAudio {
        preparedAudio
    }
}

private final class RecordingChunkTranscriptionService: FluidAudioTranscriptionServicing, @unchecked Sendable {
    var outputs: [FluidAudioRunnerOutput]
    private(set) var recordedChunkDurations: [Int] = []

    init(outputs: [FluidAudioRunnerOutput]) {
        self.outputs = outputs
    }

    func transcribe(
        preparedAudio: PreparedSessionAudio,
        modelDirectoryURL: URL,
        channel: TranscriptChannel
    ) async throws -> FluidAudioRunnerOutput {
        recordedChunkDurations.append(preparedAudio.durationMs)
        guard !outputs.isEmpty else {
            return FluidAudioRunnerOutput(language: nil, segments: [])
        }
        return outputs.removeFirst()
    }
}

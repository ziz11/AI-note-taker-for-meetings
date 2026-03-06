import XCTest
@testable import CallRecorderPro

final class TranscriptionPipelineTests: XCTestCase {
    func testDiarizationFailureFallsBackToRemote() async throws {
        let pipeline = TranscriptionPipeline(
            asrEngine: MockASREngine(),
            diarizationService: FailingDiarizationService()
        )

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
            modelResolution: RequiredModelsResolution(asrModelURL: modelURL, diarizationModelURL: nil)
        )
        XCTAssertEqual(result.state, .ready)
        XCTAssertNil(result.systemDiarizationJSONFile)

        let transcriptURL = temp.appendingPathComponent("transcript.json")
        let data = try Data(contentsOf: transcriptURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(TranscriptDocument.self, from: data)
        XCTAssertTrue(doc.segments.contains(where: { $0.channel == .system && $0.speaker == "Remote" }))
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

    private struct FailingDiarizationService: SystemDiarizationService {
        func diarize(
            systemAudioURL: URL,
            sessionID: UUID,
            configuration: DiarizationServiceConfiguration
        ) async throws -> DiarizationDocument {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}

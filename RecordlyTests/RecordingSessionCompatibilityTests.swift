import XCTest
@testable import Recordly

final class RecordingSessionCompatibilityTests: XCTestCase {
    func testOldSessionJSONDecodesWithoutNewFields() throws {
        let json = """
        {
          "id": "7E035153-985A-4301-BC0A-F2FDD68AFA6E",
          "title": "Old",
          "createdAt": "2026-03-06T10:00:00Z",
          "duration": 12,
          "lifecycleState": "ready",
          "transcriptState": "ready",
          "source": "liveCapture",
          "notes": "ok",
          "assets": {
            "microphoneFile": "microphone.m4a",
            "systemAudioFile": "system-audio.caf",
            "transcriptFile": "transcript.txt",
            "srtFile": "transcript.srt"
          }
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(RecordingSession.self, from: Data(json.utf8))

        XCTAssertFalse(session.isFavorite)
        XCTAssertEqual(session.assets.transcriptJSONFile, nil)
        XCTAssertEqual(session.assets.micASRJSONFile, nil)
        XCTAssertEqual(session.assets.systemASRJSONFile, nil)
        XCTAssertEqual(session.assets.systemDiarizationJSONFile, nil)
    }

    func testTranscriptProgressMapping() {
        XCTAssertNil(makeSession(state: .idle).transcriptProgress)
        XCTAssertEqual(makeSession(state: .queued).transcriptProgress, 0.08)
        XCTAssertEqual(makeSession(state: .transcribingMic).transcriptProgress, 0.24)
        XCTAssertEqual(makeSession(state: .transcribingSystem).transcriptProgress, 0.46)
        XCTAssertEqual(makeSession(state: .diarizingSystem).transcriptProgress, 0.64)
        XCTAssertEqual(makeSession(state: .merging).transcriptProgress, 0.82)
        XCTAssertEqual(makeSession(state: .renderingOutputs).transcriptProgress, 0.94)
        XCTAssertEqual(makeSession(state: .ready).transcriptProgress, 1)
        XCTAssertNil(makeSession(state: .failed).transcriptProgress)
    }

    func testHasSummarizationSourceWhenOnlySRTExists() {
        var session = makeSession(state: .ready)
        session.assets.srtFile = "transcript.srt"

        XCTAssertTrue(session.hasSummarizationSource)
    }

    func testHasSummarizationSourceWhenNoTranscriptArtifactsExist() {
        let session = makeSession(state: .ready)
        XCTAssertFalse(session.hasSummarizationSource)
    }

    func testLegacyTranscriptJSONWithYouInfersMeRoleAndID() throws {
        let json = """
        {
          "version": 1,
          "sessionID": "7E035153-985A-4301-BC0A-F2FDD68AFA6E",
          "createdAt": "2026-03-06T10:00:00Z",
          "channelsPresent": ["mic", "system"],
          "diarizationApplied": true,
          "mergePolicy": "deterministicStartEndChannelID",
          "segments": [
            {
              "id": "m1",
              "channel": "mic",
              "speaker": "You",
              "startMs": 0,
              "endMs": 1000,
              "text": "hello"
            }
          ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(TranscriptDocument.self, from: Data(json.utf8))

        XCTAssertEqual(document.segments.first?.speakerRole, .me)
        XCTAssertEqual(document.segments.first?.speakerId, "me")
    }

    func testLegacyTranscriptJSONWithSpeakerLabelInfersRemoteRole() throws {
        let json = """
        {
          "version": 1,
          "sessionID": "7E035153-985A-4301-BC0A-F2FDD68AFA6E",
          "createdAt": "2026-03-06T10:00:00Z",
          "channelsPresent": ["system"],
          "diarizationApplied": true,
          "mergePolicy": "deterministicStartEndChannelID",
          "segments": [
            {
              "id": "s1",
              "channel": "system",
              "speaker": "Speaker 2",
              "startMs": 0,
              "endMs": 1000,
              "text": "hi"
            }
          ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(TranscriptDocument.self, from: Data(json.utf8))

        XCTAssertEqual(document.segments.first?.speakerRole, .remote)
        XCTAssertEqual(document.segments.first?.speakerId, "remote_2")
    }

    func testTranscriptSegmentRoundTripPreservesSpeakerRoleAndID() throws {
        let segment = TranscriptSegment(
            id: "s1",
            channel: .system,
            speaker: "Speaker 1",
            speakerRole: .remote,
            speakerId: "remote_1",
            startMs: 0,
            endMs: 1200,
            text: "hello",
            confidence: 0.9,
            language: "en",
            speakerConfidence: 0.8,
            words: nil
        )

        let document = TranscriptDocument(
            version: 1,
            sessionID: UUID(),
            createdAt: Date(),
            channelsPresent: [.system],
            diarizationApplied: true,
            mergePolicy: .deterministicStartEndChannelID,
            segments: [segment]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(document)
        let decoded = try decoder.decode(TranscriptDocument.self, from: data)

        XCTAssertEqual(decoded.segments.first?.speakerRole, .remote)
        XCTAssertEqual(decoded.segments.first?.speakerId, "remote_1")
    }

    private func makeSession(state: TranscriptPipelineState) -> RecordingSession {
        RecordingSession(
            id: UUID(),
            title: "Test",
            createdAt: Date(),
            duration: 42,
            lifecycleState: .processing,
            transcriptState: state,
            source: .liveCapture,
            notes: "",
            assets: RecordingAssets()
        )
    }

    func testAdaptiveLayoutUsesCompactThresholdAtOrBelow800() {
        XCTAssertTrue(AdaptiveLayoutMetrics.isCompactWindow(800))
        XCTAssertTrue(AdaptiveLayoutMetrics.isCompactWindow(760))
    }

    func testAdaptiveLayoutUsesRegularThresholdAbove800() {
        XCTAssertFalse(AdaptiveLayoutMetrics.isCompactWindow(801))
        XCTAssertFalse(AdaptiveLayoutMetrics.isCompactWindow(1040))
    }

    func testAdaptiveLayoutSidebarModes() {
        XCTAssertTrue(AdaptiveLayoutMetrics.isSidebarNarrow(259))
        XCTAssertFalse(AdaptiveLayoutMetrics.isSidebarNarrow(260))
    }
}

import XCTest
@testable import CallRecorderPro

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

        XCTAssertEqual(session.assets.transcriptJSONFile, nil)
        XCTAssertEqual(session.assets.micASRJSONFile, nil)
        XCTAssertEqual(session.assets.systemASRJSONFile, nil)
        XCTAssertEqual(session.assets.systemDiarizationJSONFile, nil)
    }
}

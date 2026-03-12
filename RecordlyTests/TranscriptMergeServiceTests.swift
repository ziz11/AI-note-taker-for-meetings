import XCTest
@testable import Recordly

final class TranscriptMergeServiceTests: XCTestCase {
    func testMergeSortIsDeterministicByRules() {
        let service = TranscriptMergeService()

        let mic = TranscriptSegment(
            id: "b",
            channel: .mic,
            speaker: "You",
            speakerRole: .me,
            speakerId: "me",
            startMs: 1000,
            endMs: 2000,
            text: "mic",
            confidence: nil,
            language: nil,
            speakerConfidence: nil,
            words: nil
        )
        let sys = TranscriptSegment(
            id: "a",
            channel: .system,
            speaker: "Speaker 1",
            speakerRole: .remote,
            speakerId: "remote_1",
            startMs: 1000,
            endMs: 2000,
            text: "sys",
            confidence: nil,
            language: nil,
            speakerConfidence: nil,
            words: nil
        )

        let merged = service.merge(micSegments: [mic], systemSegments: [sys])
        XCTAssertEqual(merged.map(\.channel), [.mic, .system])
        XCTAssertEqual(merged.map(\.speakerRole), [.me, .remote])
        XCTAssertEqual(merged.map(\.speakerId), ["me", "remote_1"])
    }

    func testMicOnlyMerge() {
        let service = TranscriptMergeService()
        let mic = TranscriptSegment(id: "m1", channel: .mic, speaker: "You", speakerRole: .me, speakerId: "me", startMs: 0, endMs: 1000, text: "hello", confidence: nil, language: nil, speakerConfidence: nil, words: nil)

        let merged = service.merge(micSegments: [mic], systemSegments: [])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.channel, .mic)
        XCTAssertEqual(merged.first?.speakerRole, .me)
        XCTAssertEqual(merged.first?.speakerId, "me")
    }

    func testSystemOnlyMerge() {
        let service = TranscriptMergeService()
        let sys = TranscriptSegment(id: "s1", channel: .system, speaker: "Speaker 1", speakerRole: .remote, speakerId: "remote_1", startMs: 0, endMs: 1000, text: "hello", confidence: nil, language: nil, speakerConfidence: nil, words: nil)

        let merged = service.merge(micSegments: [], systemSegments: [sys])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.channel, .system)
        XCTAssertEqual(merged.first?.speakerRole, .remote)
        XCTAssertEqual(merged.first?.speakerId, "remote_1")
    }

    func testMergePreservesSortedTimelineAndSpeakerIdentity() {
        let service = TranscriptMergeService()
        let mic = TranscriptSegment(id: "m2", channel: .mic, speaker: "You", speakerRole: .me, speakerId: "me", startMs: 1500, endMs: 2000, text: "me", confidence: nil, language: nil, speakerConfidence: nil, words: nil)
        let system = TranscriptSegment(id: "s1", channel: .system, speaker: "Speaker 2", speakerRole: .remote, speakerId: "remote_2", startMs: 1000, endMs: 1400, text: "them", confidence: nil, language: nil, speakerConfidence: nil, words: nil)

        let merged = service.merge(micSegments: [mic], systemSegments: [system])

        XCTAssertEqual(merged.map(\.id), ["s1", "m2"])
        XCTAssertEqual(merged.map(\.speakerRole), [.remote, .me])
        XCTAssertEqual(merged.map(\.speakerId), ["remote_2", "me"])
    }
}

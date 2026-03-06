import XCTest
@testable import CallRecorderPro

final class TranscriptMergeServiceTests: XCTestCase {
    func testMergeSortIsDeterministicByRules() {
        let service = TranscriptMergeService()

        let mic = TranscriptSegment(
            id: "b",
            channel: .mic,
            speaker: "You",
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
            speaker: "Remote",
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
    }

    func testMicOnlyMerge() {
        let service = TranscriptMergeService()
        let mic = TranscriptSegment(id: "m1", channel: .mic, speaker: "You", startMs: 0, endMs: 1000, text: "hello", confidence: nil, language: nil, speakerConfidence: nil, words: nil)

        let merged = service.merge(micSegments: [mic], systemSegments: [])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.channel, .mic)
    }

    func testSystemOnlyMerge() {
        let service = TranscriptMergeService()
        let sys = TranscriptSegment(id: "s1", channel: .system, speaker: "Remote", startMs: 0, endMs: 1000, text: "hello", confidence: nil, language: nil, speakerConfidence: nil, words: nil)

        let merged = service.merge(micSegments: [], systemSegments: [sys])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.channel, .system)
    }
}

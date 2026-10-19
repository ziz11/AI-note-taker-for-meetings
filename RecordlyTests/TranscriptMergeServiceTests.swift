import XCTest
@testable import Recordly

final class TranscriptMergeServiceTests: XCTestCase {
    func testDisplayPreservesSubwordSpacingAndNeverBreaksInsideWord() {
        let words = ["Это", "за", "пла", "ни", "ро", "ван", "ный", "спринт", "."].enumerated().map {
            ASRWord(word: $0.element, startMs: $0.offset * 1_000, endMs: $0.offset * 1_000 + 100, confidence: 0.9)
        }
        let segment = TranscriptSegment(id: "subwords", channel: .mic, speaker: "You", speakerRole: .me,
            speakerId: "me", startMs: 0, endMs: 8_100, text: "Это запланированный спринт.", confidence: nil,
            language: "ru", speakerConfidence: nil, words: words)
        let display = StructuredTranscriptExportService(maxCharactersPerSegment: 8, longPauseThresholdMs: 500)
            .makeDisplaySegments(from: [segment])
        XCTAssertEqual(display.map(\.text), ["Это", "запланированный", "спринт."])
        XCTAssertEqual(display.map(\.startMs), [0, 1_000, 7_000])
        XCTAssertEqual(display.map(\.endMs), [100, 6_100, 8_100])
    }

    func testTimedTextRetainsBoundaryWhenFirstSubtokenOfWordIsFiltered() {
        let words = ["Это", "по", "то", "му"].enumerated().map {
            ASRWord(word: $0.element, startMs: $0.offset * 100, endMs: $0.offset * 100 + 90, confidence: nil)
        }
        let text = ASRTimedText(text: "Это по тому", words: words)
        XCTAssertEqual(text.text(for: [words[0], words[1], words[3]]), "Это по му")
    }

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

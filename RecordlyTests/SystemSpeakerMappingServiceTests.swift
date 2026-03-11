import XCTest
@testable import Recordly

final class SystemTranscriptAlignmentServiceTests: XCTestCase {
    func testAlignmentUsesBestOverlapAndAssignsStableRemoteSpeakerIDs() {
        let service = SystemTranscriptAlignmentService(overlapThresholdRatio: 0.2)

        let aligned = service.align(
            asrSegments: [
                ASRSegment(id: "seg-1", startMs: 0, endMs: 1000, text: "first", confidence: nil, language: nil, words: nil),
                ASRSegment(id: "seg-2", startMs: 1100, endMs: 2100, text: "second", confidence: nil, language: nil, words: nil),
            ],
            diarization: DiarizationDocument(
                version: 1,
                sessionID: UUID(),
                createdAt: Date(),
                segments: [
                    DiarizationSegment(id: "d1", speaker: "fluid-b", startMs: 1100, endMs: 2100, confidence: 0.92),
                    DiarizationSegment(id: "d2", speaker: "fluid-a", startMs: 0, endMs: 1000, confidence: 0.94),
                ]
            )
        )

        XCTAssertEqual(aligned.map(\.speakerRole), [.remote, .remote])
        XCTAssertEqual(aligned.map(\.speakerId), ["remote_1", "remote_2"])
        XCTAssertEqual(aligned.map(\.speaker), ["Speaker 1", "Speaker 2"])
    }

    func testAlignmentCollapsesOverlappingDiarizationToSingleBestSpeaker() {
        let service = SystemTranscriptAlignmentService(overlapThresholdRatio: 0.2)

        let aligned = service.align(
            asrSegments: [
                ASRSegment(id: "seg-1", startMs: 1000, endMs: 2000, text: "hello", confidence: nil, language: nil, words: nil)
            ],
            diarization: DiarizationDocument(
                version: 1,
                sessionID: UUID(),
                createdAt: Date(),
                segments: [
                    DiarizationSegment(id: "d1", speaker: "speaker-a", startMs: 900, endMs: 2100, confidence: 0.9),
                    DiarizationSegment(id: "d2", speaker: "speaker-b", startMs: 1400, endMs: 1700, confidence: 0.95),
                ]
            )
        )

        XCTAssertEqual(aligned.count, 1)
        XCTAssertEqual(aligned[0].speaker, "Speaker 1")
        XCTAssertEqual(aligned[0].speakerRole, .remote)
        XCTAssertEqual(aligned[0].speakerId, "remote_1")
    }

    func testLowOverlapFallsBackToRemoteUnknownSpeakerRole() {
        let service = SystemTranscriptAlignmentService(overlapThresholdRatio: 0.8)

        let aligned = service.align(
            asrSegments: [
                ASRSegment(id: "seg-1", startMs: 1000, endMs: 2000, text: "hello", confidence: nil, language: nil, words: nil)
            ],
            diarization: DiarizationDocument(
                version: 1,
                sessionID: UUID(),
                createdAt: Date(),
                segments: [
                    DiarizationSegment(id: "d1", speaker: "Speaker 1", startMs: 1900, endMs: 2000, confidence: 0.9)
                ]
            )
        )

        XCTAssertEqual(aligned.first?.speaker, "Remote")
        XCTAssertEqual(aligned.first?.speakerRole, .unknown)
        XCTAssertNil(aligned.first?.speakerId)
    }

    func testMissingDiarizationMarksSpeakerAsUnknown() {
        let service = SystemTranscriptAlignmentService()

        let aligned = service.align(
            asrSegments: [
                ASRSegment(id: "seg-1", startMs: 0, endMs: 1000, text: "hello", confidence: nil, language: nil, words: nil)
            ],
            diarization: nil
        )

        XCTAssertEqual(aligned.first?.speaker, "Remote")
        XCTAssertEqual(aligned.first?.speakerRole, .unknown)
        XCTAssertNil(aligned.first?.speakerId)
    }
}

import XCTest
@testable import Recordly

final class SystemSpeakerMappingServiceTests: XCTestCase {
    func testMappingUsesMaxOverlapAndMarksRemoteSpeakerRole() {
        let service = SystemSpeakerMappingService(overlapThresholdRatio: 0.2)

        let systemASR = [
            ASRSegment(id: "seg-1", startMs: 1000, endMs: 2000, text: "hello", confidence: nil, language: nil, words: nil)
        ]
        let diarization = DiarizationDocument(
            version: 1,
            sessionID: UUID(),
            createdAt: Date(),
            segments: [
                DiarizationSegment(id: "d1", speaker: "Speaker 1", startMs: 900, endMs: 2100, confidence: 0.9)
            ]
        )

        let mapped = service.mapSystemSpeakers(asrSegments: systemASR, diarization: diarization)
        XCTAssertEqual(mapped.first?.speaker, "Speaker 1")
        XCTAssertEqual(mapped.first?.speakerRole, .remote)
        XCTAssertEqual(mapped.first?.speakerId, "remote_1")
    }

    func testLowOverlapGetsUnknownSpeakerRole() {
        let service = SystemSpeakerMappingService(overlapThresholdRatio: 0.8)

        let systemASR = [
            ASRSegment(id: "seg-1", startMs: 1000, endMs: 2000, text: "hello", confidence: nil, language: nil, words: nil)
        ]
        let diarization = DiarizationDocument(
            version: 1,
            sessionID: UUID(),
            createdAt: Date(),
            segments: [
                DiarizationSegment(id: "d1", speaker: "Speaker 1", startMs: 1900, endMs: 2000, confidence: 0.9)
            ]
        )

        let mapped = service.mapSystemSpeakers(asrSegments: systemASR, diarization: diarization)
        XCTAssertEqual(mapped.first?.speaker, "Unknown Speaker")
        XCTAssertEqual(mapped.first?.speakerRole, .unknown)
        XCTAssertNil(mapped.first?.speakerId)
    }

    func testMissingDiarizationMarksSpeakerAsUnknown() {
        let service = SystemSpeakerMappingService()
        let systemASR = [
            ASRSegment(id: "seg-1", startMs: 0, endMs: 1000, text: "hello", confidence: nil, language: nil, words: nil)
        ]

        let mapped = service.mapSystemSpeakers(asrSegments: systemASR, diarization: nil)

        XCTAssertEqual(mapped.first?.speaker, "Remote")
        XCTAssertEqual(mapped.first?.speakerRole, .unknown)
        XCTAssertNil(mapped.first?.speakerId)
    }

    func testMappingAssignsStableRemoteIDsInChronologicalSpeakerOrder() {
        let service = SystemSpeakerMappingService(overlapThresholdRatio: 0.2)
        let systemASR = [
            ASRSegment(id: "seg-1", startMs: 0, endMs: 1000, text: "first", confidence: nil, language: nil, words: nil),
            ASRSegment(id: "seg-2", startMs: 1100, endMs: 2100, text: "second", confidence: nil, language: nil, words: nil),
        ]
        let diarization = DiarizationDocument(
            version: 1,
            sessionID: UUID(),
            createdAt: Date(),
            segments: [
                DiarizationSegment(id: "d1", speaker: "fluid-B", startMs: 1100, endMs: 2100, confidence: 0.92),
                DiarizationSegment(id: "d2", speaker: "fluid-A", startMs: 0, endMs: 1000, confidence: 0.94),
            ]
        )

        let mapped = service.mapSystemSpeakers(asrSegments: systemASR, diarization: diarization)

        XCTAssertEqual(mapped.map(\.speakerRole), [.remote, .remote])
        XCTAssertEqual(mapped.map(\.speakerId), ["remote_1", "remote_2"])
        XCTAssertEqual(mapped.map(\.speaker), ["Speaker 1", "Speaker 2"])
    }
}

import XCTest
@testable import CallRecorderPro

final class SystemSpeakerMappingServiceTests: XCTestCase {
    func testMappingUsesMaxOverlap() {
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
    }

    func testLowOverlapGetsUnknownSpeaker() {
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
    }
}

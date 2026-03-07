import Foundation

struct SystemSpeakerMappingService {
    let overlapThresholdRatio: Double

    init(overlapThresholdRatio: Double = 0.25) {
        self.overlapThresholdRatio = overlapThresholdRatio
    }

    func mapSystemSpeakers(asrSegments: [ASRSegment], diarization: DiarizationDocument?) -> [TranscriptSegment] {
        asrSegments.map { asr in
            let speakerInfo = bestSpeaker(for: asr, in: diarization)
            return TranscriptSegment(
                id: asr.id,
                channel: .system,
                speaker: speakerInfo.name,
                startMs: asr.startMs,
                endMs: asr.endMs,
                text: asr.text,
                confidence: asr.confidence,
                language: asr.language,
                speakerConfidence: speakerInfo.confidence,
                words: asr.words
            )
        }
    }

    private func bestSpeaker(for segment: ASRSegment, in diarization: DiarizationDocument?) -> (name: String, confidence: Double?) {
        guard let diarization else {
            return ("Remote", nil)
        }

        let segmentDuration = max(segment.endMs - segment.startMs, 1)
        var bestMatch: DiarizationSegment?
        var bestOverlap = 0

        for candidate in diarization.segments {
            let overlapStart = max(segment.startMs, candidate.startMs)
            let overlapEnd = min(segment.endMs, candidate.endMs)
            let overlap = max(overlapEnd - overlapStart, 0)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestMatch = candidate
            }
        }

        guard let bestMatch else {
            return ("Unknown Speaker", nil)
        }

        let ratio = Double(bestOverlap) / Double(segmentDuration)
        guard ratio >= overlapThresholdRatio else {
            return ("Unknown Speaker", bestMatch.confidence)
        }

        return (bestMatch.speaker, bestMatch.confidence)
    }
}

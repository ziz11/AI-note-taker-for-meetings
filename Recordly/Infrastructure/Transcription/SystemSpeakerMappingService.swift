import Foundation

struct SystemSpeakerMappingService {
    let overlapThresholdRatio: Double

    private struct SpeakerInfo {
        let displayLabel: String
        let role: SpeakerRole
        let speakerId: String?
        let confidence: Double?
    }

    private struct RemoteSpeakerAlias {
        let displayLabel: String
        let speakerId: String
    }

    init(overlapThresholdRatio: Double = 0.25) {
        self.overlapThresholdRatio = overlapThresholdRatio
    }

    func mapSystemSpeakers(asrSegments: [ASRSegment], diarization: DiarizationDocument?) -> [TranscriptSegment] {
        let remoteAliases = makeRemoteSpeakerAliases(in: diarization)

        return asrSegments.map { asr in
            let speakerInfo = bestSpeaker(for: asr, in: diarization, remoteAliases: remoteAliases)
            return TranscriptSegment(
                id: asr.id,
                channel: .system,
                speaker: speakerInfo.displayLabel,
                speakerRole: speakerInfo.role,
                speakerId: speakerInfo.speakerId,
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

    private func bestSpeaker(
        for segment: ASRSegment,
        in diarization: DiarizationDocument?,
        remoteAliases: [String: RemoteSpeakerAlias]
    ) -> SpeakerInfo {
        guard let diarization else {
            return SpeakerInfo(displayLabel: "Remote", role: .unknown, speakerId: nil, confidence: nil)
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
            return SpeakerInfo(displayLabel: "Unknown Speaker", role: .unknown, speakerId: nil, confidence: nil)
        }

        let ratio = Double(bestOverlap) / Double(segmentDuration)
        guard ratio >= overlapThresholdRatio else {
            return SpeakerInfo(displayLabel: "Unknown Speaker", role: .unknown, speakerId: nil, confidence: bestMatch.confidence)
        }

        let alias = remoteAliases[bestMatch.speaker]
        return SpeakerInfo(
            displayLabel: alias?.displayLabel ?? "Remote",
            role: .remote,
            speakerId: alias?.speakerId,
            confidence: bestMatch.confidence
        )
    }

    private func makeRemoteSpeakerAliases(in diarization: DiarizationDocument?) -> [String: RemoteSpeakerAlias] {
        guard let diarization else {
            return [:]
        }

        var aliases: [String: RemoteSpeakerAlias] = [:]
        let orderedSegments = diarization.segments.sorted { lhs, rhs in
            if lhs.startMs != rhs.startMs { return lhs.startMs < rhs.startMs }
            if lhs.endMs != rhs.endMs { return lhs.endMs < rhs.endMs }
            if lhs.speaker != rhs.speaker { return lhs.speaker < rhs.speaker }
            return lhs.id < rhs.id
        }

        for segment in orderedSegments where aliases[segment.speaker] == nil {
            let index = aliases.count + 1
            aliases[segment.speaker] = RemoteSpeakerAlias(
                displayLabel: "Speaker \(index)",
                speakerId: "remote_\(index)"
            )
        }

        return aliases
    }
}

import Foundation

struct TranscriptMergeService {
    func merge(micSegments: [TranscriptSegment], systemSegments: [TranscriptSegment]) -> [TranscriptSegment] {
        let all = micSegments + systemSegments
        return all.sorted { lhs, rhs in
            if lhs.startMs != rhs.startMs { return lhs.startMs < rhs.startMs }
            if lhs.endMs != rhs.endMs { return lhs.endMs < rhs.endMs }
            if lhs.channel.priority != rhs.channel.priority { return lhs.channel.priority < rhs.channel.priority }
            return lhs.id < rhs.id
        }
    }
}

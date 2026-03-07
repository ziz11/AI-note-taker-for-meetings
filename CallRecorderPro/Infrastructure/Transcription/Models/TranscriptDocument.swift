import Foundation

enum TranscriptChannel: String, Codable, Hashable, CaseIterable {
    case mic
    case system

    var priority: Int {
        switch self {
        case .mic:
            return 0
        case .system:
            return 1
        }
    }
}

enum TranscriptMergePolicy: String, Codable, Hashable {
    case deterministicStartEndChannelID
}

struct TranscriptSegment: Codable, Hashable {
    var id: String
    var channel: TranscriptChannel
    var speaker: String
    var startMs: Int
    var endMs: Int
    var text: String
    var confidence: Double?
    var language: String?
    var speakerConfidence: Double?
    var words: [ASRWord]?
}

struct TranscriptDocument: Codable, Hashable {
    var version: Int
    var sessionID: UUID
    var createdAt: Date
    var channelsPresent: [TranscriptChannel]
    var diarizationApplied: Bool
    var mergePolicy: TranscriptMergePolicy
    var segments: [TranscriptSegment]
}

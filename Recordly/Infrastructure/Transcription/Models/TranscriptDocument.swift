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

enum SpeakerRole: String, Codable, Hashable {
    case me
    case remote
    case unknown
}

struct TranscriptSegment: Codable, Hashable {
    var id: String
    var channel: TranscriptChannel
    var speaker: String?
    var speakerRole: SpeakerRole
    var speakerId: String?
    var startMs: Int
    var endMs: Int
    var text: String
    var confidence: Double?
    var language: String?
    var speakerConfidence: Double?
    var words: [ASRWord]?

    var displaySpeakerLabel: String {
        if let speaker, !speaker.isEmpty {
            return speaker
        }

        switch speakerRole {
        case .me:
            return "You"
        case .remote:
            if let speakerId, let remoteIndex = Self.remoteIndex(from: speakerId) {
                return "Speaker \(remoteIndex)"
            }
            return "Remote"
        case .unknown:
            return "Unknown Speaker"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case channel
        case speaker
        case speakerRole
        case speakerId
        case startMs
        case endMs
        case text
        case confidence
        case language
        case speakerConfidence
        case words
    }

    init(
        id: String,
        channel: TranscriptChannel,
        speaker: String?,
        speakerRole: SpeakerRole,
        speakerId: String?,
        startMs: Int,
        endMs: Int,
        text: String,
        confidence: Double?,
        language: String?,
        speakerConfidence: Double?,
        words: [ASRWord]?
    ) {
        self.id = id
        self.channel = channel
        self.speaker = speaker
        self.speakerRole = speakerRole
        self.speakerId = speakerId
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.confidence = confidence
        self.language = language
        self.speakerConfidence = speakerConfidence
        self.words = words
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        channel = try container.decode(TranscriptChannel.self, forKey: .channel)
        speaker = try container.decodeIfPresent(String.self, forKey: .speaker)
        startMs = try container.decode(Int.self, forKey: .startMs)
        endMs = try container.decode(Int.self, forKey: .endMs)
        text = try container.decode(String.self, forKey: .text)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        speakerConfidence = try container.decodeIfPresent(Double.self, forKey: .speakerConfidence)
        words = try container.decodeIfPresent([ASRWord].self, forKey: .words)

        if let decodedRole = try container.decodeIfPresent(SpeakerRole.self, forKey: .speakerRole) {
            speakerRole = decodedRole
            speakerId = try container.decodeIfPresent(String.self, forKey: .speakerId)
        } else {
            let inferred = Self.inferLegacySpeakerSemantics(from: speaker)
            speakerRole = inferred.role
            speakerId = inferred.speakerId
        }
    }

    private static func inferLegacySpeakerSemantics(from speaker: String?) -> (role: SpeakerRole, speakerId: String?) {
        guard let speaker, !speaker.isEmpty else {
            return (.unknown, nil)
        }

        if speaker == "You" {
            return (.me, "me")
        }

        if let remoteIndex = remoteIndex(from: speaker) {
            return (.remote, "remote_\(remoteIndex)")
        }

        return (.unknown, nil)
    }

    private static func remoteIndex(from speakerIdentifier: String) -> Int? {
        let trimmed = speakerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("remote_"), let index = Int(trimmed.dropFirst("remote_".count)) {
            return index
        }

        if trimmed.hasPrefix("Speaker "), let index = Int(trimmed.dropFirst("Speaker ".count)) {
            return index
        }

        return nil
    }
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

import Foundation

struct DiarizationSegment: Codable, Hashable {
    var id: String
    var speaker: String
    var startMs: Int
    var endMs: Int
    var confidence: Double?
}

struct DiarizationDocument: Codable, Hashable {
    var version: Int
    var sessionID: UUID
    var createdAt: Date
    var segments: [DiarizationSegment]
}

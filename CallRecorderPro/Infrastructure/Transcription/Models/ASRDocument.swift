import Foundation

struct ASRWord: Codable, Hashable {
    var word: String
    var startMs: Int
    var endMs: Int
    var confidence: Double?
}

struct ASRSegment: Codable, Hashable {
    var id: String
    var startMs: Int
    var endMs: Int
    var text: String
    var confidence: Double?
    var language: String?
    var words: [ASRWord]?
}

struct ASRDocument: Codable, Hashable {
    var version: Int
    var sessionID: UUID
    var channel: TranscriptChannel
    var createdAt: Date
    var segments: [ASRSegment]
}

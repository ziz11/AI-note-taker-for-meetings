import Foundation

struct DiarizationSegment: Codable, Hashable {
    var id: String
    var speaker: String
    var startMs: Int
    var endMs: Int
    var confidence: Double?
}

/// Backend-neutral normalized voice observations. Times are local to the bounded
/// diarization input. The matcher intersects them with exclusive owned turns.
struct DiarizationVoiceObservation: Codable, Hashable {
    var speaker: String
    var startMs: Int
    var endMs: Int
    var embedding: [Float]

    static func normalized(_ vector: [Float]) -> [Float]? {
        guard vector.count == 256, vector.allSatisfy(\.isFinite) else { return nil }
        let squared = vector.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard squared.isFinite, squared > 1e-12 else { return nil }
        let magnitude = sqrt(squared)
        return vector.map { Float(Double($0) / magnitude) }
    }
}

struct DiarizationDocument: Codable, Hashable {
    var version: Int
    var sessionID: UUID
    var createdAt: Date
    var segments: [DiarizationSegment]
    var voiceObservations: [DiarizationVoiceObservation]? = nil
    var embeddingSpace: String? = nil
    var embeddingArtifactFingerprint: String? = nil
}

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

/// Reconstructs any ordered selection of timed tokens using the decoded text's
/// whitespace, rather than assuming each token is a complete word. No token or
/// timestamp is rewritten, including when reading older inference caches.
struct ASRTimedText {
    private let words: [ASRWord]
    private let pieces: [String]?

    var isAligned: Bool { pieces != nil }

    init(text: String, words: [ASRWord]) {
        self.words = words
        let characters = Array(text)
        var cursor = 0
        var aligned: [String] = []
        for word in words {
            let start = cursor
            let token = word.word.filter { !$0.isWhitespace }
            guard !token.isEmpty else { pieces = nil; return }
            for character in token {
                while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
                guard cursor < characters.count, characters[cursor] == character else {
                    pieces = nil
                    return
                }
                cursor += 1
            }
            aligned.append(String(characters[start..<cursor]))
        }
        guard characters[cursor...].allSatisfy(\.isWhitespace) else { pieces = nil; return }
        pieces = aligned
    }

    func text(for selectedWords: [ASRWord]) -> String {
        guard let pieces else { return Self.joinWords(selectedWords) }
        var cursor = 0
        var result = ""
        for word in selectedWords {
            let skippedStart = cursor
            while cursor < words.count, words[cursor] != word { cursor += 1 }
            guard cursor < words.count else { return Self.joinWords(selectedWords) }
            let piece = pieces[cursor]
            // Filtering can remove the first subtoken carrying a word's space.
            // Carry that boundary forward instead of joining two separate words.
            let crossedBoundary = pieces[skippedStart..<cursor].contains { $0.contains(where: \.isWhitespace) }
            let tightPunctuation = piece.first.map { ",.!?;:)]}".contains($0) } == true
            if !result.isEmpty, crossedBoundary, piece.first?.isWhitespace != true, !tightPunctuation {
                result += " "
            }
            result += piece
            cursor += 1
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func canSplit(after index: Int) -> Bool {
        guard let pieces, pieces.indices.contains(index + 1) else { return true }
        return pieces[index + 1].first?.isWhitespace == true
    }

    private static func joinWords(_ words: [ASRWord]) -> String {
        var result = ""
        for word in words {
            let token = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            let tightPunctuation = token.first.map { ",.!?;:)]}".contains($0) } == true
            if !result.isEmpty, !tightPunctuation { result += " " }
            result += token
        }
        return result
    }
}

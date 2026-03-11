import Foundation

struct TranscriptRenderOutput {
    var transcriptText: String
    var srtText: String
}

struct StructuredTranscriptSegment: Codable, Hashable {
    var id: String
    var startMs: Int
    var endMs: Int
    var startTimestamp: String
    var endTimestamp: String
    var speaker: String
    var speakerRole: SpeakerRole
    var speakerId: String?
    var channel: TranscriptChannel
    var text: String
}

struct StructuredTranscriptDocument: Codable, Hashable {
    var version: Int
    var sessionID: UUID
    var createdAt: Date
    var segments: [StructuredTranscriptSegment]
}

struct StructuredTranscriptRenderOutput {
    var document: StructuredTranscriptDocument
    var text: String
}

struct TranscriptRenderService {
    func render(document: TranscriptDocument) -> TranscriptRenderOutput {
        let transcript = document.segments
            .map { "[\(Self.formatTime($0.startMs)) - \(Self.formatTime($0.endMs))] [\($0.displaySpeakerLabel)] \($0.text)" }
            .joined(separator: "\n")

        let srtChunks = document.segments.enumerated().map { index, segment in
            """
            \(index + 1)
            \(Self.formatSRTTime(segment.startMs)) --> \(Self.formatSRTTime(segment.endMs))
            [\(segment.displaySpeakerLabel)] \(segment.text)
            """
        }

        return TranscriptRenderOutput(
            transcriptText: transcript,
            srtText: srtChunks.joined(separator: "\n\n")
        )
    }
}

// Legacy export path retained for compatibility. The default transcription flow no longer writes these artifacts.
struct StructuredTranscriptExportService {
    let maxCharactersPerSegment: Int
    let longPauseThresholdMs: Int

    init(
        maxCharactersPerSegment: Int = 140,
        longPauseThresholdMs: Int = 900
    ) {
        self.maxCharactersPerSegment = maxCharactersPerSegment
        self.longPauseThresholdMs = longPauseThresholdMs
    }

    func render(
        document: TranscriptDocument,
        diarization: DiarizationDocument? = nil
    ) -> StructuredTranscriptRenderOutput {
        let structuredSegments = document.segments
            .flatMap { reflow(segment: $0, diarization: diarization) }
            .sorted { lhs, rhs in
                if lhs.startMs != rhs.startMs { return lhs.startMs < rhs.startMs }
                if lhs.endMs != rhs.endMs { return lhs.endMs < rhs.endMs }
                if lhs.channel.priority != rhs.channel.priority { return lhs.channel.priority < rhs.channel.priority }
                return lhs.id < rhs.id
            }

        let structuredDocument = StructuredTranscriptDocument(
            version: 1,
            sessionID: document.sessionID,
            createdAt: document.createdAt,
            segments: structuredSegments
        )

        let text = structuredSegments
            .map { "\($0.startTimestamp) | \($0.speaker) | \($0.text)" }
            .joined(separator: "\n")

        return StructuredTranscriptRenderOutput(
            document: structuredDocument,
            text: text
        )
    }

    private func reflow(
        segment: TranscriptSegment,
        diarization: DiarizationDocument?
    ) -> [StructuredTranscriptSegment] {
        guard let words = segment.words, !words.isEmpty else {
            return [makeStructuredSegment(from: segment, diarization: diarization, idSuffix: nil, startMs: segment.startMs, endMs: segment.endMs, text: segment.text)]
        }

        var result: [StructuredTranscriptSegment] = []
        var currentWords: [ASRWord] = []
        var chunkIndex = 1

        for (index, word) in words.enumerated() {
            currentWords.append(word)
            let nextWord = words.indices.contains(index + 1) ? words[index + 1] : nil
            let currentText = join(words: currentWords)
            let shouldSplit = endsSentence(word.word)
                || currentText.count >= maxCharactersPerSegment
                || gap(after: word, next: nextWord) >= longPauseThresholdMs

            if shouldSplit {
                result.append(
                    makeStructuredSegment(
                        from: segment,
                        diarization: diarization,
                        idSuffix: chunkIndex,
                        startMs: currentWords.first?.startMs ?? segment.startMs,
                        endMs: currentWords.last?.endMs ?? segment.endMs,
                        text: currentText
                    )
                )
                chunkIndex += 1
                currentWords.removeAll(keepingCapacity: true)
            }
        }

        if !currentWords.isEmpty {
            result.append(
                makeStructuredSegment(
                    from: segment,
                    diarization: diarization,
                    idSuffix: chunkIndex,
                    startMs: currentWords.first?.startMs ?? segment.startMs,
                    endMs: currentWords.last?.endMs ?? segment.endMs,
                    text: join(words: currentWords)
                )
            )
        }

        return result
    }

    private func makeStructuredSegment(
        from segment: TranscriptSegment,
        diarization: DiarizationDocument?,
        idSuffix: Int?,
        startMs: Int,
        endMs: Int,
        text: String
    ) -> StructuredTranscriptSegment {
        let resolvedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = if let idSuffix {
            "\(segment.id)-\(idSuffix)"
        } else {
            segment.id
        }

        let speakerIdentity = resolveSpeakerIdentity(
            for: segment,
            diarization: diarization,
            startMs: startMs,
            endMs: max(endMs, startMs + 1)
        )

        return StructuredTranscriptSegment(
            id: id,
            startMs: startMs,
            endMs: max(endMs, startMs + 1),
            startTimestamp: TranscriptRenderService.formatTimestamp(startMs),
            endTimestamp: TranscriptRenderService.formatTimestamp(max(endMs, startMs + 1)),
            speaker: speakerIdentity.label,
            speakerRole: speakerIdentity.role,
            speakerId: speakerIdentity.speakerId,
            channel: segment.channel,
            text: resolvedText.isEmpty ? segment.text : resolvedText
        )
    }

    private func resolveSpeakerIdentity(
        for segment: TranscriptSegment,
        diarization: DiarizationDocument?,
        startMs: Int,
        endMs: Int
    ) -> (label: String, role: SpeakerRole, speakerId: String?) {
        guard segment.channel == .system,
              let diarization else {
            return (segment.displaySpeakerLabel, segment.speakerRole, segment.speakerId)
        }

        let aliases = makeRemoteSpeakerAliases(in: diarization)
        let chunkDuration = max(endMs - startMs, 1)
        var bestMatch: DiarizationSegment?
        var bestOverlap = 0

        for candidate in diarization.segments {
            let overlapStart = max(startMs, candidate.startMs)
            let overlapEnd = min(endMs, candidate.endMs)
            let overlap = max(overlapEnd - overlapStart, 0)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestMatch = candidate
            }
        }

        guard let bestMatch,
              Double(bestOverlap) / Double(chunkDuration) >= 0.25 else {
            return (segment.displaySpeakerLabel, segment.speakerRole, segment.speakerId)
        }

        if let alias = aliases[bestMatch.speaker] {
            return (alias.displayLabel, .remote, alias.speakerId)
        }

        return (segment.displaySpeakerLabel, segment.speakerRole, segment.speakerId)
    }

    private func makeRemoteSpeakerAliases(in diarization: DiarizationDocument) -> [String: (displayLabel: String, speakerId: String)] {
        var aliases: [String: (displayLabel: String, speakerId: String)] = [:]
        let orderedSegments = diarization.segments.sorted { lhs, rhs in
            if lhs.startMs != rhs.startMs { return lhs.startMs < rhs.startMs }
            if lhs.endMs != rhs.endMs { return lhs.endMs < rhs.endMs }
            if lhs.speaker != rhs.speaker { return lhs.speaker < rhs.speaker }
            return lhs.id < rhs.id
        }

        for segment in orderedSegments where aliases[segment.speaker] == nil {
            let index = aliases.count + 1
            aliases[segment.speaker] = ("Speaker \(index)", "remote_\(index)")
        }

        return aliases
    }

    private func gap(after word: ASRWord, next: ASRWord?) -> Int {
        guard let next else { return 0 }
        return max(0, next.startMs - word.endMs)
    }

    private func endsSentence(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?") || trimmed.hasSuffix("…")
    }

    private func join(words: [ASRWord]) -> String {
        var result = ""

        for word in words {
            let token = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }

            if result.isEmpty || token.first.map(isTightPunctuation) == true {
                result += token
            } else {
                result += " \(token)"
            }
        }

        return result
    }

    private func isTightPunctuation(_ character: Character) -> Bool {
        [",", ".", "!", "?", ";", ":", ")", "]", "}"].contains(character)
    }
}

extension TranscriptRenderService {
    static func formatTimestamp(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    static func formatTime(_ ms: Int) -> String {
        let seconds = Double(ms) / 1000.0
        let minutes = Int(seconds) / 60
        let sec = Int(seconds) % 60
        return String(format: "%02d:%02d", minutes, sec)
    }

    static func formatSRTTime(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        let milliseconds = ms % 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, milliseconds)
    }
}

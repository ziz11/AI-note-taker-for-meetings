import Foundation

struct TranscriptRenderOutput {
    var transcriptText: String
    var srtText: String
}

struct TranscriptRenderService {
    func render(document: TranscriptDocument) -> TranscriptRenderOutput {
        let transcript = document.segments
            .map { "[\(formatTime($0.startMs)) - \(formatTime($0.endMs))] [\($0.speaker)] \($0.text)" }
            .joined(separator: "\n")

        let srtChunks = document.segments.enumerated().map { index, segment in
            """
            \(index + 1)
            \(formatSRTTime(segment.startMs)) --> \(formatSRTTime(segment.endMs))
            [\(segment.speaker)] \(segment.text)
            """
        }

        return TranscriptRenderOutput(
            transcriptText: transcript,
            srtText: srtChunks.joined(separator: "\n\n")
        )
    }

    private func formatTime(_ ms: Int) -> String {
        let seconds = Double(ms) / 1000.0
        let minutes = Int(seconds) / 60
        let sec = Int(seconds) % 60
        return String(format: "%02d:%02d", minutes, sec)
    }

    private func formatSRTTime(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        let milliseconds = ms % 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, milliseconds)
    }
}

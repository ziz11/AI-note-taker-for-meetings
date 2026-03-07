import Foundation

enum SummaryPromptBuilder {
    static let maxContextCharacters = 12_000

    static func build(transcript: String, srtText: String?, recordingTitle: String) -> String {
        let source = preferredSource(transcript: transcript, srtText: srtText)
        let trimmed = truncated(source, maxCharacters: maxContextCharacters)

        return """
        You are an expert meeting analyst.

        Your task is to summarize a conversation transcript.

        Return structured markdown using the exact sections below.

        Rules:

        - Use short bullet points
        - Each bullet must be one sentence
        - Do not repeat information
        - Do not invent facts
        - If a section has no items write: None

        Return ONLY markdown.

        Structure:

        ## Topics
        Key subjects discussed in the conversation.

        ## Decisions
        Confirmed decisions or agreements.

        ## Action Items
        Tasks assigned or implied actions.

        ## Risks
        Concerns, blockers, or unresolved issues.

        If the transcript is incomplete, summarize the available information.

        Recording title: \(recordingTitle)

        Transcript:
        \(trimmed)

        Write the summary now.
        """
    }

    private static func preferredSource(transcript: String, srtText: String?) -> String {
        if let srtText, !srtText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return srtText
        }
        return transcript
    }

    private static func truncated(_ text: String, maxCharacters: Int) -> String {
        if text.count > maxCharacters {
            return String(text.prefix(maxCharacters))
        }
        return text
    }
}

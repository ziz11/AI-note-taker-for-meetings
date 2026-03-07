import Foundation

enum SummaryPromptBuilder {
    static let maxContextCharacters = 12_000

    static func build(transcript: String, srtText: String?, recordingTitle: String) -> String {
        let source = preferredSource(transcript: transcript, srtText: srtText)
        let trimmed = truncated(source, maxCharacters: maxContextCharacters)

        return """
        You are an expert call analyst.

        Your task is to summarize a phone call transcript.

        Return structured markdown using the exact sections below.

        Rules:

        - Use short bullet points
        - Each bullet must be one sentence
        - Do not repeat information
        - Do not invent facts
        - Answer in Russian by default. Keep important English terms (product names, APIs) in original form.
        - Ignore obvious noise artifacts (e.g. [Motor], repeated broken fragments, ASR glitches) when possible.
        - For each topic include related agreements if present.
        - If a section has no items write: None

        Return ONLY markdown.

        Structure:

        ## Call Summary
        Overall summary of the call in 2-4 bullets.

        ## Topics
        Discussed topics with short per-topic summary and related agreements.

        ## Decisions
        Confirmed decisions and agreements.

        ## Action Items
        Follow-up tasks with owner/date when available.

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

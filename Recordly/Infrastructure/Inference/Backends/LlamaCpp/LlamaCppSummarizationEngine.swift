import Foundation

struct LlamaCppSummarizationEngine: SummarizationEngine {
    static let minimumTranscriptLength = 50

    private let runner: LlamaCppRunner

    init(runner: LlamaCppRunner = ProcessLlamaCppRunner(
        resolveBinaryURL: { try resolveLlamaBinaryURL() }
    )) {
        self.runner = runner
    }

    func summarize(
        transcript: String,
        srtText: String?,
        recordingTitle: String,
        configuration: SummarizationConfiguration
    ) async throws -> SummaryDocument {
        if Task.isCancelled {
            throw SummarizationError.cancelled
        }

        let effectiveSource = if let srtText, !srtText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            srtText
        } else {
            transcript
        }

        guard effectiveSource.count >= Self.minimumTranscriptLength else {
            throw SummarizationError.transcriptTooShort
        }

        guard FileManager.default.fileExists(atPath: configuration.modelURL.path) else {
            throw SummarizationError.modelMissing(configuration.modelURL)
        }

        let prompt = SummaryPromptBuilder.build(
            transcript: transcript,
            srtText: srtText,
            recordingTitle: recordingTitle
        )

        let output = try await runner.generate(prompt: prompt, configuration: configuration)

        if Task.isCancelled {
            throw SummarizationError.cancelled
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SummarizationError.emptyOutput
        }

        let document = try SummaryOutputParser.parse(trimmed)
        let hasStructuredContent = !document.topics.isEmpty
            || !document.decisions.isEmpty
            || !document.actionItems.isEmpty
            || !document.risks.isEmpty
        guard hasStructuredContent else {
            throw SummarizationError.outputParseFailed
        }

        return document
    }
}

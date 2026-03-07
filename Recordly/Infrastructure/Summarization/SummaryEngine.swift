import Foundation

struct SummarizationRuntimeSettings: Codable, Equatable, Sendable {
    var contextSize: Int
    var temperature: Double
    var topP: Double

    static let `default` = SummarizationRuntimeSettings(
        contextSize: 8_192,
        temperature: 0.3,
        topP: 0.9
    )
}

struct SummaryEngineConfiguration: Sendable {
    var modelURL: URL
    var runtime: SummarizationRuntimeSettings = .default
}

struct SummaryDocument: Equatable {
    var topics: [String]
    var decisions: [String]
    var actionItems: [String]
    var risks: [String]
    var rawMarkdown: String
}

enum SummarizationError: LocalizedError, Equatable {
    case binaryMissing
    case modelMissing(URL)
    case transcriptTooShort
    case inferenceFailed(message: String)
    case outputParseFailed
    case emptyOutput
    case cancelled

    var errorDescription: String? {
        switch self {
        case .binaryMissing:
            return "Summarization binary (llama-cli) was not found."
        case .modelMissing(let url):
            return "Summarization model is missing at: \(url.path)"
        case .transcriptTooShort:
            return "Transcript is too short to summarize."
        case .inferenceFailed(let message):
            return "Summarization inference failed: \(message)"
        case .outputParseFailed:
            return "Failed to parse summarization output."
        case .emptyOutput:
            return "Summarization produced empty output."
        case .cancelled:
            return "Summarization was cancelled."
        }
    }
}

protocol SummaryEngine {
    func summarize(
        transcript: String,
        srtText: String?,
        recordingTitle: String,
        configuration: SummaryEngineConfiguration
    ) async throws -> SummaryDocument
}

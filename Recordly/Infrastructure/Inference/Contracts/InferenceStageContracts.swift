import Foundation

@MainActor
protocol AudioCaptureEngine: AnyObject {
    func startCapture(in sessionDirectory: URL) async throws -> CaptureArtifacts
    func stopCapture() async throws -> CaptureArtifacts
    func currentMicrophoneLevel() -> Double
    func currentSystemAudioLevel() -> Double
    var systemAudioStatusLabel: String { get }
    func recoverPendingSessions(in recordingsDirectory: URL) async
}

struct ASREngineConfiguration: Sendable {
    var modelURL: URL
}

enum ASREngineRuntimeError: LocalizedError, Equatable {
    case modelMissing(URL)
    case inferenceFailed(message: String)
    case unsupportedFormat(URL)
    case outputParseFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .modelMissing(let url):
            return "ASR model is missing at: \(url.path)"
        case .inferenceFailed(let message):
            return "ASR inference failed: \(message)"
        case .unsupportedFormat(let url):
            return "Unsupported audio format for ASR: \(url.lastPathComponent)"
        case .outputParseFailed:
            return "Failed to parse ASR output."
        case .cancelled:
            return "ASR inference was cancelled."
        }
    }
}

protocol ASREngine {
    var displayName: String { get }
    func cacheFingerprint(configuration: ASREngineConfiguration) -> String
    func transcribe(
        audioURL: URL,
        channel: TranscriptChannel,
        sessionID: UUID,
        configuration: ASREngineConfiguration
    ) async throws -> ASRDocument
}

extension ASREngine {
    func cacheFingerprint(configuration: ASREngineConfiguration) -> String {
        "\(configuration.modelURL.standardizedFileURL.path)|backend:fluidaudio|v3"
    }
}

struct DiarizationEngineConfiguration: Sendable {
    var modelURL: URL?
}

protocol DiarizationEngine {
    func diarize(
        systemAudioURL: URL,
        sessionID: UUID,
        configuration: DiarizationEngineConfiguration
    ) async throws -> DiarizationDocument
}

struct SummarizationConfiguration: Sendable {
    var modelURL: URL
    var runtime: SummarizationRuntimeSettings = .default
}

protocol SummarizationEngine {
    func summarize(
        transcript: String,
        srtText: String?,
        recordingTitle: String,
        configuration: SummarizationConfiguration
    ) async throws -> SummaryDocument
}

struct VoiceActivitySegment: Equatable, Sendable {
    var startMs: Int
    var endMs: Int
}

struct VoiceActivityDetectionConfiguration: Sendable {
    var modelURL: URL?
}

protocol VoiceActivityDetectionEngine {
    func detectVoiceActivity(
        audioURL: URL,
        configuration: VoiceActivityDetectionConfiguration
    ) async throws -> [VoiceActivitySegment]
}

struct NoopVoiceActivityDetectionEngine: VoiceActivityDetectionEngine {
    func detectVoiceActivity(
        audioURL: URL,
        configuration: VoiceActivityDetectionConfiguration
    ) async throws -> [VoiceActivitySegment] {
        []
    }
}

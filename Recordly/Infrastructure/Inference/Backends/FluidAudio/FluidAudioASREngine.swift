import Foundation

#if arch(arm64) && canImport(FluidAudio)
import FluidAudio
#endif

struct FluidAudioModelValidator {
    static let requiredMarkers: [String] = [
        "parakeet_vocab.json",
        "Preprocessor.mlmodelc",
        "Encoder.mlmodelc",
        "Decoder.mlmodelc",
        "JointDecision.mlmodelc"
    ]

    static func isValidModelDirectory(_ modelDirectoryURL: URL, fileManager: FileManager = .default) -> Bool {
        guard let values = try? modelDirectoryURL.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true,
              fileManager.fileExists(atPath: modelDirectoryURL.path) else {
            return false
        }

        return requiredMarkers.allSatisfy { marker in
            fileManager.fileExists(atPath: modelDirectoryURL.appendingPathComponent(marker).path)
        }
    }

    static func validateModelDirectory(_ modelDirectoryURL: URL, fileManager: FileManager = .default) throws {
        guard isValidModelDirectory(modelDirectoryURL, fileManager: fileManager) else {
            throw ASREngineRuntimeError.inferenceFailed(
                message: "FluidAudio model directory is invalid. Expected staged assets: \(requiredMarkers.joined(separator: ", "))"
            )
        }
    }
}

protocol FluidAudioLanguageMapper {
    func map(language: ASRLanguage) -> String?
}

struct DefaultFluidAudioLanguageMapper: FluidAudioLanguageMapper {
    func map(language: ASRLanguage) -> String? {
        nil
    }
}

struct FluidAudioRunnerOutput {
    var language: String?
    var segments: [FluidAudioSegment]
}

struct FluidAudioSegment {
    var id: String
    var startMs: Int
    var endMs: Int
    var text: String
    var confidence: Double?
    var words: [ASRWord]?
}

protocol FluidAudioTranscribing {
    func transcribe(
        audioURL: URL,
        modelDirectoryURL: URL,
        channel: TranscriptChannel,
        languageCode: String?
    ) async throws -> FluidAudioRunnerOutput
}

final class FluidAudioTranscriber: FluidAudioTranscribing {
#if arch(arm64) && canImport(FluidAudio)
    private var cachedManager: AsrManager?
    private var cachedModelPath: String?
#endif

    func transcribe(
        audioURL: URL,
        modelDirectoryURL: URL,
        channel: TranscriptChannel,
        languageCode: String?
    ) async throws -> FluidAudioRunnerOutput {
#if arch(arm64) && canImport(FluidAudio)
        _ = languageCode
        let manager = try await resolveManager(for: modelDirectoryURL)
        let source = fluidSource(for: channel)
        let rawResult = try await manager.transcribe(audioURL, source: source)
        return mapResult(rawResult)
#else
        throw ASREngineRuntimeError.inferenceFailed(
            message: "FluidAudio SDK is not available. Add the FluidAudio Swift Package to Recordly target."
        )
#endif
    }

#if arch(arm64) && canImport(FluidAudio)
    private func resolveManager(for modelDirectoryURL: URL) async throws -> AsrManager {
        let modelPath = modelDirectoryURL.standardizedFileURL.path
        if let manager = cachedManager, cachedModelPath == modelPath {
            return manager
        }
        let models = try await AsrModels.load(from: modelDirectoryURL, configuration: nil, version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        cachedManager = manager
        cachedModelPath = modelPath
        return manager
    }

    private func fluidSource(for channel: TranscriptChannel) -> AudioSource {
        switch channel {
        case .system:
            return .system
        case .mic:
            return .microphone
        }
    }

    private func mapResult(_ result: ASRResult) -> FluidAudioRunnerOutput {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let confidence = Double(result.confidence)
        let words = mapTokenTimings(result.tokenTimings)
        let startMs = words.map(\.startMs).min() ?? 0
        let endMs = max(words.map(\.endMs).max() ?? (startMs + 1), startMs + 1)

        guard !text.isEmpty else {
            return FluidAudioRunnerOutput(language: nil, segments: [])
        }

        return FluidAudioRunnerOutput(
            language: nil,
            segments: [
                FluidAudioSegment(
                    id: "seg-1",
                    startMs: startMs,
                    endMs: endMs,
                    text: text,
                    confidence: confidence,
                    words: words.isEmpty ? nil : words
                )
            ]
        )
    }

    private func mapTokenTimings(_ timings: [TokenTiming]?) -> [ASRWord] {
        guard let timings else { return [] }

        return timings.compactMap { timing in
            let cleanedToken = timing.token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedToken.isEmpty else { return nil }

            let startMs = max(0, Int(timing.startTime * 1_000))
            let endMs = max(Int(timing.endTime * 1_000), startMs + 1)

            return ASRWord(
                word: cleanedToken,
                startMs: startMs,
                endMs: endMs,
                confidence: Double(timing.confidence)
            )
        }
    }
#endif
}

struct FluidAudioASREngine: ASREngine {
    let displayName: String = "FluidAudio"

    private let transcriber: FluidAudioTranscribing
    private let languageMapper: FluidAudioLanguageMapper
    private let fileManager: FileManager

    init(
        transcriber: FluidAudioTranscribing = FluidAudioTranscriber(),
        languageMapper: FluidAudioLanguageMapper = DefaultFluidAudioLanguageMapper(),
        fileManager: FileManager = .default
    ) {
        self.transcriber = transcriber
        self.languageMapper = languageMapper
        self.fileManager = fileManager
    }

    func cacheFingerprint(configuration: ASREngineConfiguration) -> String {
        let modelPath = configuration.modelURL.standardizedFileURL.path
        return "\(modelPath)|backend:fluidaudio|v3|lang:auto"
    }

    func transcribe(
        audioURL: URL,
        channel: TranscriptChannel,
        sessionID: UUID,
        configuration: ASREngineConfiguration
    ) async throws -> ASRDocument {
        if Task.isCancelled {
            throw ASREngineRuntimeError.cancelled
        }

        guard fileManager.fileExists(atPath: audioURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        guard fileManager.fileExists(atPath: configuration.modelURL.path) else {
            throw ASREngineRuntimeError.modelMissing(configuration.modelURL)
        }

        try FluidAudioModelValidator.validateModelDirectory(configuration.modelURL, fileManager: fileManager)

        let supportedExtensions: Set<String> = ["caf", "wav", "mp3", "m4a", "flac", "ogg"]
        let ext = audioURL.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw ASREngineRuntimeError.unsupportedFormat(audioURL)
        }

        let output = try await transcriber.transcribe(
            audioURL: audioURL,
            modelDirectoryURL: configuration.modelURL,
            channel: channel,
            languageCode: languageMapper.map(language: configuration.language)
        )

        if Task.isCancelled {
            throw ASREngineRuntimeError.cancelled
        }

        return ASRDocument(
            version: 1,
            sessionID: sessionID,
            channel: channel,
            createdAt: Date(),
            segments: output.segments.map {
                ASRSegment(
                    id: $0.id,
                    startMs: $0.startMs,
                    endMs: $0.endMs,
                    text: $0.text,
                    confidence: $0.confidence,
                    language: output.language,
                    words: $0.words
                )
            }
        )
    }
}

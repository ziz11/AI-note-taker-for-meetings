import Foundation

#if canImport(FluidAudio)
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

struct FluidAudioTranscriber: FluidAudioTranscribing {
    func transcribe(
        audioURL: URL,
        modelDirectoryURL: URL,
        channel: TranscriptChannel,
        languageCode: String?
    ) async throws -> FluidAudioRunnerOutput {
#if canImport(FluidAudio)
        _ = languageCode
        let models = try await AsrModels.load(from: modelDirectoryURL, configuration: nil, version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        let source = fluidSource(for: channel)
        let rawResult = try await manager.transcribe(audioURL, source: source)
        return mapResult(rawResult)
#else
        throw ASREngineRuntimeError.inferenceFailed(
            message: "FluidAudio SDK is not available. Add the FluidAudio Swift Package to Recordly target."
        )
#endif
    }

#if canImport(FluidAudio)
    private func fluidSource(for channel: TranscriptChannel) -> AudioSource {
        switch channel {
        case .system:
            return .system
        case .mic:
            return .microphone
        }
    }
#endif

    private func mapResult(_ result: Any) -> FluidAudioRunnerOutput {
        let text = extractText(from: result)
        let language = extractString(field: "language", from: result)
        let confidence = extractDouble(field: "confidence", from: result)
        let words = extractWords(from: result)
        let startMs = words.map(\.startMs).min() ?? 0
        let endMs = max(words.map(\.endMs).max() ?? (startMs + 1), startMs + 1)

        guard !text.isEmpty else {
            return FluidAudioRunnerOutput(language: language, segments: [])
        }

        return FluidAudioRunnerOutput(
            language: language,
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

    private func extractText(from result: Any) -> String {
        if let text = extractString(field: "text", from: result),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let transcript = extractString(field: "transcript", from: result),
           !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let tokens = extractWords(from: result).map(\.word)
        return tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractWords(from result: Any) -> [ASRWord] {
        guard let tokenTimings = extractArray(field: "tokenTimings", from: result) else {
            return []
        }

        return tokenTimings.compactMap { token in
            let rawToken = extractString(field: "token", from: token) ?? extractString(field: "text", from: token) ?? ""
            let cleanedToken = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedToken.isEmpty else {
                return nil
            }

            let startSeconds = extractDouble(field: "startTime", from: token) ?? 0
            let endSeconds = extractDouble(field: "endTime", from: token) ?? max(startSeconds + 0.01, startSeconds)
            let confidence = extractDouble(field: "confidence", from: token)

            return ASRWord(
                word: cleanedToken,
                startMs: max(0, Int(startSeconds * 1_000)),
                endMs: max(Int(endSeconds * 1_000), Int(startSeconds * 1_000) + 1),
                confidence: confidence
            )
        }
    }

    private func extractArray(field: String, from value: Any) -> [Any]? {
        Mirror(reflecting: value).children.first(where: { $0.label == field })?.value as? [Any]
    }

    private func extractString(field: String, from value: Any) -> String? {
        if let string = Mirror(reflecting: value).children.first(where: { $0.label == field })?.value as? String {
            return string
        }

        if let optional = Mirror(reflecting: value).children.first(where: { $0.label == field })?.value {
            let optionalMirror = Mirror(reflecting: optional)
            if optionalMirror.displayStyle == .optional,
               let first = optionalMirror.children.first,
               let string = first.value as? String {
                return string
            }
        }

        return nil
    }

    private func extractDouble(field: String, from value: Any) -> Double? {
        if let double = Mirror(reflecting: value).children.first(where: { $0.label == field })?.value as? Double {
            return double
        }
        if let int = Mirror(reflecting: value).children.first(where: { $0.label == field })?.value as? Int {
            return Double(int)
        }
        if let number = Mirror(reflecting: value).children.first(where: { $0.label == field })?.value as? NSNumber {
            return number.doubleValue
        }
        return nil
    }
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

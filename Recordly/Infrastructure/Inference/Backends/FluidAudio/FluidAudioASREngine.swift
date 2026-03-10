import Foundation

// MARK: - Model validation

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

// MARK: - ASR engine

struct FluidAudioASREngine: ASREngine {
    let displayName: String = "FluidAudio"

    private let transcriber: FluidAudioTranscribing
    private let inputPreparer: FluidAudioInputPreparing
    private let sessionAudioLoader: FluidAudioSessionAudioLoading
    private let transcriptionService: FluidAudioTranscriptionServicing
    private let fileManager: FileManager

    init(
        transcriber: FluidAudioTranscribing = FluidAudioTranscriber(),
        inputPreparer: FluidAudioInputPreparing = FluidAudioInputPreparer(),
        sessionAudioLoader: (any FluidAudioSessionAudioLoading)? = nil,
        vadService: (any FluidAudioVoiceActivityDetecting)? = nil,
        transcriptionService: (any FluidAudioTranscriptionServicing)? = nil,
        fileManager: FileManager = .default
    ) {
        self.transcriber = transcriber
        self.inputPreparer = inputPreparer
        let resolvedLoader = sessionAudioLoader ?? FluidAudioSessionAudioLoader(inputPreparer: inputPreparer)
        self.sessionAudioLoader = resolvedLoader
        self.transcriptionService = transcriptionService ?? FluidAudioTranscriptionService(
            transcriber: transcriber,
            vadService: vadService ?? FluidAudioVADService()
        )
        self.fileManager = fileManager
    }

    func cacheFingerprint(configuration: ASREngineConfiguration) -> String {
        let modelPath = configuration.modelURL.standardizedFileURL.path
        return "\(modelPath)|backend:fluidaudio|v3"
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

        let preparedAudio = try sessionAudioLoader.loadAudio(from: audioURL)
        let output = try await transcriptionService.transcribe(
            preparedAudio: preparedAudio,
            modelDirectoryURL: configuration.modelURL,
            channel: channel
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

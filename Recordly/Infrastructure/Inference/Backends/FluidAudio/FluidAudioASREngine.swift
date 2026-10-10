import Foundation

#if arch(arm64) && canImport(FluidAudio)
import FluidAudio
#endif

enum FluidAudioRuntimeIdentity {
    static let sdkVersion = "0.17.7"
    static let sdkRevision = "503b4bd1bbf7220882de39fe8ae6716aae4132da"
    static let asrModel = "parakeet-v3-int8"
#if arch(arm64) && canImport(FluidAudio)
    static let asrCacheFolder = Repo.parakeetV3.folderName
    static let diarizationCacheFolder = Repo.diarizer.folderName
#else
    static let asrCacheFolder = "parakeet-tdt-0.6b-v3"
    static let diarizationCacheFolder = "speaker-diarization"
#endif
}

// MARK: - Model validation

struct FluidAudioModelValidator {
    static let requiredMarkers: [String] = [
        "parakeet_vocab.json",
        "Preprocessor.mlmodelc",
        "Encoder.mlmodelc",
        "Decoder.mlmodelc",
        "JointDecisionv3.mlmodelc"
    ]

    static func isValidModelDirectory(_ modelDirectoryURL: URL, fileManager: FileManager = .default) -> Bool {
        guard let values = try? modelDirectoryURL.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true,
              fileManager.fileExists(atPath: modelDirectoryURL.path) else {
            return false
        }

        return requiredMarkers.allSatisfy { marker in
            let item = modelDirectoryURL.appendingPathComponent(marker)
            guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else {
                return false
            }
            return marker.hasSuffix(".mlmodelc") ? isValidCompiledModel(at: item) : values.isRegularFile == true
        }
    }

    /// Mirrors the SDK's compiled-model layout gate before reporting an install ready.
    /// Downloads ending in `.partial` do not satisfy the finished bundle marker.
    static func isValidCompiledModel(at directory: URL) -> Bool {
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            return false
        }
        let marker = directory.appendingPathComponent("coremldata.bin")
        guard let markerValues = try? marker.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              markerValues.isRegularFile == true, (markerValues.fileSize ?? 0) > 0,
              let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        // A root marker can arrive before nested weights finish downloading.
        // Mirror the SDK's incomplete-cache gate rather than reporting staged assets ready.
        for case let item as URL in files where item.pathExtension == "partial" {
            return false
        }
        return true
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
    private let fileManager: FileManager

    init(
        transcriber: FluidAudioTranscribing = FluidAudioTranscriber(),
        fileManager: FileManager = .default
    ) {
        self.transcriber = transcriber
        self.fileManager = fileManager
    }

    func cacheFingerprint(configuration: ASREngineConfiguration) -> String {
        let modelPath = configuration.modelURL.standardizedFileURL.path
        return "\(modelPath)|backend:fluidaudio|sdk:\(FluidAudioRuntimeIdentity.sdkVersion)|revision:\(FluidAudioRuntimeIdentity.sdkRevision)|model:\(FluidAudioRuntimeIdentity.asrModel)"
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

        let output = try await transcriber.transcribe(
            audioURL: audioURL,
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

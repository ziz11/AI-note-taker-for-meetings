import Foundation

#if arch(arm64) && canImport(FluidAudio)
import FluidAudio
#endif

struct FluidAudioDiarizationSegment: Equatable {
    var id: String
    var speakerID: String
    var startMs: Int
    var endMs: Int
    var confidence: Double?
}

protocol FluidAudioOfflineDiarizationRunning {
    func diarize(
        preparedAudio: PreparedSessionAudio,
        modelDirectoryURL: URL
    ) async throws -> [FluidAudioDiarizationSegment]
}

final class FluidAudioOfflineDiarizationRunner: FluidAudioOfflineDiarizationRunning {
#if arch(arm64) && canImport(FluidAudio)
    private var cachedManager: OfflineDiarizerManager?
    private var cachedModelPath: String?
#endif

    func diarize(
        preparedAudio: PreparedSessionAudio,
        modelDirectoryURL: URL
    ) async throws -> [FluidAudioDiarizationSegment] {
#if arch(arm64) && canImport(FluidAudio)
        let normalizedAudio = try preparedAudio.resampled(to: 16_000)
        let manager = try await resolveManager(for: modelDirectoryURL)
        let result = try await manager.process(audio: normalizedAudio.samples)
        return result.segments.enumerated().map { index, segment in
            let startMs = max(0, Int((Double(segment.startTimeSeconds) * 1_000.0).rounded(.down)))
            return FluidAudioDiarizationSegment(
                id: "dseg-\(index + 1)",
                speakerID: segment.speakerId,
                startMs: startMs,
                endMs: max(Int((Double(segment.endTimeSeconds) * 1_000.0).rounded(.up)), startMs + 1),
                confidence: Double(segment.qualityScore)
            )
        }
#else
        throw DiarizationRuntimeError.binaryMissing
#endif
    }

#if arch(arm64) && canImport(FluidAudio)
    private func resolveManager(for modelDirectoryURL: URL) async throws -> OfflineDiarizerManager {
        let modelPath = modelDirectoryURL.standardizedFileURL.path
        if let manager = cachedManager, cachedModelPath == modelPath {
            return manager
        }

        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels(directory: modelDirectoryURL)
        cachedManager = manager
        cachedModelPath = modelPath
        return manager
    }
#endif
}

struct FluidAudioDiarizationService {
    private let runner: FluidAudioOfflineDiarizationRunning
    private let fileManager: FileManager

    init(
        runner: FluidAudioOfflineDiarizationRunning = FluidAudioOfflineDiarizationRunner(),
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.fileManager = fileManager
    }

    func diarize(
        preparedAudio: PreparedSessionAudio,
        sessionID: UUID,
        modelDirectoryURL: URL
    ) async throws -> DiarizationDocument {
        guard let resourceValues = try? modelDirectoryURL.resourceValues(forKeys: [.isDirectoryKey]),
              resourceValues.isDirectory == true,
              fileManager.fileExists(atPath: modelDirectoryURL.path) else {
            throw DiarizationRuntimeError.modelMissing(modelDirectoryURL)
        }

        let segments = try await runner.diarize(
            preparedAudio: preparedAudio,
            modelDirectoryURL: modelDirectoryURL
        )
        guard !segments.isEmpty else {
            throw DiarizationRuntimeError.emptySegments
        }

        return DiarizationDocument(
            version: 1,
            sessionID: sessionID,
            createdAt: Date(),
            segments: segments.map {
                DiarizationSegment(
                    id: $0.id,
                    speaker: $0.speakerID,
                    startMs: $0.startMs,
                    endMs: $0.endMs,
                    confidence: $0.confidence
                )
            }
        )
    }
}

struct FluidAudioDiarizationEngine: DiarizationEngine {
    private let fileManager: FileManager
    private let sessionAudioLoader: FluidAudioSessionAudioLoading
    private let diarizationService: FluidAudioDiarizationService

    init(
        fileManager: FileManager = .default,
        sessionAudioLoader: FluidAudioSessionAudioLoading = FluidAudioSessionAudioLoader(),
        diarizationService: FluidAudioDiarizationService = FluidAudioDiarizationService()
    ) {
        self.fileManager = fileManager
        self.sessionAudioLoader = sessionAudioLoader
        self.diarizationService = diarizationService
    }

    func diarize(
        systemAudioURL: URL,
        sessionID: UUID,
        configuration: DiarizationEngineConfiguration
    ) async throws -> DiarizationDocument {
        guard fileManager.fileExists(atPath: systemAudioURL.path) else {
            throw DiarizationRuntimeError.invalidInput
        }

        guard ["system.raw.caf", "system.raw.flac"].contains(systemAudioURL.lastPathComponent) else {
            throw DiarizationRuntimeError.invalidInput
        }

        let preparedAudio = try sessionAudioLoader.loadAudio(from: systemAudioURL)
        return try await diarizationService.diarize(
            preparedAudio: preparedAudio,
            sessionID: sessionID,
            modelDirectoryURL: configuration.modelURL
        )
    }
}

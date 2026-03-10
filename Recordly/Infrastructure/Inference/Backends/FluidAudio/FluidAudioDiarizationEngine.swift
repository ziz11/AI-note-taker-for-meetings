import Foundation

#if arch(arm64) && canImport(FluidAudio)
import FluidAudio
#endif

struct FluidAudioDiarizationEngine: DiarizationEngine {
    private let manager: any OfflineDiarizationManaging
    private let fileManager: FileManager
    private let sessionAudioLoader: FluidAudioSessionAudioLoading

    init(
        manager: any OfflineDiarizationManaging,
        fileManager: FileManager = .default,
        sessionAudioLoader: FluidAudioSessionAudioLoading = FluidAudioSessionAudioLoader()
    ) {
        self.manager = manager
        self.fileManager = fileManager
        self.sessionAudioLoader = sessionAudioLoader
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
        let normalizedAudio = try preparedAudio.resampled(to: 16_000)
#if arch(arm64) && canImport(FluidAudio)
        let result = try await manager.process(audio: normalizedAudio.samples)
        guard !result.segments.isEmpty else {
            throw DiarizationRuntimeError.emptySegments
        }

        return DiarizationDocument(
            version: 1,
            sessionID: sessionID,
            createdAt: Date(),
            segments: result.segments.enumerated().map { index, segment in
                let startMs = max(0, Int((Double(segment.startTimeSeconds) * 1_000.0).rounded(.down)))
                return DiarizationSegment(
                    id: "dseg-\(index + 1)",
                    speaker: segment.speakerId,
                    startMs: startMs,
                    endMs: max(Int((Double(segment.endTimeSeconds) * 1_000.0).rounded(.up)), startMs + 1),
                    confidence: Double(segment.qualityScore)
                )
            }
        )
#else
        throw DiarizationRuntimeError.binaryMissing
#endif
    }
}

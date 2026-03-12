import AVFoundation
import Foundation

#if arch(arm64) && canImport(FluidAudio)
import FluidAudio
#endif

struct FluidAudioSpeechRegion: Equatable {
    var startMs: Int
    var endMs: Int
}

protocol FluidAudioVoiceActivityDetecting {
    func detectSpeechRegions(in audio: PreparedSessionAudio) async -> [FluidAudioSpeechRegion]?
}

actor FluidAudioVADService: FluidAudioVoiceActivityDetecting {
    private let segmentationConfig: Any
    private var manager: Any?
    private var attemptedInitialization = false

    init() {
#if arch(arm64) && canImport(FluidAudio)
        self.segmentationConfig = VadSegmentationConfig.default
#else
        self.segmentationConfig = ()
#endif
    }

    func detectSpeechRegions(in audio: PreparedSessionAudio) async -> [FluidAudioSpeechRegion]? {
#if arch(arm64) && canImport(FluidAudio)
        guard let manager = await resolveManager() else {
            return nil
        }

        do {
            let buffer = try audio.makePCMBuffer()
            let convertedSamples = try AudioConverter().resampleBuffer(buffer)
            let config = self.segmentationConfig as! VadSegmentationConfig
            let segments = try await manager.segmentSpeech(convertedSamples, config: config)
            let normalized = segments.compactMap { segment -> FluidAudioSpeechRegion? in
                let startMs = max(0, Int((segment.startTime * 1_000.0).rounded(.down)))
                let endMs = min(audio.durationMs, Int((segment.endTime * 1_000.0).rounded(.up)))
                guard endMs > startMs else { return nil }
                return FluidAudioSpeechRegion(startMs: startMs, endMs: endMs)
            }
            return normalized.isEmpty ? [] : normalized
        } catch {
            return nil
        }
#else
        return nil
#endif
    }

#if arch(arm64) && canImport(FluidAudio)
    private func resolveManager() async -> VadManager? {
        if let manager = manager as? VadManager {
            return manager
        }

        if attemptedInitialization {
            return nil
        }

        attemptedInitialization = true
        do {
            let resolved = try await VadManager()
            manager = resolved
            return resolved
        } catch {
            return nil
        }
    }
#endif
}

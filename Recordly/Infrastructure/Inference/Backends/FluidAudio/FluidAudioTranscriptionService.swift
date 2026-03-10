import AVFoundation
import Foundation

#if arch(arm64) && canImport(FluidAudio)
import FluidAudio
#endif

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
        audioBuffer: AVAudioPCMBuffer,
        modelDirectoryURL: URL,
        channel: TranscriptChannel
    ) async throws -> FluidAudioRunnerOutput
}

final class FluidAudioTranscriber: FluidAudioTranscribing {
#if arch(arm64) && canImport(FluidAudio)
    private var cachedManager: AsrManager?
    private var cachedModelPath: String?
#endif

    func transcribe(
        audioBuffer: AVAudioPCMBuffer,
        modelDirectoryURL: URL,
        channel: TranscriptChannel
    ) async throws -> FluidAudioRunnerOutput {
#if arch(arm64) && canImport(FluidAudio)
        let manager = try await resolveManager(for: modelDirectoryURL)
        let source = fluidSource(for: channel)
        let rawResult = try await manager.transcribe(audioBuffer, source: source)
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

protocol FluidAudioTranscriptionServicing {
    func transcribe(
        preparedAudio: PreparedSessionAudio,
        modelDirectoryURL: URL,
        channel: TranscriptChannel
    ) async throws -> FluidAudioRunnerOutput
}

struct FluidAudioTranscriptionService: FluidAudioTranscriptionServicing {
    private let transcriber: FluidAudioTranscribing
    private let vadService: any FluidAudioVoiceActivityDetecting

    init(
        transcriber: FluidAudioTranscribing,
        vadService: any FluidAudioVoiceActivityDetecting = FluidAudioVADService()
    ) {
        self.transcriber = transcriber
        self.vadService = vadService
    }

    func transcribe(
        preparedAudio: PreparedSessionAudio,
        modelDirectoryURL: URL,
        channel: TranscriptChannel
    ) async throws -> FluidAudioRunnerOutput {
        if let regions = await vadService.detectSpeechRegions(in: preparedAudio),
           let usableRegions = normalize(regions: regions, durationMs: preparedAudio.durationMs),
           !usableRegions.isEmpty {
            do {
                return try await transcribeRegions(
                    usableRegions,
                    preparedAudio: preparedAudio,
                    modelDirectoryURL: modelDirectoryURL,
                    channel: channel
                )
            } catch {
                return try await transcribeFullInput(
                    preparedAudio: preparedAudio,
                    modelDirectoryURL: modelDirectoryURL,
                    channel: channel
                )
            }
        }

        return try await transcribeFullInput(
            preparedAudio: preparedAudio,
            modelDirectoryURL: modelDirectoryURL,
            channel: channel
        )
    }

    private func transcribeFullInput(
        preparedAudio: PreparedSessionAudio,
        modelDirectoryURL: URL,
        channel: TranscriptChannel
    ) async throws -> FluidAudioRunnerOutput {
        let buffer = try preparedAudio.makePCMBuffer()
        return try await transcriber.transcribe(
            audioBuffer: buffer,
            modelDirectoryURL: modelDirectoryURL,
            channel: channel
        )
    }

    private func transcribeRegions(
        _ regions: [FluidAudioSpeechRegion],
        preparedAudio: PreparedSessionAudio,
        modelDirectoryURL: URL,
        channel: TranscriptChannel
    ) async throws -> FluidAudioRunnerOutput {
        var mergedSegments: [FluidAudioSegment] = []
        var resolvedLanguage: String?

        for (index, region) in regions.enumerated() {
            let buffer = try preparedAudio.makePCMBuffer(for: region)
            guard buffer.frameLength > 0 else {
                continue
            }

            let output = try await transcriber.transcribe(
                audioBuffer: buffer,
                modelDirectoryURL: modelDirectoryURL,
                channel: channel
            )
            resolvedLanguage = resolvedLanguage ?? output.language

            for segment in output.segments {
                mergedSegments.append(
                    FluidAudioSegment(
                        id: "seg-\(index + 1)-\(segment.id)",
                        startMs: segment.startMs + region.startMs,
                        endMs: segment.endMs + region.startMs,
                        text: segment.text,
                        confidence: segment.confidence,
                        words: offset(words: segment.words, by: region.startMs)
                    )
                )
            }
        }

        if mergedSegments.isEmpty {
            return try await transcribeFullInput(
                preparedAudio: preparedAudio,
                modelDirectoryURL: modelDirectoryURL,
                channel: channel
            )
        }

        return FluidAudioRunnerOutput(language: resolvedLanguage, segments: mergedSegments)
    }

    private func normalize(
        regions: [FluidAudioSpeechRegion],
        durationMs: Int
    ) -> [FluidAudioSpeechRegion]? {
        let normalized = regions.compactMap { region -> FluidAudioSpeechRegion? in
            let startMs = max(0, min(region.startMs, durationMs))
            let endMs = max(startMs, min(region.endMs, durationMs))
            guard endMs > startMs else { return nil }
            return FluidAudioSpeechRegion(startMs: startMs, endMs: endMs)
        }
        .sorted { lhs, rhs in
            if lhs.startMs != rhs.startMs { return lhs.startMs < rhs.startMs }
            return lhs.endMs < rhs.endMs
        }

        return normalized.isEmpty ? nil : normalized
    }

    private func offset(words: [ASRWord]?, by offsetMs: Int) -> [ASRWord]? {
        words?.map {
            ASRWord(
                word: $0.word,
                startMs: $0.startMs + offsetMs,
                endMs: $0.endMs + offsetMs,
                confidence: $0.confidence
            )
        }
    }
}

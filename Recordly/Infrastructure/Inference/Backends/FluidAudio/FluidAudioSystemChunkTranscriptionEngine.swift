import Foundation

struct FluidAudioSystemChunkTranscriptionEngine: SystemChunkTranscriptionEngine {
    private let sessionAudioLoader: any FluidAudioSessionAudioLoading
    private let transcriptionService: any FluidAudioTranscriptionServicing
    private let fileManager: FileManager

    init(
        sessionAudioLoader: any FluidAudioSessionAudioLoading = FluidAudioSessionAudioLoader(),
        transcriptionService: (any FluidAudioTranscriptionServicing)? = nil,
        fileManager: FileManager = .default
    ) {
        self.sessionAudioLoader = sessionAudioLoader
        self.transcriptionService = transcriptionService ?? FluidAudioTranscriptionService(
            transcriber: FluidAudioTranscriber(),
            vadService: FluidAudioVADService()
        )
        self.fileManager = fileManager
    }

    func transcribeSystemChunks(
        systemAudioURL: URL,
        diarization: DiarizationDocument,
        sessionID: UUID,
        configuration: ASREngineConfiguration
    ) async throws -> SystemChunkTranscriptionDocument {
        guard fileManager.fileExists(atPath: systemAudioURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        guard fileManager.fileExists(atPath: configuration.modelURL.path) else {
            throw ASREngineRuntimeError.modelMissing(configuration.modelURL)
        }

        try FluidAudioModelValidator.validateModelDirectory(configuration.modelURL, fileManager: fileManager)

        let preparedAudio = try sessionAudioLoader.loadAudio(from: systemAudioURL)
        let orderedDiarization = diarization.segments.sorted { lhs, rhs in
            if lhs.startMs != rhs.startMs { return lhs.startMs < rhs.startMs }
            if lhs.endMs != rhs.endMs { return lhs.endMs < rhs.endMs }
            return lhs.id < rhs.id
        }

        var outputSegments: [SystemChunkTranscriptSegment] = []

        for diarizationSegment in orderedDiarization {
            guard let chunkAudio = preparedAudio.sliced(from: diarizationSegment.startMs, to: diarizationSegment.endMs) else {
                continue
            }

            let chunkOutput = try await transcriptionService.transcribe(
                preparedAudio: chunkAudio,
                modelDirectoryURL: configuration.modelURL,
                channel: .system
            )

            for segment in chunkOutput.segments {
                outputSegments.append(
                    SystemChunkTranscriptSegment(
                        id: "\(diarizationSegment.id)-\(segment.id)",
                        speakerKey: diarizationSegment.speaker,
                        startMs: segment.startMs + diarizationSegment.startMs,
                        endMs: segment.endMs + diarizationSegment.startMs,
                        text: segment.text,
                        confidence: segment.confidence,
                        language: chunkOutput.language,
                        speakerConfidence: diarizationSegment.confidence,
                        words: offset(segment.words, by: diarizationSegment.startMs)
                    )
                )
            }
        }

        return SystemChunkTranscriptionDocument(
            version: 1,
            sessionID: sessionID,
            createdAt: Date(),
            segments: outputSegments
        )
    }

    private func offset(_ words: [ASRWord]?, by offsetMs: Int) -> [ASRWord]? {
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

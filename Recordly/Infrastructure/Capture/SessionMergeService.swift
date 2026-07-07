@preconcurrency import AVFoundation
import Foundation

actor SessionMergeService {
    struct Result {
        let mergedM4AFileName: String?
        let note: String
        let driftWarnings: [String]
        let mergeMode: MergeMode
    }

    private let metadataStore: SessionMetadataStore
    private let mixer: DirectPCMMixService
    private let fileManager: FileManager

    init(
        metadataStore: SessionMetadataStore,
        mixer: DirectPCMMixService = DirectPCMMixService(),
        fileManager: FileManager = .default
    ) {
        self.metadataStore = metadataStore
        self.mixer = mixer
        self.fileManager = fileManager
    }

    func mergeSession(in sessionDirectory: URL) async throws -> Result {
        var metadata = try await metadataStore.load(in: sessionDirectory)
        metadata.status = .mixing
        try await save(metadata, in: sessionDirectory)

        // A previous merge that crashed mid-run may have left a pending file behind.
        sweepStalePendingFiles(in: sessionDirectory)

        // Mix directly into an AAC m4a pending file in the session directory
        // (same volume, so the final replace is atomic). The mixer encodes on
        // write, so no intermediate PCM CAF or AVAssetExportSession pass is needed.
        let pendingURL = sessionDirectory
            .appendingPathComponent("merged-call.pending-\(UUID().uuidString).m4a")

        let mixResult: DirectPCMMixResult
        var warnings: [String]
        var temporaryPreparedInputs: [URL] = []
        do {
            let prepared = try prepareInputTracks(
                metadata: metadata,
                sessionDirectory: sessionDirectory,
                sourcePreference: .durableM4A
            )
            temporaryPreparedInputs = prepared.temporaryFiles
            warnings = prepared.driftWarnings
            mixResult = try mixer.mix(tracks: prepared.inputTracks, outputURL: pendingURL)
        } catch {
            temporaryPreparedInputs.forEach { try? fileManager.removeItem(at: $0) }
            try? fileManager.removeItem(at: pendingURL)
            do {
                let prepared = try prepareInputTracks(
                    metadata: metadata,
                    sessionDirectory: sessionDirectory,
                    sourcePreference: .rawCAF
                )
                temporaryPreparedInputs = prepared.temporaryFiles
                warnings = prepared.driftWarnings
                mixResult = try mixer.mix(tracks: prepared.inputTracks, outputURL: pendingURL)
            } catch {
                temporaryPreparedInputs.forEach { try? fileManager.removeItem(at: $0) }
                try? fileManager.removeItem(at: pendingURL)
                metadata = try await metadataStore.load(in: sessionDirectory)
                metadata.status = .mixError
                metadata.mergeMode = .unavailable
                metadata.notes.append("PCM merge failed: \(error.localizedDescription)")
                try await save(metadata, in: sessionDirectory)
                throw AudioCaptureError.mixdownFailed
            }
        }
        temporaryPreparedInputs.forEach { try? fileManager.removeItem(at: $0) }

        let mergedM4AFileName = try finalizeMergedM4A(pendingURL: pendingURL, in: sessionDirectory)

        metadata = try await metadataStore.load(in: sessionDirectory)
        metadata.status = .ready
        metadata.mergeMode = mixResult.mergeMode
        metadata.driftWarnings.append(contentsOf: warnings)
        metadata.notes.append("Offline merge completed.")
        try await save(metadata, in: sessionDirectory)

        let note: String
        switch mixResult.mergeMode {
        case .micOnly:
            note = "Ready (Mic Only)"
        case .systemOnly:
            note = "Ready (System Only)"
        case .dualTrack:
            note = "Ready"
        case .unavailable:
            note = "Ready"
        }

        return Result(
            mergedM4AFileName: mergedM4AFileName,
            note: note,
            driftWarnings: warnings,
            mergeMode: mixResult.mergeMode
        )
    }

    private enum SourcePreference {
        case durableM4A
        case rawCAF
    }

    private struct PreparedMergeInputs {
        var inputTracks: [DirectPCMMixService.InputTrack]
        var temporaryFiles: [URL]
        var driftWarnings: [String]
    }

    private func prepareInputTracks(
        metadata: SessionMetadata,
        sessionDirectory: URL,
        sourcePreference: SourcePreference
    ) throws -> PreparedMergeInputs {
        let stats = [metadata.tracks[.microphone], metadata.tracks[.system]]
            .compactMap { $0 }
            .filter { $0.framesWritten > 0 }

        guard !stats.isEmpty else {
            throw DirectPCMMixService.MixError.noUsableTracks
        }

        let firstPTSValues = stats.compactMap { $0.firstPTS }
        let earliestPTS = firstPTSValues.min() ?? 0
        let driftThreshold: Double = 0.2
        var warnings: [String] = []
        var temporaryFiles: [URL] = []
        var inputTracks: [DirectPCMMixService.InputTrack] = []

        for trackStats in stats {
            guard let sourceURL = usableSourceURL(
                for: trackStats,
                in: sessionDirectory,
                sourcePreference: sourcePreference
            ) else {
                continue
            }

            let preparedSource = try prepareCanonicalPCMSourceIfNeeded(sourceURL)
            if let temporaryURL = preparedSource.temporaryURL {
                temporaryFiles.append(temporaryURL)
            }

            let offsetSeconds = max(0, (trackStats.firstPTS ?? earliestPTS) - earliestPTS)
            let offsetFrames = AVAudioFramePosition((offsetSeconds * PCMTrackWriter.canonicalSampleRate).rounded())
            let expectedFrames = AVAudioFramePosition(trackStats.framesWritten)

            let ptsDuration = max(0, (trackStats.lastPTS ?? trackStats.firstPTS ?? 0) - (trackStats.firstPTS ?? 0))
            let frameDuration = trackStats.durationByFrames
            if abs(ptsDuration - frameDuration) > driftThreshold {
                let ptsText = String(format: "%.3f", ptsDuration)
                let frameText = String(format: "%.3f", frameDuration)
                warnings.append("\(trackStats.kind.rawValue) driftWarning: PTS=\(ptsText)s frames=\(frameText)s")
            }

            inputTracks.append(
                DirectPCMMixService.InputTrack(
                    kind: trackStats.kind,
                    fileURL: preparedSource.url,
                    offsetFrames: offsetFrames,
                    expectedFrames: expectedFrames
                )
            )
        }

        guard !inputTracks.isEmpty else {
            temporaryFiles.forEach { try? fileManager.removeItem(at: $0) }
            throw DirectPCMMixService.MixError.noUsableTracks
        }

        return PreparedMergeInputs(
            inputTracks: inputTracks,
            temporaryFiles: temporaryFiles,
            driftWarnings: warnings
        )
    }

    private func usableSourceURL(
        for stats: TrackRuntimeStats,
        in sessionDirectory: URL,
        sourcePreference: SourcePreference
    ) -> URL? {
        let candidates: [String]
        switch sourcePreference {
        case .durableM4A:
            // Per-track fallback: a missing durable m4a (e.g. failed export) must not
            // drop that track from the merge while its raw capture still exists.
            candidates = [durableFileName(for: stats.kind), stats.fileName]
        case .rawCAF:
            candidates = [stats.fileName]
        }

        for fileName in candidates {
            let url = sessionDirectory.appendingPathComponent(fileName)
            if isUsableAudioFile(url) {
                return url
            }
        }
        return nil
    }

    private func durableFileName(for kind: TrackKind) -> String {
        switch kind {
        case .microphone:
            return "mic.m4a"
        case .system:
            return "system.m4a"
        }
    }

    private func prepareCanonicalPCMSourceIfNeeded(_ sourceURL: URL) throws -> (url: URL, temporaryURL: URL?) {
        // The mixer opens inputs with a forced Float32 non-interleaved processing
        // format, so only sample rate and channel count matter here. App-produced
        // files (durable m4a, raw CAF in any bit depth) always pass through; the
        // temp-file conversion below is a cold path for foreign files only —
        // streaming that conversion inside the mixer isn't worth a second decode path.
        let inputFile = try AVAudioFile(
            forReading: sourceURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let inputFormat = inputFile.processingFormat
        guard let canonicalFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: PCMTrackWriter.canonicalSampleRate,
            channels: PCMTrackWriter.canonicalChannels,
            interleaved: false
        ) else {
            throw DirectPCMMixService.MixError.invalidOutputFormat
        }

        if inputFormat.sampleRate == canonicalFormat.sampleRate,
           inputFormat.channelCount == canonicalFormat.channelCount {
            return (sourceURL, nil)
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: canonicalFormat) else {
            throw DirectPCMMixService.MixError.invalidInputFormat(fileName: sourceURL.lastPathComponent)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("merge-input-\(UUID().uuidString).caf")
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: canonicalFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        while inputFile.framePosition < inputFile.length {
            let remainingFrames = inputFile.length - inputFile.framePosition
            let readFrames = AVAudioFrameCount(min(remainingFrames, 8192))
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: readFrames) else {
                throw DirectPCMMixService.MixError.unsupportedInputData(fileName: sourceURL.lastPathComponent)
            }

            try inputFile.read(into: inputBuffer, frameCount: readFrames)
            guard inputBuffer.frameLength > 0 else {
                break
            }

            let ratio = canonicalFormat.sampleRate / inputFormat.sampleRate
            let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 16
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: outputCapacity) else {
                throw DirectPCMMixService.MixError.invalidOutputFormat
            }

            var conversionError: NSError?
            var consumed = false
            converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            if let conversionError {
                throw conversionError
            }

            if outputBuffer.frameLength > 0 {
                try outputFile.write(from: outputBuffer)
            }
        }

        guard isUsableAudioFile(outputURL) else {
            try? fileManager.removeItem(at: outputURL)
            throw DirectPCMMixService.MixError.noUsableTracks
        }

        return (outputURL, outputURL)
    }

    private func finalizeMergedM4A(pendingURL: URL, in sessionDirectory: URL) throws -> String {
        let outputFileName = "merged-call.m4a"
        let outputURL = sessionDirectory.appendingPathComponent(outputFileName)

        do {
            guard isUsableAudioFile(pendingURL) else {
                throw AudioCaptureError.mixdownFailed
            }

            if fileManager.fileExists(atPath: outputURL.path) {
                _ = try fileManager.replaceItemAt(outputURL, withItemAt: pendingURL)
            } else {
                try fileManager.moveItem(at: pendingURL, to: outputURL)
            }
        } catch {
            try? fileManager.removeItem(at: pendingURL)
            throw error
        }

        return outputFileName
    }

    private func sweepStalePendingFiles(in sessionDirectory: URL) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: sessionDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in contents where url.lastPathComponent.hasPrefix("merged-call.pending-") {
            try? fileManager.removeItem(at: url)
        }
    }

    private func isUsableAudioFile(_ url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else {
            return false
        }

        guard let file = try? AVAudioFile(forReading: url) else {
            return false
        }
        return file.length > 0
    }

    private func save(_ metadata: SessionMetadata, in sessionDirectory: URL) async throws {
        try await metadataStore.replace(metadata, in: sessionDirectory)
    }
}

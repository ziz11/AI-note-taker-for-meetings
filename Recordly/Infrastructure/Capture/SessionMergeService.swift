import AVFoundation
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

    init(metadataStore: SessionMetadataStore, mixer: DirectPCMMixService = DirectPCMMixService()) {
        self.metadataStore = metadataStore
        self.mixer = mixer
    }

    func mergeSession(in sessionDirectory: URL, exportM4A: Bool) async throws -> Result {
        var metadata = try await metadataStore.load(in: sessionDirectory)
        metadata.status = .mixing
        try await save(metadata, in: sessionDirectory)

        let micStats = metadata.tracks[.microphone]
        let systemStats = metadata.tracks[.system]

        let availableTracks: [(TrackKind, TrackRuntimeStats, URL)] = [micStats, systemStats]
            .compactMap { $0 }
            .filter { $0.framesWritten > 0 }
            .compactMap { stats in
                let url = sessionDirectory.appendingPathComponent(stats.fileName)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return (stats.kind, stats, url)
            }

        guard !availableTracks.isEmpty else {
            metadata.status = .mixError
                metadata.notes.append("No non-empty raw tracks to merge.")
                metadata.mergeMode = .unavailable
                try await save(metadata, in: sessionDirectory)
                return Result(
                    mergedM4AFileName: nil,
                    note: "No audio available for merge.",
                    driftWarnings: metadata.driftWarnings,
                    mergeMode: .unavailable
                )
        }

        let firstPTSValues = availableTracks.compactMap { $0.1.firstPTS }
        let earliestPTS = firstPTSValues.min() ?? 0

        let driftThreshold: Double = 0.2
        var warnings: [String] = []

        var inputTracks: [DirectPCMMixService.InputTrack] = []
        inputTracks.reserveCapacity(availableTracks.count)

        for (kind, stats, url) in availableTracks {
            let offsetSeconds = max(0, (stats.firstPTS ?? earliestPTS) - earliestPTS)
            let offsetFrames = AVAudioFramePosition((offsetSeconds * PCMTrackWriter.canonicalSampleRate).rounded())
            let expectedFrames = AVAudioFramePosition(stats.framesWritten)

            let ptsDuration = max(0, (stats.lastPTS ?? stats.firstPTS ?? 0) - (stats.firstPTS ?? 0))
            let frameDuration = stats.durationByFrames
            if abs(ptsDuration - frameDuration) > driftThreshold {
                let ptsText = String(format: "%.3f", ptsDuration)
                let frameText = String(format: "%.3f", frameDuration)
                warnings.append("\(stats.kind.rawValue) driftWarning: PTS=\(ptsText)s frames=\(frameText)s")
            }

            inputTracks.append(
                DirectPCMMixService.InputTrack(
                    kind: kind,
                    fileURL: url,
                    offsetFrames: offsetFrames,
                    expectedFrames: expectedFrames
                )
            )
        }

        let mergedCAFURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("merged-call-\(UUID().uuidString).caf")

        let mixResult: DirectPCMMixResult
        do {
            mixResult = try mixer.mix(tracks: inputTracks, outputURL: mergedCAFURL)
        } catch {
            metadata = try await metadataStore.load(in: sessionDirectory)
            metadata.status = .mixError
            metadata.mergeMode = .unavailable
            metadata.notes.append("PCM merge failed: \(error.localizedDescription)")
            try await save(metadata, in: sessionDirectory)
            throw AudioCaptureError.mixdownFailed
        }

        let mergedM4AFileName: String?
        if exportM4A {
            mergedM4AFileName = try await exportMergedM4A(from: mergedCAFURL, in: sessionDirectory)
        } else {
            mergedM4AFileName = nil
        }

        if FileManager.default.fileExists(atPath: mergedCAFURL.path) {
            try? FileManager.default.removeItem(at: mergedCAFURL)
        }

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

    private func exportMergedM4A(from sourceURL: URL, in sessionDirectory: URL) async throws -> String {
        let outputFileName = "merged-call.m4a"
        let outputURL = sessionDirectory.appendingPathComponent(outputFileName)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let asset = AVURLAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioCaptureError.mixdownFailed
        }

        try await exportSession.export(to: outputURL, as: .m4a)

        return outputFileName
    }

    private func save(_ metadata: SessionMetadata, in sessionDirectory: URL) async throws {
        try await metadataStore.replace(metadata, in: sessionDirectory)
    }
}

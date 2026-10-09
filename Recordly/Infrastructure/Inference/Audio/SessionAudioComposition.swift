@preconcurrency import AVFoundation
import Foundation

/// Native playlist composition keeps compressed files separate and preserves session gaps.
enum SessionAudioComposition {
    static func make(manifest: SessionAudioManifest, directory: URL, source: PlaybackAudioSource) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        let kinds: [TrackKind] = source == .mixed ? [.microphone, .system] : [source == .microphone ? .microphone : .system]
        let total = CMTime(value: manifest.durationFrames, timescale: 48_000)
        for kind in kinds {
            guard let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw SessionAudioError.invalidAudio }
            var end: Int64 = 0
            for segment in manifest.segments.filter({ $0.track == kind && $0.state == .committed }).sorted(by: { $0.startFrame < $1.startFrame }) {
                try Task.checkCancellation()
                guard segment.startFrame >= end, segment.frameCount > 0 else { throw SessionAudioError.invalidMetadata }
                let url = directory.appendingPathComponent(segment.fileName)
                guard url.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else { throw SessionAudioError.invalidMetadata }
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw SessionAudioError.invalidAudio }
                let available = try await track.load(.timeRange)
                let length = CMTime(value: segment.frameCount, timescale: 48_000)
                guard CMTimeCompare(available.duration, length) >= 0 else { throw SessionAudioError.invalidAudio }
                try destination.insertTimeRange(CMTimeRange(start: available.start, duration: length), of: track,
                                                at: CMTime(value: segment.startFrame, timescale: 48_000))
                end = segment.endFrame
            }
        }
        if CMTimeCompare(composition.duration, total) < 0 {
            // AVFoundation drops trailing empty edits. A short silence asset anchors the
            // semantic end without allocating or rendering a full-session silence file.
            guard manifest.durationFrames > 0, let url = silenceAnchorURL,
                  let anchor = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw SessionAudioError.invalidAudio }
            let silenceAsset = AVURLAsset(url: url)
            guard let silence = try await silenceAsset.loadTracks(withMediaType: .audio).first else { throw SessionAudioError.invalidAudio }
            let anchorLength = CMTime(value: min(4_800, manifest.durationFrames), timescale: 48_000)
            try anchor.insertTimeRange(CMTimeRange(start: .zero, duration: anchorLength), of: silence, at: total - anchorLength)
        }
        return composition
    }

    private static let silenceAnchorURL: URL? = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recordly-silence-\(UUID()).m4a")
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
            buffer.frameLength = 4_800
            buffer.floatChannelData![0].initialize(repeating: 0, count: 4_800)
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000])
            try file.write(from: buffer)
            file.close()
            return url
        } catch { return nil }
    }()

    static func export(manifest: SessionAudioManifest, directory: URL, to destination: URL) async throws {
        let composition = try await make(manifest: manifest, directory: directory, source: .mixed)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { throw SessionAudioError.invalidAudio }
        // A full-session file is produced only in response to an explicit export.
        try await exporter.export(to: destination, as: .m4a)
    }
}

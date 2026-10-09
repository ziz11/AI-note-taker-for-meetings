@preconcurrency import AVFoundation
import Foundation

/// Bounded decoding across physical files; positions stay on the capture timeline.
struct SessionAudioRangeReader {
    let manifest: SessionAudioManifest
    let directory: URL
    static let maximumFrames: Int64 = 48_000 * 60

    func read(track: TrackKind, startFrame: Int64, frameCount: Int64) throws -> AVAudioPCMBuffer {
        guard startFrame >= 0, frameCount > 0, frameCount <= Self.maximumFrames,
              startFrame <= Int64.max - frameCount else { throw SessionAudioError.invalidMetadata }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { throw SessionAudioError.invalidAudio }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(frameCount))
        let store = SessionAudioStore(directory: directory, sessionID: manifest.sessionID, hostTimeOrigin: manifest.hostTimeOrigin)
        // Validate paths/schema before opening any chunk files.
        guard manifest.version == 2, manifest.timelineSampleRate == 48_000 else { throw SessionAudioError.unsupportedVersion }
        for segment in manifest.segments where segment.track == track && segment.state == .committed {
            let lower = max(startFrame, segment.startFrame)
            let upper = min(startFrame + frameCount, segment.endFrame)
            guard lower < upper else { continue }
            let url = store.finalURL(for: segment)
            guard url.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else { throw SessionAudioError.invalidMetadata }
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard file.processingFormat.sampleRate == 48_000, file.processingFormat.channelCount == 1,
                  file.length == segment.frameCount else { throw SessionAudioError.invalidAudio }
            file.framePosition = lower - segment.startFrame
            let frames = AVAudioFrameCount(upper - lower)
            let part = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
            try file.read(into: part, frameCount: frames)
            guard part.frameLength == frames else { throw SessionAudioError.invalidAudio }
            buffer.floatChannelData![0].advanced(by: Int(lower - startFrame)).update(from: part.floatChannelData![0], count: Int(frames))
        }
        return buffer
    }

    func containsAudio(track: TrackKind, startFrame: Int64, endFrame: Int64) -> Bool {
        manifest.segments.contains { $0.track == track && $0.state == .committed && $0.startFrame < endFrame && $0.endFrame > startFrame }
    }

    func materialize(track: TrackKind, startFrame: Int64, frameCount: Int64, to url: URL) throws {
        let buffer = try read(track: track, startFrame: startFrame, frameCount: frameCount)
        let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
        try file.write(from: buffer)
        file.close()
    }
}

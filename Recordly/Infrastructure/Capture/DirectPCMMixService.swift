import Accelerate
import AVFoundation
import Foundation

struct DirectPCMMixResult {
    let mergeMode: MergeMode
    let totalFrames: AVAudioFramePosition
}

final class DirectPCMMixService {
    enum MixError: LocalizedError {
        case noUsableTracks
        case invalidInputFormat(fileName: String)
        case unsupportedInputData(fileName: String)
        case invalidOutputFormat

        var errorDescription: String? {
            switch self {
            case .noUsableTracks:
                return "No non-empty input tracks are available for PCM merge."
            case let .invalidInputFormat(fileName):
                return "Input track format mismatch for \(fileName)."
            case let .unsupportedInputData(fileName):
                return "Input track \(fileName) could not be decoded as Float32 PCM."
            case .invalidOutputFormat:
                return "Unable to configure canonical output format for PCM merge."
            }
        }
    }

    struct InputTrack {
        let kind: TrackKind
        let fileURL: URL
        let offsetFrames: AVAudioFramePosition
        let expectedFrames: AVAudioFramePosition
    }

    private final class OpenTrack {
        let kind: TrackKind
        let file: AVAudioFile
        let offsetFrames: AVAudioFramePosition
        let frameCount: AVAudioFramePosition
        var gain: Float
        var nextReadPosition: AVAudioFramePosition = 0

        init(
            kind: TrackKind,
            file: AVAudioFile,
            offsetFrames: AVAudioFramePosition,
            frameCount: AVAudioFramePosition,
            gain: Float
        ) {
            self.kind = kind
            self.file = file
            self.offsetFrames = offsetFrames
            self.frameCount = frameCount
            self.gain = gain
        }
    }

    private let chunkSize: AVAudioFrameCount
    private let micGain: Float
    private let systemGain: Float

    init(chunkSize: AVAudioFrameCount = 8192, micGain: Float = 1.0, systemGain: Float = 1.0) {
        self.chunkSize = chunkSize
        self.micGain = micGain
        self.systemGain = systemGain
    }

    func mix(tracks: [InputTrack], outputURL: URL) throws -> DirectPCMMixResult {
        guard !tracks.isEmpty else {
            throw MixError.noUsableTracks
        }

        guard let canonicalFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: PCMTrackWriter.canonicalSampleRate,
            channels: PCMTrackWriter.canonicalChannels,
            interleaved: false
        ) else {
            throw MixError.invalidOutputFormat
        }

        var openTracks: [OpenTrack] = []
        openTracks.reserveCapacity(tracks.count)

        for track in tracks {
            // Force a Float32 non-interleaved processing format so any on-disk
            // format (Float32 CAF, Int16 CAF, AAC m4a) decodes uniformly.
            let file = try AVAudioFile(
                forReading: track.fileURL,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            let format = file.processingFormat
            guard format.channelCount == PCMTrackWriter.canonicalChannels,
                  format.sampleRate == PCMTrackWriter.canonicalSampleRate else {
                throw MixError.invalidInputFormat(fileName: track.fileURL.lastPathComponent)
            }

            let frameCount = min(max(track.expectedFrames, 0), file.length)
            guard frameCount > 0 else { continue }

            let gain: Float
            switch track.kind {
            case .microphone:
                gain = micGain
            case .system:
                gain = systemGain
            }

            openTracks.append(
                OpenTrack(
                    kind: track.kind,
                    file: file,
                    offsetFrames: track.offsetFrames,
                    frameCount: frameCount,
                    gain: gain
                )
            )
        }

        guard !openTracks.isEmpty else {
            throw MixError.noUsableTracks
        }

        let mergeMode: MergeMode
        let kinds = Set(openTracks.map(\.kind))
        if kinds == [.microphone] {
            mergeMode = .micOnly
        } else if kinds == [.system] {
            mergeMode = .systemOnly
        } else {
            mergeMode = .dualTrack
        }

        let totalFrames = openTracks.map { $0.offsetFrames + $0.frameCount }.max() ?? 0
        guard totalFrames > 0 else {
            throw MixError.noUsableTracks
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // Scoped so the AVAudioFile deallocates (and the encoder finalizes the
        // bitstream — required for AAC/m4a output) before the caller validates the file.
        do {
            let outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: PCMTrackWriter.fileSettings(for: outputURL),
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try writeMix(openTracks: openTracks, totalFrames: totalFrames, canonicalFormat: canonicalFormat, outputFile: outputFile)
        }

        return DirectPCMMixResult(mergeMode: mergeMode, totalFrames: totalFrames)
    }

    private func writeMix(
        openTracks: [OpenTrack],
        totalFrames: AVAudioFramePosition,
        canonicalFormat: AVAudioFormat,
        outputFile: AVAudioFile
    ) throws {
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: chunkSize),
              let outChannel = outBuffer.floatChannelData?[0],
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: chunkSize),
              let inputChannel = inputBuffer.floatChannelData?[0] else {
            throw MixError.invalidOutputFormat
        }

        var globalPosition: AVAudioFramePosition = 0

        while globalPosition < totalFrames {
            let remaining = totalFrames - globalPosition
            let frameCount = AVAudioFrameCount(min(AVAudioFramePosition(chunkSize), remaining))
            let frameCountInt = Int(frameCount)

            outBuffer.frameLength = frameCount
            vDSP_vclr(outChannel, 1, vDSP_Length(frameCountInt))

            let chunkStart = globalPosition
            let chunkEnd = globalPosition + AVAudioFramePosition(frameCount)

            for track in openTracks {
                let trackStart = track.offsetFrames
                let trackEnd = track.offsetFrames + track.frameCount

                let intersectionStart = max(chunkStart, trackStart)
                let intersectionEnd = min(chunkEnd, trackEnd)
                guard intersectionStart < intersectionEnd else { continue }

                let readFrames = AVAudioFrameCount(intersectionEnd - intersectionStart)
                let localStart = intersectionStart - trackStart
                let destinationOffset = Int(intersectionStart - chunkStart)

                // Reads are sequential chunk-to-chunk; only seek when the local
                // position actually diverges (first intersecting chunk). Explicit
                // framePosition sets are expensive on compressed inputs.
                if track.nextReadPosition != localStart {
                    track.file.framePosition = localStart
                }
                try track.file.read(into: inputBuffer, frameCount: readFrames)
                track.nextReadPosition = localStart + AVAudioFramePosition(inputBuffer.frameLength)

                let actualFrames = Int(inputBuffer.frameLength)
                guard actualFrames > 0 else { continue }
                var gain = track.gain
                vDSP_vsma(
                    inputChannel, 1,
                    &gain,
                    outChannel + destinationOffset, 1,
                    outChannel + destinationOffset, 1,
                    vDSP_Length(actualFrames)
                )
            }

            var lowerBound: Float = -1
            var upperBound: Float = 1
            vDSP_vclip(outChannel, 1, &lowerBound, &upperBound, outChannel, 1, vDSP_Length(frameCountInt))

            try outputFile.write(from: outBuffer)
            globalPosition += AVAudioFramePosition(frameCount)
        }
    }
}

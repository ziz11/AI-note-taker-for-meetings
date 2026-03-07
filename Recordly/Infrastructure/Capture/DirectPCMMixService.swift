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

        struct OpenTrack {
            let kind: TrackKind
            let file: AVAudioFile
            let offsetFrames: AVAudioFramePosition
            let frameCount: AVAudioFramePosition
            let gain: Float
        }

        var openTracks: [OpenTrack] = []
        openTracks.reserveCapacity(tracks.count)

        for track in tracks {
            let file = try AVAudioFile(forReading: track.fileURL)
            let format = file.processingFormat
            guard format.commonFormat == .pcmFormatFloat32,
                  format.channelCount == PCMTrackWriter.canonicalChannels,
                  format.sampleRate == PCMTrackWriter.canonicalSampleRate,
                  format.isInterleaved == false else {
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

        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: canonicalFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        var globalPosition: AVAudioFramePosition = 0

        while globalPosition < totalFrames {
            let remaining = totalFrames - globalPosition
            let frameCount = AVAudioFrameCount(min(AVAudioFramePosition(chunkSize), remaining))
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: frameCount),
                  let outChannel = outBuffer.floatChannelData?[0] else {
                throw MixError.invalidOutputFormat
            }

            outBuffer.frameLength = frameCount
            let frameCountInt = Int(frameCount)
            outChannel.initialize(repeating: 0, count: frameCountInt)

            let chunkStart = globalPosition
            let chunkEnd = globalPosition + AVAudioFramePosition(frameCount)

            for track in openTracks {
                let trackStart = track.offsetFrames
                let trackEnd = track.offsetFrames + track.frameCount

                let intersectionStart = max(chunkStart, trackStart)
                let intersectionEnd = min(chunkEnd, trackEnd)
                guard intersectionStart < intersectionEnd else { continue }

                // Read-seek policy: each input is independently seek/read based on its
                // local range intersection with the current global output chunk.
                let readFrames = AVAudioFrameCount(intersectionEnd - intersectionStart)
                let localStart = intersectionStart - trackStart
                let destinationOffset = Int(intersectionStart - chunkStart)

                guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: readFrames),
                      let inputChannel = inputBuffer.floatChannelData?[0] else {
                    throw MixError.unsupportedInputData(fileName: track.file.url.lastPathComponent)
                }

                track.file.framePosition = localStart
                try track.file.read(into: inputBuffer, frameCount: readFrames)

                let actualFrames = Int(inputBuffer.frameLength)
                for index in 0..<actualFrames {
                    outChannel[destinationOffset + index] += track.gain * inputChannel[index]
                }
            }

            for index in 0..<frameCountInt {
                outChannel[index] = max(-1, min(1, outChannel[index]))
            }

            try outputFile.write(from: outBuffer)
            globalPosition += AVAudioFramePosition(frameCount)
        }

        return DirectPCMMixResult(mergeMode: mergeMode, totalFrames: totalFrames)
    }
}

import AVFoundation
import Foundation

struct PreparedSessionAudio {
    var samples: [Float]
    var sampleRate: Int
    var durationMs: Int
    var sourceURL: URL

    func makePCMBuffer(startSample: Int = 0, endSample: Int? = nil) throws -> AVAudioPCMBuffer {
        let clampedStart = max(0, min(startSample, samples.count))
        let clampedEnd = max(clampedStart, min(endSample ?? samples.count, samples.count))
        let slice = Array(samples[clampedStart..<clampedEnd])

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(max(slice.count, 1))
        ) else {
            throw ASREngineRuntimeError.unsupportedFormat(sourceURL)
        }

        buffer.frameLength = AVAudioFrameCount(slice.count)
        if let channelData = buffer.floatChannelData {
            for (index, sample) in slice.enumerated() {
                channelData[0][index] = sample
            }
        }

        return buffer
    }

    func makePCMBuffer(for region: FluidAudioSpeechRegion) throws -> AVAudioPCMBuffer {
        let startSample = Int((Double(region.startMs) / 1_000.0) * Double(sampleRate))
        let endSample = Int((Double(region.endMs) / 1_000.0) * Double(sampleRate))
        return try makePCMBuffer(startSample: startSample, endSample: endSample)
    }

    func resampled(to targetSampleRate: Int) throws -> PreparedSessionAudio {
        guard targetSampleRate > 0 else {
            throw ASREngineRuntimeError.unsupportedFormat(sourceURL)
        }

        if sampleRate == targetSampleRate {
            return self
        }

        let sourceBuffer = try makePCMBuffer()
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(targetSampleRate),
            channels: 1,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat) else {
            throw ASREngineRuntimeError.unsupportedFormat(sourceURL)
        }

        let ratio = Double(targetSampleRate) / Double(sampleRate)
        let estimatedCapacity = AVAudioFrameCount(max((Double(sourceBuffer.frameLength) * ratio).rounded(.up), 1))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedCapacity) else {
            throw ASREngineRuntimeError.unsupportedFormat(sourceURL)
        }

        var conversionError: NSError?
        var didProvideInput = false
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .endOfStream
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        guard status != .error,
              conversionError == nil,
              outputBuffer.frameLength > 0,
              let channelData = outputBuffer.floatChannelData else {
            throw ASREngineRuntimeError.unsupportedFormat(sourceURL)
        }

        let count = Int(outputBuffer.frameLength)
        let converted = Array(UnsafeBufferPointer(start: channelData[0], count: count))
        let durationMs = Int((Double(converted.count) / Double(targetSampleRate) * 1_000.0).rounded())

        return PreparedSessionAudio(
            samples: converted,
            sampleRate: targetSampleRate,
            durationMs: durationMs,
            sourceURL: sourceURL
        )
    }
}

protocol FluidAudioInputPreparing {
    func prepareInput(from audioURL: URL) throws -> AVAudioPCMBuffer
}

struct FluidAudioInputPreparer: FluidAudioInputPreparing {
    func prepareInput(from audioURL: URL) throws -> AVAudioPCMBuffer {
        do {
            let audioFile = try AVAudioFile(forReading: audioURL)
            let fileLength = audioFile.length
            guard fileLength > 0 else {
                throw ASREngineRuntimeError.unsupportedFormat(audioURL)
            }

            guard fileLength <= AVAudioFramePosition(UInt32.max),
                  let sourceBuffer = AVAudioPCMBuffer(
                      pcmFormat: audioFile.processingFormat,
                      frameCapacity: AVAudioFrameCount(fileLength)
                  ) else {
                throw ASREngineRuntimeError.unsupportedFormat(audioURL)
            }

            try audioFile.read(into: sourceBuffer)
            guard sourceBuffer.frameLength > 0 else {
                throw ASREngineRuntimeError.unsupportedFormat(audioURL)
            }

            return try convertIfNeeded(sourceBuffer, audioURL: audioURL)
        } catch let error as ASREngineRuntimeError {
            throw error
        } catch {
            throw ASREngineRuntimeError.unsupportedFormat(audioURL)
        }
    }

    private func convertIfNeeded(
        _ inputBuffer: AVAudioPCMBuffer,
        audioURL: URL
    ) throws -> AVAudioPCMBuffer {
        let inputFormat = inputBuffer.format

        guard let decodeFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: inputFormat.channelCount,
            interleaved: false
        ) else {
            throw ASREngineRuntimeError.unsupportedFormat(audioURL)
        }

        if inputFormat.sampleRate == decodeFormat.sampleRate,
           inputFormat.channelCount == decodeFormat.channelCount,
           inputFormat.commonFormat == decodeFormat.commonFormat,
           inputFormat.isInterleaved == decodeFormat.isInterleaved {
            return inputBuffer
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: decodeFormat) else {
            throw ASREngineRuntimeError.unsupportedFormat(audioURL)
        }

        let ratio = decodeFormat.sampleRate / max(inputFormat.sampleRate, 1)
        let estimatedCapacity = AVAudioFrameCount((Double(inputBuffer.frameLength) * ratio).rounded(.up))
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: decodeFormat,
            frameCapacity: max(estimatedCapacity, 1)
        ) else {
            throw ASREngineRuntimeError.unsupportedFormat(audioURL)
        }

        var conversionError: NSError?
        var didProvideInput = false
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .endOfStream
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error,
              conversionError == nil,
              outputBuffer.frameLength > 0 else {
            throw ASREngineRuntimeError.unsupportedFormat(audioURL)
        }

        return outputBuffer
    }
}

protocol FluidAudioSessionAudioLoading {
    func loadAudio(from audioURL: URL) throws -> PreparedSessionAudio
}

struct FluidAudioSessionAudioLoader: FluidAudioSessionAudioLoading {
    private let inputPreparer: FluidAudioInputPreparing

    init(inputPreparer: FluidAudioInputPreparing = FluidAudioInputPreparer()) {
        self.inputPreparer = inputPreparer
    }

    func loadAudio(from audioURL: URL) throws -> PreparedSessionAudio {
        let buffer = try inputPreparer.prepareInput(from: audioURL)
        guard let channelData = buffer.floatChannelData else {
            throw ASREngineRuntimeError.unsupportedFormat(audioURL)
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else {
            throw ASREngineRuntimeError.unsupportedFormat(audioURL)
        }

        var monoSamples: [Float] = Array(repeating: 0, count: frameCount)
        if channelCount == 1 {
            monoSamples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        } else {
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += channelData[channel][frame]
                }
                monoSamples[frame] = sum / Float(channelCount)
            }
        }

        let sampleRate = Int(buffer.format.sampleRate.rounded())
        let durationMs = Int((Double(frameCount) / buffer.format.sampleRate * 1_000.0).rounded())

        return PreparedSessionAudio(
            samples: monoSamples,
            sampleRate: sampleRate,
            durationMs: durationMs,
            sourceURL: audioURL
        )
    }
}

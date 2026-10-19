@preconcurrency import AVFoundation
import Foundation

/// Tap buffers belong to AVAudioEngine; copy before handing them to the bounded consumer.
final class SegmentedMicrophoneCapture: @unchecked Sendable {
    private struct Sample: @unchecked Sendable {
        var buffer: AVAudioPCMBuffer
        var timestamp: CMTime
    }
    private var engine: AVAudioEngine?
    private var pipeline: CaptureSamplePipeline<Sample>?
    private var writer: MirroredTrackWriter?
    private let levelLock = NSLock()
    private var level: Double = 0
    private var failed = false

    func start(writer: MirroredTrackWriter, onFailure: @escaping @Sendable (Error) -> Void) throws {
        setFailed(false)
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioCaptureError.recorderFailedToStart }
        let pipeline = CaptureSamplePipeline<Sample>(bufferLimit: 64) { sample in
            guard !self.isFailed else { return }
            do { try await writer.append(pcmBuffer: sample.buffer, presentationTime: sample.timestamp) }
            catch {
                if CaptureWriteFailurePolicy.isTerminal(error) { self.setFailed(true) }
                await writer.recordDiagnostic("Fallback microphone append failed: \(error.localizedDescription)")
                onFailure(error)
            }
        }
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { buffer, time in
            if let data = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                var squares: Double = 0
                for frame in 0..<Int(buffer.frameLength) { squares += Double(data[frame] * data[frame]) }
                self.setLevel(min(1, sqrt(squares / Double(buffer.frameLength)) * 4))
            }
            guard time.isHostTimeValid, buffer.frameLength > 0,
                  let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in source.indices {
                guard let src = source[index].mData, let dst = destination[index].mData else { return }
                memcpy(dst, src, min(Int(source[index].mDataByteSize), Int(destination[index].mDataByteSize)))
            }
            pipeline.submit(Sample(buffer: copy, timestamp: CMTime(seconds: AVAudioTime.seconds(forHostTime: time.hostTime), preferredTimescale: 48_000)))
        }
        engine.prepare()
        do { try engine.start() }
        catch { input.removeTap(onBus: 0); throw error }
        self.pipeline = pipeline
        self.writer = writer
        self.engine = engine
    }

    func stop() async {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        await pipeline?.finish()
        if let pipeline, pipeline.droppedCount > 0 {
            await writer?.recordDiagnostic("Fallback microphone pipeline dropped \(pipeline.droppedCount) buffers; gaps preserve missing time.")
        }
        pipeline = nil
        writer = nil
        setLevel(0)
    }

    func currentLevel() -> Double {
        levelLock.lock(); defer { levelLock.unlock() }
        return level
    }

    private func setLevel(_ value: Double) {
        levelLock.lock(); defer { levelLock.unlock() }
        level = value
    }

    private var isFailed: Bool {
        levelLock.lock(); defer { levelLock.unlock() }
        return failed
    }

    private func setFailed(_ value: Bool) {
        levelLock.lock(); defer { levelLock.unlock() }
        failed = value
    }
}

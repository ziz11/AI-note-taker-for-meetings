@preconcurrency import AVFoundation
import Foundation

/// Serial capture consumer; finalization runs on independent actors after handoff.
actor SegmentedTrackWriter: TrackWriting {
    private let kind: TrackKind
    private let store: SessionAudioStore
    private let committer: SessionAudioCommitter
    private let targetFrames: Int64
    private let maximumPendingFinalizations: Int
    private var active: PCMTrackWriter?
    private var segment: SessionAudioSegment?
    private var index = 0
    private var expectedEndFrame: Int64 = 0
    private var totalFrames: Int64 = 0
    private var bufferCount = 0
    private var firstPTS: Double?
    private var lastPTS: Double?
    private var diagnostics: [String] = []
    private var publicationFailed = false
    private var pending: [(Task<Void, Never>, ChunkFinalizationState)] = []
    private var stopped = false
    private var appending = false

    init(kind: TrackKind, store: SessionAudioStore, committer: SessionAudioCommitter, chunkDuration: Double = 180,
         maximumPendingFinalizations: Int = 2) {
        self.kind = kind
        self.store = store
        self.committer = committer
        let normalizedDuration = chunkDuration.isFinite ? min(max(0.001, chunkDuration), 180) : 180
        self.targetFrames = max(1, Int64((normalizedDuration * 48_000).rounded()))
        self.maximumPendingFinalizations = max(1, maximumPendingFinalizations)
    }

    func append(sampleBuffer: CMSampleBuffer) async throws {
        guard !stopped, !appending else { throw SessionAudioError.invalidInput }
        appending = true
        defer { appending = false }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        let rate = CMSampleBufferGetFormatDescription(sampleBuffer).flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 48_000
        guard rate.isFinite, rate > 0 else { throw SessionAudioError.invalidInput }
        let seconds = duration.isValid && duration.seconds > 0 ? duration.seconds : Double(CMSampleBufferGetNumSamples(sampleBuffer)) / rate
        let frames = try Self.frames(for: seconds)
        try await prepareForAppend(pts: pts.isValid ? pts.seconds : nil, frames: frames)
        try await active?.append(sampleBuffer: sampleBuffer)
        bufferCount += 1
    }

    func append(pcmBuffer: AVAudioPCMBuffer, presentationTime: CMTime? = nil) async throws {
        guard !stopped, !appending else { throw SessionAudioError.invalidInput }
        appending = true
        defer { appending = false }
        guard pcmBuffer.format.sampleRate.isFinite, pcmBuffer.format.sampleRate > 0 else { throw SessionAudioError.invalidInput }
        let frames = try Self.frames(for: Double(pcmBuffer.frameLength) / pcmBuffer.format.sampleRate)
        try await prepareForAppend(pts: presentationTime?.seconds, frames: frames)
        try await active?.append(pcmBuffer: pcmBuffer, presentationTime: presentationTime)
        bufferCount += 1
    }

    private func prepareForAppend(pts: Double?, frames: Int64) async throws {
        guard frames > 0 else { throw SessionAudioError.invalidInput }
        reapFinalizations()
        guard !publicationFailed else { throw SessionAudioError.publicationFailed }
        if let pts {
            guard pts.isFinite, store.hostTimeOrigin.isFinite, abs(pts - store.hostTimeOrigin) < Double(Int64.max / 48_000) else { throw SessionAudioError.invalidInput }
        }
        let position = pts.map { max(0, Int64((($0 - store.hostTimeOrigin) * 48_000).rounded())) } ?? expectedEndFrame
        guard position <= Int64.max - frames else { throw SessionAudioError.invalidInput }
        if bufferCount > 0, position < expectedEndFrame - 1 {
            recordDiagnostic("Rejected stale capture timestamp at frame \(position)")
            throw SessionAudioError.invalidInput
        }
        if let current = segment, position >= current.startFrame + targetFrames {
            // At most two files may be finalizing. Fail explicitly rather than grow memory.
            guard pending.count < maximumPendingFinalizations else { throw SessionAudioError.rotationBacklog }
            let previousWriter = active!
            let previousSegment = current
            try store.checkpoint(previousSegment)
            try openSegment(startFrame: position)
            store.faultInjector?("rotation-handoff")
            enqueueFinalization(previousWriter, segment: previousSegment)
        } else if active == nil { try openSegment(startFrame: position) }
        if let pts {
            if firstPTS == nil { firstPTS = pts }
            lastPTS = pts
            if segment?.firstCapturePTS == nil { segment?.firstCapturePTS = pts }
            segment?.lastCapturePTS = pts
        }
        if position > expectedEndFrame, bufferCount > 0 {
            segment?.gaps.append(AudioTimelineGap(startFrame: expectedEndFrame, frameCount: position - expectedEndFrame, reason: "capture-gap"))
        }
        // Capture timing is authoritative; stale timestamps must not shrink the timeline.
        expectedEndFrame = max(expectedEndFrame, position + frames)
    }

    private static func frames(for seconds: Double) throws -> Int64 {
        // Capture queues contain at most 64 source buffers, each at most one second.
        guard seconds.isFinite, seconds > 0, seconds <= 1 else { throw SessionAudioError.invalidInput }
        return max(1, Int64((seconds * 48_000).rounded()))
    }

    private func openSegment(startFrame: Int64) throws {
        let next = SessionAudioSegment(track: kind, index: index, startFrame: startFrame)
        try store.prepare(next)
        let writer = try PCMTrackWriter(kind: kind, fileName: next.fileName, fileURL: store.pendingURL(for: next))
        active = writer
        segment = next
        index += 1
    }

    private func enqueueFinalization(_ writer: PCMTrackWriter, segment: SessionAudioSegment) {
        let state = ChunkFinalizationState()
        let task = Task.detached { [committer] in
            let stats = await writer.finalize()
            var finalized = segment
            finalized.frameCount = stats.framesWritten
            do {
                guard finalized.frameCount > 0 else { throw SessionAudioError.invalidAudio }
                guard !stats.diagnostics.contains(where: { $0.hasPrefix("Final flush failed") }) else { throw SessionAudioError.invalidAudio }
                try await committer.publish(finalized)
                state.finish(frames: stats.framesWritten, error: nil)
            } catch { state.finish(frames: 0, error: "Chunk \(segment.id) finalization failed: \(error)") }
        }
        pending.append((task, state))
    }

    private func reapFinalizations() {
        pending.removeAll { entry in
            guard let result = entry.1.result else { return false }
            totalFrames += result.frames
            if let error = result.error { publicationFailed = true; recordDiagnostic(error) }
            return true
        }
    }

    func finalize() async -> TrackRuntimeStats {
        stopped = true
        while appending { await Task.yield() }
        if let active, let segment {
            while pending.count >= maximumPendingFinalizations {
                await pending[0].0.value
                reapFinalizations()
            }
            do { try store.checkpoint(segment) }
            catch { recordDiagnostic("Chunk timing checkpoint failed: \(error)") }
            enqueueFinalization(active, segment: segment)
            self.active = nil
            self.segment = nil
        }
        for entry in pending { await entry.0.value }
        reapFinalizations()
        return TrackRuntimeStats(kind: kind, fileName: "audio-manifest.json", firstPTS: firstPTS,
                                 lastPTS: lastPTS, framesWritten: totalFrames, sampleRate: 48_000,
                                 bufferCount: bufferCount, fallback: false, diagnostics: diagnostics)
    }

    func recordDiagnostic(_ diagnostic: String) {
        if diagnostics.count < 128 { diagnostics.append(diagnostic) }
        else if diagnostics.count == 128 { diagnostics.append("Additional capture diagnostics omitted.") }
    }
}

enum CaptureWriteFailurePolicy {
    static func isTerminal(_ error: Error) -> Bool {
        if error is PCMWriterError { return false }
        if let error = error as? SessionAudioError {
            switch error {
            case .invalidInput: return false
            default: return true
            }
        }
        return true
    }
}

private final class ChunkFinalizationState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (frames: Int64, error: String?)?
    var result: (frames: Int64, error: String?)? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func finish(frames: Int64, error: String?) {
        lock.lock(); defer { lock.unlock() }
        value = (frames, error)
    }
}

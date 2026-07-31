import Accelerate
import AppKit
@preconcurrency import AVFoundation
import Foundation
import ApplicationServices
import os.signpost
import ScreenCaptureKit

private enum LiveCaptureArtifactNames {
    static let microphoneTemporary = "mic.raw.caf"
    static let systemTemporary = "system.raw.caf"
    static let microphoneDurable = "mic.m4a"
    static let systemDurable = "system.m4a"
}

struct CaptureArtifacts {
    var microphoneFile: String?
    var systemAudioFile: String?
    var mergedCallFile: String?
    var connectorNotesFile: String?
    var note: String?
}

enum CaptureArtifactValidator {
    static func usableAudioFileName(_ fileName: String?, in sessionDirectory: URL) -> String? {
        guard let fileName else { return nil }
        let url = sessionDirectory.appendingPathComponent(fileName)
        return isUsableAudioFile(url) ? fileName : nil
    }

    static func shouldReplaceDestination(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return true
        }
        return !isUsableAudioFile(url)
    }

    static func isUsableAudioFile(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else {
            return false
        }

        guard let file = try? AVAudioFile(forReading: url) else {
            return false
        }
        return file.length > 0
    }
}

enum AudioCaptureError: LocalizedError {
    case microphonePermissionDenied
    case captureAlreadyRunning
    case noActiveCapture
    case recorderFailedToStart
    case recorderFailedToFinalize
    case invalidRecordedFile
    case systemAudioUnsupported
    case systemAudioPermissionDenied
    case systemAudioFailedToStart
    case systemAudioStartupTimeout
    case captureFinalizationTimedOut
    case invalidSystemAudioFile
    case mixdownFailed
    case noScreenToCapture

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission was denied."
        case .captureAlreadyRunning:
            return "A recording is already in progress."
        case .noActiveCapture:
            return "No active recording session exists."
        case .recorderFailedToStart:
            return "The recorder could not start."
        case .recorderFailedToFinalize:
            return "The audio file could not be finalized after stopping."
        case .invalidRecordedFile:
            return "The microphone recording was created, but the audio file is invalid or unreadable."
        case .systemAudioUnsupported:
            return "System audio capture is not supported on this macOS configuration."
        case .systemAudioPermissionDenied:
            return "System audio capture permission was denied."
        case .systemAudioFailedToStart:
            return "The system audio recorder could not start."
        case .systemAudioStartupTimeout:
            return "System audio capture did not start in time."
        case .captureFinalizationTimedOut:
            return "Capture finalization timed out."
        case .invalidSystemAudioFile:
            return "The system audio file was created, but the audio data is invalid or unreadable."
        case .mixdownFailed:
            return "The app could not create the mixed playback track."
        case .noScreenToCapture:
            return "No active display is available for ScreenCaptureKit stream setup."
        }
    }
}

enum RecordingSessionStatus: String, Codable {
    case recording
    case finalizingTracks
    case readyForMix
    case mixing
    case ready
    case mixError
}

enum TrackKind: String, Codable {
    case microphone
    case system
}

struct ScreenCapturePermissionCoordinator {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")

    private let hasPermission: () -> Bool
    private let requestPermission: () -> Bool
    private let openSettings: () -> Void

    init(
        hasPermission: @escaping () -> Bool = {
            CGPreflightScreenCaptureAccess()
        },
        requestPermission: @escaping () -> Bool = {
            CGRequestScreenCaptureAccess()
        },
        openSettings: @escaping () -> Void = {
            guard let settingsURL = ScreenCapturePermissionCoordinator.settingsURL else {
                return
            }
            NSWorkspace.shared.open(settingsURL)
        }
    ) {
        self.hasPermission = hasPermission
        self.requestPermission = requestPermission
        self.openSettings = openSettings
    }

    func hasSystemRecordingPermission() -> Bool {
        hasPermission()
    }

    func openSystemRecordingSettings() {
        openSettings()
    }

    @discardableResult
    func requestSystemRecordingPermission() -> Bool {
        let granted = requestPermission()
        if !granted {
            openSettings()
        }
        return granted
    }
}

enum MergeMode: String, Codable {
    case dualTrack
    case micOnly
    case systemOnly
    case unavailable
}

struct TrackRuntimeStats: Codable {
    var kind: TrackKind
    var fileName: String
    var firstPTS: Double?
    var lastPTS: Double?
    var framesWritten: Int64
    var sampleRate: Double
    var bufferCount: Int
    var fallback: Bool
    var diagnostics: [String]

    var durationByPTS: Double? {
        guard let firstPTS, let lastPTS else { return nil }
        return max(0, lastPTS - firstPTS)
    }

    var durationByFrames: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(framesWritten) / sampleRate
    }
}

struct SessionMetadata: Codable {
    var id: UUID
    var createdAt: Date
    var status: RecordingSessionStatus
    var sampleRate: Double
    var channelCount: Int
    var tracks: [TrackKind: TrackRuntimeStats]
    var driftWarnings: [String]
    var notes: [String]
    var mergeMode: MergeMode

    static func empty(id: UUID) -> SessionMetadata {
        SessionMetadata(
            id: id,
            createdAt: Date(),
            status: .recording,
            sampleRate: PCMTrackWriter.canonicalSampleRate,
            channelCount: Int(PCMTrackWriter.canonicalChannels),
            tracks: [:],
            driftWarnings: [],
            notes: [],
            mergeMode: .unavailable
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case status
        case sampleRate
        case channelCount
        case tracks
        case driftWarnings
        case notes
        case mergeMode
    }

    init(
        id: UUID,
        createdAt: Date,
        status: RecordingSessionStatus,
        sampleRate: Double,
        channelCount: Int,
        tracks: [TrackKind: TrackRuntimeStats],
        driftWarnings: [String],
        notes: [String],
        mergeMode: MergeMode
    ) {
        self.id = id
        self.createdAt = createdAt
        self.status = status
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.tracks = tracks
        self.driftWarnings = driftWarnings
        self.notes = notes
        self.mergeMode = mergeMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        status = try container.decode(RecordingSessionStatus.self, forKey: .status)
        sampleRate = try container.decode(Double.self, forKey: .sampleRate)
        channelCount = try container.decode(Int.self, forKey: .channelCount)
        tracks = try container.decode([TrackKind: TrackRuntimeStats].self, forKey: .tracks)
        driftWarnings = try container.decode([String].self, forKey: .driftWarnings)
        notes = try container.decode([String].self, forKey: .notes)
        mergeMode = try container.decodeIfPresent(MergeMode.self, forKey: .mergeMode) ?? .unavailable
    }
}

actor SessionMetadataStore {
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    func metadataURL(in sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent("capture-session.json")
    }

    func createSession(id: UUID, in sessionDirectory: URL) throws {
        let metadata = SessionMetadata.empty(id: id)
        try save(metadata, in: sessionDirectory)
    }

    func updateStatus(_ status: RecordingSessionStatus, in sessionDirectory: URL) throws {
        var metadata = try loadOrCreate(in: sessionDirectory)
        metadata.status = status
        try save(metadata, in: sessionDirectory)
    }

    func updateTrack(_ stats: TrackRuntimeStats, in sessionDirectory: URL) throws {
        var metadata = try loadOrCreate(in: sessionDirectory)
        metadata.tracks[stats.kind] = stats
        try save(metadata, in: sessionDirectory)
    }

    func appendNote(_ note: String, in sessionDirectory: URL) throws {
        var metadata = try loadOrCreate(in: sessionDirectory)
        metadata.notes.append(note)
        try save(metadata, in: sessionDirectory)
    }

    func appendDriftWarning(_ warning: String, in sessionDirectory: URL) throws {
        var metadata = try loadOrCreate(in: sessionDirectory)
        metadata.driftWarnings.append(warning)
        try save(metadata, in: sessionDirectory)
    }

    func replace(_ metadata: SessionMetadata, in sessionDirectory: URL) throws {
        try save(metadata, in: sessionDirectory)
    }

    func load(in sessionDirectory: URL) throws -> SessionMetadata {
        let url = metadataURL(in: sessionDirectory)
        let data = try Data(contentsOf: url)
        return try decoder.decode(SessionMetadata.self, from: data)
    }

    private func loadOrCreate(in sessionDirectory: URL) throws -> SessionMetadata {
        do {
            return try load(in: sessionDirectory)
        } catch {
            let id = UUID(uuidString: sessionDirectory.lastPathComponent) ?? UUID()
            return SessionMetadata.empty(id: id)
        }
    }

    private func save(_ metadata: SessionMetadata, in sessionDirectory: URL) throws {
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL(in: sessionDirectory), options: .atomic)
    }
}

enum PCMWriterError: Error {
    case invalidSampleBuffer
    case unsupportedAudioFormat
    case conversionFailed
}

protocol TrackWriting: Actor {
    func append(sampleBuffer: CMSampleBuffer) throws
    func append(pcmBuffer: AVAudioPCMBuffer, presentationTime: CMTime?) throws
    func finalize() -> TrackRuntimeStats
    func recordDiagnostic(_ diagnostic: String)
}

actor PCMTrackWriter: TrackWriting {
    static let canonicalSampleRate: Double = 48_000
    static let canonicalChannels: AVAudioChannelCount = 1
    static let durableAACBitRate = 96_000
    private static let signposter = OSSignposter(subsystem: "com.recordly.capture", category: "writer")

    let kind: TrackKind
    let fileName: String
    let fileURL: URL

    private let outputFormat: AVAudioFormat
    private var audioFile: AVAudioFile
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    private var firstPTS: Double?
    private var lastPTS: Double?
    private var nextExpectedPTS: Double?
    private var framesWritten: Int64 = 0
    private var bufferCount = 0
    private let fallback: Bool
    private var diagnostics: [String]

    private var stagingBuffer: AVAudioPCMBuffer?
    private var stagedFrames: AVAudioFrameCount = 0
    private let flushThresholdFrames = AVAudioFrameCount(48_000 / 2) // ~500 ms

    init(kind: TrackKind, fileName: String, fileURL: URL, fallback: Bool = false, diagnostics: [String] = []) throws {
        guard let canonical = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.canonicalSampleRate,
            channels: Self.canonicalChannels,
            interleaved: false
        ) else {
            throw PCMWriterError.unsupportedAudioFormat
        }
        self.kind = kind
        self.fileName = fileName
        self.fileURL = fileURL
        self.outputFormat = canonical

        self.audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: Self.fileSettings(for: fileURL),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        self.fallback = fallback
        self.diagnostics = diagnostics
    }

    static func fileSettings(for fileURL: URL) -> [String: Any] {
        switch fileURL.pathExtension.lowercased() {
        case "flac":
            [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: Self.canonicalSampleRate,
                AVNumberOfChannelsKey: Int(Self.canonicalChannels),
                AVLinearPCMBitDepthKey: 24
            ]
        case "m4a":
            [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.canonicalSampleRate,
                AVNumberOfChannelsKey: Int(Self.canonicalChannels),
                AVEncoderBitRateKey: Self.durableAACBitRate,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
        default:
            // Int16 halves raw CAF size vs Float32 (330 MB/hr vs 660 MB/hr per track);
            // capture sources deliver ≤1.0 material, so no headroom is lost in practice.
            // Processing format stays Float32 — ExtAudioFile converts on write.
            [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.canonicalSampleRate,
                AVNumberOfChannelsKey: Int(Self.canonicalChannels),
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        }
    }

    func append(sampleBuffer: CMSampleBuffer) throws {
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            throw PCMWriterError.invalidSampleBuffer
        }

        let inputBuffer = try Self.makePCMBuffer(from: sampleBuffer)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        try append(pcmBuffer: inputBuffer, presentationTime: pts.isValid ? pts : nil)
    }

    func append(pcmBuffer: AVAudioPCMBuffer, presentationTime: CMTime? = nil) throws {
        let presentationSeconds: Double?
        if let presentationTime, presentationTime.isValid {
            presentationSeconds = presentationTime.seconds
            let seconds = presentationTime.seconds
            if firstPTS == nil {
                firstPTS = seconds
            }
            lastPTS = seconds
        } else {
            presentationSeconds = nil
        }

        let renderedBuffer = try convertIfNeeded(pcmBuffer)
        guard renderedBuffer.frameLength > 0 else { return }

        if let presentationSeconds, let nextExpectedPTS {
            let gapFrames = Int64(
                ((presentationSeconds - nextExpectedPTS) * outputFormat.sampleRate).rounded()
            )
            if gapFrames > 0 {
                try stageSilence(frames: gapFrames)
                diagnostics.append("Inserted \(gapFrames) silence frames for capture timeline gap.")
            }
        }
        try stage(renderedBuffer)
        let renderedDuration = Double(renderedBuffer.frameLength) / outputFormat.sampleRate
        if let presentationSeconds {
            nextExpectedPTS = presentationSeconds + renderedDuration
        } else if let nextExpectedPTS {
            self.nextExpectedPTS = nextExpectedPTS + renderedDuration
        }
        bufferCount += 1
    }

    func finalize() -> TrackRuntimeStats {
        flushStagingBuffer()
        // Close the file so the container is complete (AAC/m4a stays invalid until
        // closed) — stop-time validation and immediate reads depend on this.
        audioFile.close()
        return TrackRuntimeStats(
            kind: kind,
            fileName: fileName,
            firstPTS: firstPTS,
            lastPTS: lastPTS,
            framesWritten: framesWritten,
            sampleRate: outputFormat.sampleRate,
            bufferCount: bufferCount,
            fallback: fallback,
            diagnostics: diagnostics
        )
    }

    func recordDiagnostic(_ diagnostic: String) {
        diagnostics.append(diagnostic)
    }

    private func stage(_ buffer: AVAudioPCMBuffer) throws {
        let incoming = buffer.frameLength
        guard incoming > 0 else { return }

        if stagingBuffer == nil {
            stagingBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: flushThresholdFrames + 8192)
            stagedFrames = 0
        }
        guard let staging = stagingBuffer,
              let srcChannel = buffer.floatChannelData?[0],
              let dstChannel = staging.floatChannelData?[0] else {
            // Fallback: write directly if staging allocation failed.
            try audioFile.write(from: buffer)
            framesWritten += Int64(incoming)
            return
        }

        let space = staging.frameCapacity - stagedFrames
        if incoming <= space {
            dstChannel.advanced(by: Int(stagedFrames)).update(from: srcChannel, count: Int(incoming))
            stagedFrames += incoming
            staging.frameLength = stagedFrames
        } else {
            // Fill remaining space, flush, then stage the rest.
            if space > 0 {
                dstChannel.advanced(by: Int(stagedFrames)).update(from: srcChannel, count: Int(space))
                stagedFrames += space
                staging.frameLength = stagedFrames
            }
            try flushStagingBufferThrowing()
            let remainder = incoming - space
            dstChannel.update(from: srcChannel.advanced(by: Int(space)), count: Int(remainder))
            stagedFrames = remainder
            staging.frameLength = stagedFrames
        }

        if stagedFrames >= flushThresholdFrames {
            try flushStagingBufferThrowing()
        }
    }

    private func stageSilence(frames: Int64) throws {
        var remaining = frames
        while remaining > 0 {
            let chunkFrames = AVAudioFrameCount(
                min(remaining, Int64(flushThresholdFrames))
            )
            guard let silence = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: chunkFrames
            ), let channel = silence.floatChannelData?[0] else {
                throw PCMWriterError.conversionFailed
            }
            silence.frameLength = chunkFrames
            vDSP_vclr(channel, 1, vDSP_Length(chunkFrames))
            try stage(silence)
            remaining -= Int64(chunkFrames)
        }
    }

    private func flushStagingBufferThrowing() throws {
        guard let staging = stagingBuffer, stagedFrames > 0 else { return }
        let signpostState = Self.signposter.beginInterval("capture.flush")
        defer { Self.signposter.endInterval("capture.flush", signpostState) }
        staging.frameLength = stagedFrames
        try audioFile.write(from: staging)
        framesWritten += Int64(stagedFrames)
        stagedFrames = 0
    }

    private func flushStagingBuffer() {
        try? flushStagingBufferThrowing()
    }

    private func convertIfNeeded(_ inputBuffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let inputFormat = inputBuffer.format
        if inputFormat.sampleRate == outputFormat.sampleRate,
           inputFormat.channelCount == outputFormat.channelCount,
           inputFormat.commonFormat == outputFormat.commonFormat,
           inputFormat.isInterleaved == outputFormat.isInterleaved {
            return inputBuffer
        }

        if sourceFormat == nil || sourceFormat != inputFormat {
            sourceFormat = inputFormat
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }

        guard let converter else {
            throw PCMWriterError.unsupportedAudioFormat
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 8
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw PCMWriterError.conversionFailed
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

        return outputBuffer
    }

    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw PCMWriterError.unsupportedAudioFormat
        }

        var asbd = asbdPointer.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw PCMWriterError.unsupportedAudioFormat
        }

        var bufferListSize = 0
        let statusSize = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard statusSize == noErr else {
            throw PCMWriterError.invalidSampleBuffer
        }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }

        let audioBufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else {
            throw PCMWriterError.invalidSampleBuffer
        }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList, deallocator: nil) else {
            throw PCMWriterError.invalidSampleBuffer
        }

        pcmBuffer.frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        return pcmBuffer
    }
}

actor MirroredTrackWriter {
    private let temporary: any TrackWriting
    private let durable: (any TrackWriting)?
    private var durableMirrorFailed = false
    private var durableFailureMessage: String?

    init(temporary: any TrackWriting, durable: (any TrackWriting)?) {
        self.temporary = temporary
        self.durable = durable
    }

    func append(sampleBuffer: CMSampleBuffer) async throws {
        try await temporary.append(sampleBuffer: sampleBuffer)
        try await durable?.append(sampleBuffer: sampleBuffer)
    }

    @discardableResult
    func appendPreservingCanonical(sampleBuffer: CMSampleBuffer) async throws -> String? {
        try await temporary.append(sampleBuffer: sampleBuffer)
        guard let durable else {
            return nil
        }
        guard !durableMirrorFailed else {
            return durableFailureMessage
        }
        do {
            try await durable.append(sampleBuffer: sampleBuffer)
            return nil
        } catch {
            let message = "durable mirror append failed: \(error.localizedDescription)"
            durableMirrorFailed = true
            durableFailureMessage = message
            await temporary.recordDiagnostic(message)
            await durable.recordDiagnostic(message)
            return message
        }
    }

    func append(pcmBuffer: AVAudioPCMBuffer, presentationTime: CMTime? = nil) async throws {
        try await temporary.append(pcmBuffer: pcmBuffer, presentationTime: presentationTime)
        try await durable?.append(pcmBuffer: pcmBuffer, presentationTime: presentationTime)
    }

    @discardableResult
    func appendPreservingCanonical(
        pcmBuffer: AVAudioPCMBuffer,
        presentationTime: CMTime? = nil
    ) async throws -> String? {
        try await temporary.append(pcmBuffer: pcmBuffer, presentationTime: presentationTime)
        guard let durable else {
            return nil
        }
        guard !durableMirrorFailed else {
            return durableFailureMessage
        }
        do {
            try await durable.append(pcmBuffer: pcmBuffer, presentationTime: presentationTime)
            return nil
        } catch {
            let message = "durable mirror append failed: \(error.localizedDescription)"
            durableMirrorFailed = true
            durableFailureMessage = message
            await temporary.recordDiagnostic(message)
            await durable.recordDiagnostic(message)
            return message
        }
    }

    func requiresDurableExport() -> Bool {
        durableMirrorFailed
    }

    func finalize() async -> [TrackRuntimeStats] {
        var stats: [TrackRuntimeStats] = []
        stats.append(await temporary.finalize())
        if let durable {
            stats.append(await durable.finalize())
        }
        return stats
    }

    func recordDiagnostic(_ diagnostic: String) async {
        await temporary.recordDiagnostic(diagnostic)
        await durable?.recordDiagnostic(diagnostic)
    }
}

final class FallbackMicrophoneRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var finishContinuation: CheckedContinuation<Void, Error>?

    func startRecording(to fileURL: URL) throws {
        let settings: [String: Any]
        if fileURL.pathExtension.lowercased() == "flac" {
            settings = [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: PCMTrackWriter.canonicalSampleRate,
                AVNumberOfChannelsKey: Int(PCMTrackWriter.canonicalChannels),
                AVLinearPCMBitDepthKey: 24
            ]
        } else {
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: PCMTrackWriter.canonicalSampleRate,
                AVNumberOfChannelsKey: Int(PCMTrackWriter.canonicalChannels),
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        }

        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw AudioCaptureError.recorderFailedToStart
        }
        self.recorder = recorder
    }

    func stopRecording() async throws {
        guard let recorder else { return }
        if !recorder.isRecording {
            self.recorder = nil
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            finishContinuation = continuation
            recorder.stop()
        }
        self.recorder = nil
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let continuation = finishContinuation
        finishContinuation = nil
        if flag {
            continuation?.resume()
        } else {
            continuation?.resume(throwing: AudioCaptureError.recorderFailedToFinalize)
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let continuation = finishContinuation
        finishContinuation = nil
        self.recorder = nil
        continuation?.resume(throwing: error ?? AudioCaptureError.recorderFailedToFinalize)
    }

    func currentLevel() -> Double {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let averagePower = recorder.averagePower(forChannel: 0)
        let minDb: Float = -60
        return Double(max(0, (averagePower - minDb) / abs(minDb)))
    }
}

final class ScreenCaptureStreamLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var nextCaptureRequest: UInt64 = 0
    private var currentCaptureRequest: UInt64?
    private var nextStreamGeneration: UInt64 = 0
    private var currentStreamID: ObjectIdentifier?
    private var currentStreamGeneration: UInt64?
    private var streamGenerations: [ObjectIdentifier: UInt64] = [:]
    private var intentionalStops: Set<ObjectIdentifier> = []
    private var forwardedStops: Set<ObjectIdentifier> = []
    private var pendingStops: Set<ObjectIdentifier> = []

    func beginCaptureRequest() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextCaptureRequest &+= 1
        currentCaptureRequest = nextCaptureRequest
        return nextCaptureRequest
    }

    func cancelCaptureRequest() {
        lock.lock()
        defer { lock.unlock() }
        nextCaptureRequest &+= 1
        currentCaptureRequest = nil
    }

    func isCurrentCaptureRequest(_ request: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentCaptureRequest == request
    }

    @discardableResult
    func install(_ stream: AnyObject) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if let currentStreamID {
            streamGenerations[currentStreamID] = nil
        }
        nextStreamGeneration &+= 1
        let generation = nextStreamGeneration
        let streamID = ObjectIdentifier(stream)
        intentionalStops.remove(streamID)
        forwardedStops.remove(streamID)
        streamGenerations[streamID] = generation
        currentStreamID = ObjectIdentifier(stream)
        currentStreamGeneration = generation
        return generation
    }

    func generation(for stream: AnyObject) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return streamGenerations[ObjectIdentifier(stream)]
    }

    func isCurrentStreamGeneration(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentStreamGeneration == generation
    }

    func markIntentionalStop(for stream: AnyObject) {
        lock.lock()
        defer { lock.unlock() }
        let streamID = ObjectIdentifier(stream)
        intentionalStops.insert(streamID)
        streamGenerations[streamID] = nil
        if currentStreamID == streamID {
            currentStreamID = nil
            currentStreamGeneration = nil
        }
    }

    func beginPendingStop(for stream: AnyObject) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingStops.insert(ObjectIdentifier(stream)).inserted
    }

    func finishPendingStop(for stream: AnyObject) {
        lock.lock()
        defer { lock.unlock() }
        pendingStops.remove(ObjectIdentifier(stream))
    }

    func shouldForwardStop(for stream: AnyObject) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let streamID = ObjectIdentifier(stream)
        guard currentStreamID == streamID,
              !intentionalStops.contains(streamID),
              !forwardedStops.contains(streamID) else {
            return false
        }
        forwardedStops.insert(streamID)
        return true
    }
}

@MainActor
final class PendingStreamStopQueue {
    typealias Operation = @MainActor () async throws -> Void

    private var tail: Task<Result<Void, Error>, Never>?
    private var pending: [Task<Result<Void, Error>, Never>] = []

    func schedule(_ operation: @escaping Operation) {
        let previous = tail
        let task = Task<Result<Void, Error>, Never> { @MainActor in
            if let previous {
                _ = await previous.value
            }
            do {
                try await operation()
                return Result<Void, Error>.success(())
            } catch {
                return Result<Void, Error>.failure(error)
            }
        }
        tail = task
        pending.append(task)
    }

    func drain() async throws {
        var firstError: Error?
        while !pending.isEmpty {
            let task = pending.removeFirst()
            if case .failure(let error) = await task.value, firstError == nil {
                firstError = error
            }
        }
        tail = nil
        if let firstError {
            throw firstError
        }
    }
}

@MainActor
protocol ScreenAudioStreaming: AnyObject {
    var microphoneViaStreamEnabled: Bool { get }
    var onUnexpectedStop: (@MainActor (String) -> Void)? { get set }

    func startCapture(
        onSystemSample: @escaping (CMSampleBuffer, UInt64) -> Void,
        onMicrophoneSample: @escaping (CMSampleBuffer, UInt64) -> Void
    ) async throws
    func restartCapture() async throws
    func stopCapture() async throws
    func cancelPendingRestart()
    func isCurrentStreamGeneration(_ generation: UInt64) -> Bool
}

@MainActor
final class ScreenCaptureAudioService: NSObject, SCStreamDelegate, ScreenAudioStreaming {
    private final class OutputRouter: NSObject, SCStreamOutput {
        var generationForStream: ((SCStream) -> UInt64?)?
        var onSystemSample: ((CMSampleBuffer, UInt64) -> Void)?
        var onMicrophoneSample: ((CMSampleBuffer, UInt64) -> Void)?

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
            guard sampleBuffer.isValid,
                  let generation = generationForStream?(stream) else {
                return
            }
            switch outputType {
            case .audio:
                onSystemSample?(sampleBuffer, generation)
            case .microphone:
                onMicrophoneSample?(sampleBuffer, generation)
            case .screen:
                break
            @unknown default:
                break
            }
        }
    }

    private var stream: SCStream?
    private let router = OutputRouter()
    private let lifecycle = ScreenCaptureStreamLifecycle()
    private let sampleQueue = DispatchQueue(label: "Recordly.ScreenCaptureSamples", qos: .userInitiated)
    private let screenDiscardQueue = DispatchQueue(label: "Recordly.ScreenCaptureDiscard", qos: .utility)
    private let pendingStopQueue = PendingStreamStopQueue()
    private(set) var microphoneViaStreamEnabled = false
    private var captureRequested = false
    var onUnexpectedStop: (@MainActor (String) -> Void)?

    override init() {
        super.init()
        router.generationForStream = { [lifecycle] stream in
            lifecycle.generation(for: stream)
        }
    }

    func startCapture(
        onSystemSample: @escaping (CMSampleBuffer, UInt64) -> Void,
        onMicrophoneSample: @escaping (CMSampleBuffer, UInt64) -> Void
    ) async throws {
        try await drainPendingStreamStops()
        try await stopCurrentStreamIfPresent()
        captureRequested = true
        let request = lifecycle.beginCaptureRequest()
        router.onSystemSample = onSystemSample
        router.onMicrophoneSample = onMicrophoneSample
        do {
            try await startNewStream(for: request)
        } catch {
            captureRequested = false
            lifecycle.cancelCaptureRequest()
            throw error
        }
    }

    func restartCapture() async throws {
        try await drainPendingStreamStops()
        guard captureRequested else {
            throw CancellationError()
        }
        let request = lifecycle.beginCaptureRequest()
        try await stopCurrentStreamIfPresent()
        guard captureRequested,
              lifecycle.isCurrentCaptureRequest(request) else {
            throw CancellationError()
        }
        try await startNewStream(for: request)
    }

    func stopCapture() async throws {
        captureRequested = false
        lifecycle.cancelCaptureRequest()
        scheduleCurrentStreamStop()
        try await drainPendingStreamStops()
        try await stopCurrentStreamIfPresent()
        clearCaptureState()
    }

    func cancelPendingRestart() {
        lifecycle.cancelCaptureRequest()
        scheduleCurrentStreamStop()
    }

    func isCurrentStreamGeneration(_ generation: UInt64) -> Bool {
        lifecycle.isCurrentStreamGeneration(generation)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard lifecycle.shouldForwardStop(for: stream) else {
            return
        }
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.onUnexpectedStop?(message)
        }
    }

    private func startNewStream(for request: UInt64) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard captureRequested,
              lifecycle.isCurrentCaptureRequest(request) else {
            throw CancellationError()
        }
        guard let display = content.displays.first else {
            throw AudioCaptureError.noScreenToCapture
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true
        config.excludesCurrentProcessAudio = false
        config.sampleRate = Int(PCMTrackWriter.canonicalSampleRate)
        config.channelCount = Int(PCMTrackWriter.canonicalChannels)
        config.queueDepth = 8
        // Audio-only capture: keep the video leg of the stream as cheap as possible.
        // Without this, SCK captures full-res frames at display refresh rate and
        // drops each one with a "stream output NOT found" error.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)

        try stream.addStreamOutput(router, type: .audio, sampleHandlerQueue: sampleQueue)

        // SCK still produces a video stream for a display filter even when we only
        // want audio. Register a screen output (frames are discarded in the router)
        // so its queue has a consumer — otherwise every frame logs
        // "stream output NOT found. Dropping frame".
        try? stream.addStreamOutput(router, type: .screen, sampleHandlerQueue: screenDiscardQueue)

        do {
            try stream.addStreamOutput(router, type: .microphone, sampleHandlerQueue: sampleQueue)
            microphoneViaStreamEnabled = true
        } catch {
            microphoneViaStreamEnabled = false
        }

        lifecycle.install(stream)
        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            lifecycle.markIntentionalStop(for: stream)
            if self.stream === stream {
                self.stream = nil
            }
            throw error
        }

        guard captureRequested,
              lifecycle.isCurrentCaptureRequest(request) else {
            lifecycle.markIntentionalStop(for: stream)
            try await stream.stopCapture()
            if self.stream === stream {
                self.stream = nil
            }
            throw CancellationError()
        }
    }

    private func clearCaptureState() {
        stream = nil
        router.onSystemSample = nil
        router.onMicrophoneSample = nil
        microphoneViaStreamEnabled = false
    }

    private func stopCurrentStreamIfPresent() async throws {
        guard let stream else {
            return
        }
        lifecycle.markIntentionalStop(for: stream)
        try await stream.stopCapture()
        if self.stream === stream {
            self.stream = nil
        }
    }

    private func scheduleCurrentStreamStop() {
        guard let stream else {
            return
        }
        guard lifecycle.beginPendingStop(for: stream) else {
            return
        }
        lifecycle.markIntentionalStop(for: stream)
        pendingStopQueue.schedule { @MainActor [weak self, lifecycle] in
            defer {
                lifecycle.finishPendingStop(for: stream)
            }
            try await stream.stopCapture()
            guard let self else {
                return
            }
            if self.stream === stream {
                self.stream = nil
            }
        }
    }

    private func drainPendingStreamStops() async throws {
        try await pendingStopQueue.drain()
    }
}

@MainActor
final class AudioCaptureService: AudioCaptureEngine {
    private struct GenerationTaggedSample: @unchecked Sendable {
        var buffer: CMSampleBuffer
        var generation: UInt64
    }

    private let metadataStore = SessionMetadataStore()
    private lazy var mergeService = SessionMergeService(metadataStore: metadataStore)
    private let screenCaptureService: any ScreenAudioStreaming
    private let recoveryPolicy: CaptureRecoveryPolicy
    private let screenCapturePermissionCoordinator = ScreenCapturePermissionCoordinator()
    private let fallbackMicrophoneRecorder = FallbackMicrophoneRecorder()
    private let clock = ContinuousClock()

    private var isRunning = false
    private var microphoneFileName: String?
    private var systemAudioFileName: String?
    private var activeSessionDirectory: URL?
    private var activeSessionID: UUID?

    private var microphoneWriter: MirroredTrackWriter?
    private var systemWriter: MirroredTrackWriter?

    private var microphoneLevelValue: Double = 0
    private var systemLevelValue: Double = 0
    private var systemStatusLabelValue = "Idle"
    private var systemSamplePipeline: CaptureSamplePipeline<GenerationTaggedSample>?
    private var microphoneSamplePipeline: CaptureSamplePipeline<GenerationTaggedSample>?
    private var healthRuntime: CaptureHealthRuntime?
    private var healthWatchdogTask: Task<Void, Never>?
    private var healthUnexpectedStopTask: Task<Void, Never>?
    private var diagnosticPersistenceTask: Task<Void, Never>?
    private let screenCaptureStartupTimeoutNanos: UInt64 = 2_000_000_000

    init(
        screenCaptureService: (any ScreenAudioStreaming)? = nil,
        recoveryPolicy: CaptureRecoveryPolicy = .production
    ) {
        self.screenCaptureService = screenCaptureService ?? ScreenCaptureAudioService()
        self.recoveryPolicy = recoveryPolicy
    }

    private func recordSampleArrival(for channel: CaptureChannel, generation: UInt64) {
        guard screenCaptureService.isCurrentStreamGeneration(generation) else {
            return
        }
        healthRuntime?.receiveHeartbeat(
            for: channel,
            level: 0,
            at: clock.now
        )
    }

    func startCapture(in sessionDirectory: URL) async throws -> CaptureArtifacts {
        guard !isRunning else {
            throw AudioCaptureError.captureAlreadyRunning
        }

        let hasMicrophoneAccess = await AVCaptureDevice.requestAccess(for: .audio)
        guard hasMicrophoneAccess else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        // Ensure system capture permission is requested before trying to start ScreenCaptureKit.

        let sessionID = UUID(uuidString: sessionDirectory.lastPathComponent) ?? UUID()

        let microphoneTemporaryURL = sessionDirectory.appendingPathComponent(LiveCaptureArtifactNames.microphoneTemporary)
        let systemTemporaryURL = sessionDirectory.appendingPathComponent(LiveCaptureArtifactNames.systemTemporary)
        let microphoneDurableURL = sessionDirectory.appendingPathComponent(LiveCaptureArtifactNames.microphoneDurable)
        let systemDurableURL = sessionDirectory.appendingPathComponent(LiveCaptureArtifactNames.systemDurable)

        do {
            try await metadataStore.createSession(id: sessionID, in: sessionDirectory)
            var streamStartError: Error?
            var systemCaptureAttempted = false
            var didStartStreamCapture = false
            var micWriter: MirroredTrackWriter?
            var sysWriter: MirroredTrackWriter?

            // Avoid CGRequestScreenCaptureAccess() here. When multiple dev copies share one
            // bundle identifier, the system-managed "quit and reopen" flow can relaunch a
            // different registered copy instead of the one the user started.
            let hasSystemCapturePermission = screenCapturePermissionCoordinator.hasSystemRecordingPermission()

            if hasSystemCapturePermission {
                let streamMicWriter = try MirroredTrackWriter(
                    temporary: PCMTrackWriter(
                        kind: .microphone,
                        fileName: LiveCaptureArtifactNames.microphoneTemporary,
                        fileURL: microphoneTemporaryURL
                    ),
                    durable: PCMTrackWriter(
                        kind: .microphone,
                        fileName: LiveCaptureArtifactNames.microphoneDurable,
                        fileURL: microphoneDurableURL
                    )
                )
                let streamSysWriter = try MirroredTrackWriter(
                    temporary: PCMTrackWriter(
                        kind: .system,
                        fileName: LiveCaptureArtifactNames.systemTemporary,
                        fileURL: systemTemporaryURL
                    ),
                    durable: PCMTrackWriter(
                        kind: .system,
                        fileName: LiveCaptureArtifactNames.systemDurable,
                        fileURL: systemDurableURL
                    )
                )
                micWriter = streamMicWriter
                sysWriter = streamSysWriter
                systemCaptureAttempted = true
                // Buffers flow through single-consumer pipelines off the main actor;
                // UI/metering state hops back to MainActor at most every 100 ms.
                let systemMeter = MeteringThrottle()
                let systemPipeline = CaptureSamplePipeline<GenerationTaggedSample>(
                    bufferLimit: 64,
                    onSubmit: { [weak self] sample in
                        Task { @MainActor [weak self] in
                            self?.recordSampleArrival(for: .system, generation: sample.generation)
                        }
                    },
                    handler: { [weak self] sample in
                        do {
                            _ = try await streamSysWriter.appendPreservingCanonical(sampleBuffer: sample.buffer)
                            let level = sample.buffer.normalizedLevel
                            guard let self else { return }
                            await MainActor.run {
                                guard self.screenCaptureService.isCurrentStreamGeneration(sample.generation) else {
                                    return
                                }
                                if systemMeter.due() {
                                    self.systemLevelValue = level
                                }
                            }
                        } catch {
                            await streamSysWriter.recordDiagnostic("system append failed: \(error.localizedDescription)")
                            guard let self else { return }
                            await MainActor.run {
                                self.systemLevelValue = 0
                            }
                        }
                    }
                )
                let microphoneMeter = MeteringThrottle()
                let microphonePipeline = CaptureSamplePipeline<GenerationTaggedSample>(
                    bufferLimit: 64,
                    onSubmit: { [weak self] sample in
                        Task { @MainActor [weak self] in
                            self?.recordSampleArrival(for: .microphone, generation: sample.generation)
                        }
                    },
                    handler: { [weak self] sample in
                        do {
                            _ = try await streamMicWriter.appendPreservingCanonical(sampleBuffer: sample.buffer)
                            let level = sample.buffer.normalizedLevel
                            guard let self else { return }
                            await MainActor.run {
                                guard self.screenCaptureService.isCurrentStreamGeneration(sample.generation) else {
                                    return
                                }
                                if microphoneMeter.due() {
                                    self.microphoneLevelValue = level
                                }
                            }
                        } catch {
                            // Keep recording alive if one buffer fails to convert.
                        }
                    }
                )
                self.systemSamplePipeline = systemPipeline
                self.microphoneSamplePipeline = microphonePipeline

                do {
                    try await withStartupTimeout { [self] in
                        try await self.screenCaptureService.startCapture(
                            onSystemSample: { sampleBuffer, generation in
                                systemPipeline.submit(
                                    GenerationTaggedSample(buffer: sampleBuffer, generation: generation)
                                )
                            },
                            onMicrophoneSample: { sampleBuffer, generation in
                                microphonePipeline.submit(
                                    GenerationTaggedSample(buffer: sampleBuffer, generation: generation)
                                )
                            }
                        )
                    }
                    didStartStreamCapture = true
                    systemStatusLabelValue = "Waiting for audio"
                } catch {
                    streamStartError = error
                    systemStatusLabelValue = label(for: error)
                }
            } else {
                streamStartError = AudioCaptureError.systemAudioPermissionDenied
                systemStatusLabelValue = "Permission denied"
            }

            if streamStartError != nil || !systemCaptureAttempted || !screenCaptureService.microphoneViaStreamEnabled {
                didStartStreamCapture = false
                try? await screenCaptureService.stopCapture()
                micWriter = nil
                sysWriter = nil
                removeInvalidFileIfPresent(microphoneDurableURL)
                removeInvalidFileIfPresent(systemDurableURL)
                try fallbackMicrophoneRecorder.startRecording(to: microphoneTemporaryURL)
                if let streamStartError {
                    try await metadataStore.appendNote(
                        "ScreenCaptureKit start failed (\(streamStartError.localizedDescription)). Falling back to mic-only capture.",
                        in: sessionDirectory
                    )
                } else {
                    try await metadataStore.appendNote(
                        "SCStream microphone output unavailable. Fallback mic recorder is active.",
                        in: sessionDirectory
                    )
                }
            }

            self.microphoneWriter = didStartStreamCapture ? micWriter : nil
            self.systemWriter = didStartStreamCapture ? sysWriter : nil
            self.activeSessionDirectory = sessionDirectory
            self.activeSessionID = sessionID
            self.microphoneFileName = LiveCaptureArtifactNames.microphoneDurable
            self.systemAudioFileName = didStartStreamCapture ? LiveCaptureArtifactNames.systemDurable : nil
            self.isRunning = true

            if didStartStreamCapture {
                let runtime = makeCaptureHealthRuntime(sessionDirectory: sessionDirectory)
                self.healthRuntime = runtime
                runtime.start(
                    requiredChannels: screenCaptureService.microphoneViaStreamEnabled
                        ? [.microphone, .system]
                        : [.system],
                    at: clock.now
                )
                screenCaptureService.onUnexpectedStop = { [weak self] reason in
                    guard let self else {
                        return
                    }
                    self.healthUnexpectedStopTask?.cancel()
                    self.healthUnexpectedStopTask = Task { @MainActor [weak self] in
                        guard let self, let runtime = self.healthRuntime else {
                            return
                        }
                        await runtime.receiveUnexpectedStop(reason: reason, at: self.clock.now)
                    }
                }
                startHealthWatchdog()
            }

            return CaptureArtifacts(
                microphoneFile: LiveCaptureArtifactNames.microphoneDurable,
                systemAudioFile: didStartStreamCapture ? LiveCaptureArtifactNames.systemDurable : nil,
                mergedCallFile: nil,
                connectorNotesFile: "capture-session.json",
                note: streamStartError == nil
                    ? "Recording microphone and system audio to temporary CAF and durable M4A tracks."
                    : "Recording microphone only. System capture permissions are unavailable."
            )
        } catch {
            await self.systemSamplePipeline?.finish()
            await self.microphoneSamplePipeline?.finish()
            self.systemSamplePipeline = nil
            self.microphoneSamplePipeline = nil
            self.microphoneWriter = nil
            self.systemWriter = nil
            self.activeSessionDirectory = nil
            self.activeSessionID = nil
            self.microphoneFileName = nil
            self.systemAudioFileName = nil
            self.healthWatchdogTask?.cancel()
            self.healthWatchdogTask = nil
            self.healthUnexpectedStopTask?.cancel()
            self.healthUnexpectedStopTask = nil
            self.healthRuntime?.stop()
            self.healthRuntime = nil
            self.screenCaptureService.onUnexpectedStop = nil
            throw error
        }
    }

    private func makeCaptureHealthRuntime(
        sessionDirectory: URL
    ) -> CaptureHealthRuntime {
        CaptureHealthRuntime(
            policy: recoveryPolicy,
            restart: { [weak self] in
                guard let self else {
                    throw CancellationError()
                }
                try await self.withStartupTimeout {
                    try await self.screenCaptureService.restartCapture()
                }
            },
            cancelRestart: { [weak self] in
                self?.screenCaptureService.cancelPendingRestart()
            },
            onDiagnostic: { [weak self] diagnostic in
                self?.persistCaptureDiagnostic(diagnostic, in: sessionDirectory)
            }
        )
    }

    private func startHealthWatchdog() {
        healthWatchdogTask?.cancel()
        healthWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                guard let self,
                      self.isRunning,
                      let runtime = self.healthRuntime else {
                    return
                }
                await runtime.process(at: self.clock.now)
            }
        }
    }

    private func persistCaptureDiagnostic(
        _ diagnostic: String,
        in sessionDirectory: URL
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let note = "[capture-health \(timestamp)] \(diagnostic)"
        let previousTask = diagnosticPersistenceTask
        diagnosticPersistenceTask = Task { [metadataStore] in
            await previousTask?.value
            try? await metadataStore.appendNote(note, in: sessionDirectory)
        }
    }

    private func withStartupTimeout<T: Sendable>(_ operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            let timeoutNanos = screenCaptureStartupTimeoutNanos
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanos)
                throw AudioCaptureError.systemAudioStartupTimeout
            }

            guard let result = try await group.next() else {
                throw CancellationError()
            }

            group.cancelAll()
            return result
        }
    }

    private func label(for error: Error) -> String {
        if let captureError = error as? AudioCaptureError,
           captureError == .systemAudioPermissionDenied {
            return "Permission denied"
        }

        return "Unavailable"
    }

    func stopCapture() async throws -> CaptureArtifacts {
        guard isRunning, let sessionDirectory = activeSessionDirectory else {
            throw AudioCaptureError.noActiveCapture
        }

        let watchdogTask = healthWatchdogTask
        let unexpectedStopTask = healthUnexpectedStopTask
        healthWatchdogTask?.cancel()
        healthWatchdogTask = nil
        healthUnexpectedStopTask?.cancel()
        healthUnexpectedStopTask = nil
        healthRuntime?.stop()
        screenCaptureService.onUnexpectedStop = nil

        do {
            try await screenCaptureService.stopCapture()
        } catch {
            try? await metadataStore.appendNote(
                "ScreenCaptureKit stop failed: \(error.localizedDescription). Continuing finalization.",
                in: sessionDirectory
            )
        }
        await watchdogTask?.value
        await unexpectedStopTask?.value
        await diagnosticPersistenceTask?.value

        defer {
            isRunning = false
            microphoneWriter = nil
            systemWriter = nil
            systemSamplePipeline = nil
            microphoneSamplePipeline = nil
            activeSessionDirectory = nil
            activeSessionID = nil
            microphoneLevelValue = 0
            systemLevelValue = 0
            systemStatusLabelValue = "Idle"
            healthRuntime = nil
            diagnosticPersistenceTask = nil
        }

        try await metadataStore.updateStatus(.finalizingTracks, in: sessionDirectory)
        try? await fallbackMicrophoneRecorder.stopRecording()

        // Drain buffered samples before finalizing so tail audio isn't lost.
        await systemSamplePipeline?.finish()
        await microphoneSamplePipeline?.finish()
        if let systemSamplePipeline, systemSamplePipeline.droppedCount > 0 {
            try? await metadataStore.appendNote(
                "system pipeline dropped \(systemSamplePipeline.droppedCount) buffers",
                in: sessionDirectory
            )
        }
        if let microphoneSamplePipeline, microphoneSamplePipeline.droppedCount > 0 {
            try? await metadataStore.appendNote(
                "microphone pipeline dropped \(microphoneSamplePipeline.droppedCount) buffers",
                in: sessionDirectory
            )
        }

        var microphoneRequiresDurableExport = false
        if let microphoneWriter {
            microphoneRequiresDurableExport = await microphoneWriter.requiresDurableExport()
            if let micStats = await microphoneWriter.finalize().first {
                try await metadataStore.updateTrack(micStats, in: sessionDirectory)
            }
        }

        var systemRequiresDurableExport = false
        if let systemWriter {
            systemRequiresDurableExport = await systemWriter.requiresDurableExport()
            if let systemStats = await systemWriter.finalize().first {
                try await metadataStore.updateTrack(systemStats, in: sessionDirectory)
            }
        }

        var preferCanonicalMicrophone = false
        do {
            try await exportDurableTrackIfNeeded(
                from: sessionDirectory.appendingPathComponent(LiveCaptureArtifactNames.microphoneTemporary),
                to: sessionDirectory.appendingPathComponent(LiveCaptureArtifactNames.microphoneDurable),
                forceReplace: microphoneRequiresDurableExport
            )
        } catch {
            preferCanonicalMicrophone = true
            try? await metadataStore.appendNote(
                "Microphone durable export failed: \(error.localizedDescription)",
                in: sessionDirectory
            )
        }
        var preferCanonicalSystem = false
        if systemAudioFileName != nil {
            do {
                try await exportDurableTrackIfNeeded(
                    from: sessionDirectory.appendingPathComponent(LiveCaptureArtifactNames.systemTemporary),
                    to: sessionDirectory.appendingPathComponent(LiveCaptureArtifactNames.systemDurable),
                    forceReplace: systemRequiresDurableExport
                )
            } catch {
                preferCanonicalSystem = true
                try? await metadataStore.appendNote(
                    "System durable export failed: \(error.localizedDescription)",
                    in: sessionDirectory
                )
            }
        }

        try await metadataStore.updateStatus(.readyForMix, in: sessionDirectory)

        return CaptureArtifacts(
            microphoneFile: preferredUsableTrackFileName(
                durable: microphoneFileName,
                canonical: LiveCaptureArtifactNames.microphoneTemporary,
                preferCanonical: preferCanonicalMicrophone,
                in: sessionDirectory
            ),
            systemAudioFile: preferredUsableTrackFileName(
                durable: systemAudioFileName,
                canonical: LiveCaptureArtifactNames.systemTemporary,
                preferCanonical: preferCanonicalSystem,
                in: sessionDirectory
            ),
            mergedCallFile: nil,
            connectorNotesFile: "capture-session.json",
            note: "Audio saved. Mixed playback is being prepared."
        )
    }

    func mergeCompletedSession(in sessionDirectory: URL) async throws -> CaptureArtifacts {
        let mergeResult = try await mergeService.mergeSession(in: sessionDirectory)
        return CaptureArtifacts(
            microphoneFile: preferredUsableTrackFileName(
                durable: LiveCaptureArtifactNames.microphoneDurable,
                canonical: LiveCaptureArtifactNames.microphoneTemporary,
                in: sessionDirectory
            ),
            systemAudioFile: preferredUsableTrackFileName(
                durable: LiveCaptureArtifactNames.systemDurable,
                canonical: LiveCaptureArtifactNames.systemTemporary,
                in: sessionDirectory
            ),
            mergedCallFile: mergeResult.mergedM4AFileName,
            connectorNotesFile: "capture-session.json",
            note: mergeResult.note
        )
    }

    func exportDurableTrackIfNeeded(
        from sourceURL: URL,
        to destinationURL: URL,
        forceReplace: Bool = false
    ) async throws {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return
        }
        let signposter = OSSignposter(subsystem: "com.recordly.capture", category: "export")
        let signpostState = signposter.beginInterval("capture.durableExport")
        defer { signposter.endInterval("capture.durableExport", signpostState) }
        guard forceReplace || CaptureArtifactValidator.shouldReplaceDestination(at: destinationURL) else {
            return
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        let asset = AVURLAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioCaptureError.mixdownFailed
        }

        do {
            try await exportSession.export(to: destinationURL, as: .m4a)
            guard CaptureArtifactValidator.isUsableAudioFile(destinationURL) else {
                throw AudioCaptureError.invalidRecordedFile
            }
        } catch {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            throw error
        }
    }

    func preferredUsableTrackFileName(
        durable: String?,
        canonical: String,
        preferCanonical: Bool = false,
        in sessionDirectory: URL
    ) -> String? {
        if preferCanonical,
           let canonical = CaptureArtifactValidator.usableAudioFileName(canonical, in: sessionDirectory) {
            return canonical
        }
        return CaptureArtifactValidator.usableAudioFileName(durable, in: sessionDirectory)
            ?? CaptureArtifactValidator.usableAudioFileName(canonical, in: sessionDirectory)
    }

    private func removeInvalidFileIfPresent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path),
              !CaptureArtifactValidator.isUsableAudioFile(url) else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    func currentMicrophoneLevel() -> Double {
        fallbackMicrophoneRecorder.currentLevel().isZero ? microphoneLevelValue : fallbackMicrophoneRecorder.currentLevel()
    }

    func currentSystemAudioLevel() -> Double {
        switch captureHealth.phase {
        case .recovering, .failed:
            return 0
        case .idle, .starting, .healthy:
            break
        }
        return systemLevelValue
    }

    var systemAudioStatusLabel: String {
        healthRuntime?.snapshot.statusLabel ?? systemStatusLabelValue
    }

    var captureHealth: CaptureHealthSnapshot {
        healthRuntime?.snapshot ?? CaptureHealthSnapshot(
            phase: .idle,
            affectedChannels: [],
            statusLabel: systemStatusLabelValue
        )
    }

    func retryCaptureNow() async {
        guard let healthRuntime else {
            return
        }
        await healthRuntime.retryNow(at: clock.now)
    }

    func recoverPendingSessions(in recordingsDirectory: URL) async {
        let fileManager = FileManager.default
        guard let sessionDirectories = try? fileManager.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for sessionDirectory in sessionDirectories {
            let metadataURL = sessionDirectory.appendingPathComponent("capture-session.json")
            guard fileManager.fileExists(atPath: metadataURL.path) else {
                continue
            }

            guard let metadata = try? await metadataStore.load(in: sessionDirectory) else {
                continue
            }

            let mergedM4A = sessionDirectory.appendingPathComponent("merged-call.m4a")
            if fileManager.fileExists(atPath: mergedM4A.path),
               !Self.isUsableAudioFile(mergedM4A) {
                try? fileManager.removeItem(at: mergedM4A)
            }

            switch metadata.status {
            case .finalizingTracks:
                if Self.hasUsableDurableTrack(in: sessionDirectory) {
                    try? await metadataStore.updateStatus(.readyForMix, in: sessionDirectory)
                    try? await metadataStore.appendNote("Recovered finalized channel audio. Mixed playback is pending.", in: sessionDirectory)
                } else {
                    try? await metadataStore.updateStatus(.mixError, in: sessionDirectory)
                    try? await metadataStore.appendNote("Recovered interrupted finalization without durable channel audio.", in: sessionDirectory)
                }
            case .readyForMix, .mixing:
                try? await metadataStore.updateStatus(.readyForMix, in: sessionDirectory)
            case .recording:
                try? await metadataStore.updateStatus(.mixError, in: sessionDirectory)
                try? await metadataStore.appendNote("Recovered interrupted recording session.", in: sessionDirectory)
            case .ready, .mixError:
                continue
            }
        }
    }

    private static func hasUsableDurableTrack(in sessionDirectory: URL) -> Bool {
        CaptureArtifactValidator.isUsableAudioFile(sessionDirectory.appendingPathComponent(LiveCaptureArtifactNames.microphoneDurable))
            || CaptureArtifactValidator.isUsableAudioFile(sessionDirectory.appendingPathComponent(LiveCaptureArtifactNames.systemDurable))
    }

    private static func isUsableAudioFile(_ url: URL) -> Bool {
        CaptureArtifactValidator.isUsableAudioFile(url)
    }

}

private extension CMSampleBuffer {
    var normalizedLevel: Double {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return 0
        }

        let channels = Int(max(asbdPointer.pointee.mChannelsPerFrame, 1))
        let sampleCount = CMSampleBufferGetNumSamples(self)
        guard sampleCount > 0 else { return 0 }

        var bufferListSize = 0
        let statusSize = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard statusSize == noErr else { return 0 }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }
        let audioBufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return 0 }

        let audioBuffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        var peak: Float = 0

        for buffer in audioBuffers {
            let sampleCountInBuffer = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), sampleCountInBuffer > 0 else { continue }
            var bufferPeak: Float = 0
            vDSP_maxmgv(data, 1, &bufferPeak, vDSP_Length(sampleCountInBuffer))
            peak = max(peak, bufferPeak)
        }

        return min(Double(peak), 1)
    }
}

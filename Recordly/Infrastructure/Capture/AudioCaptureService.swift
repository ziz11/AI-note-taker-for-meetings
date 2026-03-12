import AVFoundation
import Foundation
import ApplicationServices
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

actor PCMTrackWriter {
    static let canonicalSampleRate: Double = 48_000
    static let canonicalChannels: AVAudioChannelCount = 1

    let kind: TrackKind
    let fileName: String
    let fileURL: URL

    private let outputFormat: AVAudioFormat
    private var audioFile: AVAudioFile
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    private var firstPTS: Double?
    private var lastPTS: Double?
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

        let fileSettings: [String: Any]
        if fileURL.pathExtension.lowercased() == "flac" {
            fileSettings = [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: Self.canonicalSampleRate,
                AVNumberOfChannelsKey: Int(Self.canonicalChannels),
                AVLinearPCMBitDepthKey: 24
            ]
        } else {
            fileSettings = canonical.settings
        }

        self.audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        self.fallback = fallback
        self.diagnostics = diagnostics
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
        if let presentationTime, presentationTime.isValid {
            let seconds = presentationTime.seconds
            if firstPTS == nil {
                firstPTS = seconds
            }
            lastPTS = seconds
        }

        let renderedBuffer = try convertIfNeeded(pcmBuffer)
        guard renderedBuffer.frameLength > 0 else { return }

        try stage(renderedBuffer)
        bufferCount += 1
    }

    func finalize() -> TrackRuntimeStats {
        flushStagingBuffer()
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

    private func flushStagingBufferThrowing() throws {
        guard let staging = stagingBuffer, stagedFrames > 0 else { return }
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
    private let temporary: PCMTrackWriter
    private let durable: PCMTrackWriter?

    init(temporary: PCMTrackWriter, durable: PCMTrackWriter?) {
        self.temporary = temporary
        self.durable = durable
    }

    func append(sampleBuffer: CMSampleBuffer) async throws {
        try await temporary.append(sampleBuffer: sampleBuffer)
        try await durable?.append(sampleBuffer: sampleBuffer)
    }

    func append(pcmBuffer: AVAudioPCMBuffer, presentationTime: CMTime? = nil) async throws {
        try await temporary.append(pcmBuffer: pcmBuffer, presentationTime: presentationTime)
        try await durable?.append(pcmBuffer: pcmBuffer, presentationTime: presentationTime)
    }

    func finalize() async -> [TrackRuntimeStats] {
        var stats: [TrackRuntimeStats] = []
        stats.append(await temporary.finalize())
        if let durable {
            stats.append(await durable.finalize())
        }
        return stats
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
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: true
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

final class ScreenCaptureAudioService: NSObject {
    private final class OutputRouter: NSObject, SCStreamOutput {
        var onSystemSample: ((CMSampleBuffer) -> Void)?
        var onMicrophoneSample: ((CMSampleBuffer) -> Void)?

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
            guard sampleBuffer.isValid else { return }
            switch outputType {
            case .audio:
                onSystemSample?(sampleBuffer)
            case .microphone:
                onMicrophoneSample?(sampleBuffer)
            case .screen:
                break
            @unknown default:
                break
            }
        }
    }

    private var stream: SCStream?
    private let router = OutputRouter()
    private let sampleQueue = DispatchQueue(label: "Recordly.ScreenCaptureSamples", qos: .userInitiated)
    private(set) var microphoneViaStreamEnabled = false

    func hasSystemRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestSystemRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func startCapture(
        onSystemSample: @escaping (CMSampleBuffer) -> Void,
        onMicrophoneSample: @escaping (CMSampleBuffer) -> Void
    ) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
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

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        router.onSystemSample = onSystemSample
        router.onMicrophoneSample = onMicrophoneSample

        try stream.addStreamOutput(router, type: .audio, sampleHandlerQueue: sampleQueue)

        do {
            try stream.addStreamOutput(router, type: .microphone, sampleHandlerQueue: sampleQueue)
            microphoneViaStreamEnabled = true
        } catch {
            microphoneViaStreamEnabled = false
        }

        self.stream = stream
        try await stream.startCapture()
    }

    func stopCapture() async throws {
        guard let stream else { return }
        defer {
            self.stream = nil
            self.router.onSystemSample = nil
            self.router.onMicrophoneSample = nil
            self.microphoneViaStreamEnabled = false
        }
        try await stream.stopCapture()
    }
}

@MainActor
final class AudioCaptureService: AudioCaptureEngine {
    private let metadataStore = SessionMetadataStore()
    private lazy var mergeService = SessionMergeService(metadataStore: metadataStore)
    private let screenCaptureService = ScreenCaptureAudioService()
    private let fallbackMicrophoneRecorder = FallbackMicrophoneRecorder()

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
    private let screenCaptureStartupTimeoutNanos: UInt64 = 2_000_000_000

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

            var hasSystemCapturePermission = screenCaptureService.hasSystemRecordingPermission()
            if !hasSystemCapturePermission {
                hasSystemCapturePermission = screenCaptureService.requestSystemRecordingPermission()
            }

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
                do {
                    try await withStartupTimeout { [self] in
                        try await self.screenCaptureService.startCapture(
                            onSystemSample: { [weak self] sampleBuffer in
                                guard let self else { return }
                                Task {
                                    do {
                                        try await streamSysWriter.append(sampleBuffer: sampleBuffer)
                                        self.systemLevelValue = sampleBuffer.normalizedLevel
                                    } catch {
                                        // Keep recording alive if one buffer fails to convert.
                                    }
                                }
                            },
                            onMicrophoneSample: { [weak self] sampleBuffer in
                                guard let self else { return }
                                Task {
                                    do {
                                        try await streamMicWriter.append(sampleBuffer: sampleBuffer)
                                        self.microphoneLevelValue = sampleBuffer.normalizedLevel
                                    } catch {
                                        // Keep recording alive if one buffer fails to convert.
                                    }
                                }
                            }
                        )
                    }
                    didStartStreamCapture = true
                    systemStatusLabelValue = "Captured"
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
            self.microphoneWriter = nil
            self.systemWriter = nil
            self.activeSessionDirectory = nil
            self.activeSessionID = nil
            self.microphoneFileName = nil
            self.systemAudioFileName = nil
            throw error
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

        defer {
            isRunning = false
            microphoneWriter = nil
            systemWriter = nil
            activeSessionDirectory = nil
            activeSessionID = nil
            microphoneLevelValue = 0
            systemLevelValue = 0
            systemStatusLabelValue = "Idle"
        }

        try await metadataStore.updateStatus(.finalizingTracks, in: sessionDirectory)

        do {
            try await screenCaptureService.stopCapture()
        } catch {
            try? await metadataStore.appendNote(
                "ScreenCaptureKit stop failed: \(error.localizedDescription). Continuing finalization.",
                in: sessionDirectory
            )
        }
        try? await fallbackMicrophoneRecorder.stopRecording()

        if let microphoneWriter,
           let micStats = await microphoneWriter.finalize().first {
            try await metadataStore.updateTrack(micStats, in: sessionDirectory)
        }

        if let systemWriter,
           let systemStats = await systemWriter.finalize().first {
            try await metadataStore.updateTrack(systemStats, in: sessionDirectory)
        }

        try? await exportDurableTrackIfNeeded(
            from: sessionDirectory.appendingPathComponent(LiveCaptureArtifactNames.microphoneTemporary),
            to: sessionDirectory.appendingPathComponent(LiveCaptureArtifactNames.microphoneDurable)
        )
        if systemAudioFileName != nil {
            try? await exportDurableTrackIfNeeded(
                from: sessionDirectory.appendingPathComponent(LiveCaptureArtifactNames.systemTemporary),
                to: sessionDirectory.appendingPathComponent(LiveCaptureArtifactNames.systemDurable)
            )
        }

        try await metadataStore.updateStatus(.readyForMix, in: sessionDirectory)

        let mergeService = self.mergeService
        let metadataStore = self.metadataStore
        Task.detached(priority: .utility) {
            do {
                _ = try await mergeService.mergeSession(in: sessionDirectory, exportM4A: true)
            } catch {
                try? await metadataStore.updateStatus(.mixError, in: sessionDirectory)
                try? await metadataStore.appendNote("Background merge failed: \(error.localizedDescription)", in: sessionDirectory)
            }
        }

        return CaptureArtifacts(
            microphoneFile: microphoneFileName,
            systemAudioFile: systemAudioFileName,
            mergedCallFile: nil,
            connectorNotesFile: "capture-session.json",
            note: "Raw tracks finalized. Offline merge is running in background."
        )
    }

    private func exportDurableTrackIfNeeded(from sourceURL: URL, to destinationURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            return
        }

        let asset = AVURLAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioCaptureError.mixdownFailed
        }

        try await exportSession.export(to: destinationURL, as: .m4a)
    }

    func currentMicrophoneLevel() -> Double {
        fallbackMicrophoneRecorder.currentLevel().isZero ? microphoneLevelValue : fallbackMicrophoneRecorder.currentLevel()
    }

    func currentSystemAudioLevel() -> Double {
        systemLevelValue
    }

    var systemAudioStatusLabel: String {
        systemStatusLabelValue
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

            switch metadata.status {
            case .finalizingTracks, .readyForMix, .mixing:
                do {
                    _ = try await mergeService.mergeSession(in: sessionDirectory, exportM4A: true)
                } catch {
                    try? await metadataStore.updateStatus(.mixError, in: sessionDirectory)
                    try? await metadataStore.appendNote("Recovery merge failed: \(error.localizedDescription)", in: sessionDirectory)
                }
            case .recording:
                try? await metadataStore.updateStatus(.mixError, in: sessionDirectory)
                try? await metadataStore.appendNote("Recovered interrupted recording session.", in: sessionDirectory)
            case .ready, .mixError:
                continue
            }
        }
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
            let frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), frameCount > 0 else { continue }
            for index in 0..<(frameCount * channels) {
                peak = max(peak, abs(data[index]))
            }
        }

        return min(Double(peak), 1)
    }
}

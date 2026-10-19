import AVFoundation
import Foundation

#if arch(arm64) && canImport(FluidAudio)
import FluidAudio
#endif
struct FluidAudioDiarizationEngine: DiarizationEngine {
    private let manager: any OfflineDiarizationManaging
    private let fileManager: FileManager
    private let sessionAudioLoader: FluidAudioSessionAudioLoading
    private let timeoutSeconds: UInt64

    init(
        manager: any OfflineDiarizationManaging,
        fileManager: FileManager = .default,
        sessionAudioLoader: FluidAudioSessionAudioLoading = FluidAudioSessionAudioLoader(),
        timeoutSeconds: UInt64 = 120
    ) {
        self.manager = manager
        self.fileManager = fileManager
        self.sessionAudioLoader = sessionAudioLoader
        self.timeoutSeconds = timeoutSeconds
    }

    func diarize(
        systemAudioURL: URL,
        sessionID: UUID,
        configuration: DiarizationEngineConfiguration
    ) async throws -> DiarizationDocument {
        guard fileManager.fileExists(atPath: systemAudioURL.path) else {
            throw DiarizationRuntimeError.invalidInput
        }

        guard systemAudioURL.lastPathComponent == "system.m4a" else { throw DiarizationRuntimeError.invalidInput }
        return try await diarizeAudio(at: systemAudioURL, sessionID: sessionID, configuration: configuration)
    }

    func diarize(window: PreparedDiarizationWindow, sessionID: UUID,
                 configuration: DiarizationEngineConfiguration) async throws -> DiarizationDocument {
        guard window.track == .system, window.startFrame >= 0, window.frameCount > 0,
              window.frameCount <= SessionAudioRangeReader.maximumFrames,
              window.audioURL.pathExtension.lowercased() == "caf",
              fileManager.fileExists(atPath: window.audioURL.path) else { throw DiarizationRuntimeError.invalidInput }
        let file = try AVAudioFile(forReading: window.audioURL)
        guard file.processingFormat.sampleRate == 48_000, file.processingFormat.channelCount == 1,
              file.length == window.frameCount else { throw DiarizationRuntimeError.invalidInput }
        return try await diarizeAudio(at: window.audioURL, sessionID: sessionID, configuration: configuration)
    }

    private func diarizeAudio(at systemAudioURL: URL, sessionID: UUID, configuration: DiarizationEngineConfiguration) async throws -> DiarizationDocument {
        if let expected = configuration.modelURL, let actual = manager.modelDirectoryURL,
           expected.standardizedFileURL != actual.standardizedFileURL {
            throw FluidAudioModelProvisioningError.downloadFailed(message: "Diarization runtime and model artifact do not match.")
        }
        try Task.checkCancellation()
        try DiarizationManagerLease.shared.checkAvailable(manager)

        let preparedAudio = try sessionAudioLoader.loadAudio(from: systemAudioURL)
        let normalizedAudio = try preparedAudio.resampled(to: 16_000)
#if arch(arm64) && canImport(FluidAudio)
        let result = try await processWithTimeout(audio: normalizedAudio.samples)
        guard !result.segments.isEmpty else {
            throw DiarizationRuntimeError.emptySegments
        }

        return DiarizationDocument(
            version: 1,
            sessionID: sessionID,
            createdAt: Date(),
            segments: result.segments.enumerated().map { index, segment in
                let startMs = max(0, Int((Double(segment.startTimeSeconds) * 1_000.0).rounded(.down)))
                return DiarizationSegment(
                    id: "dseg-\(index + 1)",
                    speaker: segment.speakerId,
                    startMs: startMs,
                    endMs: max(Int((Double(segment.endTimeSeconds) * 1_000.0).rounded(.up)), startMs + 1),
                    confidence: Double(segment.qualityScore)
                )
            },
            voiceObservations: result.voiceObservations,
            embeddingSpace: result.embeddingSpace,
            embeddingArtifactFingerprint: result.embeddingArtifactFingerprint
        )
#else
        throw DiarizationRuntimeError.binaryMissing
#endif
    }

    private func processWithTimeout(audio: [Float]) async throws -> OfflineDiarizationResult {
        try Task.checkCancellation()

        try DiarizationManagerLease.shared.begin(manager)
        let attempt = TimedDiarizationAttempt(manager: manager)
        let timeoutNanoseconds = timeoutSeconds * 1_000_000_000

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard attempt.install(continuation: continuation) else {
                    DiarizationManagerLease.shared.finish(manager)
                    return
                }

                let processTask = Task.detached(priority: .userInitiated) { [manager] in
                    do {
                        try Task.checkCancellation()
                        let result = try await manager.process(audio: audio)
                        attempt.resume(with: .success(result), processCompleted: true)
                    } catch is CancellationError {
                        attempt.resume(with: .failure(DiarizationRuntimeError.cancelled), processCompleted: true)
                    } catch {
                        attempt.resume(with: .failure(error), processCompleted: true)
                    }
                }

                let timeoutTask = Task.detached(priority: .utility) {
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }

                    attempt.resume(with: .failure(DiarizationRuntimeError.timedOut))
                }

                attempt.setTasks(processTask: processTask, timeoutTask: timeoutTask)
            }
        }, onCancel: {
            attempt.cancel()
        })
    }
}

private final class TimedDiarizationAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OfflineDiarizationResult, Error>?
    private var processTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finishedResult: Result<OfflineDiarizationResult, Error>?
    private let manager: any OfflineDiarizationManaging

    init(manager: any OfflineDiarizationManaging) { self.manager = manager }

    func install(continuation: CheckedContinuation<OfflineDiarizationResult, Error>) -> Bool {
        lock.lock()
        if let finishedResult {
            lock.unlock()
            continuation.resume(with: finishedResult)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setTasks(processTask: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
        lock.lock()
        if finishedResult != nil {
            lock.unlock()
            processTask.cancel(); timeoutTask.cancel()
            return
        }
        self.processTask = processTask
        self.timeoutTask = timeoutTask
        lock.unlock()
    }

    func resume(with result: Result<OfflineDiarizationResult, Error>, processCompleted: Bool = false) {
        let continuation: CheckedContinuation<OfflineDiarizationResult, Error>?
        let processTask: Task<Void, Never>?
        let timeoutTask: Task<Void, Never>?

        lock.lock()
        guard finishedResult == nil else {
            if processCompleted { DiarizationManagerLease.shared.finish(manager) }
            lock.unlock()
            return
        }
        finishedResult = result
        // The attempt owns terminal ordering. Quarantine before releasing an
        // actual completed process, then resume the caller after both changes.
        // Lock order is always attempt -> lease; lease never calls the attempt.
        if case .failure(let error) = result,
           error as? DiarizationRuntimeError == .timedOut || error as? DiarizationRuntimeError == .cancelled {
            DiarizationManagerLease.shared.quarantine(manager)
        }
        if processCompleted { DiarizationManagerLease.shared.finish(manager) }
        continuation = self.continuation
        self.continuation = nil
        processTask = self.processTask
        timeoutTask = self.timeoutTask
        self.processTask = nil
        self.timeoutTask = nil
        lock.unlock()

        processTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }

    func cancel() {
        resume(with: .failure(DiarizationRuntimeError.cancelled))
    }
}

/// Cancellation of an SDK task does not prove its unstructured children stopped.
/// Hold one permit per actual shared manager, and quarantine timeout/cancellation
/// for the app lifetime rather than reentering mutable SDK state on a later run.
private final class DiarizationManagerLease: @unchecked Sendable {
    static let shared = DiarizationManagerLease()
    private let lock = NSLock()
    private var active = Set<ObjectIdentifier>()
    private var quarantined: [ObjectIdentifier: any OfflineDiarizationManaging] = [:]

    func checkAvailable(_ manager: any OfflineDiarizationManaging) throws {
        try lock.withLock {
            let id = ObjectIdentifier(manager)
            if quarantined[id] != nil { throw DiarizationRuntimeError.runtimeQuarantined }
            if active.contains(id) { throw DiarizationRuntimeError.runtimeBusy }
        }
    }
    func begin(_ manager: any OfflineDiarizationManaging) throws {
        try lock.withLock {
            let id = ObjectIdentifier(manager)
            if quarantined[id] != nil { throw DiarizationRuntimeError.runtimeQuarantined }
            guard active.insert(id).inserted else { throw DiarizationRuntimeError.runtimeBusy }
        }
    }
    func finish(_ manager: any OfflineDiarizationManaging) { lock.withLock { _ = active.remove(ObjectIdentifier(manager)) } }
    func quarantine(_ manager: any OfflineDiarizationManaging) { lock.withLock { quarantined[ObjectIdentifier(manager)] = manager } }
}

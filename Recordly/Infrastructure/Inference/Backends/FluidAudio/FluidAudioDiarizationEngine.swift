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

        guard systemAudioURL.lastPathComponent == "system.m4a" else {
            throw DiarizationRuntimeError.invalidInput
        }

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
            }
        )
#else
        throw DiarizationRuntimeError.binaryMissing
#endif
    }

    private func processWithTimeout(audio: [Float]) async throws -> OfflineDiarizationResult {
        try Task.checkCancellation()

        let attempt = TimedDiarizationAttempt()
        let timeoutNanoseconds = timeoutSeconds * 1_000_000_000

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                attempt.install(continuation: continuation)

                let processTask = Task.detached(priority: .userInitiated) { [manager] in
                    do {
                        let result = try await manager.process(audio: audio)
                        attempt.resume(with: .success(result))
                    } catch is CancellationError {
                        attempt.resume(with: .failure(DiarizationRuntimeError.cancelled))
                    } catch {
                        attempt.resume(with: .failure(error))
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

    func install(continuation: CheckedContinuation<OfflineDiarizationResult, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func setTasks(processTask: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
        lock.lock()
        self.processTask = processTask
        self.timeoutTask = timeoutTask
        lock.unlock()
    }

    func resume(with result: Result<OfflineDiarizationResult, Error>) {
        let continuation: CheckedContinuation<OfflineDiarizationResult, Error>?
        let processTask: Task<Void, Never>?
        let timeoutTask: Task<Void, Never>?

        lock.lock()
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

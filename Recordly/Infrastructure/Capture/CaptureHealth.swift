import Foundation

enum CaptureChannel: String, Equatable, Hashable, Sendable {
    case microphone
    case system
}

enum CaptureHealthPhase: Equatable, Sendable {
    case idle
    case starting
    case healthy
    case recovering(attempt: Int)
    case failed(message: String)
}

struct CaptureHealthSnapshot: Equatable, Sendable {
    var phase: CaptureHealthPhase
    var affectedChannels: Set<CaptureChannel>
    var statusLabel: String

    static let idle = CaptureHealthSnapshot(
        phase: .idle,
        affectedChannels: [],
        statusLabel: "Idle"
    )
}

struct CaptureRecoveryPolicy: Equatable, Sendable {
    var heartbeatTimeout: Duration
    var attemptOffsets: [Duration]
    var failureDeadline: Duration

    static let production = CaptureRecoveryPolicy(
        heartbeatTimeout: .milliseconds(1_500),
        attemptOffsets: [.zero, .seconds(2), .seconds(5)],
        failureDeadline: .seconds(6)
    )
}

enum CaptureHealthAction: Equatable, Sendable {
    case restart(attempt: Int)
    case alertFailure
}

@MainActor
final class CaptureHealthCoordinator {
    private(set) var snapshot: CaptureHealthSnapshot = .idle
    private(set) var diagnostics: [String] = []

    private let policy: CaptureRecoveryPolicy
    private var requiredChannels: Set<CaptureChannel> = []
    private var lastHeartbeatAt: [CaptureChannel: ContinuousClock.Instant] = [:]
    private var monitoringStartedAt: ContinuousClock.Instant?
    private var recoveryStartedAt: ContinuousClock.Instant?
    private var lastRestartStartedAt: ContinuousClock.Instant?
    private var affectedChannels: Set<CaptureChannel> = []
    private var nextAttemptIndex = 0
    private var restartInFlight = false
    private var alertIssued = false

    init(policy: CaptureRecoveryPolicy) {
        self.policy = policy
    }

    func start(
        requiredChannels: Set<CaptureChannel>,
        at instant: ContinuousClock.Instant
    ) {
        self.requiredChannels = requiredChannels
        lastHeartbeatAt = [:]
        monitoringStartedAt = instant
        recoveryStartedAt = nil
        lastRestartStartedAt = nil
        affectedChannels = []
        nextAttemptIndex = 0
        restartInFlight = false
        alertIssued = false
        diagnostics = []
        snapshot = CaptureHealthSnapshot(
            phase: .starting,
            affectedChannels: requiredChannels,
            statusLabel: "Starting"
        )
    }

    func receiveHeartbeat(
        for channel: CaptureChannel,
        level _: Double,
        at instant: ContinuousClock.Instant
    ) {
        guard requiredChannels.contains(channel) else {
            return
        }

        lastHeartbeatAt[channel] = instant

        switch snapshot.phase {
        case .starting:
            guard hasFreshHeartbeats(since: monitoringStartedAt) else {
                return
            }
            markHealthy()
        case .recovering:
            refreshRecoveryAffectedChannels(at: instant)
            guard !restartInFlight,
                  hasFreshHeartbeats(since: lastRestartStartedAt) else {
                return
            }
            let interruption = recoveryStartedAt.map { $0.duration(to: instant) }
            if let interruption {
                diagnostics.append("Audio capture restored after \(interruption).")
            }
            markHealthy()
        case .idle, .healthy, .failed:
            break
        }
    }

    @discardableResult
    func receiveUnexpectedStop(
        reason: String,
        at instant: ContinuousClock.Instant
    ) -> CaptureHealthAction? {
        switch snapshot.phase {
        case .idle, .failed, .recovering:
            return nil
        case .starting, .healthy:
            diagnostics.append("Unexpected capture stop: \(reason)")
            return beginRecovery(affected: requiredChannels, at: instant)
        }
    }

    func nextAction(at instant: ContinuousClock.Instant) -> CaptureHealthAction? {
        switch snapshot.phase {
        case .idle, .failed:
            return nil
        case .starting:
            guard let monitoringStartedAt,
                  monitoringStartedAt.duration(to: instant) >= policy.heartbeatTimeout else {
                return nil
            }
            diagnostics.append("Capture startup heartbeat timed out.")
            return beginRecovery(affected: missingOrStaleChannels(at: instant), at: instant)
        case .healthy:
            let staleChannels = missingOrStaleChannels(at: instant)
            guard !staleChannels.isEmpty else {
                return nil
            }
            diagnostics.append("Capture heartbeat timed out for \(channelList(staleChannels)).")
            return beginRecovery(affected: staleChannels, at: instant)
        case .recovering:
            return nextRecoveryAction(at: instant)
        }
    }

    func restartFinished(
        attempt: Int,
        error: Error?,
        at _: ContinuousClock.Instant
    ) {
        guard case .recovering(let currentAttempt) = snapshot.phase,
              currentAttempt == attempt else {
            return
        }

        restartInFlight = false
        if let error {
            diagnostics.append("Capture restart attempt \(attempt) failed: \(error.localizedDescription)")
        } else {
            diagnostics.append("Capture restart attempt \(attempt) started; waiting for fresh audio.")
        }
    }

    @discardableResult
    func retryNow(at instant: ContinuousClock.Instant) -> CaptureHealthAction? {
        guard case .failed = snapshot.phase else {
            return nil
        }
        diagnostics.append("Manual capture retry requested.")
        return beginRecovery(affected: requiredChannels, at: instant)
    }

    func stop() {
        requiredChannels = []
        lastHeartbeatAt = [:]
        monitoringStartedAt = nil
        recoveryStartedAt = nil
        lastRestartStartedAt = nil
        affectedChannels = []
        nextAttemptIndex = 0
        restartInFlight = false
        alertIssued = false
        snapshot = .idle
    }

    private func beginRecovery(
        affected: Set<CaptureChannel>,
        at instant: ContinuousClock.Instant
    ) -> CaptureHealthAction? {
        recoveryStartedAt = instant
        affectedChannels = affected.isEmpty ? requiredChannels : affected
        nextAttemptIndex = 0
        restartInFlight = false
        alertIssued = false
        snapshot = CaptureHealthSnapshot(
            phase: .recovering(attempt: 0),
            affectedChannels: affectedChannels,
            statusLabel: "Restoring audio…"
        )
        return issueRestart(at: instant)
    }

    private func nextRecoveryAction(
        at instant: ContinuousClock.Instant
    ) -> CaptureHealthAction? {
        guard let recoveryStartedAt else {
            return nil
        }

        refreshRecoveryAffectedChannels(at: instant)
        let elapsed = recoveryStartedAt.duration(to: instant)
        if elapsed >= policy.failureDeadline {
            guard !alertIssued else {
                return nil
            }
            alertIssued = true
            restartInFlight = false
            snapshot = CaptureHealthSnapshot(
                phase: .failed(message: "Audio capture could not be restored."),
                affectedChannels: affectedChannels,
                statusLabel: "Not recording"
            )
            diagnostics.append("Audio capture recovery failed after \(elapsed).")
            return .alertFailure
        }

        guard !restartInFlight,
              nextAttemptIndex < policy.attemptOffsets.count,
              elapsed >= policy.attemptOffsets[nextAttemptIndex] else {
            return nil
        }

        return issueRestart(at: instant)
    }

    private func issueRestart(
        at instant: ContinuousClock.Instant
    ) -> CaptureHealthAction? {
        guard nextAttemptIndex < policy.attemptOffsets.count else {
            return nil
        }

        let attempt = nextAttemptIndex + 1
        nextAttemptIndex += 1
        restartInFlight = true
        lastRestartStartedAt = instant
        snapshot = CaptureHealthSnapshot(
            phase: .recovering(attempt: attempt),
            affectedChannels: affectedChannels,
            statusLabel: "Restoring audio…"
        )
        diagnostics.append("Starting capture restart attempt \(attempt).")
        return .restart(attempt: attempt)
    }

    private func hasFreshHeartbeats(
        since instant: ContinuousClock.Instant?
    ) -> Bool {
        guard let instant else {
            return false
        }
        return requiredChannels.allSatisfy { channel in
            guard let heartbeat = lastHeartbeatAt[channel] else {
                return false
            }
            return heartbeat >= instant
        }
    }

    private func missingOrStaleChannels(
        at instant: ContinuousClock.Instant
    ) -> Set<CaptureChannel> {
        Set(requiredChannels.filter { channel in
            guard let heartbeat = lastHeartbeatAt[channel] else {
                return true
            }
            return heartbeat.duration(to: instant) >= policy.heartbeatTimeout
        })
    }

    private func refreshRecoveryAffectedChannels(
        at instant: ContinuousClock.Instant
    ) {
        let updated = Set(requiredChannels.filter { channel in
            guard let heartbeat = lastHeartbeatAt[channel] else {
                return true
            }
            if let lastRestartStartedAt, heartbeat < lastRestartStartedAt {
                return true
            }
            return heartbeat.duration(to: instant) >= policy.heartbeatTimeout
        })
        affectedChannels = updated
        snapshot.affectedChannels = updated
    }

    private func markHealthy() {
        recoveryStartedAt = nil
        lastRestartStartedAt = nil
        affectedChannels = []
        nextAttemptIndex = 0
        restartInFlight = false
        alertIssued = false
        snapshot = CaptureHealthSnapshot(
            phase: .healthy,
            affectedChannels: [],
            statusLabel: "Captured"
        )
    }

    private func channelList(_ channels: Set<CaptureChannel>) -> String {
        channels
            .map(\.rawValue)
            .sorted()
            .joined(separator: ", ")
    }
}

@MainActor
final class CaptureHealthRuntime {
    typealias RestartOperation = @MainActor () async throws -> Void
    typealias CancelRestartOperation = @MainActor () -> Void
    typealias DiagnosticObserver = @MainActor (String) -> Void

    private let coordinator: CaptureHealthCoordinator
    private let restart: RestartOperation
    private let cancelRestart: CancelRestartOperation
    private let onDiagnostic: DiagnosticObserver
    private var forwardedDiagnosticCount = 0
    private var restartTask: Task<Void, Never>?
    private var nextRestartTaskID: UInt64 = 0
    private var currentRestartTaskID: UInt64?

    var snapshot: CaptureHealthSnapshot {
        coordinator.snapshot
    }

    init(
        policy: CaptureRecoveryPolicy,
        restart: @escaping RestartOperation,
        cancelRestart: @escaping CancelRestartOperation = {},
        onDiagnostic: @escaping DiagnosticObserver = { _ in }
    ) {
        coordinator = CaptureHealthCoordinator(policy: policy)
        self.restart = restart
        self.cancelRestart = cancelRestart
        self.onDiagnostic = onDiagnostic
    }

    func start(
        requiredChannels: Set<CaptureChannel>,
        at instant: ContinuousClock.Instant
    ) {
        restartTask?.cancel()
        forwardedDiagnosticCount = 0
        coordinator.start(requiredChannels: requiredChannels, at: instant)
    }

    func receiveHeartbeat(
        for channel: CaptureChannel,
        level: Double,
        at instant: ContinuousClock.Instant
    ) {
        coordinator.receiveHeartbeat(for: channel, level: level, at: instant)
        forwardNewDiagnostics()
    }

    func receiveUnexpectedStop(
        reason: String,
        at instant: ContinuousClock.Instant
    ) async {
        let action = coordinator.receiveUnexpectedStop(reason: reason, at: instant)
        forwardNewDiagnostics()
        execute(action, at: instant)
    }

    func process(at instant: ContinuousClock.Instant) async {
        let action = coordinator.nextAction(at: instant)
        forwardNewDiagnostics()
        execute(action, at: instant)
    }

    func retryNow(at instant: ContinuousClock.Instant) async {
        let action = coordinator.retryNow(at: instant)
        forwardNewDiagnostics()
        execute(action, at: instant)
    }

    func stop() {
        cancelRestart()
        restartTask?.cancel()
        forwardNewDiagnostics()
        coordinator.stop()
        forwardedDiagnosticCount = 0
    }

    private func execute(
        _ action: CaptureHealthAction?,
        at instant: ContinuousClock.Instant
    ) {
        guard let action else {
            return
        }

        switch action {
        case .restart(let attempt):
            guard restartTask == nil else {
                coordinator.restartFinished(
                    attempt: attempt,
                    error: CancellationError(),
                    at: instant
                )
                break
            }
            nextRestartTaskID &+= 1
            let taskID = nextRestartTaskID
            currentRestartTaskID = taskID
            let restart = self.restart
            restartTask = Task { @MainActor [weak self, restart] in
                let restartError: Error?
                do {
                    try await restart()
                    restartError = nil
                } catch {
                    restartError = error
                }
                guard let self,
                      self.currentRestartTaskID == taskID else {
                    return
                }
                self.restartTask = nil
                self.currentRestartTaskID = nil
                self.coordinator.restartFinished(attempt: attempt, error: restartError, at: instant)
                self.forwardNewDiagnostics()
            }
        case .alertFailure:
            cancelRestart()
            restartTask?.cancel()
        }
        forwardNewDiagnostics()
    }

    private func forwardNewDiagnostics() {
        let diagnostics = coordinator.diagnostics
        guard forwardedDiagnosticCount < diagnostics.count else {
            return
        }
        for diagnostic in diagnostics[forwardedDiagnosticCount...] {
            onDiagnostic(diagnostic)
        }
        forwardedDiagnosticCount = diagnostics.count
    }
}

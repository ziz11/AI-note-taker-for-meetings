import XCTest
@testable import Recordly

@MainActor
final class CaptureHealthCoordinatorTests: XCTestCase {
    private let clock = ContinuousClock()

    func testProductionPolicyUsesThreeAttemptsWithinEightSeconds() {
        XCTAssertEqual(
            CaptureRecoveryPolicy.production.attemptOffsets,
            [.zero, .seconds(2), .seconds(5)]
        )
        XCTAssertEqual(CaptureRecoveryPolicy.production.failureDeadline, .seconds(8))
    }

    func testSilentBuffersRemainHealthy() {
        let start = clock.now
        let coordinator = CaptureHealthCoordinator(policy: .production)

        coordinator.start(
            requiredChannels: [.microphone, .system],
            at: start
        )
        coordinator.receiveHeartbeat(for: .microphone, level: 0, at: start + .milliseconds(10))
        coordinator.receiveHeartbeat(for: .system, level: 0, at: start + .milliseconds(10))

        XCTAssertEqual(coordinator.snapshot.phase, .healthy)
        XCTAssertEqual(coordinator.snapshot.statusLabel, "Captured")
        XCTAssertNil(coordinator.nextAction(at: start + .seconds(2)))
    }

    func testUnexpectedStopStartsOneRecoveryEpisode() {
        let start = clock.now
        let coordinator = makeHealthyCoordinator(at: start)

        let first = coordinator.receiveUnexpectedStop(reason: "system stopped", at: start + .seconds(1))
        let duplicate = coordinator.receiveUnexpectedStop(reason: "duplicate", at: start + .seconds(1))

        XCTAssertEqual(first, .restart(attempt: 1))
        XCTAssertNil(duplicate)
        XCTAssertEqual(coordinator.snapshot.phase, .recovering(attempt: 1))
        XCTAssertEqual(coordinator.snapshot.affectedChannels, [.microphone, .system])
    }

    func testHeartbeatTimeoutStartsRecoveryWithoutDelegateError() {
        let start = clock.now
        let coordinator = makeHealthyCoordinator(at: start)

        let action = coordinator.nextAction(at: start + .seconds(4))

        XCTAssertEqual(action, .restart(attempt: 1))
        XCTAssertEqual(coordinator.snapshot.phase, .recovering(attempt: 1))
    }

    func testRestartReturnWithoutFreshHeartbeatsDoesNotRecover() {
        let start = clock.now
        let coordinator = makeHealthyCoordinator(at: start)
        _ = coordinator.receiveUnexpectedStop(reason: "stopped", at: start + .seconds(1))

        coordinator.restartFinished(attempt: 1, error: nil, at: start + .seconds(1))

        XCTAssertEqual(coordinator.snapshot.phase, .recovering(attempt: 1))
        XCTAssertEqual(coordinator.nextAction(at: start + .seconds(3)), .restart(attempt: 2))
    }

    func testFreshRequiredHeartbeatsRecoverAfterRestart() {
        let start = clock.now
        let coordinator = makeHealthyCoordinator(at: start)
        _ = coordinator.receiveUnexpectedStop(reason: "stopped", at: start + .seconds(1))
        coordinator.restartFinished(attempt: 1, error: nil, at: start + .seconds(1))

        coordinator.receiveHeartbeat(for: .microphone, level: 0.2, at: start + .seconds(1.1))
        XCTAssertEqual(coordinator.snapshot.phase, .recovering(attempt: 1))

        coordinator.receiveHeartbeat(for: .system, level: 0, at: start + .seconds(1.1))
        XCTAssertEqual(coordinator.snapshot.phase, .healthy)
        XCTAssertEqual(coordinator.snapshot.affectedChannels, [])
    }

    func testAllAttemptsFailAtEightSecondDeadline() {
        let start = clock.now
        let coordinator = makeHealthyCoordinator(at: start)
        _ = coordinator.receiveUnexpectedStop(reason: "stopped", at: start)

        coordinator.restartFinished(attempt: 1, error: TestError.failed, at: start)
        XCTAssertEqual(coordinator.nextAction(at: start + .seconds(2)), .restart(attempt: 2))
        coordinator.restartFinished(attempt: 2, error: TestError.failed, at: start + .seconds(2))
        XCTAssertEqual(coordinator.nextAction(at: start + .seconds(5)), .restart(attempt: 3))
        coordinator.restartFinished(attempt: 3, error: TestError.failed, at: start + .seconds(5))

        XCTAssertEqual(coordinator.nextAction(at: start + .seconds(7.9)), nil)
        XCTAssertEqual(coordinator.nextAction(at: start + .seconds(8)), .alertFailure)
        XCTAssertEqual(
            coordinator.snapshot.phase,
            .failed(message: "Audio capture could not be restored.")
        )
    }

    func testManualStopCancelsRecoveryWithoutFailure() {
        let start = clock.now
        let coordinator = makeHealthyCoordinator(at: start)
        _ = coordinator.receiveUnexpectedStop(reason: "stopped", at: start + .seconds(1))

        coordinator.stop()

        XCTAssertEqual(coordinator.snapshot, .idle)
        XCTAssertNil(coordinator.nextAction(at: start + .seconds(20)))
    }

    func testManualRetryStartsNewRecoveryWindow() {
        let start = clock.now
        let coordinator = makeHealthyCoordinator(at: start)
        _ = coordinator.receiveUnexpectedStop(reason: "stopped", at: start)
        coordinator.restartFinished(attempt: 1, error: TestError.failed, at: start)
        _ = coordinator.nextAction(at: start + .seconds(8))

        let action = coordinator.retryNow(at: start + .seconds(20))

        XCTAssertEqual(action, .restart(attempt: 1))
        XCTAssertEqual(coordinator.snapshot.phase, .recovering(attempt: 1))
    }

    func testUnexpectedCurrentStreamStopIsForwardedOnce() {
        let lifecycle = ScreenCaptureStreamLifecycle()
        let stream = NSObject()
        lifecycle.install(stream)

        XCTAssertTrue(lifecycle.shouldForwardStop(for: stream))
        XCTAssertFalse(lifecycle.shouldForwardStop(for: stream))
    }

    func testIntentionalStopIsNotForwardedAsFailure() {
        let lifecycle = ScreenCaptureStreamLifecycle()
        let stream = NSObject()
        lifecycle.install(stream)
        lifecycle.markIntentionalStop(for: stream)

        XCTAssertFalse(lifecycle.shouldForwardStop(for: stream))
    }

    func testLateStopFromReplacedStreamIsIgnored() {
        let lifecycle = ScreenCaptureStreamLifecycle()
        let oldStream = NSObject()
        let replacement = NSObject()
        lifecycle.install(oldStream)
        lifecycle.install(replacement)

        XCTAssertFalse(lifecycle.shouldForwardStop(for: oldStream))
        XCTAssertTrue(lifecycle.shouldForwardStop(for: replacement))
    }

    func testRuntimeDelegateStopRestartsTheStream() async {
        let start = clock.now
        var restartCount = 0
        let runtime = CaptureHealthRuntime(
            policy: .production,
            restart: {
                restartCount += 1
            }
        )
        runtime.start(requiredChannels: [.microphone, .system], at: start)
        runtime.receiveHeartbeat(for: .microphone, level: 0.2, at: start)
        runtime.receiveHeartbeat(for: .system, level: 0, at: start)

        await runtime.receiveUnexpectedStop(reason: "stream stopped", at: start + .seconds(1))

        XCTAssertEqual(restartCount, 1)
        XCTAssertEqual(runtime.snapshot.phase, .recovering(attempt: 1))
    }

    func testRuntimeMissingHeartbeatRestartsTheStream() async {
        let start = clock.now
        var restartCount = 0
        let runtime = CaptureHealthRuntime(
            policy: .production,
            restart: {
                restartCount += 1
            }
        )
        runtime.start(requiredChannels: [.system], at: start)

        await runtime.process(at: start + .seconds(3))

        XCTAssertEqual(restartCount, 1)
        XCTAssertEqual(runtime.snapshot.phase, .recovering(attempt: 1))
    }

    func testRuntimeRestartNeedsFreshRequiredHeartbeats() async {
        let start = clock.now
        let runtime = CaptureHealthRuntime(policy: .production, restart: {})
        runtime.start(requiredChannels: [.microphone, .system], at: start)
        runtime.receiveHeartbeat(for: .microphone, level: 0.2, at: start)
        runtime.receiveHeartbeat(for: .system, level: 0, at: start)

        await runtime.receiveUnexpectedStop(reason: "stream stopped", at: start + .seconds(1))
        runtime.receiveHeartbeat(for: .system, level: 0, at: start + .seconds(1.1))
        XCTAssertEqual(runtime.snapshot.phase, .recovering(attempt: 1))

        runtime.receiveHeartbeat(for: .microphone, level: 0, at: start + .seconds(1.1))
        XCTAssertEqual(runtime.snapshot.phase, .healthy)
    }

    func testRuntimeFailedRecoveryExposesTypedHealthAtDeadline() async {
        let start = clock.now
        let runtime = CaptureHealthRuntime(
            policy: .production,
            restart: {
                throw TestError.failed
            }
        )
        runtime.start(requiredChannels: [.system], at: start)
        runtime.receiveHeartbeat(for: .system, level: 0, at: start)

        await runtime.receiveUnexpectedStop(reason: "stream stopped", at: start)
        await runtime.process(at: start + .seconds(2))
        await runtime.process(at: start + .seconds(5))
        await runtime.process(at: start + .seconds(8))

        XCTAssertEqual(
            runtime.snapshot.phase,
            .failed(message: "Audio capture could not be restored.")
        )
    }

    func testRuntimeForwardsEachDiagnosticOnlyOnce() async {
        let start = clock.now
        var diagnostics: [String] = []
        let runtime = CaptureHealthRuntime(
            policy: .production,
            restart: {},
            onDiagnostic: { diagnostics.append($0) }
        )
        runtime.start(requiredChannels: [.system], at: start)
        runtime.receiveHeartbeat(for: .system, level: 0, at: start)

        await runtime.receiveUnexpectedStop(reason: "stream stopped", at: start)
        await runtime.process(at: start + .seconds(1))
        await runtime.process(at: start + .seconds(1))

        XCTAssertEqual(
            diagnostics.filter { $0.contains("Unexpected capture stop") }.count,
            1
        )
        XCTAssertEqual(
            diagnostics.filter { $0.contains("restart attempt 1") }.count,
            2
        )
    }

    func testRuntimeStopCancelsFurtherRecoveryActions() async {
        let start = clock.now
        var restartCount = 0
        let runtime = CaptureHealthRuntime(
            policy: .production,
            restart: {
                restartCount += 1
                throw TestError.failed
            }
        )
        runtime.start(requiredChannels: [.system], at: start)
        runtime.receiveHeartbeat(for: .system, level: 0, at: start)
        await runtime.receiveUnexpectedStop(reason: "stream stopped", at: start)

        runtime.stop()
        await runtime.process(at: start + .seconds(20))

        XCTAssertEqual(runtime.snapshot, .idle)
        XCTAssertEqual(restartCount, 1)
    }

    private func makeHealthyCoordinator(at start: ContinuousClock.Instant) -> CaptureHealthCoordinator {
        let coordinator = CaptureHealthCoordinator(policy: .production)
        coordinator.start(requiredChannels: [.microphone, .system], at: start)
        coordinator.receiveHeartbeat(for: .microphone, level: 0.2, at: start)
        coordinator.receiveHeartbeat(for: .system, level: 0.2, at: start)
        return coordinator
    }
}

private enum TestError: Error {
    case failed
}

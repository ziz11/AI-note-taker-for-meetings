import XCTest
@testable import Recordly

@MainActor
final class CaptureHealthCoordinatorTests: XCTestCase {
    private let clock = ContinuousClock()

    func testProductionPolicyUsesThreeAttemptsAndAlertsWithinEightSecondsOfLastHeartbeat() {
        XCTAssertEqual(CaptureRecoveryPolicy.production.heartbeatTimeout, .milliseconds(1_500))
        XCTAssertEqual(
            CaptureRecoveryPolicy.production.attemptOffsets,
            [.zero, .seconds(2), .seconds(5)]
        )
        XCTAssertEqual(CaptureRecoveryPolicy.production.failureDeadline, .seconds(6))
    }

    func testSilentStallAlertsWithinEightSecondsOfLastHeartbeat() {
        let start = clock.now
        let coordinator = makeHealthyCoordinator(at: start)

        XCTAssertEqual(
            coordinator.nextAction(at: start + .milliseconds(1_500)),
            .restart(attempt: 1)
        )
        coordinator.restartFinished(attempt: 1, error: TestError.failed, at: start + .milliseconds(1_500))
        XCTAssertEqual(coordinator.nextAction(at: start + .seconds(3.5)), .restart(attempt: 2))
        coordinator.restartFinished(attempt: 2, error: TestError.failed, at: start + .seconds(3.5))
        XCTAssertEqual(coordinator.nextAction(at: start + .seconds(6.5)), .restart(attempt: 3))
        coordinator.restartFinished(attempt: 3, error: TestError.failed, at: start + .seconds(6.5))

        XCTAssertNil(coordinator.nextAction(at: start + .seconds(7.49)))
        XCTAssertEqual(coordinator.nextAction(at: start + .seconds(7.5)), .alertFailure)
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
        XCTAssertNil(coordinator.nextAction(at: start + .seconds(1)))
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

    func testAllAttemptsFailAtSixSecondRecoveryDeadline() {
        let start = clock.now
        let coordinator = makeHealthyCoordinator(at: start)
        _ = coordinator.receiveUnexpectedStop(reason: "stopped", at: start)

        coordinator.restartFinished(attempt: 1, error: TestError.failed, at: start)
        XCTAssertEqual(coordinator.nextAction(at: start + .seconds(2)), .restart(attempt: 2))
        coordinator.restartFinished(attempt: 2, error: TestError.failed, at: start + .seconds(2))
        XCTAssertEqual(coordinator.nextAction(at: start + .seconds(5)), .restart(attempt: 3))
        coordinator.restartFinished(attempt: 3, error: TestError.failed, at: start + .seconds(5))

        XCTAssertEqual(coordinator.nextAction(at: start + .seconds(5.9)), nil)
        XCTAssertEqual(coordinator.nextAction(at: start + .seconds(6)), .alertFailure)
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

    func testStoppingInvalidatesPendingCaptureRequest() {
        let lifecycle = ScreenCaptureStreamLifecycle()
        let request = lifecycle.beginCaptureRequest()

        XCTAssertTrue(lifecycle.isCurrentCaptureRequest(request))

        lifecycle.cancelCaptureRequest()

        XCTAssertFalse(lifecycle.isCurrentCaptureRequest(request))
    }

    func testOldStreamGenerationCannotConfirmReplacementHealth() {
        let lifecycle = ScreenCaptureStreamLifecycle()
        let oldStream = NSObject()
        let oldGeneration = lifecycle.install(oldStream)

        lifecycle.markIntentionalStop(for: oldStream)
        let replacement = NSObject()
        let replacementGeneration = lifecycle.install(replacement)

        XCTAssertNotEqual(oldGeneration, replacementGeneration)
        XCTAssertFalse(lifecycle.isCurrentStreamGeneration(oldGeneration))
        XCTAssertTrue(lifecycle.isCurrentStreamGeneration(replacementGeneration))
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
        await Task.yield()

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
        await Task.yield()

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
        await Task.yield()
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
        await Task.yield()
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
        await Task.yield()

        runtime.stop()
        await runtime.process(at: start + .seconds(20))

        XCTAssertEqual(runtime.snapshot, .idle)
        XCTAssertEqual(restartCount, 1)
    }

    func testRuntimeDeadlineDoesNotWaitForHungRestart() async {
        let start = clock.now
        var cancelCount = 0
        let runtime = CaptureHealthRuntime(
            policy: .production,
            restart: {
                try await Task.sleep(for: .seconds(60))
            },
            cancelRestart: {
                cancelCount += 1
            }
        )
        runtime.start(requiredChannels: [.system], at: start)
        runtime.receiveHeartbeat(for: .system, level: 0, at: start)

        let processStarted = clock.now
        await runtime.process(at: start + .milliseconds(1_500))
        XCTAssertLessThan(processStarted.duration(to: clock.now), .milliseconds(100))

        await runtime.process(at: start + .seconds(7.5))

        XCTAssertEqual(
            runtime.snapshot.phase,
            .failed(message: "Audio capture could not be restored.")
        )
        XCTAssertEqual(cancelCount, 1)
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

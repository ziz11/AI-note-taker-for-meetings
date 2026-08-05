# Capture Health Recovery and Alerting Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Detect a stopped or stalled ScreenCaptureKit audio stream, restore it within an eight-second retry window, and emit one short user-volume alert plus a persistent visual failure state when recovery fails.

**Architecture:** Add a typed capture-health contract and a deterministic recovery coordinator in the capture layer. `ScreenCaptureAudioService` will surface `SCStreamDelegate` stop events and support restart while existing writers remain open; `AudioCaptureService` will feed successful per-channel sample heartbeats into the coordinator. `RecordingsStore` will map typed health into UI state and own the single standard macOS alert sound.

**Tech Stack:** Swift 6, Swift concurrency, ScreenCaptureKit, AppKit, SwiftUI, XCTest, Xcode build system.

---

## Baseline

Before implementation, the isolated worktree passed:

```bash
xcodebuild test \
  -project Recordly.xcodeproj \
  -scheme Recordly \
  -destination 'platform=macOS'
```

Expected baseline: `199 tests`, `1 skipped`, `0 failures`, `** TEST SUCCEEDED **`.

Follow `@test-driven-development` for every behavior change and
`@verification-before-completion` before claiming the feature is finished.

### Task 1: Add the typed capture-health model and deterministic recovery coordinator

**Files:**

- Create: `Recordly/Infrastructure/Capture/CaptureHealth.swift`
- Create: `RecordlyTests/CaptureHealthTests.swift`
- Modify: `Recordly.xcodeproj/project.pbxproj`

**Step 1: Add both new files to the Xcode project**

Add file references, source build entries, and group membership for:

- `CaptureHealth.swift` in the Recordly target
- `CaptureHealthTests.swift` in the RecordlyTests target

Do not add any other project-file changes.

**Step 2: Write failing health-state tests**

Create `@MainActor final class CaptureHealthCoordinatorTests: XCTestCase` covering:

```swift
func testSilentBuffersRemainHealthy()
func testUnexpectedStopStartsOneRecoveryEpisode()
func testHeartbeatTimeoutStartsRecoveryWithoutDelegateError()
func testFirstSuccessfulRestartReturnsToHealthy()
func testStartSuccessWithoutHeartbeatsDoesNotCountAsRecovery()
func testAllAttemptsFailByEightSecondDeadline()
func testRepeatedStopSignalsDoNotCreateParallelRecoveryLoops()
func testManualStopCancelsRecoveryWithoutFailure()
func testManualRetryStartsNewRecoveryWindowFromFailedState()
func testDiagnosticsDescribeDetectionAttemptsAndInterruptionDuration()
```

Use a fake clock/sleeper or an explicit `advance(to:)` scheduling seam. Tests must
not sleep for production intervals.

The deadline test must assert the production policy:

```swift
XCTAssertEqual(policy.attemptOffsets, [.zero, .seconds(2), .seconds(5)])
XCTAssertEqual(policy.failureDeadline, .seconds(8))
```

The silence test must send a valid heartbeat whose level is `0`; amplitude is not
part of the health decision.

**Step 3: Run the focused test target and verify failure**

Run:

```bash
xcodebuild test \
  -project Recordly.xcodeproj \
  -scheme Recordly \
  -destination 'platform=macOS' \
  -only-testing:RecordlyTests/CaptureHealthCoordinatorTests
```

Expected: FAIL because `CaptureHealthCoordinator`, `CaptureHealthSnapshot`, and
`CaptureRecoveryPolicy` do not exist.

**Step 4: Implement the minimal typed model**

Add these public-to-the-module shapes:

```swift
enum CaptureChannel: String, Equatable, Sendable {
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
        heartbeatTimeout: .seconds(3),
        attemptOffsets: [.zero, .seconds(2), .seconds(5)],
        failureDeadline: .seconds(8)
    )
}
```

Implement `@MainActor final class CaptureHealthCoordinator` with injected callbacks:

```swift
typealias CaptureRestartOperation = @MainActor () async throws -> Void
typealias CaptureHealthObserver = @MainActor (CaptureHealthSnapshot) -> Void
typealias CaptureDiagnosticObserver = @MainActor (String) -> Void
```

The coordinator must expose:

```swift
func start(requiredChannels: Set<CaptureChannel>)
func receiveHeartbeat(for channel: CaptureChannel, at instant: ContinuousClock.Instant)
func receiveUnexpectedStop(reason: String, at instant: ContinuousClock.Instant)
func checkHealth(at instant: ContinuousClock.Instant)
func retryNow(at instant: ContinuousClock.Instant)
func stop()
```

Keep one recovery `Task` and one episode start instant. A second stop/timeout signal
during recovery must update diagnostics but must not launch another task.

Recovery succeeds only after all required channels have produced a heartbeat newer
than the current restart attempt. A return from the restart closure is not success.

**Step 5: Run focused tests**

Run the command from Step 3.

Expected: all `CaptureHealthCoordinatorTests` PASS.

**Step 6: Commit**

```bash
git add \
  Recordly/Infrastructure/Capture/CaptureHealth.swift \
  RecordlyTests/CaptureHealthTests.swift \
  Recordly.xcodeproj/project.pbxproj
git commit -m "feat(capture): add deterministic health recovery coordinator"
```

### Task 2: Surface unexpected ScreenCaptureKit stops and make the stream restartable

**Files:**

- Modify: `Recordly/Infrastructure/Capture/AudioCaptureService.swift`
- Modify: `RecordlyTests/CaptureHealthTests.swift`

**Step 1: Write failing lifecycle tests**

Add focused tests around a small stream-lifecycle policy seam:

```swift
func testUnexpectedCurrentStreamStopIsForwarded()
func testIntentionalStopIsNotForwardedAsFailure()
func testLateStopFromReplacedStreamIsIgnored()
func testRestartReusesRegisteredSampleCallbacks()
```

The tests must not construct a real `SCStream`. Extract identity/disposition logic
into a small testable helper if necessary.

**Step 2: Run the focused tests and verify failure**

Run:

```bash
xcodebuild test \
  -project Recordly.xcodeproj \
  -scheme Recordly \
  -destination 'platform=macOS' \
  -only-testing:RecordlyTests/CaptureHealthCoordinatorTests
```

Expected: FAIL because stop forwarding/restart behavior is absent.

**Step 3: Add a capture-stream boundary**

Define an `@MainActor` protocol next to `ScreenCaptureAudioService`:

```swift
protocol ScreenAudioStreaming: AnyObject {
    var microphoneViaStreamEnabled: Bool { get }
    var onUnexpectedStop: (@MainActor (String) -> Void)? { get set }

    func startCapture(
        onSystemSample: @escaping (CMSampleBuffer) -> Void,
        onMicrophoneSample: @escaping (CMSampleBuffer) -> Void
    ) async throws

    func restartCapture() async throws
    func stopCapture() async throws
}
```

Make `ScreenCaptureAudioService` conform to `SCStreamDelegate` and
`ScreenAudioStreaming`.

Create each stream with:

```swift
SCStream(filter: filter, configuration: config, delegate: self)
```

Implement:

```swift
func stream(_ stream: SCStream, didStopWithError error: Error)
```

Forward only an unexpected stop from the currently active stream. Suppress:

- the intentional final `stopCapture()`;
- a stop callback from a stream already replaced during restart;
- duplicate callbacks for the same stream generation.

Store the two sample callbacks after the first start. `restartCapture()` must rebuild
the `SCStream`, outputs, and filter while reusing those callbacks. It must not close
or recreate `PCMTrackWriter`, `MirroredTrackWriter`, or `CaptureSamplePipeline`.

**Step 4: Run focused tests**

Run the command from Step 2.

Expected: PASS.

**Step 5: Build the app**

Run:

```bash
xcodebuild build \
  -project Recordly.xcodeproj \
  -scheme Recordly \
  -destination 'platform=macOS'
```

Expected: `** BUILD SUCCEEDED **`.

**Step 6: Commit**

```bash
git add \
  Recordly/Infrastructure/Capture/AudioCaptureService.swift \
  RecordlyTests/CaptureHealthTests.swift
git commit -m "feat(capture): observe and restart ScreenCaptureKit streams"
```

### Task 3: Wire heartbeats, retries, status, and diagnostics into AudioCaptureService

**Files:**

- Modify: `Recordly/Infrastructure/Capture/AudioCaptureService.swift`
- Modify: `Recordly/Infrastructure/Inference/Contracts/InferenceStageContracts.swift`
- Modify: `RecordlyTests/CaptureHealthTests.swift`
- Modify: existing fake capture engines only where compiler conformance requires it

**Step 1: Write failing AudioCaptureService integration tests**

Use a fake `ScreenAudioStreaming`, production-like writers replaced by narrow test
seams where needed, and accelerated policy timings.

Cover:

```swift
func testSystemHeartbeatMarksCaptureHealthyEvenAtZeroLevel()
func testDelegateStopRestartsTheStream()
func testMissingHeartbeatRestartsTheStream()
func testRestartRequiresFreshSystemAndStreamMicrophoneHeartbeats()
func testFailedRecoveryExposesTypedFailedHealth()
func testStopCancelsRecoveryBeforeIntentionalStreamStop()
func testRecoveryDiagnosticsAreAppendedToSessionNotes()
```

**Step 2: Run focused tests and verify failure**

Run:

```bash
xcodebuild test \
  -project Recordly.xcodeproj \
  -scheme Recordly \
  -destination 'platform=macOS' \
  -only-testing:RecordlyTests/CaptureHealthCoordinatorTests
```

Expected: FAIL because `AudioCaptureService` is not wired to the coordinator.

**Step 3: Extend the capture-engine contract without breaking test fakes**

Add:

```swift
var captureHealth: CaptureHealthSnapshot { get }
func retryCaptureNow() async
```

to `AudioCaptureEngine`.

Provide safe extension defaults:

```swift
var captureHealth: CaptureHealthSnapshot {
    CaptureHealthSnapshot(
        phase: systemAudioStatusLabel == "Captured" ? .healthy : .idle,
        affectedChannels: [],
        statusLabel: systemAudioStatusLabel
    )
}

func retryCaptureNow() async {}
```

This avoids editing every unrelated fake engine. Override both members in
`AudioCaptureService`.

**Step 4: Inject the stream and policy**

Change `AudioCaptureService` construction to accept defaults:

```swift
init(
    screenCaptureService: any ScreenAudioStreaming = ScreenCaptureAudioService(),
    recoveryPolicy: CaptureRecoveryPolicy = .production
)
```

Create one coordinator per active capture. Required channels are:

- `.system`
- `.microphone` only when `microphoneViaStreamEnabled == true`

**Step 5: Feed real health signals**

After each successful writer append, call `receiveHeartbeat` before the metering
throttle guard. Do this even when normalized level is zero.

Connect `onUnexpectedStop` to `receiveUnexpectedStop`.

Replace side effects in `refreshSystemAudioHealth()` with coordinator snapshots.
The metering getter may call `checkHealth`, but it must not create duplicate recovery
tasks.

On start:

- publish `.starting`;
- start health monitoring after the first stream start returns;
- do not publish `Captured` until required heartbeats arrive.

On stop:

- stop the coordinator before calling the intentional stream stop;
- cancel watchdog/recovery tasks;
- reset to `.idle`.

**Step 6: Persist diagnostics through the existing notes contract**

For each coordinator diagnostic, append a timestamped note via
`SessionMetadataStore.appendNote`. Include:

- delegate error text or `heartbeat timeout`;
- attempt number;
- restored timestamp and interruption duration;
- final eight-second failure.

Do not add fields to `SessionMetadata` and do not rename any audio artifact.

**Step 7: Run capture tests**

Run:

```bash
xcodebuild test \
  -project Recordly.xcodeproj \
  -scheme Recordly \
  -destination 'platform=macOS' \
  -only-testing:RecordlyTests/CaptureHealthCoordinatorTests \
  -only-testing:RecordlyTests/CaptureSamplePipelineTests \
  -only-testing:RecordlyTests/SessionMergeServiceTests
```

Expected: PASS.

**Step 8: Commit**

```bash
git add \
  Recordly/Infrastructure/Capture/AudioCaptureService.swift \
  Recordly/Infrastructure/Inference/Contracts/InferenceStageContracts.swift \
  RecordlyTests/CaptureHealthTests.swift
git commit -m "feat(capture): recover stalled audio within eight seconds"
```

### Task 4: Propagate typed health to RecordingsStore and emit one moderate alert

**Files:**

- Modify: `Recordly/Features/Recordings/Application/RecordingWorkflowController.swift`
- Modify: `Recordly/Features/Recordings/Application/RecordingsStore.swift`
- Modify: `Recordly/Features/Recordings/Presentation/RecordingsViewState.swift`
- Modify: `RecordlyTests/RecordingsPhaseOneTests.swift`

**Step 1: Write failing store tests**

Add:

```swift
func testStorePublishesRecoveringCaptureHealth()
func testStorePublishesFailedCaptureHealth()
func testStoreAlertsOnceWhenRecoveryEpisodeFails()
func testStoreDoesNotAlertWhileRecovering()
func testStoreCanRequestManualCaptureRetry()
func testSecondFailureAfterRecoveryAlertsAgain()
```

Inject an alert closure that increments a counter. Never play a real sound in tests.

**Step 2: Run tests and verify failure**

Run:

```bash
xcodebuild test \
  -project Recordly.xcodeproj \
  -scheme Recordly \
  -destination 'platform=macOS' \
  -only-testing:RecordlyTests/RecordingsPhaseOneTests
```

Expected: FAIL because typed capture health is not propagated.

**Step 3: Expose health and retry through the workflow**

Add:

```swift
var currentCaptureHealth: CaptureHealthSnapshot {
    audioCaptureEngine.captureHealth
}

func retryCaptureNow() async {
    await audioCaptureEngine.retryCaptureNow()
}
```

**Step 4: Add runtime presentation state**

Add `captureHealth: CaptureHealthSnapshot = .idle` to `RecordingRuntimeState`.

Update it in the existing 0.25-second meter timer in the same batched runtime
assignment used for meter levels. Reset it to `.idle` when recording ends.

**Step 5: Add a single standard-volume alert edge**

Add an injected `captureFailureNotifier: @MainActor () -> Void` to
`RecordingsStore.init`.

The production default must do only:

```swift
NSSound.beep()
NSApp.requestUserAttention(.criticalRequest)
```

Do not set volume, instantiate an audio player with custom gain, or modify any macOS
sound preference.

Call the notifier only on a transition from a non-failed phase into `.failed`.
Remaining failed across timer ticks must not repeat the sound. After a real recovery,
a later distinct failure may alert once again.

Add:

```swift
func retryCaptureNow() {
    Task { await workflow.retryCaptureNow() }
}
```

**Step 6: Run store tests**

Run the command from Step 2.

Expected: PASS.

**Step 7: Commit**

```bash
git add \
  Recordly/Features/Recordings/Application/RecordingWorkflowController.swift \
  Recordly/Features/Recordings/Application/RecordingsStore.swift \
  Recordly/Features/Recordings/Presentation/RecordingsViewState.swift \
  RecordlyTests/RecordingsPhaseOneTests.swift
git commit -m "feat(ui): publish capture failures and alert once"
```

### Task 5: Add the persistent recovery/failure banner and truthful meter styling

**Files:**

- Modify: `Recordly/Features/Recordings/Views/RecordingSidebarView.swift`
- Modify: `Recordly/Features/Recordings/Presentation/RecordingsViewState.swift`
- Modify: `RecordlyTests/RecordingsPhaseOneTests.swift`

**Step 1: Add failing presentation mapping tests**

Keep copy/severity decisions outside the SwiftUI body in small computed properties
or a mapper that can be unit tested.

Cover:

```swift
func testRecoveringPresentationIsAmberAndNonFatal()
func testFailedPresentationIsRedPersistentAndRetryable()
func testHealthyPresentationHasNoBanner()
func testFailureCopyNamesAffectedSystemChannel()
func testFailureCopyNamesWholeAudioStreamWhenBothChannelsAreAffected()
```

**Step 2: Run presentation tests and verify failure**

Run:

```bash
xcodebuild test \
  -project Recordly.xcodeproj \
  -scheme Recordly \
  -destination 'platform=macOS' \
  -only-testing:RecordlyTests/RecordingsPhaseOneTests
```

Expected: FAIL because the banner/presentation mapping does not exist.

**Step 3: Render recording health near the top of the sidebar**

Insert a health section after `searchField`:

- `.recovering`: amber compact banner, progress indicator, `Restoring audio…`
- `.failed`: persistent red banner, affected-channel message, `Retry now` button
- `.healthy`, `.starting`, `.idle`: no error banner

The failure banner must remain visible until recovery or recording stop. Do not make
the sound repeat when the user interacts with the banner.

**Step 4: Make the meter status truthful**

Update the System meter to use status color and tint:

- healthy: existing accent
- starting/recovering: amber
- failed: red

Do not show `Captured` for `.starting`, `.recovering`, or `.failed`.

Add accessibility labels that include the phase and affected channel.

**Step 5: Run tests and build**

Run:

```bash
xcodebuild test \
  -project Recordly.xcodeproj \
  -scheme Recordly \
  -destination 'platform=macOS' \
  -only-testing:RecordlyTests/RecordingsPhaseOneTests

xcodebuild build \
  -project Recordly.xcodeproj \
  -scheme Recordly \
  -destination 'platform=macOS'
```

Expected: tests PASS and `** BUILD SUCCEEDED **`.

**Step 6: Commit**

```bash
git add \
  Recordly/Features/Recordings/Views/RecordingSidebarView.swift \
  Recordly/Features/Recordings/Presentation/RecordingsViewState.swift \
  RecordlyTests/RecordingsPhaseOneTests.swift
git commit -m "feat(ui): show persistent audio capture health alerts"
```

### Task 6: Regression verification and manual capture smoke test

**Files:**

- Modify only if verification reveals a defect in the scoped behavior

**Step 1: Run whitespace and repository checks**

```bash
git diff --check
git status --short
```

Expected: no whitespace errors and only intentional changes.

**Step 2: Run the complete automated suite**

```bash
xcodebuild test \
  -project Recordly.xcodeproj \
  -scheme Recordly \
  -destination 'platform=macOS'
```

Expected: all tests pass, with no regression from the baseline of 199 tests and one
known skipped test.

**Step 3: Build Release**

```bash
xcodebuild build \
  -project Recordly.xcodeproj \
  -scheme Recordly \
  -configuration Release \
  -destination 'platform=macOS'
```

Expected: `** BUILD SUCCEEDED **`.

**Step 4: Perform a manual healthy-path smoke test**

1. Start a recording while continuously playing system audio.
2. Confirm the state moves `Starting` → `Captured` only after meters receive buffers.
3. Leave it running for at least two minutes.
4. Stop and confirm both durable tracks are usable and close to the UI duration.

Expected: no recovery banner or alert; both tracks cover the session.

**Step 5: Perform a device-change smoke test**

1. Start a recording with system audio playing.
2. Switch the active input/output device, including an AirPods disconnect/reconnect
   when available.
3. Confirm either uninterrupted heartbeats or an amber recovery state.
4. Confirm recovery completes within eight seconds when ScreenCaptureKit can restart.
5. Confirm the session metadata records the interruption.

Expected: recording resumes automatically and the UI never falsely remains
`Captured` while buffers are absent.

**Step 6: Verify the hard-failure presentation with a debug/test seam**

Force all fake/injected restart attempts to fail:

- the failed state appears no later than eight seconds;
- exactly one short standard macOS beep occurs;
- system volume is unchanged;
- the red banner remains visible;
- `Retry now` starts a new recovery window;
- stopping the recording cancels the alert state.

**Step 7: Request code review**

Use `@requesting-code-review` to review:

- restart-generation race handling;
- intentional-stop suppression;
- one-task/one-alert guarantees;
- preservation of canonical CAF/M4A and recovery contracts;
- cancellation when the user stops recording.

**Step 8: Final verification commit if needed**

If verification required scoped fixes:

```bash
git add <only-the-files-changed-by-verification>
git commit -m "fix(capture): address recovery verification findings"
```

If no fixes were needed, do not create an empty commit.

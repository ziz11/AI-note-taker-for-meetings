# Capture Health Recovery and Alerting Design

**Date:** 2026-07-31

## Problem

Recordly can keep presenting an active recording after its `SCStream` has stopped
delivering audio. A real session on 2026-07-30 remained active for 3,983 seconds,
while both persisted tracks ended at about 2,346 seconds. Finalization then reported
that the ScreenCaptureKit stream was already stopped.

The current implementation has two partial signals but no recovery path:

- `SCStream` is created without an `SCStreamDelegate`, so runtime stop errors are not
  delivered to Recordly.
- A three-second sample heartbeat timeout changes the small System meter label to
  `System silent`, but it does not retry capture or produce a noticeable alert.

The product requirement is to spend no more than 5–10 seconds attempting automatic
recovery before making the failure impossible to miss.

## Chosen Behavior

Recordly will detect a stopped or stalled capture stream, attempt automatic recovery
for at most eight seconds, and then emit one short system alert sound plus a
persistent visual error if recovery fails.

The alert sound must use the user's existing macOS alert/output volume. Recordly must
not raise, override, or otherwise modify system volume.

## Capture Health Model

Introduce an explicit, backend-neutral capture health state:

- `idle`
- `starting`
- `healthy`
- `recovering(attempt, startedAt)`
- `failed(reason)`

Health is based on valid sample-buffer arrival, not signal amplitude. A valid silent
buffer is still a heartbeat and must not be treated as a failure. This avoids
alerting merely because a participant is quiet.

Two failure signals enter the same recovery coordinator:

1. `SCStreamDelegate.stream(_:didStopWithError:)`
2. A missing sample heartbeat while the stream is expected to be running

Delegate errors provide the reason when ScreenCaptureKit reports one. The heartbeat
watchdog covers cases where callbacks simply stop without a delegate notification.

## Recovery Policy

Recovery has one owner so delegate errors, heartbeat timeouts, and overlapping timer
ticks cannot start competing restart loops.

The coordinator will:

1. Enter `recovering` immediately and show an amber `Restoring audio…` state.
2. Recreate and start the ScreenCaptureKit stream immediately.
3. Retry after approximately two seconds and five seconds when needed.
4. Use eight seconds from the first detected failure as a hard deadline.
5. Count recovery as successful only after new valid audio buffers arrive. A
   successful `startCapture()` call alone is insufficient.
6. Return to `healthy` and briefly show `Audio restored` when buffers resume.

The existing writers and sample pipelines remain open during a restart. This keeps
the change local to stream lifecycle management and preserves the current session
artifact contract. The unavoidable interruption is recorded as a diagnostic note.

If all attempts fail by the deadline:

- transition to `failed`;
- play one short standard macOS alert sound at the user's configured volume;
- request user attention without changing system volume;
- show a persistent red banner stating which channel or capture stream is no longer
  recording;
- expose a `Retry now` action;
- never continue to label the affected source as captured or healthy.

Recordly continues the session so any channel that still supplies samples can be
saved. Fully separating microphone capture from ScreenCaptureKit is a larger
follow-up and is not part of this change.

## Startup Behavior

Starting the `SCStream` does not prove that recording is healthy. The UI remains in
`starting` until valid sample buffers arrive.

If the initial stream does not produce buffers, the same eight-second recovery policy
applies. Recordly must not spend an entire session displaying a healthy recording
after a startup timeout or a zero-buffer start.

## UI and Alerting

The meter area will distinguish these states visually:

- healthy: normal meter and `Captured`
- recovering: amber status and `Restoring audio…`
- failed: red status and `Not recording`

The failed state also appears as a persistent app-level banner so it is not confined
to the small footer meter. The audible alert fires once per failure episode. A new
sound is allowed only after the stream has recovered and a later, distinct failure
episode begins.

## Diagnostics

Each failure episode appends concise timestamped notes to the existing capture
session metadata:

- detection source and ScreenCaptureKit error code when available;
- recovery attempt start/result;
- first missing-sample time;
- restored time and estimated interruption duration;
- final failure at the eight-second deadline.

This uses the existing notes contract rather than introducing a new persisted schema.

## Testing

Use a controllable clock and a fake stream lifecycle boundary to verify:

- a delegate stop starts exactly one recovery loop;
- a heartbeat timeout starts recovery when no delegate callback arrives;
- zero-amplitude buffers remain healthy;
- a successful first, second, or third attempt returns to healthy;
- `startCapture()` success without new buffers does not count as recovery;
- all attempts fail and alert no later than eight seconds;
- the sound is emitted once per failure episode;
- manual stop cancels recovery and does not alert;
- repeated stop callbacks do not create parallel restarts;
- an interruption and its duration are persisted as diagnostic notes.

Existing capture, finalization, merge, and recovery tests must remain green.

## Out of Scope

- Independently recording the microphone outside ScreenCaptureKit
- Replacing canonical CAF/M4A artifacts
- Reconstructing audio that was never supplied by macOS
- Changing transcription, diarization, or summarization behavior

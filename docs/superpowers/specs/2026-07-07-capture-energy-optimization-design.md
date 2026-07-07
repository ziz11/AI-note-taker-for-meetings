# Capture Energy Optimization — Design

Date: 2026-07-07
Status: Approved

## Problem

Recording is suspected to burn more CPU/energy than necessary (no measurements yet; user perception plus code-level evidence). Target: BlueDot-class efficiency during long recordings, plus a lightweight measurement discipline so future changes don't regress.

## Scope

Four targeted changes to the live capture path and tooling. Explicitly out of scope: dual-write removal (crash safety), merge pipeline (just optimized in d6b7d08), UI work, transcription engine tuning.

## Changes

### 1. Buffer pipeline — eliminate per-buffer Task spawn

`AudioCaptureService.startCapture` sample callbacks (AudioCaptureService.swift ~891, ~907) currently spawn an unstructured `Task { try await writer.append(...) }` per CMSampleBuffer — dozens of allocations and actor hops per second across two streams.

Replace with one `AsyncStream<CMSampleBuffer>` per stream:

- SCK callback body becomes `continuation.yield(sampleBuffer)` — no allocation, no hop.
- One long-lived consumer Task per stream: `for await buffer in stream { try await writer.append(buffer) }`.
- Error handling moves into the consumer loop; keep `systemAppendErrorCount`, diagnostics, level/status updates semantics identical.
- Buffering policy `.bufferingOldest(64)`; on overflow drop newest and record a diagnostic counter (`droppedBufferCount`).
- Consumer Tasks cancelled and drained in `stopCapture` before writer finalize (finalize order preserved: drain → finalize → close).

### 2. ScreenCaptureKit configuration audit

Inspect `ScreenCaptureService` stream setup. For audio-only capture:

- No `.screen` (video) SCStreamOutput attached; if the API version requires one, configure minimal cost: smallest legal width/height, `minimumFrameInterval` at maximum, discard frames without processing.
- Confirm `capturesAudio = true`, `excludesCurrentProcessAudio` as intended, `queueDepth` reasonable (currently 8).

Outcome is either "already optimal — documented" or a config fix. If video frames were flowing, this is likely the largest single win.

### 3. Metering throttle

`CMSampleBuffer.normalizedLevel` (RMS over all samples) runs per buffer to drive UI meters. Change:

- Compute level at most once per ~100 ms per stream; skip intermediate buffers entirely (cheap timestamp check).
- Use vDSP (`vDSP_rmsqv`) for the RMS when it does run.
- UI polling (`currentMicrophoneLevel` / `currentSystemAudioLevel`) unchanged.

### 4. Measurement discipline (quality bar)

- `os_signpost` intervals: capture append path (per-flush, not per-buffer), merge stages (prepare/mix/finalize), transcription stages. Visible in Instruments → makes future profiling trivial.
- `scripts/energy-baseline.sh`: samples `powermetrics` (or `top`-based fallback without sudo) for the Recordly process over a timed window, prints average CPU % and, when available, energy impact. Usage documented in the script header. Run before/after perf changes; since no baseline exists yet, the first run after these fixes doubles as the post-hoc validation.

## Error handling

- Stream overflow: drop-newest + diagnostic counter, never block the SCK callback thread.
- Consumer loop append errors: same handling as today (count, diagnostic, status label), loop continues on next buffer.
- Cancellation during stop: consumer drains remaining buffered samples before exiting so tail audio isn't lost.

## Testing

- Unit: consumer-loop drain-on-stop test (all yielded buffers reach writer before finalize); metering throttle test (level updated ≤ once per interval); existing 195 tests stay green.
- Manual: 10-min recording with system audio; `energy-baseline.sh` snapshot; meters visibly move; merged output contains both tracks.

## Success criteria

- No per-buffer Task allocation in capture path.
- Documented SCK config (optimal or fixed).
- Energy script committed and runnable; signposts visible in Instruments.
- No audio regressions (tests + manual E2E).

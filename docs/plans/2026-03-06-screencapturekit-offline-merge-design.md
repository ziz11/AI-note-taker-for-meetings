# ScreenCaptureKit Offline Merge Design

## Context
Current capture path relies on CoreAudio tap + realtime merge, which causes lock states and brittle synchronization when track starts/durations diverge.

## Approved direction
Adopt a two-phase pipeline:
1. Capture phase writes canonical raw tracks independently (`system.raw.caf`, `mic.raw.caf`) and records timing/frame stats in `session.json`.
2. Post-processing phase performs deterministic offline merge by timeline offsets, then optionally transcodes to m4a.

## Platform and capture
- Minimum deployment target: macOS 15.0.
- Remove CoreAudio tap/aggregate device path.
- Primary system capture: ScreenCaptureKit stream audio output.
- Primary mic capture: ScreenCaptureKit microphone output.
- Mic fallback path may exist for resilience and must be declared in metadata diagnostics.

## Canonical media contract
- Float32, 48 kHz, mono, non-interleaved, CAF.
- Per session artifacts:
  - `system.raw.caf`
  - `mic.raw.caf`
  - `session.json`
  - `merged-call.caf`
  - optional `merged-call.m4a`

## Merge algorithm
- Offset source: firstPTS alignment.
- earliestPTS = min(firstPTS across non-empty tracks)
- trackOffset = track.firstPTS - earliestPTS
- Drift visibility: compare PTS duration and frame duration per track; write warning when threshold exceeded.
- Render length: max(trackOffset + trackDuration) across non-empty tracks.
- Missing/short track is padded with silence, never truncates longer track.
- Merge implementation: AVAudioEngine manual rendering (offline).

## Session states
- recording -> finalizingTracks -> readyForMix -> mixing -> ready | mixError
- `stop` must always cleanup runtime state via `defer`.
- One empty track is non-fatal and yields single-track merged output with status note.

## Recovery/idempotency
- Raw tracks + metadata are source of truth.
- Merged outputs are cache and can be regenerated safely.
- On app launch, recovery service resumes sessions stuck in `finalizingTracks`, `readyForMix`, or `mixing`.

## Validation strategy
- Build verification via xcodebuild clean build.
- Unit-level checks for offset math, drift detection, metadata state transitions, idempotent re-merge behavior.
- Runtime checks for delayed-start and unequal-length tracks.

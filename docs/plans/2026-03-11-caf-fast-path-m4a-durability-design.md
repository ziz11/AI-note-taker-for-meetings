94318647-A9AE-46C7-9CB8-0FB94EC4CF86# CAF Fast Path and M4A Durability Design

## Context

Recordly currently writes live source tracks as `mic.raw.flac` and `system.raw.flac`, while the FluidAudio backend ultimately consumes prepared PCM buffers. This means the persisted source format is doing extra work for the ASR fast path without being the SDK's native runtime input.

The approved product direction is:

- use `CAF PCM` as a temporary live-session artifact for immediate post-stop auto-transcription
- write durable `m4a` source tracks in parallel during recording for recovery and reprocessing
- keep `merged-call.m4a` as a playback-only artifact
- delete temporary `CAF` artifacts after transcription reaches a terminal state

## Approved Direction

Adopt a dual-write capture path for live sessions:

- Temporary fast-path artifacts:
  - `mic.raw.caf`
  - `system.raw.caf`
- Durable source artifacts:
  - `mic.m4a`
  - `system.m4a`
- Playback artifact:
  - `merged-call.m4a`

Immediate auto-transcription after recording stops should prefer `CAF PCM` when present and valid. Recovery after app restart, manual reprocessing, and any later transcription reruns should use the durable `m4a` source tracks.

## Ownership and Boundaries

- `AudioCaptureService` owns dual-write behavior and temporary artifact lifecycle.
- `TranscriptionPipeline` owns input selection between fast-path `CAF` and durable `m4a`.
- `RecordingWorkflowController` remains backend-agnostic and should only pass through selected artifacts/results.
- FluidAudio backend modules continue to own backend-local input preparation, but not fallback policy.
- Persistence contracts remain centered on session artifacts owned by Recordly, not on one backend's preferred format.

This keeps selection and policy outside backend modules and avoids widening workflow knowledge of backend-specific file handling.

## Persistence Contract

Long-lived session artifacts become:

- `mic.m4a`
- `system.m4a`
- `merged-call.m4a`
- transcript outputs
- diarization outputs
- summary outputs
- session metadata

Temporary processing artifacts:

- `mic.raw.caf`
- `system.raw.caf`

Temporary `CAF` files are not required for recovery semantics. If they are missing, recovery must still succeed from `m4a`.

## Capture Flow

During live capture, each incoming source buffer is written to:

1. the temporary `CAF PCM` writer for fast-path ASR input
2. the durable `m4a` writer for recovery and reprocessing

This avoids a post-stop transcode before immediate transcription while still preserving resilient disk-backed artifacts throughout the session.

## Transcription Input Selection

For live-capture recordings:

1. try `mic.raw.caf` / `system.raw.caf` for immediate auto-transcription
2. validate that the file exists and can be prepared as supported audio input
3. if validation fails or the file is absent, fall back to `mic.m4a` / `system.m4a`
4. for recovery and explicit reprocessing, use `m4a` directly

This keeps recovery deterministic and makes `CAF` an optimization, not a requirement.

## Provenance and Debugging

Record the technical transcription source in existing session metadata, rather than introducing a new sidecar file.

Suggested provenance values:

- `cafPcmFastPath`
- `m4aRecovery`
- `m4aReprocess`

This provenance should be visible in the existing detail/debug metadata surface so developers can tell whether a transcript came from the fast path or durable fallback path.

## Cleanup Rules

Delete temporary `CAF` artifacts only after transcription reaches a terminal state:

- `ready`
- `failed`

Do not delete them immediately on stop, because the immediate transcription job still depends on them. Do not require them for recovery after restart.

## Risks

- dual-write capture introduces more moving parts in finalization and error handling
- cleanup timing can accidentally break immediate transcription if it runs before the job terminal state
- source selection must not accidentally route ASR providers to `merged-call.m4a`
- existing recovery tests may assume old raw artifact names and need targeted updates

## Acceptance Criteria

- live capture writes temporary `CAF` and durable `m4a` source tracks in parallel
- auto-transcription prefers `CAF` when available and valid
- recovery and reprocessing succeed using `m4a` without requiring `CAF`
- `merged-call.m4a` remains playback-only
- transcript provenance is persisted and visible for debugging
- temporary `CAF` files are removed only after terminal transcription outcome

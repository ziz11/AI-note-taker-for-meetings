# Auto-Transcribe Precheck And Compact Models Design

**Date:** 2026-03-12

## Goal

Make live-capture auto-transcription fail predictably when the FluidAudio diarization package is missing, and make the Models settings window denser without changing its provider/runtime structure.

## Context

Recent live-capture sessions can finish recording successfully, persist valid `mic.m4a` and `system.m4a` assets, and still fail auto-transcription immediately. The likely root cause is the existing transcription availability preflight rejecting the default system path when the FluidAudio diarization package is not installed.

The current experience has two problems:

1. The failure is discovered too late in the flow and is not explained clearly enough in the UI.
2. The real transcription failure note can be overwritten later by offline-merge recovery, which hides the root cause from the user.

At the same time, the Models settings window is too tall and visually sparse for a workflow where the user often needs only one package-specific action.

## Non-Goals

- No backend switch or backend-specific workflow branching outside the existing stage-driven availability checks.
- No change to canonical recording artifacts or persistence layout.
- No redesign of the Models screen information architecture.
- No degradation-to-no-diarization behavior for the default system transcription path in this change.

## Proposed Behavior

### 1. Auto-transcribe precheck

When live capture completes and `runTranscription == true`, Recordly should perform an explicit readiness check before starting pipeline work.

If the selected profile is `.degradedNoDiarization` for the default system transcription path:

- do not start transcription
- persist a clear failure reason on the session
- keep the recording itself available
- show a compact blocking alert with a primary action to open Models

The recording should remain saved and inspectable. Only auto-transcription is blocked.

### 2. Failure reason persistence

If auto-transcription fails during the precheck or early pipeline startup, the persisted session note must continue to show the actual transcription failure reason.

Offline merge completion must not overwrite a failure note on an already failed recording. Merge recovery may still update merge-related artifacts, but it must preserve higher-value failure context.

### 3. Compact Models window

The Models window should stay grouped by provider/runtime exactly as it is today, but the presentation becomes denser:

- reduce section spacing and row padding
- convert oversized cards into compact row-like blocks where practical
- shorten secondary copy
- keep install/select actions in a tighter horizontal arrangement
- surface the FluidAudio diarization package state prominently and compactly

When opened from the auto-transcribe blocking alert, the Models screen should land in a state where the diarization package section is easy to find immediately.

## Architecture

This change stays inside workflow/UI boundaries:

- workflow owns the precheck decision and user-facing failure behavior
- runtime selection continues to report availability only
- backend modules stay unchanged
- Models UI remains a presentation-layer compaction only

This keeps Recordly stage-driven and backend-agnostic. The diarization package requirement remains expressed as availability data and workflow policy, not as backend wiring spread across the app.

## Data Flow

1. Capture completes and persists audio artifacts.
2. Workflow checks transcription availability before pipeline execution.
3. If unavailable because diarization package is missing:
   - session state is updated with failed transcript status and preserved note
   - UI alert state is populated
   - Models window can be opened directly from the alert
4. If available:
   - normal pipeline execution continues
5. Offline merge recovery may still mark merged artifacts ready, but it must not erase an existing transcription failure reason.

## Error Handling

- Missing diarization package is treated as a product precondition failure, not a backend crash.
- The persisted note must contain the actionable reason.
- UI copy should explicitly tell the user to install the FluidAudio diarization package in Models.
- If Models cannot be opened for some reason, the session still preserves the reason and remains manually recoverable later.

## Testing Strategy

Add tests for:

- precheck blocks auto-transcription when the FluidAudio diarization package is missing
- the real transcription failure note survives offline merge completion
- the user can trigger Models opening from the blocking alert flow
- compact Models UI still exposes install/select actions and package state correctly

Manual verification:

- create a fresh live-capture recording with missing diarization package
- confirm recording is saved
- confirm transcription does not start
- confirm blocking alert appears
- confirm Models opens to the relevant area
- confirm session note remains the real failure reason

## Risks

- If the note-preservation change is too broad, it may accidentally suppress useful merge-status messaging on non-failed sessions.
- Compacting the Models screen too aggressively could make provider/runtime grouping less legible.

## Mitigations

- Preserve note overwrite only when a higher-priority transcription failure already exists.
- Keep section order and grouping unchanged while reducing padding and copy length.

# Product Issue: Launch Triggers Bulk ASR and Blocks Record Navigation

## Date
2026-03-12

## Problem
On app launch, Recordly auto-recovers pending transcription work and can enqueue many recordings at once.  
When this happens, the left pane is filled with active "Transcribing..." cards, and users cannot easily scroll/find regular recordings.

## User Impact
- App appears to "start processing everything" unexpectedly.
- Main recordings list becomes hard to use.
- Core task (open a specific recording) is blocked by system-initiated background jobs.
- Perceived loss of control and trust.

## Current Behavior (Observed)
- Startup calls post-processing recovery.
- Recovery enqueues transcription jobs for:
- interrupted in-progress transcript states
- failed transcripts with missing transcript JSON
- This can create a large processing queue immediately after launch.

## Why This Is a Product Issue
This is not only technical recovery logic. It is a UX and policy issue:
- Background recovery competes with primary navigation.
- Recovery has no clear user consent at launch.
- Job presentation does not scale when queue size is large.

## Product Goals
1. Preserve crash/interruption recovery.
2. Avoid surprise bulk processing on launch.
3. Keep recordings list navigable at all times.
4. Make background recovery explicit, controllable, and reversible.

## Proposed UX Direction
1. Separate "Processing Queue" from main recordings list.
- Show queue in a collapsible panel/section with compact rows.
- Do not let queue items push normal recordings out of view.

2. Add launch-time recovery confirmation when queue is large.
- Example: "Resume 12 unfinished transcriptions?"
- Actions: `Resume`, `Skip for now`.

3. Differentiate recovery types.
- Auto-resume only truly interrupted in-progress states.
- Do not auto-retry older failed items by default.
- Offer manual "Retry failed" action.

4. Add queue controls.
- `Pause all`, `Resume all`, `Cancel all`.
- Per-item cancel/retry.

5. Add simple throttling visibility.
- Show "Processing N jobs" with clear max concurrency behavior.

## Acceptance Criteria
- On launch, user can immediately scroll and open recordings even if many recoverable jobs exist.
- If recoverable job count exceeds threshold, user gets a confirm prompt before bulk enqueue.
- Failed historical items are not retried automatically unless user explicitly opts in.
- Queue UI remains usable with 20+ jobs.
- Processing state remains visible but does not dominate navigation.

## Non-Goals (This Ticket)
- Rewriting ASR/diarization engines.
- Changing transcript quality logic.
- Changing model download/provisioning flows.

## Implementation Notes for Follow-up Agent
- Likely touch points:
- `RecordingsStore` launch recovery flow and enqueue policy.
- Sidebar/list composition where processing jobs are rendered.
- Add user decision state for launch recovery prompt.
- Keep crash recovery for in-progress states intact.

## Suggested Telemetry (Optional)
- `recovery_prompt_shown`
- `recovery_prompt_accept`
- `recovery_prompt_decline`
- `recovery_jobs_enqueued_count`
- `recovery_jobs_cancelled_count`


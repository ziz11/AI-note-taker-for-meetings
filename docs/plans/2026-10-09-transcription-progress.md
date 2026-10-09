# Transcription counters and responsive presentation

User request: persistent completed/total transcription and diarization counters, understandable overall progress, and reduce UI hesitation during segmented inference.

Design: use the existing feature worktree and backend-neutral pipeline callback. Count logical inference windows, independently of 180-second physical chunks. A snapshot carries total/handled/failed/skipped/reused counts for ASR and optional diarization. Overall progress uses completed stage work plus merge/export completion, never fixed per-stage percentages for segmented sessions. Cached work counts as handled; unavailable stages and failed ranges stay visible. Keep the existing legacy stage callback intact. Show stable counters in detail and queue; current stage remains secondary text. Batch each store snapshot mutation and throttle repeated snapshots to at most 10 Hz, always delivering initial/final snapshots. Avoid publishing recording metadata for every segmented window. Investigate file/stat/parse work triggered by body refresh before making unrelated optimizations.

Implementation steps:
1. Add failing segmented pipeline tests for counters/monotonic progression, cache reuse, failure/skips and cancel.
2. Implement a value snapshot and bounded publication at planning/start/terminal stage points; preserve cancellation and cache behavior.
3. Thread optional snapshot callback through pipeline/workflow/store. Update a job atomically; retain legacy fallback monotonicity.
4. Add stable detail/queue counter rows and total percentage. Verify with pipeline/runtime tests and a full suite.
5. Build signed standalone Release, commit/push feature changes, and leave develop/master unchanged. UI verification depends on Computer Use permission; do not claim a measured improvement of full-app responsiveness without UI/profile evidence.

## Additional user requirement

Disable summarization in app composition and workflow. Keep generation buttons and auto-summary control disabled as placeholders, remove active generation/queue/fallback machinery, preserve existing artifacts, and select Transcript initially and on recording changes. Direct entry points must remain harmless and never resolve or invoke a summary runtime.

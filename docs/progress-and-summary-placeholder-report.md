# Transcription progress and summary placeholders

> Reviewed 2026-10-10. Delivered feature report. Original stage-specific measurements/test counts below are historical evidence; the feature is included in the current installed standalone. See [current project status](project-status.md).

Implementation originated on `feature/audio_pipeline_v2` after `524551f`. It is now included in the delivered `develop`/`master` runtime and the installed FluidAudio 0.17.7 standalone. The verification counts below belong to this earlier implementation stage; the latest full suite is 362 tests, 0 failures, 3 skips. See [project status](project-status.md).

## Result

- Recording detail opens Transcript, including when changing recordings. Summary displays a temporary-unavailability placeholder. Summarize and Auto Summarize are disabled.
- Direct Store and workflow summary entry points perform no generation, runtime selection, backend construction, queueing or artifact writes. The app composition disables the summary stage. Active generation, fallback, timeout, logging, task/queue and executable/model configuration UI have been removed. Previous summary/transcript/audio assets and model preferences are preserved. Backend implementations remain isolated for compatibility and unit tests; the app workflow does not invoke them.
- Segmented processing shows persistent transcription and diarization handled/total counters in detail and the queue, with overall percentage and explicit failed/skipped/reused stage work. Counters count logical inference windows, not physical AAC files: ownership windows can cross storage boundaries. Handled includes success, cached output, failure and skipped work, with those exceptions disclosed.
- Overall progress derives from handled ASR/diarization work plus two finishing steps; it stays below 100% until output/report completion. Finishing credit survives a later failure/cancellation so progress never goes backwards. Microphone windows do not inflate diarization totals.
- UI snapshots coalesce to 10 Hz during inference with a trailing update, so an awaited backend does not leave the latest counters/phase undisplayed. Initial, merge/render and terminal boundaries flush immediately. Cancelled timer continuations cannot flush a newer snapshot. A Store snapshot updates its view state atomically and avoids publishing the recordings array on every V2 phase. Legacy adapters retain their stage callback and monotonic queue progress.

## Verification

- Initial counter regressions failed with missing progress snapshots, then passed after implementation.
- Summary regressions failed on runtime invocation and summary/log writes, then passed after disabling generation.
- Finalization regressions failed on absent cancellation/failure terminal snapshots, then passed after extending terminal handling through output writes.
- Full suite: **327 tests, zero failures, one existing skip** (`/private/tmp/recordly-progress-final-full.log`).
- Additional stale-timer race regression: **one test, zero failures** (`/private/tmp/recordly-progress-timer.log`). The fixture delays the main actor so the old timer continuation is queued, forces a new boundary, and verifies the following update still respects the throttle interval.
- Integration coverage includes queue-to-completion Store progress, cache reuse, failed ASR/diarization, unavailable/missing owned audio, cancellation during diarization and finalization, export errors, and absence of summary side effects.
- Independent review found no remaining blocking issues.

## Standalone and limits

Use `scripts/build-standalone-local.sh` to build a Release app with the existing `Recordly Local Development` identity. The delivery includes a ZIP containing `Recordly.app`; Xcode is not needed to launch it. This local identity is for this Mac, not Developer ID/notarized distribution. Summary runtime/model setup is no longer required. ASR/diarization provisioning remains unchanged.

UI automation is unavailable in this session. Code and regression tests verify reduced publication frequency and default-tab/control behavior, but full-app perceived responsiveness and real meeting inference latency were not measured.

# Recovered ASR and diarization work

> Reviewed 2026-10-10. Historical experiment archive. original-plan.md and the recovered patch remain verbatim; current SDK/speaker changes are independently implemented and verified. See [current project status](../../project-status.md).

Recovered on 2026-10-09 from the unregistered local working copy `.worktrees/codex-asr-diarization-quality`.

- Base commit: `05cbb65` (`codex/asr-diarization-quality`).
- `uncommitted-work.patch` preserves all three modified source/test files relative to that base.
- `original-plan.md` preserves the additional plan verbatim, including historical validation notes and pending work. Those notes describe the original experiment, not current verification.

The experiment adds audio diagnostics, dominant-channel downmixing, VAD padding/merging, and overlapping fallback windows. It is archived rather than applied to the current application: subsequent commits `5534fa9`, `a23dc49`, and `8adb0d3` changed FluidAudio integration to a file-based transcription boundary. The recovered tests use removed engine initializer arguments and removed stubs, so applying the old patch directly would require adapting the experiment to the current architecture.

To recover the exact experiment, apply the patch to a checkout of `05cbb65` with `git apply /absolute/path/to/uncommitted-work.patch`. Porting these ideas to the current backend and replaying real sessions remain pending.

The existing local capture fixes `607fd2f` and `f61abe7` are retained on `develop`. All other local branch tips are already ancestors of `develop`.

## Current interpretation

The archived experiment has not been directly applied. Later V2 and FluidAudio 0.17.7 work independently delivered bounded window inference and conservative voice matching; that does not complete every acceptance step in the archived plan. See [current project status](../../project-status.md) and [original-recording verification](../../recording-7C943EA0-verification.md). The historical statement about local branch ancestry applies to the recovery snapshot, not every branch created later.

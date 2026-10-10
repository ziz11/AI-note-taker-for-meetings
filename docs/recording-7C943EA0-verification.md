# Original-recording reprocessing — 2026-10-10

Recording: `7C943EA0-D956-40F2-A892-48180F282668`. Current runtime source: `0beaacb`; release record: `18add9d`; FluidAudio: **0.17.7**. A documentation-only follow-up does not change this runtime.

## Execution and data safety

The idle standalone was stopped before processing. A full backup was copied and all 282 files verified by SHA-256. The real Application Support recording was processed twice using `RecordingWorkflowController`, `DefaultInferenceComposition`, the installed user models and normal runtime selection. A temporary XCTest entry point was built separately, then the tracked test source restored. No application source or release binary changed.

Computer Use permission was unavailable, so this confirms native workflow and persisted results, not interaction with the installed application's Transcribe button. A normal app-hosted test can also trigger launch recovery; observed times are not an isolated benchmark.

## Results

| Check | Result |
|---|---|
| Original recording processed | Twice; final session/transcript/report state ready |
| Repeat equality | All 87 full segment objects equal, including IDs, text, speakers and timing |
| Identity persistence | All identities and aliases equal between passes |
| Cross-window voice reuse | Three profiles matched in 19, 7 and 2 distinct windows |
| System-channel speaker coverage | 15 of 35 segments with session voice IDs; 20 local/unknown |
| Saved custom names before processing | None |
| Name persistence on isolated copy | Assigned name retained for all 11 segments of one speaker, in identities JSON and transcript JSON/TXT/SRT |
| Original name data | No test name added |
| Original audio | All 48 AAC files retained their SHA-256 |
| Cache reuse on repeat | 172 ASR windows; 39 successful diarization windows |
| Native acceptance | 1 test, 0 failures; independent saved-artifact audit passed |
| Standalone restart | Installed `/Applications/Recordly.app` reopened; transcript JSON/TXT/SRT and identity JSON stayed byte-identical |

First pass: **235.56 seconds**; repeat: **53.54 seconds**; name probe on the copy: **53.40 seconds**.

## Accuracy limits

Final continuity is **`partiallyMatched`**. Diagnostics count 34 window groups with session voice identities and 53 local/unknown groups, including windows with absent or inadequate voice evidence. These counts describe window groups, not people. The 9 stored voice profiles are not a verified participant count. Diarization recorded 46 no-speech results and 1 empty result; successful transcript output was preserved.

IDs and labels are repeatable. It has not been established that every real speaker keeps one ID throughout this recording, or that no different speakers were merged. That requires annotated listening/voice comparison. Name persistence was proven on a copy because the original had no custom names.

## Local evidence

Temporary local evidence is under `/private/tmp/recordly-actual-reprocess-2026-10-10/`: `before/`, `before-sha256.json`, `first-transcript.json`, `first-speaker-identities.json`, `metrics.json`, `after-sha256.json`, `rename-probe/`, and `report.md`. The run log is `/private/tmp/recordly-actual-reprocess-run.log`. These temporary paths may expire; private audio/transcript/voice evidence is not committed to Git.

The committed report retains only aggregate results. See [project status](project-status.md) for current priorities and [speaker verification](fluid-speaker-verification.md) for matcher semantics.

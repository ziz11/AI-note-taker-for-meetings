# 2026-04-03 ASR + Diarization Quality Improvement

## Scope Guardrails

- Keep changes backend-local or at the audio boundary.
- Do not move quality policy into `TranscriptionPipeline` or workflow orchestration.
- Preserve live-capture persistence contracts:
  - `mic.raw.caf`
  - `system.raw.caf`
  - `merged-call.caf`
  - `merged-call.m4a`

## Batch 1 Status

- Completed: Task 1 baseline capture from persisted sessions and current routing.
- Completed: Task 2 ASR input preparation improvements in `FluidAudioSessionAudioLoader`.
- Completed: Task 3 ASR segmentation/chunking tuning in `FluidAudioTranscriptionService`.
- Pending: real-session replay after code changes for 2-3 problematic sessions.
- Pending: Task 4 diarization input path.
- Pending: Task 5 correlation check between diarization quality and system ASR quality.
- Pending: Task 6 backend-switch decision.
- Pending: Task 7 rollout verification.

## Current Input Routing Baseline

`TranscriptionPipeline.liveCaptureCandidates(...)` currently prefers:

1. `*.raw.caf`
2. `*.raw.flac`
3. durable `*.m4a`

Observed implication:

- Immediate fast-path sessions with raw artifacts present use `mic.raw.caf` and `system.raw.caf`.
- Historical recovery/reprocess sessions can run from durable `mic.m4a` and `system.m4a`.
- Quality notes therefore have to record the actual file kind, not only the session type.

## Representative Baseline Sessions

This baseline is derived from persisted artifacts in `~/Library/Application Support/Recordly/recordings` plus transcript excerpts and degradation flags.

| Session | Provenance | Effective ASR / diarization input | Mic ASR | System ASR | Speaker separation | Main issue class |
| --- | --- | --- | --- | --- | --- | --- |
| `DD65C1B8-D1C1-4CF0-82B3-A44280714DB8` | `cafPcmFastPath` | `mic.raw.caf` + `system.raw.caf` | Good, multi-segment, coherent RU/EN mix | Good, dense meeting transcript | Present, 326 diarization segments | Baseline good fast-path case |
| `DEA9150B-4CC9-485C-9088-093C1F30418D` | `cafPcmFastPath` | `mic.raw.caf` + `system.raw.caf` | Mixed, collapsed into one giant segment | Good, 256 system segments | Present, 204 diarization segments | Chunking asymmetry on mic side |
| `FDF28F5D-0DCB-464A-B44C-C5684ECF257E` | `cafPcmFastPath` | `mic.raw.caf` + `system.raw.caf` | Good content, but one very large segment | Acceptable, 79 system segments | Present, 72 diarization segments | Chunking/windowing quality can still improve |
| `FFF56D8D-42BC-47A8-9822-15440471255D` | `cafPcmFastPath` | `mic.raw.caf` + `system.raw.caf` | Good | Good | Present, 30 diarization segments | Good medium-duration dual-track case |
| `FCAE6D3D-1870-4207-A530-03AD66E51EFE` | `cafPcmFastPath` | `mic.raw.caf` + `system.raw.caf` | Mic text exists | Missing system ASR artifact | Missing diarization artifact, degraded flag set | Diarization baseline failure |
| `E3B2F459-F094-410B-B877-C90EFEF14F7B` | `cafPcmFastPath` | `mic.raw.caf` + `system.raw.caf` | Empty | Missing system ASR | Missing diarization, degraded flag set | Very short / poor-input edge case |
| `79757DD6-0363-49BD-A8B1-786306FB86B0` | `m4aRecovery` | durable `mic.m4a` + `system.m4a` | Good long-form workshop transcript | Mixed, but usable | Present, 120 diarization segments | Recovery path quality differs from raw fast-path |

## Problem Classes From Baseline

### Bad input audio

- Historical `m4aRecovery` sessions prove that some quality assessments were taken on AAC-reencoded durable files, not raw PCM.
- The backend previously had no structured diagnostics telling us sample rate, channel count, or source file kind at the consumer boundary.
- The loader also blindly averaged multichannel audio, which is unsafe for stereo inputs with channel imbalance or phase inversion.

### Bad segmentation / VAD

- Current VAD normalization used exact detector boundaries with no padding and no merge step.
- That makes phrase edges easy to clip and turns short pauses into unnecessary ASR restarts.

### Bad chunking

- Long-form sessions show chunking asymmetry: system audio often produces multiple usable chunks while mic audio can collapse into one large block.
- The 30-second fallback windows had no overlap, which risks boundary truncation when VAD is unavailable or poor.

### Bad diarization baseline

- `FCAE6D3D-1870-4207-A530-03AD66E51EFE` is the clearest current failure case: mic ASR exists, system diarization degrades, system ASR never materializes.
- This should be treated as a diarization-input-path problem first, not as a pipeline/orchestration problem.

## Batch 1 Implementation Notes

### Task 2: ASR input preparation

Changed `FluidAudioSessionAudioLoader` to:

- capture structured diagnostics for:
  - source file kind
  - original sample rate
  - original channel count
  - applied downmix strategy
- log those diagnostics when audio is loaded
- replace unconditional stereo averaging with a safer policy:
  - pass through mono unchanged
  - prefer the dominant channel when channels are strongly anti-correlated or one channel clearly dominates
  - use average only when multichannel content looks safe to mix

Validated root cause with a synthetic regression:

- a stereo input with phase-inverted channels previously collapsed toward silence under averaging
- after the boundary fix, the loader preserves the dominant channel instead of canceling it

### Task 3: ASR segmentation and chunking

Changed `FluidAudioTranscriptionService` to:

- pad VAD regions before ASR
- enforce a minimum speech window
- merge close speech regions
- fall back out of obviously fragmented VAD output
- add overlap between fallback 30-second windows

Validated with regressions for:

- merging close VAD regions into one ASR call
- overlapping fallback windows so the second window starts before the hard `30_000 ms` boundary

## Verification

Baseline before changes:

- `xcodebuild test -scheme Recordly -destination 'platform=macOS' -only-testing:RecordlyTests/FluidAudioASREngineTests -only-testing:RecordlyTests/FluidAudioSystemChunkTranscriptionEngineTests -only-testing:RecordlyTests/TranscriptionPipelineTests ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
- Result: 50 tests, 0 failures

Targeted regression after changes:

- `xcodebuild test -scheme Recordly -destination 'platform=macOS' -only-testing:RecordlyTests/FluidAudioASREngineTests ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
- Result: 22 tests, 0 failures

## Next Batch

1. Replay 2-3 problematic sessions through the updated backend path and record before/after transcript snippets.
2. Improve diarization input preparation in `FluidAudioDiarizationEngine` using the same diagnostics-first approach.
3. Check whether bad diarization strongly predicts bad chunked system ASR before discussing backend switching.

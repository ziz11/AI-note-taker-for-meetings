# Recordly project status — 2026-10-10

This is the current project summary. Dated plans preserve their original decisions; their review notices explain what has shipped or been superseded. See the [documentation audit](documentation-audit-2026-10-10.md) for every Markdown file.

## Delivered implementation

| Area | Current state | Remaining limits |
|---|---|---|
| Durable audio | Separate 48 kHz mono AAC chunks, manifest, recovery sidecars, native timeline playback and explicit combined export | An unfinished active chunk may be lost on termination; power-loss durability is best effort |
| Disk allocation | Closed-chunk compaction copies and verifies bytes, without re-encoding | This does not reduce the AAC logical byte count or bulk-rewrite old sessions |
| Transcription | FluidAudio **0.17.7**, exact revision `503b4bd1bbf7220882de39fe8ae6716aae4132da`, Parakeet v3 via Core ML | No live streaming transcript; Ultra/Redux are available upstream but not selected |
| Inference memory | V2 owns 50-second windows with up to 5 seconds of context per side; PCM input at most 60 seconds | Whole-app RSS/energy and long hardware capture are not comprehensively benchmarked; legacy single-file preparation differs |
| Progress | Separate handled/total ASR and diarization counters, overall progress, failures/skips/cache reuse, UI updates coalesced to 10 Hz | Counters measure semantic windows, not physical AAC files; perceived UI responsiveness lacks a GUI benchmark |
| Speakers | Model-scoped voice matching, persistent names and rebuilt aliases within a recording | Conservative partial matching; not verified that every person has one identity throughout every meeting |
| Summaries | Disabled placeholders; Transcript opens by default; no llama.cpp/MLX invocation or template generation | Retained backend/types/settings are compatibility code; summarization is not a delivered feature |
| Standalone | Locally signed Release installed at `/Applications/Recordly.app`; launch verified after reprocessing; Xcode is unnecessary at runtime | Local certificate, not notarized distribution; native inference acceptance is Apple Silicon |

## Source and release

The delivered runtime source is `0beaacb04eb2f00984155f07fc96ec9472d3b4cf`. Release-record commit `18add9dbb9afa58b138aa344394232bd2aac9a56` added the archive and documentation. `develop` and `master` were synchronized to that release before this documentation update; the subsequent documentation commit retains the same application code and binary. `main` is not the delivery branch and has not been advanced by this work.

- [Latest standalone](../releases/standalone-2026-10-10-fluid-speakers/README.md), tag `standalone-2026-10-10-fluid-speakers`.
- App version 0.1.0, build 1; minimum macOS 15. Universal bundle (arm64/x86_64), inference verified on M3 Pro.
- ZIP: **23,927,266 bytes**; SHA-256 `b697238a613444adb002ceb32d38f565161cca629bbd5039d7c411251f44edba`.
- Executable SHA-256 `923640be9c4e429112a41a720a455ae8e41129b8f5b4e0b946a4e04b5a507b6a`.
- New SDK/default NeMo normalization explains the archive increase over the older 6,187,339-byte release. Models are separately provisioned and not inside this ZIP.

## Verification evidence

The last full source suite before this documentation-only update executed **362 tests, 0 failures, 3 skips**. Two opt-in native copied-recording/measured-voice checks then passed with no failures. The requested original recording was subsequently processed twice through the current workflow/composition; an additional native acceptance test and independent artifact audit passed.

For `7C943EA0-D956-40F2-A892-48180F282668`:

- All **87 transcript segments** and all saved identities/aliases matched on the repeat, including text, speaker IDs, labels and timing.
- Three voice profiles were reused across **19, 7 and 2 distinct inference windows**. These are model matches, not verified human identities.
- **15 of 35 system-channel transcript segments** have session voice IDs; **20 remain local or unknown**. Result: `partiallyMatched`. Nine stored profiles do not establish nine participants.
- There were no custom names before processing. A name assigned on an isolated copy survived for all **11 segments** of the selected speaker and appeared in JSON/TXT/SRT. The original has no test name.
- All **48 AAC files** retained their SHA-256. After reopening the installed standalone, transcript JSON/TXT/SRT and speaker-identities JSON remained byte-identical.
- GUI automation permission was unavailable. Processing used the current published application code through a temporary app-hosted acceptance harness; clicking Transcribe in the installed binary was not verified.

See [original-recording verification](recording-7C943EA0-verification.md) and [SDK/speaker verification](fluid-speaker-verification.md). Earlier copied-recording timings (185.98/53.98 seconds) and the actual-recording run (235.56/53.54 seconds) describe different runs; they are not a controlled benchmark.

## Next priorities

1. Improve meeting-wide speaker continuity, with annotated real recordings to measure false splits, false merges and speaker changes. Repeatable IDs alone do not prove voice accuracy.
2. Measure GUI responsiveness, full-app memory and capture energy/long-session behavior on the target Mac.
3. Keep summaries disabled until a separate, tested redesign is approved. Adding a model does not enable generation.
4. Treat notarized distribution and alternate ASR model selection as separate future work.

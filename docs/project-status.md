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
| Speakers | Model-scoped voice matching, fragmented-turn aggregation, timed speaker changes, shared boundary links and persistent names | Conservative partial matching; not verified that every person has one identity throughout every meeting |
| Summaries | Disabled placeholders; Transcript opens by default; no llama.cpp/MLX invocation or template generation | Retained backend/types/settings are compatibility code; summarization is not a delivered feature |
| Standalone | Locally signed Release installed at `/Applications/Recordly.app`; launch verified after reprocessing; Xcode is unnecessary at runtime | Local certificate, not notarized distribution; native inference acceptance is Apple Silicon |

## Source and release

The delivered runtime source is `5268b03c1f59bb198a6cea649aa92a6febaa3289`. The subsequent release-record commit adds the standalone archive and final documentation without changing compiled application code. `develop` and `master` receive this final delivery together. `main` is not the delivery branch and has not been advanced by this work.

- [Latest standalone](../releases/standalone-2026-10-10-speaker-alignment/README.md), tag `standalone-2026-10-10-speaker-alignment`.
- App version 0.1.0, build 1; minimum macOS 15. Universal bundle (arm64/x86_64), inference verified on M3 Pro.
- ZIP: **23,975,751 bytes**; SHA-256 `48b97bf8779b137d3531c848549e67a11ab17ed20e626d677687a6624e725488`.
- Executable SHA-256 `00df5f4662ce07aa120f35eb1bb52d822ec11daa5a45ed46e32d5e071c547630`.
- Locally signed bundle installed and launched at `/Applications/Recordly.app`; signature and running executable path/hash verified. Opening the app left transcript/identity/session files byte-identical.
- Previous releases remain available for rollback. Models and recordings are outside the application ZIP.

## Verification evidence

The final source suite executed **368 tests, 0 failures, 3 optional skips**. A native copied-recording test passed, then the final original-recording/repeat/name-copy acceptance passed; independent saved-artifact audit passed too. Regression tests failed before their corresponding fixes.

For `7C943EA0-D956-40F2-A892-48180F282668`:

- The old result had 20 of 35 remote segments without session IDs. The principal cause was whole-ASR-phrase alignment against a single diarization turn; fragmented same-voice turns and multiple speakers were not handled correctly.
- After correction, **16 of the 20 original problem windows** contain session-attributed speech; **31 of the original 35 system windows** contain it overall. These are window-presence counts, not a claim that all text in those windows is resolved.
- **4,193 of 4,444 remote tokens (94.35%)** now have session voice IDs, compared with 2,274 (51.17%) before. Remaining: 131 unknown and 120 local tokens. Timed text now splits at speaker changes, so event counts are not comparable with the previous 15/35 ratio.
- All **143 resulting transcript segments** and saved identities/aliases are identical on repeat. All baseline timed tokens, their times, all 172 cached ASR documents, 39 successful diarization documents and established voice IDs are preserved.
- Three profiles are reused across **20, 7 and 2 windows**. Nine profiles do not establish nine human participants; the result is still `partiallyMatched`.
- Four original problem windows lack reliable global assignment: two have no ASR/diarization temporal intersection, two have short insufficient embedding evidence. Other split phrases can contain unresolved tokens too.
- The original had no custom names. On a separate copy, a chosen name survived all **23 selected-speaker segments** and JSON/TXT/SRT. No test name was added to the original.
- All **48 AAC hashes** and original session metadata remained unchanged. A complete 282-file backup was verified before processing.
- GUI automation was unavailable. Native application pipeline/composition and installed models were invoked through a temporary opt-in harness; clicking Transcribe in the installed binary was not verified.

See [alignment analysis](speaker-transcript-alignment.md), [original-recording verification](recording-7C943EA0-verification.md), and [SDK/speaker history](fluid-speaker-verification.md). Observed in-place passes took 58.69/66.36 seconds; copy rename check took 60.45 seconds. These are not a controlled performance or annotated voice-accuracy benchmark.

## Next priorities

1. Improve meeting-wide speaker continuity, with annotated real recordings to measure false splits, false merges and speaker changes. Repeatable IDs alone do not prove voice accuracy.
2. Measure GUI responsiveness, full-app memory and capture energy/long-session behavior on the target Mac.
3. Keep summaries disabled until a separate, tested redesign is approved. Adding a model does not enable generation.
4. Treat notarized distribution and alternate ASR model selection as separate future work.

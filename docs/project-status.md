# Recordly project status — 2026-10-16

> Distribution preparation update, 20 October 2026: the confirmed public name is **Barkenson**. See the [coordination plan](plans/2026-10-20-barkenson-distribution.md) and [current application/icon integration](distribution/2026-10-20-app-icon-integration.md). The older build/test records below remain historical; they do not certify a new branded release.

This is the current project summary. Dated plans preserve their original decisions; their review notices explain what has shipped or been superseded. See the [documentation audit](documentation-audit-2026-10-10.md) for every Markdown file.

## Delivered implementation

| Area | Current state | Remaining limits |
|---|---|---|
| Durable audio | Separate 48 kHz mono AAC chunks, manifest, recovery sidecars, native timeline playback and explicit combined export | An unfinished active chunk may be lost on termination; power-loss durability is best effort |
| Disk allocation | Closed-chunk compaction copies and verifies bytes, without re-encoding | This does not reduce the AAC logical byte count or bulk-rewrite old sessions |
| Transcription | FluidAudio **0.17.7**, exact revision `503b4bd1bbf7220882de39fe8ae6716aae4132da`, Parakeet Ultra by default, selectable v3 through Core ML | No live streaming transcript; native Ultra acceptance covers a bounded excerpt, not annotated meeting-wide accuracy |
| Inference memory | V2 owns 50-second windows with up to 5 seconds of context per side; PCM input at most 60 seconds | Whole-app RSS/energy and long hardware capture are not comprehensively benchmarked; legacy single-file preparation differs |
| Progress | Separate handled/total ASR and diarization counters, overall progress, failures/skips/cache reuse, UI updates coalesced to 10 Hz | Counters measure semantic windows, not physical AAC files; complete frame/GUI benchmark remains open |
| Compute diagnostics | Tiny toolbar chip; explicit CPU+ANE ASR configuration; bounded local stage timing, process CPU/RAM, main-queue delay, thermal/Low Power Mode; 2-second background sampling stops when idle | Diarization allows GPU; no live ANE utilization, watts, energy savings or complete UI-latency benchmark |
| Speakers | Model-scoped voice matching, fragmented-turn aggregation, timed speaker changes, shared boundary links and persistent names | Conservative partial matching; not verified that every person has one identity throughout every meeting |
| Summaries | Disabled placeholders; Transcript opens by default; no llama.cpp/MLX invocation or template generation | Retained backend/types/settings are compatibility code; summarization is not a delivered feature |
| Standalone | Compute diagnostics plus minimal Models panel, Ultra + spacing Release 0.1.0 (4) installed and launched from `/Applications/Recordly.app`; Xcode is unnecessary at runtime | Local certificate, not notarized distribution; installed GUI interactions were not automated |

## Source and release

The application/test source matches `9e4bf07` (long-transcript layout fix), including the preceding diagnostics, Ultra/model selection and spacing work. These changes are consolidated as one commit after `12bf952`. Only `develop` and `main` are active delivery branches, synchronized locally and on origin. Older source hashes below are historical build evidence, not current branch heads.

Binary archives were removed from Git on 2026-10-20, including obsolete standalone tags that retained them. The `releases/` directory now contains text reports/checksums only; build output belongs in ignored `build/` or external release assets. The original local binaries and pre-cleanup history are preserved outside Git.

- [Historical standalone build 4 record](../releases/standalone-2026-10-16-performance-diagnostics/README.md). The archived build predates the final long-transcript fix; build from current source to include it. There is no binary download in the source checkout.
- App version **0.1.0, build 4**; minimum macOS 15. Universal arm64/x86_64.
- ZIP: **24,149,264 bytes**; SHA-256 `3daa4e5fa671b26af9a3c60ca0f0c937ecae0f58389877b3aeff399b6b071436`.
- Executable SHA-256 `2c66cd8038fa5420d49935c30fa43a0c3a9e965279c621c69f79515deb5c220f`; built/extracted/installed signatures and executable equality verified.
- Installed and launched at `/Applications/Recordly.app`; process path and unchanged signing requirement verified. The previous idle process was normally terminated after checking open recording/audio/model files; no forced termination.
- Previous app backed up in `build/performance-diagnostics-backup-2026-10-16/Recordly.app`; historical release binaries are retained locally outside Git. Models and recordings are outside the ZIP.

## Verification evidence

Final diagnostics source suite: **392 tests, zero failures, eight optional skips**. Separate final native diagnostics/render run: **8 tests, zero failures, zero skips**. On M3 Pro, repeated engine calls processed a 30-second Ultra excerpt in about 0.39–0.43 seconds after setup; initial cold setup took 15 seconds. Only two UI probes (21–45 ms) were captured in the later short run, so responsiveness and peak memory are not comprehensively characterized. Core ML encoder plan prefers 1,376 ANE operations, but operation counts are not live utilization or watts. Current managed v3 was missing; legacy cache inspection was not used as a substitute. No energy benchmark or complete meeting was run. See [diagnostics evidence](performance-diagnostics-2026-10-16.md).

Initial minimal-panel/model checks executed **43 tests, 0 failures, 1 optional native smoke skipped**; final settings/render refinements passed **5 tests**. Six native intrinsic-size fixtures cover dark/light ready, missing, downloading, preparing and failed states. Ready size is400×230 points; expanded custom files scroll within100points. Review found the custom-list overflow, which was fixed and re-reviewed. See the [minimal panel](compact-model-panel-2026-10-16.md).

The previous Ultra + spacing source suite executed **383 tests, 0 failures, 5 optional skips**. Final model-settings/render checks passed **4 tests**. Native installed Ultra/v3 bounded-excerpt and render acceptance passed **2 tests**, followed by a successful native timed-text reconstruction repeat. Both models preserve decoded word boundaries through the spacing fix. Ultra: 14.22 s; v3: 17.49 s on the initial 30-second excerpt, including setup. This is functional evidence, not a controlled accuracy/speed/energy comparison. Source recording data were read only by this test.

The minimal Models panel exposes real installed/downloadable Ultra/v3 choices, persistent selection, current-asset SDK progress, retry and guarded deletion. One job keeps its original model across all chunks. Diarization/voice-name semantics are unchanged. See [model selector report](ultra-model-selection-2026-10-16.md) and [separate spacing correction](transcript-spacing-fix-2026-10-16.md).

### Previous speaker-alignment acceptance — 2026-10-10

The following is evidence for the earlier v3 speaker-alignment release and saved recording. It is not a full-meeting Ultra reprocessing result.

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
2. Use the new diagnostics and target-specific Instruments profiling to measure complete GUI/frame responsiveness, peak memory and capture/processing energy over long sessions.
3. Keep summaries disabled until a separate, tested redesign is approved. Adding a model does not enable generation.
4. Treat notarized distribution as separate future work; measure Ultra/v3 accuracy on annotated meetings before claiming a quality gain.

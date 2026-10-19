# FluidAudio upgrade and session speaker verification

> Reviewed 2026-10-10. Current reference. Evidence and open acceptance limits are tracked centrally. See [current project status](project-status.md).

Date: 2026-10-10. Upstream changes and enabled features are documented in [the upgrade changelog](fluidaudio-upgrade-changelog.md).

## Environment and SDK migration

- Xcode 26.3 (17C529), Swift 6.2.4, Apple M3 Pro, macOS 26.1 (25B78).
- Application deployment target: macOS 15.0.
- FluidAudio 0.17.7, exact revision `503b4bd1bbf7220882de39fe8ae6716aae4132da`.
- SDK migration source commit: `caca628400947b97fb2ee5d3911b1402099f5e8e`.
- Dedicated package cache and DerivedData were used; the user's Xcode package checkout was not modified.
- SDK migration tests: **340 executed, 0 failures, 1 existing skip**; unsigned universal Release build succeeded. RED runs exposed canonical selection, false readiness, missing compiled markers, incomplete weights and runtime cache identity before each fix.
- Independent spec and code reviews approved the migration after correcting the SDK cache-folder distinction: `Repo.folderName` strips `-coreml`; the Hugging Face repository name is not the cache directory name.

The installed v3 model was copied to a temporary directory and provisioned through the new SDK. File hashes showed **only `JointDecisionv3.mlmodelc` was added**; all existing files were unchanged. Its weights are 12,642,764 bytes. Offline diarization assets loaded through the pinned SDK were byte-identical to the installed canonical `speaker-diarization` package.

## Native Core ML smoke test

Short clips were decoded read-only from one local recording into temporary mono 16 kHz inputs. Original recordings, transcripts and cached inference results were untouched. A temporary Swift Package Manager executable used the exact 0.17.7 sources. It disabled the optional normalization trait only in this isolated diarization harness; the Recordly application retains default NeMo normalization.

The diarizer used `OfflineDiarizerConfig.exposeChunkEmbeddings = true`. Its public `embedding256` observations were inspected, rather than assuming the reconstructed speaker database contains the same vector space.

| Input | Duration | Native processing | Result |
| --- | ---: | ---: | --- |
| Early system clip A | 55 s | 0.321 s | 9 turns, 27 embeddings, one local group |
| Different system clip C | 54.974 s | 0.330 s | 11 turns, 27 embeddings, one local group |
| Exact repeat of A | 55 s | 0.331 s | Same voice features |
| Microphone clip | 55 s | 0.254 s | 2 turns, 8 embeddings |
| Later system clip, approximately 35 minutes into the recording | 55 s | 0.366 s | 10 turns, two local speaker groups; one orphan `S-1` observation must be excluded |
| Silent system clip | 55 s | — | `noSpeechDetected`, expected degraded outcome |

All exported voice features had **256 dimensions**. Cosine similarity between normalized group averages was **0.9359** for A/C, **1.0** for the exact repeat and **0.4652** for A/microphone. The two later groups had low similarity to A (0.1115 and 0.1651); there is no annotated ground truth establishing their personal identities.

The warm model load took **0.165 s**. The six-input process took **2.00 s** overall, with **284,426,240 bytes maximum resident set size** reported by `/usr/bin/time -l`. The same tool separately reported 648,184,672 bytes peak memory footprint; these are different operating-system metrics. Initial model setup and compilation were slower, so these warm timings must not be used as a complete meeting-processing estimate.

A separate native Parakeet v3 smoke test successfully transcribed clip A: **463 output characters and 193 token timings**, without retaining transcript content in the report. Provisioning/model load took **19.363 s**, inference **0.562 s**, maximum resident set size **529,399,808 bytes**. This verifies model/API compatibility, not transcription accuracy. The isolated harness did not exercise the application's text-normalization output.

## Acceptance limits

These measurements establish that the exact SDK runs on this Mac, that voice evidence is available and that distinct/repeated observations can be tested. They do not measure meeting-wide false merges, false splits, overlap accuracy or Russian/English word error rates. Those require annotated recordings. Conservative matching and explicit unresolved groups are necessary even when all software tests pass.

No real audio or voice-vector fixture is committed to the repository. Optional native-evidence acceptance uses a local temporary JSON path.

## Initial session matching and standalone delivery (superseded coverage)

Session matching source: `cf8edc3`, with a subsequent default-root provisioning fix. The final full source suite ran **362 tests, 0 failures, 3 skips**. Skips are one pre-existing optional check and two opt-in native checks without local fixture environment variables. Independent spec and quality reviews approved the code. Regressions first exposed stale rebuild aliases, padding-only continuity counts, renames during both final publication callbacks and missing fresh-install artifact paths; all were fixed.

Voice profiles use compatible normalized 256-dimensional observations, at least 3 seconds of exclusive owned speech, a 0.80 similarity threshold and 0.08 runner-up margin. Near matches below the threshold stay unresolved; local groups are resolved as a batch and conflicting assignments are declined together. A profile retains at most eight samples plus eight compatible named anchors; there are at most 128 active profiles. Reprocessing recomputes aliases, while exact-turn local names remain stored. SDK/model changes prevent old incompatible profiles or local names from being attached automatically to new voice identities.

Native acceptance runs on an isolated copy of a 48-chunk recording, not the user's recording directory. It checks fresh processing, cache-warm processing, unchanged event IDs/times/speaker IDs, a persisted rename, final JSON names and unchanged SHA-256 for all source and copied AAC files. A separate opt-in matcher test uses measured voice observations from distinct clips, an exact repeat after a simulated 20-minute gap, and distinct groups in one later window. These are matcher checks, not annotated identity accuracy.

The original word reconciliation repeatedly normalized/scanned all selected words. The native recording supplied 12,585 timed words; the first run took 253.72 seconds and its cache-warm repeat took 84.19 seconds before optimization. The lookup now normalizes once and considers matching channel/text keys with still-overlapping time intervals. Tests preserve long overlapping intervals, replacement behavior, repeated words at distinct times and boundary reconciliation.

The final native run completed **2 tests, 0 failures, 0 skips**. Fresh processing took **185.98 seconds** and cache-warm processing **53.98 seconds** on the same Mac and recording. These observed improvements are not a controlled accuracy benchmark. The repeat reused all **172 ASR windows** and **39 successful diarization windows**, preserved transcript event IDs/times/speaker IDs and the renamed display name, and verified **all 48 original and copied AAC hashes**. Maximum materialized input was **2,880,000 frames (60 seconds)**.

The final report is explicitly `partiallyMatched`: **34 remote groups** used session identities and **53 remained local/unknown**. There were **9 voice profiles**, which must not be interpreted as nine verified people. **47 diarization range issues** were 46 `No speech detected` outcomes and one empty-segment result; no ASR range failed. Unsuccessful diarization ranges are retried on a cache-warm pass.

The processed copy used **82,502,175 logical bytes / 83,177,472 allocated bytes**, compared with **78,137,723 / 78,839,808** in the source at measurement. The window cache was **6,296,863 bytes** and identity metadata **224,743 bytes**. Additional voice/cache metadata is real storage, while unused AAC allocation remains reclaimed; no whole-session PCM or duplicate audio was retained. All private measurement files stay outside the repository.

For the installed v3 package, the missing verified `JointDecisionv3.mlmodelc` was added; SHA-256 confirmed all **23 previously installed files** unchanged. The fresh-install adapter also resolves the SDK default directory before the first download, so loaded voice evidence has an artifact path without restarting.

## Signed standalone artifact

The signed Release source is `0beaacb04eb2f00984155f07fc96ec9472d3b4cf`. [The release manifest](../releases/standalone-2026-10-10-fluid-speakers/README.md) records the archive and SHA-256. Both the built and extracted app passed `codesign --verify --deep --strict` using `Recordly Local Development`; the designated requirement is certificate-backed. The app includes the FluidAudio resource bundle and exact upstream dependency notices, and its dynamic dependencies are system libraries/frameworks.

The ZIP is **23,927,266 bytes**, SHA-256 `b697238a613444adb002ceb32d38f565161cca629bbd5039d7c411251f44edba`; the app is **53,462,686 logical bytes**. Compared with the previous 6,187,339-byte ZIP, this is a material increase from the new SDK/default NeMo static dependency. Default normalization was retained rather than silently disabled. The bundle contains arm64 and x86_64 architectures; native inference acceptance was on Apple Silicon, and macOS 15 remains the app minimum. Running the app requires no Xcode.

The previous standalone release remains tracked for rollback. User recordings and voice-vector measurements are not included in either archive.

## Initial original recording processed in place (superseded coverage)

The subsequent [original-recording verification](recording-7C943EA0-verification.md) used the current workflow/composition and installed user models. Two passes preserved all 87 full transcript segment objects and all identities/aliases. Three profiles were reused in 19, 7 and 2 distinct windows. Of 35 system-channel segments, 15 have session voice IDs and 20 remain local/unknown; this remains **partiallyMatched**, not verified full meeting-wide identity accuracy.

No custom names existed before processing. On a separate copy, an assigned name survived for all 11 segments of the selected speaker and in JSON/TXT/SRT. All 48 original AAC hashes were unchanged. The installed standalone was reopened; transcript and identity files remained byte-identical. One additional native acceptance test and an independent artifact audit passed. GUI permission was unavailable, so processing was invoked through a temporary test harness rather than a button in the installed binary.

Observed in-place timings: 235.56 seconds first pass, 53.54 seconds repeat, 53.40 seconds copy rename probe. These differ from the isolated copied-recording timings above and must not be presented as the same benchmark. App-hosted launch recovery can overlap work; no controlled full-app speed claim follows from these numbers.

## Transcript alignment follow-up

Source `5268b03` corrects the fragmented-turn/whole-phrase mapping issue and links one short shared-audio boundary turn. The SDK and embedding gates above are unchanged. Full suite: **368 tests, 0 failures, 3 optional skips**. Final original-recording/repeat/name-copy acceptance and an independent artifact audit passed. **4,193/4,444 remote tokens (94.35%)** now have session voice IDs; all cached tokens/times, established voice IDs and 48 audio hashes remain unchanged. All 143 complete output segments and identities are stable on repeat, with the copied test name preserved in 23 segments. Four original problem windows remain without reliable global assignment. See [current recording verification](recording-7C943EA0-verification.md), [alignment policy](speaker-transcript-alignment.md), and [latest standalone](../releases/standalone-2026-10-10-speaker-alignment/README.md).

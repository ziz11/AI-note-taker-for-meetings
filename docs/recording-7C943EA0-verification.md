# Original-recording verification — 2026-10-10

Recording: `7C943EA0-D956-40F2-A892-48180F282668`. Current runtime source: `5268b03`; FluidAudio **0.17.7**. [Latest standalone](../releases/standalone-2026-10-10-speaker-alignment/README.md).

## Cause and correction

The previous result had 15 of 35 system-channel segments with session voice IDs and 20 without them: 17 unknown and 3 local. Successful diarization existed for the 17 unknown windows. The assembler checked only the longest individual turn against the entire ASR phrase, losing fragmented same-voice evidence and treating multi-speaker phrases as one event.

The fix unions same-identity turns, attributes timed tokens and splits at speaker changes, fills short unambiguous same-voice pauses, and links a boundary turn seen on identical audio in adjacent padding. See [the mapping analysis](speaker-transcript-alignment.md) for gates and regression tests. Embedding thresholds remain unchanged.

## Final original-recording results

| Check | Result |
|---|---|
| Original processed | Twice; final report ready and session metadata unchanged |
| Original problem windows with a session ID after correction | **16 of 20** contain attributed speech; 4 still lack a reliable session assignment |
| Original system windows containing session-attributed text | **31 of 35** |
| Remote token coverage | **4,193 of 4,444 (94.35%)**; baseline 2,274 (51.17%) |
| Remaining tokens | 131 unknown; 120 window-local |
| New transcript segmentation | 143 total: 52 mic, 91 system; system comprises 52 session-voice, 6 local and 33 unknown events |
| Text/time preservation | Every baseline timed token retained with its exact channel, text and time; all 172 cached ASR documents unchanged |
| Successful diarization cache | All 39 documents unchanged |
| Repeat equality | All 143 complete segment objects and all identities/aliases identical |
| Established voice IDs | All previously used session voice IDs preserved |
| Cross-window reuse | Three profiles used in **20, 7 and 2** windows |
| Names | Original had no custom names; assigned name on a separate copy retained in all **23** selected-speaker segments and JSON/TXT/SRT |
| Original audio | All **48 AAC files** retained SHA-256 |
| Native checks | Copy acceptance and final in-place/repeat/name-copy acceptance each passed; independent audit passed |
| Standalone | Signed Release installed and launched in Applications; transcript/identity/session files byte-identical after launch |

The 16/20 and 31/35 counts refer to the **original windows containing attributed speech**, not a claim that every word in those windows is resolved. Event counts increased because multi-speaker phrases now split into separate events. Token coverage is directly comparable before/after; new event coverage is not comparable with the old 15/35 count.

Original passes took **58.69 / 66.36 seconds**; isolated rename probe **60.45 seconds**. Release compilation overlapped part of this run, so these times are observations rather than a controlled benchmark. A preliminary native-copy run took 117.54 seconds for its two passes and checked cached word/time equality, established IDs, repeat stability, names and audio integrity.

## Remaining uncertainty

Continuity remains **`partiallyMatched`**. The four original windows without session-attributed text are:

- `system-48000000` (ownership starts at 1,000 seconds): ASR word span and diarization do not intersect.
- `system-98400000` (2,050 seconds): the same temporal mismatch.
- `system-52800000` (1,100 seconds): only about 2.65 seconds of owned embedding-supported speech; best weighted cosine about 0.761, below the 0.80 gate and with an insufficient runner-up margin.
- `system-124800000` (2,600 seconds): about 2.40 seconds of supported speech; best weighted cosine about 0.755, below the gate.

Other split phrases can include local or unaligned tokens too. The mapper does not assign those to a neighboring person merely to improve coverage. The 9 profiles are not 9 verified participants. Diagnostics count 35 session-voice groups and 52 unresolved groups across all inference windows, including 47 no-speech/empty diarization outcomes. Those counts are not transcript-event or person counts.

This proves software-level mapping and name persistence for supported evidence. It does not prove zero false merges/splits against annotated listening. GUI automation was unavailable; the original was processed through the application's native pipeline/composition and installed models using a temporary opt-in XCTest entry point. Its source was restored before committing. The original session remained ready throughout, avoiding an app-launch recovery race.

## Data safety and local evidence

A complete 282-file backup was hash-verified before changes. Evidence is local under `/private/tmp/recordly-alignment-actual-evidence/`: `before/`, before/after hashes, first-pass JSON, `metrics.json`, and `rename-probe/`. Final run log: `/private/tmp/recordly-alignment-actual-run.log`; independent audit: `/private/tmp/recordly-alignment-audit.py`. Temporary paths may expire. No private text, audio or voice-vector fixture is committed.

The earlier `0beaacb` verification preserved 87 segments and a name on 11 copied segments but left the 20/35 speaker issue. Its historical evidence remains under `/private/tmp/recordly-actual-reprocess-2026-10-10/`; current results above supersede its coverage and delivery status.

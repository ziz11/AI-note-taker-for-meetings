# Transcript speaker alignment — 2026-10-10

The initial verification of recording `7C943EA0-D956-40F2-A892-48180F282668` found 20 of 35 system-channel transcript segments without a session voice ID. This investigation distinguishes transcript alignment from voice-profile recognition.

## Root cause

Seventeen segments were `remote_unknown` even though their windows had successful diarization. The assembler compared a whole ASR phrase with the longest single diarization turn and required 25% coverage. Several shorter turns of the same voice were not combined; pauses made the longest turn insufficient. A phrase containing multiple voices was also assigned as one transcript event rather than split using word timing.

Of these seventeen, two had no temporal intersection with diarized speech. Those cannot be attributed from the cached timestamps alone. Three additional segments had only window-local IDs because exclusive embedding-supported speech was below the 3-second voice-profile gate. One of those short turns also appears in the preceding window's padding with an established voice ID, providing direct same-audio continuity evidence.

## Corrected mapping

- Union intervals belonging to each resolved identity, without double-counting overlaps. Single-identity phrases retain the 25% aggregate coverage gate.
- Attribute timed tokens individually and split at identity changes. Preserve every token, its time and cross-window reconciliation behavior.
- Fill gaps of at most 2 seconds between confirmed words of the same identity only when no different diarized voice intersects the gap. Voice transitions and overlaps remain unresolved.
- Leave untimed multi-voice phrases and completely unaligned speech unknown rather than assign a majority voice to all text.
- Compare mutually unique turns in adjacent padded windows on the exact shared audio interval. Require at least 750 ms shared speech, at least 80% overlap against the larger turn coverage, compatible SDK/model space and matching committed audio hashes.
- Link owned local groups to established session voices only. Reject conflicting destinations, collisions between distinct owned groups and incompatible custom names. Short turns do not create or update voice profiles through this path.
- Transfer a compatible local custom name to the shared identity atomically with mapping publication. Clear its retired local copy so subsequent edits or name removal are not overridden during rebuild.

Voice embedding thresholds remain **0.80 similarity / 0.08 margin / 3 seconds exclusive speech**. No forced match, SDK change, PCM storage migration or new neural inference is required for the mapping correction. Existing window cache and embedding provenance remain valid; output alignment is rebuilt and its policy is recorded in report diagnostics.

## Verification

Six synthetic regressions exercise fragmented turns, A/B/A changes, untimed ambiguity and non-overlap, shared boundary speech with a rename, incompatible audio / owned-group collisions, and short same-voice pauses. Failing runs were observed before implementing the corresponding behavior. The full suite executed **368 tests, 0 failures, 3 opt-in skips**.

The opt-in native copy test additionally supports exact comparison of cached tokens/times and preservation of established voice IDs. Private audio and embeddings are not committed. Current original-recording results and acceptance limits are in [recording verification](recording-7C943EA0-verification.md); current delivery is tracked in [project status](project-status.md).

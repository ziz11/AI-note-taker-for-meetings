# Closed AAC allocation reclamation

> Reviewed 2026-10-10. Delivered allocation fix; original measurements are retained separately from later inference-metadata growth. See [current project status](project-status.md).

## Observed issue

Finder showed the recording `7C943EA0-D956-40F2-A892-48180F282668` at about **78.1 MB logical / 102.1 MB on disk**. Live allocated-size measurement initially showed **78.14 MB / 97.10 MB**; cached Finder and live values can differ. The excess was in closed AAC chunks: one had 2,150,167 logical bytes but 3,153,920 allocated bytes. A verified byte copy occupied 2,150,400 bytes. The real writer's synthetic 181-second fixture reproduced the excess allocation after close.

## Delivered fix

After validation/close, background publication reclaims excess allocation above **64 KiB** by copying logical bytes to a neighboring exclusive temporary file. It uses **128 KiB** buffers, preserves metadata/ACL/xattrs, synchronizes output, verifies SHA-256 and size, checks original identity/size/timestamps, and atomically installs the copy. Audio is not re-encoded. Timeline/hash/sidecar/cache contracts remain unchanged; normal filesystem rounding does not trigger a rewrite. A failed optional compaction preserves the original and records a diagnostic.

Interrupted copy cleanup affects only regular files in the owned UUID namespace and expected track directories; directories, symlinks and unrelated files survive. This does not add a directory-fsync power-loss guarantee. Old recordings are not bulk-rewritten merely by opening them.

## Original recording repair

The ready session contained 48 committed audio segments and had no open audio handles. A temporary tool compiled the production helper, verified all manifest hashes before and after repair, and confirmed session/manifest bytes unchanged.

| Measurement | Before repair | After repair |
|---|---:|---:|
| Logical bytes | 78,137,723 | 78,137,723 |
| Allocated bytes | 97,087,488 | 79,286,272 |
| Files | 282 | 282 |

**23 files compacted; 17,801,216 bytes reclaimed** (17.80 decimal MB). Remaining folder allocation overhead was approximately 1.47%. These are measurements of that repair, not a codec compression benchmark. Later SDK processing legitimately adds voice/cache metadata, so this table is not a promise of the folder's current total byte count.

## Verification and current delivery

- RED: the actual AAC writer failed the closed-file allocation bound twice.
- GREEN: allocation bound, unchanged bytes/mtime/permissions, idempotence, write-failure preservation, xattrs and owned-temp cleanup. Existing waveform/timeline/playback/crash/recovery/backlog checks passed.
- Historical implementation suite: **331 tests, 0 failures, 1 skip**. Current delivered source suite: **362 tests, 0 failures, 3 skips**.
- Crash fixture replaced a blocking Foundation wait with bounded asynchronous process checks.
- Local historical measurements: `/private/tmp/recordly-allocation-before.json` and `/private/tmp/recordly-allocation-repair.json`; temporary paths may expire.

The fix is in the installed [FluidAudio/session-speakers standalone](../releases/standalone-2026-10-10-fluid-speakers/README.md). Subsequent [original-recording reprocessing](recording-7C943EA0-verification.md) preserved all 48 AAC hashes. See [project status](project-status.md) for current source/delivery and remaining validation.

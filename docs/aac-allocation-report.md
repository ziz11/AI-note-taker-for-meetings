# Closed AAC allocation reclamation

## Observed issue

The user supplied recording `7C943EA0-D956-40F2-A892-48180F282668` with Finder reporting approximately78.1MB logical/102.1MB on disk. Live `stat.st_blocks`/Foundation allocated-size measurement initially showed approximately78.14MB logical/97.10MB allocated. Finder snapshots and live values need not represent the same cached moment. The excess was concentrated in closed AAC chunks: e.g2,150,167 logicalbytes versus3,153,920 allocatedbytes. An explicit byte-copy occupied2,150,400bytes with identicalSHA256. The same issue reproduced with the actual writer's synthetic181-second fixture: roughly1.9MB logicalchunks retained2.73MB of allocatedstorage afterclose.

## Fix

At background chunk publication, after audio validation and close, reclaim excess allocation above64KiB by copying only logicalbytes into a neighboring exclusive temporary file. The implementation uses128KiB buffers, copies metadata/ACL/xattrs, synchronizes output, verifies copiedSHA256 andsize, checks the original path/inode/size/timestamps, and atomically installs the verifiedcopy. Audio is not re-encoded; frame/timeline/content-hash/sidecar/cache contracts stay unchanged. Small normal filesystem rounding does not trigger rewriting. Failed optional compaction retains the original, allows normal publication and records a diagnostic. Capture ingress does not perform the copy.

Interrupted copies have UUID names in an owned namespace. Reconciliation removes only matching regularfiles in expected trackdirectories; matching directories, symlinks and unrelated files survive. Original AAC remains intact until atomic installation. This is not a new claim of directory-fsync power-loss durability.

## Actual recording repair

The named session and capture metadata were ready and everymanifestsegment committed. Noaudiofilehandles were observed before repair. A temporary command-line tool compiled the exact productionhelper, validated all48 originalmanifesthashes beforechangingfiles, then verified all48again and checked session/manifestbytes unchanged.

| Measurement | Before | After |
|---|---:|---:|
| Logicalbytes |78,137,723|78,137,723|
| Allocatedbytes |97,087,488|79,286,272|
| Files |282|282|

23files compacted.17,801,216bytes reclaimed (17.80decimalMB); remainingfolderoverhead approximately1.47%. Noaudioencoding, transcript regeneration or speaker/cache invalidation was necessary. These are filesystem measurements of this completedrecording, not a general compression-ratio benchmark.

## Verification

- RED: actualAACwriter failed the closed-file allocation bound twice.
- GREEN: realAAC allocationbound, unchangedbytes/mtime/permissions, idempotence, failed-write sourcepreservation, owned-temp cleanup with directory/symlink preservation. Existing waveform, timeline, playback, crash/recovery and bounded-backlog checks pass. Independentreview also verified xattr preservation and cancellation leaving theoriginal intact.
- Full suite:331tests, zero failures, oneexisting skip (`/private/tmp/recordly-allocation-final-full.log`).
- Crashfixture's redundant Foundation waitUntilExit blocked after an exited child; a sampled stack confirmed theblocking call. Fixture now uses bounded asynchronous process checks without that blockingwait.
- Original/repair measurements saved in `/private/tmp/recordly-allocation-before.json` and `/private/tmp/recordly-allocation-repair.json`.

The updated signedstandaloneapp is delivered separately. Existing app instances retain their older executable until restarted. Future completedchunks use thefix automatically. Older closedrecordings are not rewritten merely by viewing them.

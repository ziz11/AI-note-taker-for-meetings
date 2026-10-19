# Recordly standalone — compute and performance diagnostics

> Historical release record only. Binary archives and obsolete standalone tags were removed from Git on 2026-10-20. Names, source hashes and checksums below describe the original local builds. Build a new app with `scripts/build-standalone-local.sh`; these records are not download links. Checksum commands apply only if you separately have the corresponding archive.

`Recordly-9ceee2e-local.zip` (historical artifact; not included in Git). **0.1.0 (4)**, installed and launched from `/Applications/Recordly.app` on 2026-10-16. Xcode is unnecessary at runtime. Models and recordings stay outside the app.

A tiny chip icon opens a 310-point panel with configured CPU + Neural Engine ASR policy, recent ASR/job speed, process CPU/RAM, main-queue delay, thermal state and Low Power Mode. Sampling runs every two seconds while active and stops when idle. Diarization still allows GPU; ANE utilization and app watts are not measured. See the [measurements and limitations](../../docs/performance-diagnostics-2026-10-16.md).

- Compiled source: `9ceee2e74457cac7cde149b447bb42d4fa6ecc54`; the following delivery commit changes only documentation/archive.
- Tag: `standalone-2026-10-16-performance-diagnostics`.
- ZIP: **24,149,264 bytes**; SHA-256 `3daa4e5fa671b26af9a3c60ca0f0c937ecae0f58389877b3aeff399b6b071436`.
- Executable SHA-256 `2c66cd8038fa5420d49935c30fa43a0c3a9e965279c621c69f79515deb5c220f`; logical app size **54,294,419 bytes**.
- Universal arm64/x86_64, minimum macOS 15.0. Speech inference verified on Apple Silicon; universal packaging does not establish Intel speech support.
- Strict deep signatures verified on built/extracted/installed copies with the persistent `Recordly Local Development` identity; executable hashes match. Signing requirement unchanged. Local certificate, not notarized distribution.
- Final complete suite: **392 tests, zero failures, eight optional skips**. Separate final diagnostics/native/render run: **8 tests, zero failures, zero skips**. Native SwiftUI fixture inspected; installed GUI clicks were not automated.
- Ultra repeated engine calls processed 30 seconds of audio in about 0.39–0.43 seconds with retained manager and warmed caches. Cold setup took about 15 seconds in an earlier run. No full-meeting, energy or GPU comparison is claimed. Current managed v3 was absent during the performance run.
- The idle previous process was normally terminated after checking its open audio/model files. Build 4 launched with verified Applications process path. No forced termination or source-recording rewrite was performed.

Verify with `shasum -a 256 -c SHA256SUMS`. Previous app backed up locally at `build/performance-diagnostics-backup-2026-10-16/Recordly.app`. [Build 3 archive](../standalone-2026-10-16-compact-model-panel/README.md) remains available. The existing minimal Models panel, Ultra/v3 choices, speaker identities, disabled summaries and audio persistence are preserved.

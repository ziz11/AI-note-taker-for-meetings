# Recordly standalone — Ultra and model selection

> Historical release record only. Binary archives and obsolete standalone tags were removed from Git on 2026-10-20. Names, source hashes and checksums below describe the original local builds. Build a new app with `scripts/build-standalone-local.sh`; these records are not download links. Checksum commands apply only if you separately have the corresponding archive.

`Recordly-d504f0f-local.zip` (historical artifact; not included in Git). Installed at `/Applications/Recordly.app` on **2026-10-16**. Xcode is unnecessary at runtime; models are provisioned separately. The existing Xcode instance was actively recording during installation, so it was left running. **Stop the recording normally, quit that instance, then open `/Applications/Recordly.app` to load this release.** A launch of this installed revision has not been verified.

## Changes

Parakeet Ultra is the default transcription model; Models offers selectable Parakeet TDT 0.6B v3 in a Spokenly-inspired table, with separate Download/Use, per-asset SDK progress and safe removal. Both use FluidAudio/Core ML with default CPU/Neural Engine placement. The release includes the transcript-spacing correction (`4783b3d`). AAC/chunk capture, speaker models/matching and disabled summaries are preserved. See [model-selection report](../../docs/ultra-model-selection-2026-10-16.md) and [spacing report](../../docs/transcript-spacing-fix-2026-10-16.md).

## Integrity and checks

- Compiled source: `d504f0fc93d0e7fff3bc5bf1c6a197968ae8856b`. Later delivery documentation/test-only changes do not alter compiled application behavior.
- Release tag: `standalone-2026-10-16-ultra-models`.
- FluidAudio **0.17.7**, revision `503b4bd1bbf7220882de39fe8ae6716aae4132da`.
- ZIP: **24,098,452 bytes**, SHA-256 `5de58ae8cc9f2c7ef8af111eb49a28ca7ec125979a5089f76b24df643a9b9137`.
- App: **54,070,307 logical bytes**. Executable SHA-256 `455c7d7fcc6359fdad3518dd38ec7050a7e31c56c4cabc344e8d8147c78925c2`.
- Universal arm64/x86_64; native inference accepted on Apple Silicon. Version 0.1.0, build 1, minimum macOS 15.
- Built, extracted and installed bundles passed strict deep signature verification with `Recordly Local Development`. Installed designated signing requirement is unchanged. This is a local release, not notarized Developer ID distribution.
- Combined suite: **383 tests, 0 failures, 5 optional skips**. Final model-settings/render checks: **4 tests, 0 failures**. Native Ultra/v3 + render acceptance: **2 tests, 0 failures**; an additional native timed-text reconstruction repeat passed.
- Ultra and v3 were run on the same temporary 30-second excerpt; private audio/transcripts are absent from Git and the ZIP. No full-meeting Ultra accuracy/energy or installed-GUI click-through benchmark was performed.

Run `shasum -a 256 -c SHA256SUMS` in this folder to verify the archive. The previous installed app is backed up locally under `build/ultra-upgrade-backup-2026-10-16/Recordly.app`; the [previous committed standalone](../standalone-2026-10-10-speaker-alignment/README.md) also remains available.

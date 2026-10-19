# Recordly standalone — minimal Models panel

> Historical release record only. Binary archives and obsolete standalone tags were removed from Git on 2026-10-20. Names, source hashes and checksums below describe the original local builds. Build a new app with `scripts/build-standalone-local.sh`; these records are not download links. Checksum commands apply only if you separately have the corresponding archive.

`Recordly-278062c-local.zip` (historical artifact; not included in Git). **0.1.0 (3)**, installed and launched from `/Applications/Recordly.app` on2026-10-16. Xcode is unnecessary at runtime. Models stay outside the app.

The Models screen is now a **400×230-point** panel with two model choices and one speaker-status row. Decorative icons, badges, catalog columns and descriptions are gone; small controls retain download, selection, removal, progress and retry. The custom-file disclosure has bounded scrolling. See the [panel and verification report](../../docs/compact-model-panel-2026-10-16.md).

- Compiled source: `278062c8f28f18a89ca30dc800139f4b896cc62b`; following delivery commit changes only docs/archive.
- Tag: `standalone-2026-10-16-compact-model-panel`.
- ZIP: **24,003,833 bytes**; SHA-256 `b8a1be89add5033b165ca274a795aa09169dd29336c23378ac1a3a2d34b189fb`.
- Executable SHA-256 `ff0158848f858fd95e5d29bc5a333ee349a92cf749a20f8b58cb6edd17168cb5`; logical app size **53,752,211 bytes**.
- Universal arm64/x86_64, minimum macOS15.0; existing FluidAudio0.17.7, Ultra default/v3 selection and transcript-spacing fixes retained. Audio/inference/storage behavior unchanged.
- Strict deep signatures verified on built/extracted/installed app using `Recordly Local Development`; executable hashes match. Signing requirement unchanged. Local certificate, not notarized distribution.
- Initial model/ASR checks: **43 tests, 0 failures, 1 optional native smoke skipped**; final settings/render checks: **5 tests, 0 failures**. Six native visual states inspected. Review issue about expanded-file overflow fixed and re-reviewed. Installed process path verified; installed GUI clicks were not automated.

Verify with `shasum -a 256 -c SHA256SUMS`. Previous installed app backed up locally at `build/compact-panel-backup-2026-10-16/Recordly.app`; [previous build2 archive](../standalone-2026-10-16-models-layout/README.md) is preserved.

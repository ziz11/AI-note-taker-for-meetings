# Recordly standalone — compact Models screen

> Historical release record only. Binary archives and obsolete standalone tags were removed from Git on 2026-10-20. Names, source hashes and checksums below describe the original local builds. Build a new app with `scripts/build-standalone-local.sh`; these records are not download links. Checksum commands apply only if you separately have the corresponding archive.

`Recordly-743f10b-local.zip` (historical artifact; not included in Git). Version **0.1.0 (2)**, installed at `/Applications/Recordly.app` on **2026-10-16**. The installed Applications binary was launched and its process path verified after the previous instance had exited. Xcode is unnecessary at runtime; models remain separate.

## Changes

Complete Models sheet relayout using the user's Spokenly reference: one compact heading, aligned Ultra/v3 catalog, consistent speaker-separation row, small text actions, progress/retry, and a muted disabled-summary footer. Ready content fits at 900×620; the default size is 1040×680. Light/dark appearances are supported. Diarization download now immediately shows busy and ignores repeated clicks until completion.

Includes the previous Ultra default/v3 selection and transcript-spacing correction. Audio chunks, ASR implementation, voice matching and disabled summarization are preserved. See the [screen report and native render](../../docs/model-settings-redesign-2026-10-16.md).

## Integrity and verification

- Compiled source: `743f10bb637a4f4b57c0877e2ea237cff31185aa`. The following archive/documentation commit does not change application code.
- Tag: `standalone-2026-10-16-models-layout`.
- ZIP: **24,087,742 bytes**, SHA-256 `5b25ddcb2a86d743e8c13d5eb9258c52f727892fcc9e0c000ad883b3f7442a75`.
- Executable SHA-256 `885cdba09e7c6bbee41a77af67d8543bf961d3cc930d7df42146bb1667d11595`; logical app bytes **54,185,379**.
- Universal arm64/x86_64, minimum macOS 15.0. Model inference remains the existing Apple Silicon FluidAudio/Core ML implementation.
- Built, extracted and installed bundles passed strict deep signature verification using `Recordly Local Development`; executable hashes match at all three locations. Designated signing requirement remains unchanged. Local certificate, not notarized Developer ID distribution.
- Targeted model-settings/ASR checks: **43 tests, 0 failures, 1 optional native smoke skipped**. Suspended download regression observed RED then GREEN. Seven native SwiftUI/AppKit visual fixtures inspected, including compact/light/loading/error cases. Read-only review: no actionable findings.
- Native inference behavior was unchanged; the earlier Ultra/v3 excerpt acceptance is historical evidence, not a new full-meeting or performance test. GUI clicks inside the installed Release were not automated; its launch/process path was verified separately.

Verify with `shasum -a 256 -c SHA256SUMS` in this folder. The previous installed app is backed up locally at `build/models-layout-backup-2026-10-16/Recordly.app`; the [prior Ultra archive](../standalone-2026-10-16-ultra-models/README.md) remains unchanged for rollback.

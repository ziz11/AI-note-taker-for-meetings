# Recordly standalone — 2026-10-10

[Download the standalone app](Recordly-409c4f0-local.zip).

This archive contains Recordly.app, built in Release configuration from source commit `409c4f09cfc5070b0292a8eb8fb5f823dcb7443c`. App version: 0.1.0 (build 1). Architectures: Apple Silicon (arm64) and Intel (x86_64).

## Included changes

- Segmented AAC capture with recovery, timeline playback and bounded inference windows.
- Stable transcription and diarization counters, overall progress and coalesced interface updates.
- Summarization controls are disabled placeholders; Transcript opens by default.
- Closed AAC chunks reclaim unused disk allocation without re-encoding audio or changing its content hashes.

## Run without Xcode

1. Download and unzip the archive.
2. Quit the currently running Recordly.
3. Move Recordly.app into Applications and open it.

The app uses the persistent `Recordly Local Development` signing identity configured on the development Mac. This is a local build, not a notarized Developer ID release for distribution to other Macs. Speech-model provisioning and macOS capture permissions still apply.

Existing recording data stays in the app's Application Support directory. New closed chunks reclaim unused allocation automatically; this release does not bulk-rewrite older recordings on launch.

## Integrity and source

- Source commit: `409c4f09cfc5070b0292a8eb8fb5f823dcb7443c`.
- Release tag: `standalone-2026-10-10` (source plus this archive and release record).
- Archive size: 6,187,339 bytes.
- SHA-256: `d0812f555bfb6566c029ea8775c4974bccb2ac2781fe5e9274ed6efedc66b836`.
- Archive contents and the extracted app passed `codesign --verify --deep --strict` on the development Mac.
- The full source test suite completed with 331 tests, zero failures and one existing skip.

The commit containing this release directory adds the archive and its release record to the source commit above. No compiled source differs between them.

To check the downloaded archive in Terminal:

```sh
shasum -a 256 Recordly-409c4f0-local.zip
```

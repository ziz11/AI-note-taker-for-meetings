# Recordly standalone — FluidAudio and session speakers

[Download the standalone app](Recordly-0beaacb-local.zip).

Built in Release from source commit `0beaacb04eb2f00984155f07fc96ec9472d3b4cf`, with FluidAudio **0.17.7** at `503b4bd1bbf7220882de39fe8ae6716aae4132da`. App version: 0.1.0 (build 1). The bundle is universal (arm64/x86_64); on-device inference is tested on Apple M3 Pro and requires the application's Apple Silicon path. Minimum app deployment target: macOS 15.

## Included changes

- Returning remote voices can share a persistent identity and display name across windows of one recording, using compatible voice evidence. Short, overlapping or ambiguous groups stay local/unknown.
- Reprocessing rebuilds mappings, retains compatible named anchors and preserves renames during final JSON/TXT/SRT publication.
- Word reconciliation searches relevant overlapping observations instead of scanning and normalizing all previous words repeatedly.
- Exact SDK model provisioning, cache compatibility and first-install artifact paths are validated. Parakeet v3 and offline diarization remain selected.
- Existing AAC capture, bounded inference, progress counters and disabled Summary controls remain included.

See [upstream changelog](../../docs/fluidaudio-upgrade-changelog.md) and [verification report](../../docs/fluid-speaker-verification.md).

## Run without Xcode

Unzip the archive, quit Recordly, move Recordly.app into Applications and open it. Runtime speech models are provisioned separately through the app; Xcode is not required to run it. Existing recordings remain in Application Support.

The persistent `Recordly Local Development` certificate signs this build for the development Mac. This is not a notarized Developer ID distribution for other Macs. Complete runtime dependency notices and the FluidAudio resource bundle are included.

## Integrity and verification

- Source commit: `0beaacb04eb2f00984155f07fc96ec9472d3b4cf`.
- Release tag: `standalone-2026-10-10-fluid-speakers`.
- Archive: **23,927,266 bytes**.
- Archive SHA-256: `b697238a613444adb002ceb32d38f565161cca629bbd5039d7c411251f44edba`.
- App logical size: **53,462,686 bytes**. Executable SHA-256: `923640be9c4e429112a41a720a455ae8e41129b8f5b4e0b946a4e04b5a507b6a`.
- Built app and extracted archive app passed `codesign --verify --deep --strict`; the designated requirement uses the persistent certificate. Dynamic dependencies are system libraries/frameworks.
- Full suite: **362 tests, 0 failures, 3 optional skips**. Native copied-recording and measured-voice acceptance: **2 tests, 0 failures**.
- Native observed first processing: **185.98 seconds**; cache-warm repeat: **53.98 seconds**, with all 48 AAC hashes unchanged. This is not an annotated speaker-accuracy benchmark.

The archive is larger than the previous 6,187,339-byte standalone because the upgraded SDK includes default NeMo normalization and its static runtime. The previous [standalone release](../standalone-2026-10-10/README.md) remains available for rollback. The release-record commit only adds this archive and documentation; compiled sources match the source commit above.

Verify the download with:

```sh
shasum -a 256 -c SHA256SUMS
```

# Barkenson 0.1.0 (5) — preview for the author and friends

Meeting recorder for Mac. Free standalone application.

## Download

Release asset: `Barkenson-0.1.0-build5-macOS.zip` (24,078,882 bytes).

SHA-256:

```text
1ee36de64e35f7750bfd621ae338347b75d6cb2582f60e03e04e76eaf71c5124
```

[Published prerelease: v0.1.0-preview.1](https://github.com/ziz11/Barkenson-Meeting-recorder-for-Mac/releases/tag/v0.1.0-preview.1). The downloaded ZIP was independently verified against the SHA-256 above. Binary archives remain outside Git.

## Requirements and installation

- macOS 15 or later. Apple Silicon is required for local transcription and speaker separation. The universal executable does not enable Intel inference.
- Download and extract the ZIP. Stop any recording, quit the previous app and keep a backup of that app and its data before replacing it. Keep one active installed copy: Barkenson and Recordly share the same bundle identifier.
- The extracted application is `Barkenson.app`. Xcode and a source checkout are not needed at runtime.
- This preview is signed with the existing **Recordly Local Development** certificate. It is **not notarised** and is not a Developer ID release. macOS may prevent or question first launch. Do not disable Gatekeeper globally or install a signing private key on a recipient's Mac. Pause and inspect any unexpected security warning before proceeding.
- Allow microphone and system audio capture through the normal macOS permission flow. Open **Models** to download and select a transcription model; speaker separation has an optional separate package. Internet access is required for downloads; inference runs locally after setup.

Existing recordings, models and preferences retain their Recordly storage paths and `com.local.Recordly` identity. The public app name and selected orange quotation-mark icon are Barkenson. No data migration, model relocation or automatic permission reset is part of this release.

## Included

- Microphone and system audio recording, playback, audio import and combined audio export.
- Local FluidAudio transcription with Parakeet Ultra or selectable v3, and partial system-track speaker labelling.
- TXT transcript export, with SRT and JSON artefacts available in the recording folder.
- Barkenson name, About/menu/permission copy, approved native typography and orange accent, and the selected The Imprint icon.
- Inactive summary controls removed; summary generation remains disabled.

## Verification and limits

The coordinator's integrated application suite passed **397 tests with 0 failures and 8 explained skips**. After the PNG-only icon update, the Release build and extracted signature were verified, and the compiled asset catalogue contained all ten icon representations. The owner confirmed local Xcode and standalone operation and closed the additional-Mac acceptance item. These owner reports are separate from automated evidence.

No guarantee is made of perfect speaker identification, meeting-wide accuracy, live transcription, general imported-file diarisation, long-session sleep/endurance behaviour or notarisation. A real Finder/Dock inspection was unavailable to coordinator automation. The website is deferred and is not part of this release.

## Provenance

The ZIP is the exact locally checked archive from source commit `15be35a`, relabelled without rebuilding or changing its bytes. The subsequent integration/report commits have identical application, test, project and packaging source. Version is **0.1.0 (5)**. The bundle contains third-party notices and excludes recordings, transcripts and model weights. Detailed evidence: [application/icon integration](https://github.com/ziz11/Barkenson-Meeting-recorder-for-Mac/blob/main/docs/distribution/2026-10-20-app-icon-integration.md).

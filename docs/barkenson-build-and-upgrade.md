# Build and upgrade Barkenson

Barkenson is the public name of the existing Recordly application. It records microphone and system audio, imports audio, transcribes locally, separates speakers, plays recordings and exports audio/transcripts. Automatic summaries remain disabled. Speaker separation is imperfect and optional.

## Build on a Mac

Use Xcode with the macOS 15 SDK or later. Native inference has been verified on Apple Silicon; an x86_64 build alone does not establish Intel model-runtime support. Keep the pinned FluidAudio 0.17.7 package; no model or algorithm change is part of this rename.

```sh
./scripts/setup-local-signing.sh  # Only when the existing identity is absent.
open Recordly.xcodeproj
```

Run the **Recordly** scheme. The Xcode project, target, Swift module, build product and executable intentionally keep their internal names. The bundle public name, window, About panel and permission descriptions use **Barkenson**. Version is 0.1.0, build 5.

To run the automated suite without signing:

```sh
xcodebuild -project Recordly.xcodeproj -scheme Recordly \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/tests CODE_SIGNING_ALLOWED=NO test
```

## Local standalone archive

```sh
./scripts/build-standalone-local.sh
```

The script builds `Recordly.app`, copies it to a temporary `Barkenson.app`, adds third-party notices, signs with the existing **Recordly Local Development** identity, verifies the signature and creates `build/standalone-local/Barkenson-<commit>-local.zip`. The executable inside Barkenson.app remains `Contents/MacOS/Recordly`. Environment overrides retain their existing `RECORDLY_*` names.

This is a local certificate build, not Developer ID distribution or notarisation. It establishes neither Gatekeeper acceptance nor first launch on another Mac. Do not describe it as a verified public release. No models, recordings or transcripts are copied into the bundle by this script. Release QA must inspect the extracted archive and record its source commit, checksum, architecture, signing requirement and exact acceptance results before publication.

## Upgrade an existing installation

1. Stop recording, wait for finalisation and quit the existing application normally. Keep a backup of the existing application and data before replacing it.
2. Build with the same signing identity as the installed version. Renaming the public app does not require recreating the certificate or resetting privacy permissions.
3. Extract the archive. Replace the old app rather than leaving two copies with the same bundle identifier. The coordinator/release engineer owns installation and publication; this task does not overwrite `/Applications`.
4. Launch Barkenson and verify that existing recordings, model readiness, active model selection and settings remain available. Check playback and export before processing a copy of an existing recording.

Compatibility invariants retained:

- Bundle identifier and preferences domain: `com.local.Recordly`.
- Local signing identity: `Recordly Local Development`; existing designated requirements must be compared on the build Mac.
- Sessions: `~/Library/Application Support/Recordly/recordings/`.
- Legacy model roots: `~/Library/Application Support/Recordly/Models/`, `/Users/Shared/RecordlyModels`, `~/models` and project-local models.
- SDK caches: `~/Library/Application Support/FluidAudio/Models/`.
- Existing preference keys, session manifests/sidecars, audio chunks, transcript, speaker identity and summary artefacts.

The welcome screen uses only a new `barkenson.welcomeSeen` flag. It may appear once after upgrading; continuing does not change installed models or model selection. Recovery prompts take priority over the welcome screen. No storage migration, automatic download, model removal or permission reset runs as part of the rename.

## First launch and troubleshooting

The welcome screen explains setup. You can continue without models and record or import audio first. Open **Models** in the sidebar or **Barkenson → Models…** (⌘,) at any time. Download a transcription model, then select it; download and selection are separate actions. The existing SDK provider reports download/preparation state, current-file progress, failures and Retry. Model downloads need an internet connection. Transcription runs locally after setup. Speaker separation has its own optional download and retry.

When recording starts, macOS may request Microphone and Screen & System Audio Recording access. Allow Barkenson in **System Settings → Privacy & Security**. If denied, enable the appropriate permission, then stop and start a new recording; follow any restart instruction macOS displays. The screen access permission is used for system audio; screen video is not saved. Under an existing grant, macOS may still show the previous Recordly label. Do not reset permissions automatically to change that label.

Missing transcription models: open Models, download, select, then retry transcription. Missing speaker models: transcription remains available with reduced speaker labelling. A failed download can be retried in Models; check the internet connection and available disk space first. Do not delete an existing recording to retry processing.

See the [fresh verification report](barkenson-app-verification.md) for exact source, checks and limitations.

## Links and deferred work

- [Source and issues](https://github.com/ziz11/AI-note-taker-for-meetings)
- [Release assets](https://github.com/ziz11/AI-note-taker-for-meetings/releases) — no specific Barkenson download is promised until an asset exists.
- [Report a problem](https://github.com/ziz11/AI-note-taker-for-meetings/issues)
- [Architecture and historical acceptance](project-status.md)

Final icon artwork is explicitly deferred pending the designer's selection; the existing icon remains. Site publication, repository renaming, notarisation, installation on another Mac, recording/sleep endurance and real microphone/system permission checks belong to release/integration acceptance. The README refresh in PR #22 is separate; its integrator should adopt this public name and build guide while retaining compatibility paths.

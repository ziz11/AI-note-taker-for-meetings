# Barkenson

**Meeting recorder for Mac.** Free, with local transcription and speaker diarisation.

Barkenson is the confirmed public name. The application uses the Barkenson display name. The source project, executable and compatibility namespaces retain Recordly to preserve existing data and settings. See the [distribution plan](docs/plans/2026-10-20-barkenson-distribution.md) and [current integration evidence](docs/distribution/2026-10-20-app-icon-integration.md). The standalone preview and [GitHub Pages website](https://ziz11.github.io/Barkenson-Meeting-recorder-for-Mac/) are published.

The application records microphone and system audio, converts speech to text, and labels speaker turns on your Mac.

Record a call, listen back to the audio and export a transcript with speaker labels. Recordings and transcripts are stored locally, and transcription and diarisation run on your device.

## Download the preview

[Download Barkenson 0.1.0 (5) for Mac](https://github.com/ziz11/Barkenson-Meeting-recorder-for-Mac/releases/download/v0.1.0-preview.1/Barkenson-0.1.0-build5-macOS.zip) · [Release notes](https://github.com/ziz11/Barkenson-Meeting-recorder-for-Mac/releases/tag/v0.1.0-preview.1)

Requires macOS 15 or later and Apple Silicon for transcription and speaker separation. This author-and-friends preview uses a local development certificate and is not notarised. Read the installation notes before opening it. Xcode is not required to run the standalone app.

## What you can do

* **Record both sides of a call.** Capture your microphone and the audio playing on your Mac.
* **Transcribe recordings locally.** Use FluidAudio speech recognition with Parakeet Ultra or Parakeet TDT 0.6B v3.
* **Import existing audio.** Transcribe an audio file without making a new recording.
* **Follow the conversation by speaker.** Add speaker labels and names, with partial matching across a recording.
* **Listen back and export.** Play recordings in the app and export combined audio or a TXT transcript. Processing also saves SRT and JSON artefacts in the session folder.
* **Resume interrupted processing.** Reuse completed transcription windows when the audio, model and settings still match.

## Project status

Barkenson is under active development. Recording, audio import, playback and local transcription are implemented.

**Speaker identification is still being improved.** Short turns, overlapping speech and ambiguous voices can produce separate or unresolved labels. A speaker is not guaranteed to have one consistent identity throughout a meeting.

**Automatic summary generation is disabled.** Barkenson currently focuses on recording, transcription and diarisation. Any remaining summary controls are inactive placeholders.

The existing standalone packaging route uses a local signing certificate. Notarised distribution is not yet available; older build reports do not certify a new release. See the [project status](docs/project-status.md) for release details, verification evidence and remaining work.

## Requirements

* macOS 15 or later.
* Apple Silicon is required for the active speech recognition and diarisation backends. Historical native checks used an M3 Pro; the universal executable does not provide Intel speech inference.
* Microphone and Screen Recording permissions for live capture.
* An internet connection to download speech models during setup. Inference runs locally once the required models are available.
* Xcode and its command line build tools to build from source.

A paid Apple Developer account is not required for local development. Distribution to other Macs needs a tested signing and Gatekeeper policy. Developer ID signing and notarisation are the normal route for a low-friction public download; any limited non-notarised release for friends must state its trust limitations.

## Getting started

### 1. Build the app

Clone the repository:

```bash
git clone https://github.com/ziz11/Barkenson-Meeting-recorder-for-Mac.git
cd Barkenson-Meeting-recorder-for-Mac
```

Set up the persistent local signing identity:

```bash
./scripts/setup-local-signing.sh
```

The script reuses the existing `Recordly Local Development` certificate, or creates and locally trusts one if absent. Keep the existing certificate when upgrading; a new certificate with the same name is a different identity. A compatible persistent signing identity is intended to retain macOS permissions across rebuilds; an upgrade still needs a permission check, particularly if the signing identity changes.

Open `Recordly.xcodeproj` in Xcode and run the app with ⌘R.

Alternatively, build a standalone Release app and ZIP:

```bash
./scripts/build-standalone-local.sh
unzip build/standalone-local/Barkenson-YOUR_COMMIT-local.zip -d build/standalone-preview
open build/standalone-preview/Barkenson.app
```

Replace `YOUR_COMMIT` with the revision printed by the script. This build runs independently of Xcode on the build Mac. Its local certificate is intended for development, not public distribution. The [historical standalone build record](releases/standalone-2026-10-16-performance-diagnostics/README.md) documents a verified local build. Binary archives are not included in Git. See the [artifact policy](releases/README.md) for details.

### 2. Grant recording permissions

Allow Microphone access when prompted. Use Barkenson's **Open Settings** action to open the Screen Recording permission flow, then restart the app if macOS requests it.

<details>
<summary>Moving from an older ad hoc signed build</summary>

Older Debug builds used a different signing identity after each rebuild. After setting up the persistent certificate, quit all running Recordly instances and reset the obsolete permissions once:

```bash
tccutil reset Microphone com.local.Recordly
tccutil reset ScreenCapture com.local.Recordly
```

Run Barkenson again and grant both permissions. Later builds must preserve a compatible signing identity; verify that both grants remain valid after an upgrade.

To check that the certificate is available:

```bash
security find-identity -v -p codesigning | grep "Recordly Local Development"
```

If Xcode cannot find it, rerun the setup script from the same macOS user account.

</details>

### 3. Download a speech model

Open **Models** in the toolbar.

1. Download **Parakeet Ultra**, the default model, or download and select **Parakeet TDT 0.6B v3**.
2. To add remote speaker labels, also download the **FluidAudio Speaker Separation** package.
3. Start a recording or import an audio file, then run transcription.

Downloading and selecting a model are separate actions. Your selection applies to the next transcription job. Transcription can run without the speaker package, with reduced speaker labelling.

## Local storage and processing

Each recording has its own session folder containing audio, metadata and transcript artefacts:

```text
~/Library/Application Support/Recordly/recordings/<session-id>/
```

FluidAudio downloads and manages speech models separately:

```text
~/Library/Application Support/FluidAudio/Models/
```

New recordings store microphone and system audio as separate AAC chunks. Playback follows the session timeline, including known gaps. A combined audio file is created when you explicitly export it. Older single file recordings remain supported.

Transcription processes bounded audio windows and caches successful stages. If processing is interrupted or one track fails, completed work can be retained. Missing audio and failed ranges are recorded rather than silently treated as successful.

The toolbar's chip icon opens local processing diagnostics, including job speed, process CPU and memory use, and thermal state. It does not measure live Neural Engine utilisation or power consumption.

## For contributors

Barkenson separates recording workflows, audio storage, model provisioning and inference backends. The active speech recognition and diarisation backends use FluidAudio. Summary backend code remains in the repository for compatibility and development, but is disabled in the app.

Start with these references:

| Document | Contents |
| :--- | :--- |
| [Documentation index](docs/README.md) | Current references and historical notes |
| [Project status](docs/project-status.md) | Delivered features, validation limits and next priorities |
| [Architecture](ARCHITECTURE.md) | Project structure, inference stages and ownership boundaries |
| [Agent rules](AGENTS.md) | Rules for changing backends, workflows and persistence |
| [Model integration](docs/model-integration.md) | Model provisioning, resolution and runtime selection |
| [Inference context](docs/inference-context.md) | Compact reference for inference changes |
| [Audio pipeline verification](docs/audio-pipeline-v2-report.md) | Storage, recovery and validation evidence |
| [Speaker verification](docs/fluid-speaker-verification.md) | Speaker matching behaviour and known limits |
| [Performance diagnostics](docs/performance-diagnostics-2026-10-16.md) | Measurements and their limitations |
| [FluidAudio upgrade history](docs/fluidaudio-upgrade-changelog.md) | SDK changes and enabled features |

## Acknowledgements

Barkenson uses [FluidAudio](https://github.com/FluidInference/FluidAudio), developed by FluidInference, for local speech recognition and diarisation.

FluidAudio is licensed under the Apache License 2.0. See [third party licences](THIRD_PARTY_LICENSES.md) for attribution details.

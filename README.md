# Recordly

Recordly is a local-first macOS app for call capture with session-based storage and deterministic on-device post-processing.

## Current status (October 2026)

- New live recordings use compact segmented AAC storage, recovery reconciliation, native timeline playback, and explicit combined export. Existing single-file recordings remain supported.
- Import-audio flow is supported.
- Model management UI supports FluidAudio SDK-managed ASR provisioning and folder-based local models for diarization/summarization.
- Current design direction for Models settings is provider-first:
  - users download or install models
  - users select the active model per task
  - provider/runtime grouping stays explicit
- Inference architecture is backend-agnostic and stage-driven (`contracts -> runtime profile -> selector/factory -> backend modules`).
- ASR inference is FluidAudio-only in this branch. `FluidAudioASREngine` uses the FluidAudio SDK (v3, CoreML-based) through thin backend-local adapters.
- ASR model provisioning is SDK-managed via `FluidAudioASRModelProvider`. Models are downloaded and cached by the SDK, not picked from local `.bin` files.
- Legacy ASR preference keys (`selectedASRBackend`, `selectedASRLanguage`) are preserved for migration compatibility only and do not affect active runtime language/backend behavior.
- Default diarization inference is FluidAudio-based via `FluidAudioDiarizationEngine`, with degraded fallback when model/output is unavailable.
- Summarization inference is wired through llama.cpp-compatible runner (explicitly configured `llama-cli`) in `LlamaCppSummarizationEngine`. Falls back to template summary when LLM is unavailable.
- Per-stage backend switching point is localized in `DefaultInferenceComposition` + `DefaultInferenceEngineFactory`.
- Whisper / `whisper.cpp` is not part of the active ASR path in this branch.

## Reliability behavior

- If the FluidAudio diarization package is missing, transcription can still run, but remote speaker labeling degrades.
- Summarization falls back to template summary if LLM path fails.
- Successful microphone or system windows survive failure of the other track. Failed ranges and missing audio are recorded as degradation. Cancellation remains cancellation.
- Segmented inference owns 50-second intervals with up to 5 seconds of context on each side. Each temporary PCM input is at most 60 seconds. Window caches resume successful stages and validate provenance. Remote speaker continuity across windows is explicitly unresolved; local speaker renames persist independently of raw backend labels.
- Transcript rendering falls back to segment text when backend token timings look syllabified or subword-like.
- Persisted transcript/srt/json artifacts and recovery flow remain unchanged.
- Transcription/summarization flows are recoverable.

## Prerequisites

- **Summarization:** select a compatible GGUF model and save the absolute path to an existing `llama-cli` executable in Models settings. Finder launches use this saved path. A template fallback explicitly shows why inference was unavailable. Model weights and the executable are external to the app bundle.
- **Local Debug signing identity** (for Xcode Run): create the repository's persistent self-signed `Recordly Local Development` identity as described below. No Apple Developer account is required.
- **Developer ID Application certificate** (for outside-App-Store distribution): installed in Keychain Access on the build Mac.

## Build

### One-time local signing setup

Recordly's Debug configuration deliberately uses one persistent local certificate so
macOS Microphone and Screen Recording permissions survive rebuilds. Create it once:

```bash
./scripts/setup-local-signing.sh
security find-identity -v -p codesigning | grep "Recordly Local Development"
```

The script creates a self-signed code-signing identity in the current user's login
keychain and trusts it locally for Code Signing. It is idempotent, requires no paid
Apple Developer account, and is intended only for development on this Mac. Do not
use it for distribution, notarization, or the Mac App Store.

Open `Recordly.xcodeproj` and use Xcode Run (⌘R). If Xcode reports that the signing
certificate is missing, rerun the setup script from the same macOS user account.

### One-time permission migration from ad-hoc builds

Old Debug builds were ad-hoc signed, so macOS recorded each rebuilt binary as a
different identity. After installing the persistent certificate, quit every running
Recordly instance and reset only those obsolete Recordly grants once:

```bash
tccutil reset Microphone com.local.Recordly
tccutil reset ScreenCapture com.local.Recordly
```

Run Recordly from Xcode and grant Microphone access when prompted. Use Recordly's
**Grant Access** action for Screen Recording, grant it in System Settings, and restart
Recordly once if macOS requests it. Later Xcode Run builds should keep both grants;
do not remove and re-add Recordly in System Settings after every build.

To inspect the built application, copy its path from Xcode's Products group and run:

```bash
codesign -dvvv -r- "/path/from/Xcode/Recordly.app"
```

The output should show `Authority=Recordly Local Development`, and its designated
requirement must be certificate-backed rather than CDHash-only.

### Packaging

Build a locally signed Release app and ZIP without opening Xcode:

```bash
./scripts/build-standalone-local.sh
open build/standalone-local/Build/Products/Release/Recordly.app
```

The script uses the persistent `Recordly Local Development` identity and requires the Xcode command-line build tools. The resulting app runs independently of Xcode on this Mac. This local certificate does not provide Developer ID distribution or notarization. The old unsigned/distribution scripts remain disabled placeholders.

## Local models setup

1. Build and run app.
2. Open `Models` (top-right toolbar button).
3. Download the FluidAudio v3 model (one-time, SDK-managed).
4. Optionally select local model files for:
   - `Speaker Separation Model` (optional, improves remote speaker labeling)
   - `Summarization Model` (a GGUF file), plus the absolute `llama-cli` executable path
5. Start live-recording transcription, imported-audio transcription, or summarization.

Diarization and summarization models remain local-file based. Common discovery locations include:

- `/Users/Shared/RecordlyModels/diarization/diarization-enhanced-v1/`
- `/Users/Shared/RecordlyModels/summarization/example-model.gguf`
- `~/Library/Application Support/Recordly/Models/<kind>/<model-id>/`
- `~/models/<kind>/`
- `<repo>/Models/` and `<repo>/models/`

Legacy diarization `.bin` selections are not auto-migrated and degrade cleanly.

## Storage locations

- Sessions:
  - `~/Library/Application Support/Recordly/recordings/<session-id>/`
- FluidAudio models (SDK-managed):
  - `~/Library/Application Support/FluidAudio/Models/<version>/`
- Local models (diarization, summarization):
  - `~/Library/Application Support/Recordly/Models/<kind>/<model-id>/`

## Audio format decisions

- ScreenCaptureKit supplies timestamped buffers; microphone fallback uses AVAudioEngine on the same monotonic host-clock origin.
- Durable new-session storage is `audio-manifest.json` plus independent `audio/microphone/` and `audio/system/` chunks: AAC, 48 kHz, mono, 96 kbps, about 180 seconds per chunk.
- Timing uses integer frames at 48 kHz. Known capture gaps preserve elapsed time as silence. Decoder padding does not define the session timeline.
- Each chunk has a stable UUID and recovery sidecar. Finalization, validation, publication and atomic manifest persistence are separate steps. Recovery reconciles closed orphans and preserves missing/corrupt ranges.
- AVFoundation compositions play the logical timeline directly. A full mixed M4A is generated only by explicit export.
- Semantic inference windows may cross storage boundaries. Only short PCM CAF inputs are materialized; no whole-session PCM is required for V2.
- Legacy CAF/M4A and imported single-file sessions retain their existing adapters.

See [Audio Pipeline V2 verification report](docs/audio-pipeline-v2-report.md) for measured results, crash guarantees and validation limits.

## Documentation

- `docs/README.md` — index of current reference docs vs historical notes
- `ARCHITECTURE.md` — file tree, inference architecture, orchestration boundaries
- `AGENTS.md` — agent rules, ownership boundaries, change routing, extension checklists
- `docs/model-integration.md` — model resolution, local model policy, runtime selection details
- `docs/inference-context.md` — compact canonical inference context for backend changes and agent prompts
- `docs/prompts/2026-03-11-model-settings-screen-redesign.md` — current Models settings redesign brief
- `docs/research/diarization-options.md` — diarization backend research (FluidAudio, sherpa-onnx, etc.)
- `docs/plans/` — completed implementation plans (historical)

## Acknowledgments

Recordly uses [FluidAudio](https://github.com/FluidInference/FluidAudio) for on-device speech recognition.

FluidAudio is developed by FluidInference and licensed under the Apache License 2.0. See `THIRD_PARTY_LICENSES.md` for attribution details.

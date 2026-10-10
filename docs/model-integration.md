# Model Integration Notes

> Reviewed 2026-10-10. Current reference. Evidence and open acceptance limits are tracked centrally. See [current project status](project-status.md).

## Current status (October 2026)

Model management and inference runtime are split by responsibility:

- `FluidAudioASRModelProvider` handles ASR model provisioning via FluidAudio SDK (download, cache, resolve).
- `FluidAudioDiarizationModelProvider` provisions the active offline diarization package and owns its prepared manager.
- `ModelManager` retains legacy/local discovery and summary preferences/settings; these do not activate summarization.
- `DefaultInferenceRuntimeProfileSelector` resolves runtime profile (stage selection + model artifacts + params).
- `DefaultInferenceEngineFactory` routes stage/backend to concrete engines.
- `TranscriptionPipeline` and `RecordingWorkflowController` stay backend-agnostic.

Concrete backend modules:

- ASR: `FluidAudioASREngine` (FluidAudio 0.17.7, Parakeet v3, Core ML)
- Diarization: `FluidAudioDiarizationEngine` (default local path), `CliDiarizationEngine` retained for legacy runtime routing
- Summarization: disabled placeholder; retained backend code is not invoked by the workflow.

The active ASR stack in this branch is FluidAudio-only. Whisper / `whisper.cpp` local `.bin` selection is no longer part of the runtime ASR flow.
`ASRLanguage` is no longer part of active ASR runtime contracts; the runtime profile carries only model URL/backend data for ASR execution.

## Runtime selection model

Runtime selection is represented by:

- `InferenceStage`
- `InferenceBackend`
- `StageRuntimeSelection`
- `InferenceRuntimeProfile`

Default stage mapping is composed in `DefaultInferenceComposition`:

- `audioCapture -> nativeCapture`
- `asr -> fluidAudio`
- `diarization -> fluidAudio`
- `summarization -> disabled`
- `vad -> disabled`

## ASR model provisioning (FluidAudio)

ASR model management is SDK-managed, not local-file based:

- `FluidAudioASRModelProvider` resolves provisioned models from `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3/`.
- Models are downloaded via `AsrModels.downloadAndLoad(version: .v3)` which handles caching internally.
- A valid model directory contains: `parakeet_vocab.json`, `Preprocessor.mlmodelc`, `Encoder.mlmodelc`, `Decoder.mlmodelc`, `JointDecisionv3.mlmodelc`.
- `FluidAudioModelValidator` validates model directories before use.
- Missing ASR model is a hard block for transcription.

## Model resolution behavior

- ASR: resolved via `FluidAudioASRModelProvider.resolveForRuntime()`. No local file picking needed.
- Summarization: selected model IDs are persisted by model kind. Runtime profile selector reads local selection via `ModelManager`.
- Diarization: runtime profile selection only checks provider readiness; runtime engine creation is delegated to `DefaultInferenceEngineFactory` with `FluidAudioDiarizationModelProvider`.
- Missing FluidAudio diarization package degrades speaker labeling rather than blocking transcription; runtime availability reports `.degradedNoDiarization` and workflow can continue.
- Summarization controls are placeholders; no summary runtime or fallback generation is invoked.

Compatibility note:

- `ModelPreferencesStore` still normalizes legacy persisted values for `selectedASRBackend` and `selectedASRLanguage` so older installs still load cleanly.
- That compatibility layer is intentionally migration-only today and does not change active ASR runtime behavior.

Historical note:

- Some general model-management code still supports local model discovery primitives and legacy ASR preference fields.
- Those compatibility pieces should not be documented as an active Whisper runtime path unless the codebase intentionally reintroduces one.

## Local model policy (diarization, summarization)

The active FluidAudio diarizer uses the SDK-managed `~/Library/Application Support/FluidAudio/Models/speaker-diarization/` package. `Segmentation`, `FBank`, `Embedding`, `PldaRho` and finite positive `plda_psi` are validated by the provider. It exports compatible 256-dimensional voice observations and fingerprints the actual loaded artifacts.

Legacy/local discovery remains available for compatibility:

- Local model directories include:
  - `/Users/Shared/RecordlyModels/<kind>/`
  - `~/Library/Application Support/Recordly/Models/<kind>/`
- Supported extensions:
  - Diarization: model directories are legacy/local compatibility paths; default active runtime uses `FluidAudioDiarizationModelProvider`
  - Summarization: validated GGUF bytes (`.gguf`, or legacy `.bin` only when its header is actually GGUF); Whisper/GGML artifacts are excluded.
- `model-registry.json` remains for metadata/legacy install flows.

Legacy diarization `.bin` selections are not auto-converted and degrade cleanly under the FluidAudio diarization path.

## Summarization runtime

Summarization is disabled in `DefaultInferenceComposition` and the workflow. Buttons preserve the recording and do not invoke llama.cpp or MLX. The transcript tab is selected by default. Historical model preferences and backend types remain for compatibility, not as an active generation path.

## ASR audio boundary policy

New live recordings use durable segmented AAC and short semantic inference-window CAFs (at most 60 seconds). FluidAudio adapters prepare SDK PCM from these windows. Storage boundaries do not reset the transcript timeline. Legacy single-file CAF/FLAC/M4A inputs continue through existing adapters.

See [V2 baseline](audio-pipeline-v2-report.md), [native speaker verification](fluid-speaker-verification.md) and [original-recording verification](recording-7C943EA0-verification.md). Native models have run; annotated meeting-wide speaker accuracy remains unverified.

See [FluidAudio upgrade changelog](fluidaudio-upgrade-changelog.md) for upstream changes and enabled model choices.

# Model Integration Notes

## Current status (March 2026)

Model management and inference runtime are split by responsibility:

- `FluidAudioASRModelProvider` handles ASR model provisioning via FluidAudio SDK (download, cache, resolve).
- `ModelManager` handles model discovery/install/resolution/settings for diarization and summarization.
- `DefaultInferenceRuntimeProfileSelector` resolves runtime profile (stage selection + model artifacts + params).
- `DefaultInferenceEngineFactory` routes stage/backend to concrete engines.
- `TranscriptionPipeline` and `RecordingWorkflowController` stay backend-agnostic.

Concrete backend modules:

- ASR: `FluidAudioASREngine` (FluidAudio SDK v3, CoreML-based)
- Diarization: `FluidAudioDiarizationEngine` (default local path), `CliDiarizationEngine` retained for legacy runtime routing
- Summarization: `LlamaCppSummarizationEngine` (`llama-cli`)

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
- `summarization -> llamaCpp`
- `vad -> disabled`

## ASR model provisioning (FluidAudio)

ASR model management is SDK-managed, not local-file based:

- `FluidAudioASRModelProvider` resolves provisioned models from `~/Library/Application Support/FluidAudio/Models/<version>/`.
- Models are downloaded via `AsrModels.downloadAndLoad(version: .v3)` which handles caching internally.
- A valid model directory contains: `parakeet_vocab.json`, `Preprocessor.mlmodelc`, `Encoder.mlmodelc`, `Decoder.mlmodelc`, `JointDecision.mlmodelc`.
- `FluidAudioModelValidator` validates model directories before use.
- Missing ASR model is a hard block for transcription.

## Model resolution behavior

- ASR: resolved via `FluidAudioASRModelProvider.resolveForRuntime()`. No local file picking needed.
- Summarization: selected model IDs are persisted by model kind. Runtime profile selector reads local selection via `ModelManager`.
- Diarization: runtime profile selection only checks provider readiness; runtime engine creation is delegated to `DefaultInferenceEngineFactory` with `FluidAudioDiarizationModelProvider`.
- Missing FluidAudio diarization package currently blocks the default system transcription path at workflow preflight. Degraded behavior remains legacy/debug-path behavior rather than the default live path.
- Missing summarization model triggers fallback summary generation.

Compatibility note:

- `ModelPreferencesStore` still normalizes legacy persisted values for `selectedASRBackend` and `selectedASRLanguage` so older installs still load cleanly.
- That compatibility layer is intentionally migration-only today and does not change active ASR runtime behavior.

Historical note:

- Some general model-management code still supports local model discovery primitives and legacy ASR preference fields.
- Those compatibility pieces should not be documented as an active Whisper runtime path unless the codebase intentionally reintroduces one.

## Local model policy (diarization, summarization)

Diarization and summarization models remain local-file based:

- Local model directories include:
  - `/Users/Shared/RecordlyModels/<kind>/`
  - `~/Library/Application Support/Recordly/Models/<kind>/`
- Supported extensions:
  - Diarization: model directories are legacy/local compatibility paths; default active runtime uses `FluidAudioDiarizationModelProvider`
  - Summarization: `.bin`, `.gguf`
- `model-registry.json` remains for metadata/legacy install flows.

Legacy diarization `.bin` selections are not auto-converted and degrade cleanly under the FluidAudio diarization path.

## ASR audio boundary policy

- Internal capture/storage contract remains canonical PCM-in-CAF for immediate live processing, with durable per-source `m4a` persisted for recovery.
- The active FluidAudio backend path loads persisted `CAF`, `FLAC`, or per-source `m4a` artifacts and prepares SDK-ready mono Float32 PCM inside backend-local adapters.
- Do not change internal capture format to satisfy a single backend input requirement.

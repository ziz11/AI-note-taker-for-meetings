# Model Integration Notes

## Current status (March 2026)

Model management and inference runtime are split by responsibility:

- `FluidAudioModelProvider` handles ASR model provisioning via FluidAudio SDK (download, cache, resolve).
- `ModelManager` handles model discovery/install/resolution/settings for diarization and summarization.
- `DefaultInferenceRuntimeProfileSelector` resolves runtime profile (stage selection + model artifacts + params).
- `DefaultInferenceEngineFactory` routes stage/backend to concrete engines.
- `TranscriptionPipeline` and `RecordingWorkflowController` stay backend-agnostic.

Concrete backend modules:

- ASR: `FluidAudioASREngine` (FluidAudio SDK v3, CoreML-based)
- Diarization: `CliDiarizationEngine` (`diarization-main`)
- Summarization: `LlamaCppSummarizationEngine` (`llama-cli`)

The active ASR stack in this branch is FluidAudio-only. Whisper / `whisper.cpp` local `.bin` selection is no longer part of the runtime ASR flow.

## Runtime selection model

Runtime selection is represented by:

- `InferenceStage`
- `InferenceBackend`
- `StageRuntimeSelection`
- `InferenceRuntimeProfile`

Default stage mapping is composed in `DefaultInferenceComposition`:

- `audioCapture -> nativeCapture`
- `asr -> fluidAudio`
- `diarization -> cliDiarization`
- `summarization -> llamaCpp`
- `vad -> disabled`

## ASR model provisioning (FluidAudio)

ASR model management is SDK-managed, not local-file based:

- `FluidAudioModelProvider` resolves provisioned models from `~/Library/Application Support/FluidAudio/Models/<version>/`.
- Models are downloaded via `AsrModels.downloadAndLoad(version: .v3)` which handles caching internally.
- A valid model directory contains: `parakeet_vocab.json`, `Preprocessor.mlmodelc`, `Encoder.mlmodelc`, `Decoder.mlmodelc`, `JointDecision.mlmodelc`.
- `FluidAudioModelValidator` validates model directories before use.
- Missing ASR model is a hard block for transcription.

## Model resolution behavior

- ASR: resolved via `FluidAudioModelProvider.resolveForRuntime()`. No local file picking needed.
- Diarization/summarization: selected model IDs are persisted by model kind. Runtime profile selector reads selected local options and resolves model URLs via `ModelManager`.
- Missing diarization model degrades transcription path without failing transcript generation.
- Missing summarization model triggers fallback summary generation.

Historical note:

- Some general model-management code still supports local model discovery primitives and legacy ASR preference fields.
- Those compatibility pieces should not be documented as an active Whisper runtime path unless the codebase intentionally reintroduces one.

## Local model policy (diarization, summarization)

Diarization and summarization models remain local-file based:

- Local model directories include:
  - `/Users/Shared/RecordlyModels/<kind>/`
  - `~/Library/Application Support/Recordly/Models/<kind>/`
- Supported extensions:
  - Diarization: `.bin`
  - Summarization: `.bin`, `.gguf`
- `model-registry.json` remains for metadata/legacy install flows.

## ASR audio boundary policy

- Internal capture/storage contract remains canonical CAF/PCM.
- FluidAudio SDK accepts CAF files directly — no format conversion is needed at the ASR boundary.
- Do not change internal capture format to satisfy a single backend input requirement.

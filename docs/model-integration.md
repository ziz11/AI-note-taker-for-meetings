# Model Integration Notes

## Current status (March 2026)

Model management and inference runtime are now split by responsibility:

- `ModelManager` handles model discovery/install/resolution/settings only.
- `DefaultInferenceRuntimeProfileSelector` resolves runtime profile (stage selection + model artifacts + params).
- `DefaultInferenceEngineFactory` routes stage/backend to concrete engines.
- `TranscriptionPipeline` and `RecordingWorkflowController` stay backend-agnostic.

Concrete backend modules:

- ASR: `WhisperCppASREngine` (`whisper-cli`)
- Diarization: `CliDiarizationEngine` (`diarization-main`)
- Summarization: `LlamaCppSummarizationEngine` (`llama-cli`)

## Runtime selection model

Runtime selection is represented by:

- `InferenceStage`
- `InferenceBackend`
- `StageRuntimeSelection`
- `InferenceRuntimeProfile`

Default stage mapping is composed in `DefaultInferenceComposition`:

- `audioCapture -> nativeCapture`
- `asr -> whisperCpp`
- `diarization -> cliDiarization`
- `summarization -> llamaCpp`
- `vad -> disabled`

## Model resolution behavior

- Selected model IDs are persisted by model kind (`asr`, `diarization`, `summarization`).
- Runtime profile selector reads selected local options and resolves model URLs.
- Missing ASR model is a hard block for transcription.
- Missing diarization model degrades transcription path without failing transcript generation.
- Missing summarization model triggers fallback summary generation.

## Local model policy (v1)

This build is local-file based.

- Local model directories include:
  - `/Users/Shared/RecordlyModels/<kind>/`
  - `~/Library/Application Support/Recordly/Models/<kind>/`
- Supported extensions:
  - ASR / diarization: `.bin`
  - Summarization: `.bin`, `.gguf`
- `model-registry.json` remains for metadata/legacy install flows.

## ASR audio boundary policy

- Internal capture/storage contract remains canonical CAF/PCM.
- Boundary adaptation happens near ASR runner (`ProcessWhisperCppRunner.convertToWAVIfNeeded()`).
- Do not change internal capture format to satisfy a single backend input requirement.

## Extension path (FluidAudio)

To integrate FluidAudio later:

1. Add backend module(s) under `Infrastructure/Inference/Backends/FluidAudio`.
2. Add routing in `DefaultInferenceEngineFactory`.
3. Adjust stage mapping in `DefaultInferenceComposition`.

No pipeline/workflow rewrite should be required.

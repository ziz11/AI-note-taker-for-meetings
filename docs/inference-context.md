# Recordly Inference Context

Use this file as the primary context for inference-related work.

Optimized for:

- LLM prompt loading
- backend changes
- stage routing changes
- audio adaptation changes
- transcription or summarization workflow changes
- model resolution wiring

## Mental model

Recordly stores canonical session artifacts, orchestrates by stage contracts, resolves runtime via a profile, creates engines through a factory, and keeps backend-specific behavior inside backend modules.

## Architecture flow

```text
RecordlyApp
  -> DefaultInferenceComposition
    -> { InferenceRuntimeProfileSelecting + InferenceEngineFactory + AudioCaptureEngine }
      -> RecordingsStore
        -> RecordingWorkflowController
          -> TranscriptionPipeline
            -> stage contracts
              -> backend modules
```

Default local stage map:

- `audioCapture -> nativeCapture`
- `asr -> whisperCpp`
- `diarization -> cliDiarization`
- `summarization -> llamaCpp`
- `vad -> disabled`

## Ownership boundaries

Workflow and pipeline:

- `RecordingsStore`, `RecordingWorkflowController`, and `TranscriptionPipeline` own stage order, state transitions, fallback behavior, degraded behavior, artifact writing flow, and recovery behavior.
- These layers must stay backend-agnostic.
- Do not instantiate concrete backend classes here.

Runtime selection:

- `DefaultInferenceRuntimeProfileSelector` resolves `InferenceRuntimeProfile`.
- It may resolve stage selections, model artifacts, ASR language, and summarization runtime settings.
- It must not run inference, instantiate engines, or decide product fallback policy.

Factory and routing:

- `DefaultInferenceEngineFactory` owns `stage + backend -> engine`.
- It may construct concrete engines and return unsupported-backend errors.
- It must not own fallback logic, UI behavior, or recording-session state.

Model layer:

- `ModelManager` owns discovery, install state, selected model IDs, artifact resolution, and runtime settings persistence.
- It must not become an orchestration or inference-execution layer.

Backend modules:

- Backends own inference execution, backend-specific parsing, and the minimum input adaptation needed to satisfy that backend.
- Backends must not absorb global workflow policy, model discovery, or app state management.

## Stable contracts

Stage contracts in `Recordly/Infrastructure/Inference/Contracts/InferenceStageContracts.swift`:

- `AudioCaptureEngine`
- `ASREngine`
- `DiarizationEngine`
- `SummarizationEngine`
- `VoiceActivityDetectionEngine`

Runtime primitives in `Recordly/Infrastructure/Inference/Runtime/InferenceRuntimeProfile.swift`:

- `InferenceStage`
- `InferenceBackend`
- `StageRuntimeSelection`
- `InferenceModelArtifacts`
- `InferenceRuntimeProfile`

Audio boundary types in `Recordly/Infrastructure/Inference/Audio/AudioInput.swift`:

- `AudioInput`
- `PreparedAudioInput`
- `AudioInputAdapter`

Rule:

- runtime profile data is configuration, not product policy

## Canonical artifacts and persistence invariants

Live capture source of truth remains normalized PCM in CAF.

Canonical live artifacts:

- `mic.raw.caf`
- `system.raw.caf`
- `merged-call.caf`
- `merged-call.m4a`

Do not change without an explicit migration reason:

- session folder layout
- canonical artifact names
- transcript, SRT, JSON, or summary locations
- recovery semantics

Backend rule:

- adapt backend requirements to persisted artifacts more often than adapting persistence for one backend

## Audio invariants

- internal capture stays `CAF + PCM`
- if a backend needs WAV, FLAC, buffers, or another representation, adapt at the consumer boundary
- do not rewrite the capture pipeline for one backend format preference
- `whisper.cpp` is a boundary adapter, not the source of truth for capture or storage decisions

## Current behavior to preserve

Transcription pipeline:

- `TranscriptionPipeline.process(...)` receives `InferenceRuntimeProfile` and `InferenceEngineFactory`
- it resolves prepared inputs through `AudioInputAdapter`
- it requires ASR model information in the runtime profile
- it may run diarization, but diarization failure degrades speaker labeling rather than failing transcription

Artifacts written by the pipeline:

- `mic.asr.json`
- `system.asr.json`
- `system.diarization.json` when diarization succeeds
- `transcript.json`
- `transcript.txt`
- `transcript.srt`
- ASR fingerprint cache files

Summarization workflow:

- `RecordingWorkflowController.summarize(...)` resolves summarization runtime through the selector and engine through the factory
- success writes `summary.md`
- if summarization is unavailable, missing, fails, or times out, workflow falls back to a template summary

Hard failure rule:

- ASR failure is generally a hard failure for transcript generation

## Change routing

If changing backend selection:

- change `DefaultInferenceComposition`
- change `DefaultInferenceEngineFactory`
- change the relevant backend module
- do not change workflow or pipeline unless the stage contract changes

If adding preprocessing:

- add it under `Recordly/Infrastructure/Inference/Audio/` or another narrow preprocessing module
- keep it reusable and stage-boundary oriented
- do not hide reusable preprocessing inside one backend class

If adding a new stage:

- add a stable contract only if the capability is cross-backend and has product meaning
- then add runtime-selection support, factory routing, and orchestration integration
- if backend-private, keep it inside the backend module

If changing product fallback behavior:

- change workflow or pipeline
- do not move that logic into selector, factory, or backend code

If changing model discovery or settings persistence:

- change `ModelManager`
- do not turn the model layer into an execution coordinator

If changing persistence layout or artifact naming:

- require explicit migration reasoning first

## Extension checklists

New backend:

1. Confirm which stages it supports.
2. Confirm accepted input forms.
3. Confirm whether it is file-based, buffer-based, or streaming.
4. Confirm model artifact requirements.
5. Confirm failure modes.
6. Confirm whether extra preprocessing is needed.
7. Add backend module.
8. Implement relevant stage contracts.
9. Add factory routing.
10. Update composition stage mapping.

Preprocessing:

1. Confirm whether it is reusable across multiple backends.
2. Confirm timestamp or segment-alignment impact.
3. Confirm whether it helps one stage but harms another.
4. Feed prepared inputs through stage boundaries instead of mutating persistence contracts.

## Anti-patterns

Do not:

- redesign the architecture around one backend
- let selector code execute inference
- let factory code decide fallback behavior
- turn `ModelManager` into orchestration
- hide cross-backend preprocessing inside one backend
- scatter backend wiring across the app
- change storage formats for backend convenience alone
- add protocols without a real replacement or extension need

## Minimal file map

- `Recordly/App/RecordlyApp.swift`
- `Recordly/Infrastructure/Inference/Composition/DefaultInferenceComposition.swift`
- `Recordly/Infrastructure/Inference/Runtime/DefaultInferenceRuntimeProfileSelector.swift`
- `Recordly/Infrastructure/Inference/Factory/DefaultInferenceEngineFactory.swift`
- `Recordly/Infrastructure/Inference/Contracts/InferenceStageContracts.swift`
- `Recordly/Infrastructure/Inference/Audio/AudioInput.swift`
- `Recordly/Features/Recordings/Application/RecordingWorkflowController.swift`
- `Recordly/Infrastructure/Transcription/TranscriptionPipeline.swift`
- `Recordly/Infrastructure/Models/ModelManager.swift`
- `Recordly/Infrastructure/Persistence/RecordingsRepository.swift`

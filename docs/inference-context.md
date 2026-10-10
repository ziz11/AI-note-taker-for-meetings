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

This branch is FluidAudio-only for ASR. Do not search for or reintroduce `WhisperCppASREngine`, `whisper-cli`, or `CAF -> WAV` assumptions when working on the active transcription path.
Legacy ASR preference keys (`selectedASRBackend`, `selectedASRLanguage`) are preserved only for migration compatibility and do not participate in active runtime behavior.

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
- `asr -> fluidAudio`
- `diarization -> fluidAudio`
- `summarization -> llamaCpp`
- `vad -> disabled`

## Ownership boundaries

Workflow and pipeline:

- `RecordingsStore`, `RecordingWorkflowController`, and `TranscriptionPipeline` own stage order, state transitions, fallback behavior, degraded behavior, artifact writing flow, and recovery behavior.
- These layers must stay backend-agnostic.
- Do not instantiate concrete backend classes here.

Runtime selection:

- `DefaultInferenceRuntimeProfileSelector` resolves `InferenceRuntimeProfile`.
- It resolves ASR model via `FluidAudioASRModelProvider` (SDK-managed provisioning).
- It resolves summarization model artifacts via `ModelManager` and delegates diarization model readiness to `FluidAudioDiarizationModelProvider`.
- It must not run inference, instantiate engines, or decide product fallback policy.

Factory and routing:

- `DefaultInferenceEngineFactory` owns `stage + backend -> engine`.
- It may construct concrete engines and return unsupported-backend errors.
- It must not own fallback logic, UI behavior, or recording-session state.

Model layer:

- `ModelManager` owns discovery, install state, selected model IDs, artifact resolution, and runtime settings persistence for diarization and summarization.
- `FluidAudioASRModelProvider` owns ASR model provisioning (SDK-managed download/cache/resolve).
- Any legacy ASR preference fields that still exist are compatibility residue, not an active local-file Whisper path.
- Model layers must not become orchestration or inference-execution layers.
- Models settings UX should remain provider-first. Do not flatten provider-managed and local-file-backed models into one generic selector.
- Keep download/install actions separate from active-model selection in the settings surface.

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
- `InferenceRuntimeProfile` carries no ASR language field; ASR runtime behavior is backend-determined and currently effectively language-agnostic (`auto`).

Audio boundary types in `Recordly/Infrastructure/Inference/Audio/AudioInput.swift`:

- `AudioInput`
- `PreparedAudioInput`
- `AudioInputAdapter`

Rule:

- runtime profile data is configuration, not product policy

## Canonical artifacts and audio boundaries

New live sessions persist a v2 `audio-manifest.json` and independent AAC chunks with UUIDs, frame timing, gaps, hashes and recovery sidecars. Capture uses a shared monotonic host-clock origin; storage does not define inference-window boundaries.

`SessionAudioRangeReader` materializes at most 60 seconds of mono PCM for windows owning 50 seconds with 5-second context. Window stage caches validate audio, actual artifact fingerprints, backend settings and implementation versions. Successful windows survive optional-stage failure. Cancellation propagates.

Native compositions play the logical timeline; full mixed M4A is explicit export only. Old CAF/M4A and imported-file sessions retain the legacy path. Transcript/SRT/summary locations remain compatible.

Backend speaker labels are local to an inference run and window. Model-scoped 256-dimensional voice observations allow the segmented identity store to match returning remote speakers within a recording. Matching requires enough exclusive owned speech, similarity and a runner-up margin, with one-to-one local-group constraints. Insufficient or ambiguous evidence stays window-local. Reprocessing rebuilds aliases from current evidence and retains compatible named anchors; exact-turn local names remain stored. SDK/model changes invalidate incompatible evidence, so old local names are not automatically attached to new voice profiles. See `fluid-speaker-verification.md` and `fluidaudio-upgrade-changelog.md`.

## Current behavior to preserve

Transcription pipeline:

- `TranscriptionPipeline.process(...)` receives `InferenceRuntimeProfile` and `InferenceEngineFactory`
- it resolves prepared inputs through `AudioInputAdapter`
- it requires ASR model information in the runtime profile
- the active ASR contract now uses model URL only; language selection is not part of the ASR runtime input
- the active ASR engine is `FluidAudioASREngine`
- the default diarization engine is `FluidAudioDiarizationEngine`
- diarization failure degrades speaker labeling rather than failing transcription

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

Partial failure rule:

- Independent ASR tracks/windows preserve successful output with degraded ranges. Failure of every usable track remains an error. Cancellation propagates.

Transcript rendering behavior:

- `TranscriptRenderService` only trusts `segment.words` when timings look lexical enough for display reflow
- if backend token timings look syllabified or subword-like, render/export falls back to `segment.text` plus segment timing

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

UI design reference:

- `docs/prompts/2026-03-11-model-settings-screen-redesign.md`

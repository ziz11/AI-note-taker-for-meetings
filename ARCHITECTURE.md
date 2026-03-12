# Recordly Architecture

## Structure

```text
Recordly/
  App/
    ContentView.swift
    RecordlyApp.swift
  Domain/
    Recordings/
      RecordingSession.swift
  Features/
    Recordings/
      Application/
        RecordingsStore.swift
        RecordingWorkflowController.swift
        PlaybackController.swift
      Presentation/
        RecordingsViewState.swift
      Views/
        RecordingSidebarView.swift
        RecordingDetailView.swift
        RecordingRowView.swift
        RecordButton.swift
        EmptyRecordingView.swift
    Onboarding/
      ModelOnboardingCoordinator.swift
      ModelOnboardingView.swift
    Settings/
      Models/
        ModelSettingsView.swift
        ModelSettingsViewModel.swift
  Infrastructure/
    Capture/
      AudioCaptureService.swift
      SessionMergeService.swift
      DirectPCMMixService.swift
    Inference/
      Contracts/
        InferenceStageContracts.swift
      Runtime/
        InferenceRuntimeProfile.swift
        DefaultInferenceRuntimeProfileSelector.swift
      Factory/
        InferenceEngineFactory.swift
        DefaultInferenceEngineFactory.swift
      Composition/
        DefaultInferenceComposition.swift
      Audio/
        AudioInput.swift
      Backends/
        FluidAudio/
          FluidAudioASREngine.swift
          FluidAudioSessionAudioLoader.swift
          FluidAudioVADService.swift
          FluidAudioTranscriptionService.swift
          FluidAudioDiarizationEngine.swift
          FluidAudioASRModelProvider.swift
        CliDiarization/
          CliDiarizationEngine.swift
        LlamaCpp/
          LlamaCppRunner.swift
          LlamaCppSummarizationEngine.swift
    Transcription/
      TranscriptionPipeline.swift
      TranscriptMergeService.swift
      TranscriptRenderService.swift
      SystemSpeakerMappingService.swift
      Models/
        ASRDocument.swift
        DiarizationDocument.swift
        TranscriptDocument.swift
    Summarization/
      SummaryEngine.swift
      SummaryPromptBuilder.swift
      SummaryOutputParser.swift
    Models/
      ModelTypes.swift
      ModelRegistry.swift
      ModelStorage.swift
      ModelDownloader.swift
      ModelPreferencesStore.swift
      ModelManager.swift
    Persistence/
      AppPaths.swift
      RecordingsRepository.swift
```

## Inference Architecture

Inference is capability + backend-centric and split by responsibility:

- Stage contracts: `AudioCaptureEngine`, `ASREngine`, `DiarizationEngine`, `SummarizationEngine`, `VoiceActivityDetectionEngine`.
- Runtime selection: `InferenceStage`, `InferenceBackend`, `StageRuntimeSelection`, `InferenceRuntimeProfile`.
- Profile resolving: `DefaultInferenceRuntimeProfileSelector` resolves ASR model via `FluidAudioASRModelProvider` (SDK-managed provisioning), reads summarization artifacts from `ModelManager`, and checks diarization readiness through `FluidAudioDiarizationModelProvider`.
- Engine routing: `DefaultInferenceEngineFactory` creates concrete stage engines by `stage + backend`.
- Composition root: `DefaultInferenceComposition` is the single place where per-stage backend defaults are selected. In this branch the default ASR and diarization backends are `fluidAudio`.

Dependency flow:

```text
RecordlyApp
  -> DefaultInferenceComposition
    -> { InferenceRuntimeProfileSelecting + InferenceEngineFactory + AudioCaptureEngine }
      -> RecordingsStore
        -> RecordingWorkflowController
          -> TranscriptionPipeline
            -> stage contracts (backend-agnostic)
```

## Orchestration Boundaries

- `RecordingsStore` coordinates app state and injects workflow dependencies.
- `RecordingWorkflowController` owns workflow policies (degradation/fallback/timeout behavior).
- `TranscriptionPipeline` orchestrates stage execution and persistence of transcript artifacts.
- Pipeline/workflow do not instantiate concrete backends directly.

Current ASR path:

- capture/import produces canonical session audio artifacts
- runtime selector resolves the FluidAudio ASR model via `FluidAudioASRModelProvider`
- factory routes `.asr -> .fluidAudio`
- `FluidAudioASREngine` orchestrates backend-local audio loading + transcription services and produces ASR documents
- default diarization routing is `.diarization -> .fluidAudio`
- `FluidAudioDiarizationEngine` loads session audio through the same backend-local prep path and returns existing diarization documents
- transcript merge/render stages persist transcript JSON/TXT/SRT without changing session storage contracts

Fallback ownership:

- Backend implementations throw stage-specific errors.
- Selector only resolves runtime profile and artifacts.
- Factory only routes/creates engines.
- Degradation/fallback decisions remain in orchestration (`RecordingWorkflowController`, `TranscriptionPipeline`).

## Model Responsibilities

- `ModelManager` is not an orchestration center.
- `ModelManager` owns model discovery/install/resolution, and runtime settings persistence for summarization.
- `FluidAudioASRModelProvider` owns ASR model provisioning via FluidAudio SDK (download, cache, resolve).
- ASR is not resolved from user-picked Whisper `.bin` files in this branch.
- `InferenceRuntimeProfile` carries resolved artifacts and stage runtime params into pipeline execution.

## Model Settings Surface

- The Models settings screen should be organized by provider/runtime first, then by task/stage inside each provider.
- The screen must preserve two separate actions:
  - download or install a model
  - select the active model for the relevant stage
- SDK-managed models and local-file-backed models should be visually distinguished rather than merged into a single flat list.

Reference brief:

- `docs/prompts/2026-03-11-model-settings-screen-redesign.md`

## Audio Boundary

- Live capture writes temporary PCM `CAF` source tracks (`mic.raw.caf`, `system.raw.caf`) and durable AAC `m4a` source tracks (`mic.m4a`, `system.m4a`) in parallel.
- Immediate live transcription prefers source-track `CAF`; recovery and later reprocessing fall back to durable per-source `m4a`.
- Merge/render may still use `merged-call.caf` internally as a deterministic PCM intermediate.
- Backend-local FluidAudio adapters may load persisted `CAF`, `FLAC`, or per-source `m4a` session artifacts and prepare SDK-ready mono Float32 PCM at the consumer boundary.
- `AudioInput`/`AudioInputAdapter` provide boundary-level adaptation for stage engines without changing capture/storage contracts.
- `merged-call.m4a` remains preferred playback artifact for live recordings and should not become the source-track input of record for ASR/diarization.

Historical note:

- Earlier branches used Whisper / `whisper.cpp` and format-adaptation notes tied to that runtime. Those do not describe the active ASR implementation on this branch.

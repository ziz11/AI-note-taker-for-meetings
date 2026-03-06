# CallRecorderPro Architecture

## Structure

```text
CallRecorderPro/
  Infrastructure/
    Models/
      ModelTypes.swift
      ModelRegistry.swift
      ModelStorage.swift
      ModelDownloader.swift
      ModelManager.swift
```

## Model architecture

- `ModelRegistry`: loads known models from bundle JSON manifest.
- `ModelStorage`: manages install paths under Application Support and checksum validation.
- `ModelDownloader`: local-only source reader (`file://`), no network fetch in v1.
- `ModelManager`: high-level orchestration for install/remove/state/profile requirements.

## Transcription dependency injection

- `RecordingWorkflowController` calls `ModelManager.ensureRequiredModelsInstalled(...)` before transcription.
- `TranscriptionPipeline` receives resolved model URLs via `RequiredModelsResolution`.
- `WhisperCppEngine` and `SystemDiarizationService` consume model URLs through configuration objects.

## Reliability contracts

- Mutable model files are never read from app bundle.
- Incomplete/invalid installs are not treated as valid.
- Reinstall is idempotent when checksum and local artifacts are already valid.

## Current technical gap

- Real ASR inference and real diarization inference are not implemented yet.
- Current engines are placeholder implementations to validate integration contracts.

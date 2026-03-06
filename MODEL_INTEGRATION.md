# Model Integration Notes

## Current status (March 6, 2026)

Model management is wired into app flow, but ASR/diarization engines are still placeholder implementations.

- Model profile selection works (`compact`, `balanced`, `enhanced`).
- Install/remove buttons work through `ModelManager`.
- Transcription preflight checks required ASR model installation.
- `ASREngine` and `SystemDiarizationService` now receive model URL via config/DI.
- Real speech recognition and real speaker diarization are not integrated yet.

## Local-only model policy (v1)

This build supports only local model sources.

- `downloadURL` in `model-registry.json` must be `file://...`
- HTTP/HTTPS model URLs are intentionally rejected.
- Models are installed outside app bundle:
  - `~/Library/Application Support/CallRecorderPro/Models/asr/<model-id>/`
  - `~/Library/Application Support/CallRecorderPro/Models/diarization/<model-id>/`

## Install source of truth

A model is treated as installed only when all checks pass:

1. installed file exists
2. checksum file exists and matches descriptor
3. recomputed SHA-256 matches descriptor checksum

If checksum fails, installation is rejected as invalid.

## What is still placeholder

- `WhisperCppEngine.transcribe(...)` currently returns empty ASR segments.
- `PlaceholderSystemDiarizationService.diarize(...)` currently returns empty diarization segments.
- Because of this, transcript pipeline can run but transcript content quality is placeholder-level.

## How to use local models now

1. Put model files on disk (for example under `/Users/<you>/Models/CallRecorderPro/`).
2. Update `CallRecorderPro/Resources/model-registry.json` with `file://` absolute URLs.
3. Set correct `checksum` (`sha256:<hex>`), profile, and size.
4. Build and run app.
5. Install models from sidebar "Models" section.

# CallRecorderPro

CallRecorderPro is a macOS app for local call capture with session-based storage and on-device post-processing.

## Current status (March 2026)

- Capture and merge pipeline: functional.
- Model management (install/remove/profile/state): functional.
- Model source in this build: local files only (`file://` URLs in model manifest).
- Real ASR and real diarization inference: not yet integrated (placeholder services).

## Local models setup

1. Place model files on disk (outside app bundle), e.g. `/Users/<you>/Models/CallRecorderPro/`.
2. Edit `CallRecorderPro/Resources/model-registry.json`:
   - set `downloadURL` to `file:///absolute/path/to/model.bin`
   - set correct `checksum` as `sha256:<hex>`
3. Build and run app.
4. In sidebar "Models", install required profile models.
5. Start transcription.

## Storage locations

- Sessions:
  - `~/Library/Application Support/CallRecorderPro/recordings/<session-id>/`
- Installed models:
  - `~/Library/Application Support/CallRecorderPro/Models/asr/<model-id>/`
  - `~/Library/Application Support/CallRecorderPro/Models/diarization/<model-id>/`

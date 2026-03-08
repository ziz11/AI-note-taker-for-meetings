# Recordly ASR Migration Status

Completed:
- Whisper backend removed from active codebase
- FluidAudio is now the only ASR backend in this branch
- ASR model provisioning normalized to FluidAudio semantics
- ASR settings/backend/language legacy assumptions removed
- Audio boundary stabilized: session/import audio is decoded to Float32 non-interleaved PCM at the Fluid ASR boundary
- Transcript mapping/output compatibility preserved
- Migration docs updated
- Targeted test suites passing

Known limitations:
- Long recordings are still decoded into a single in-memory buffer before ASR
- No streaming transcription yet
- No forced mono/resample step before FluidAudio unless later required

Next work should be feature/stability work, not backend migration cleanup.

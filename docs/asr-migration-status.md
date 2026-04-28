# Recordly ASR Migration Status

Completed:
- Whisper backend removed from active codebase
- FluidAudio is now the only ASR backend in this branch
- ASR model provisioning normalized to FluidAudio semantics
- `ASRLanguage` removed from runtime inference contracts (`ASREngineConfiguration`, `InferenceRuntimeProfile`) and from ASR cache-key decisions
- Runtime ASR uses model URL + backend only; language is no longer an active runtime input
- `Recordly/Infrastructure/Models/ModelPreferencesStore` keeps legacy `selectedASRBackend` / `selectedASRLanguage` key normalization for migration compatibility
- Audio boundary stabilized: session/import audio is decoded to Float32 non-interleaved PCM at the Fluid ASR boundary
- Long full-input fallback is chunked into backend-local fixed windows when VAD yields no usable regions, instead of persisting one session-wide ASR segment
- Transcript rendering now rejects syllabified/subword token timings and falls back to segment text for display/export
- Transcript mapping/output compatibility preserved
- Migration docs updated
- Targeted test suites passing

Known limitations:
- Long recordings are still prepared in memory before backend-local windowing; there is still no streaming ASR path
- No streaming transcription yet
- Session audio is currently normalized to mono at the backend-local FluidAudio prep boundary; diarization resamples to 16 kHz only where the FluidAudio diarization runtime requires it

Next work should be feature/stability work, not backend migration cleanup.

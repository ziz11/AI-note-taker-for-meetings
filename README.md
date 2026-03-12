# Recordly

Recordly is a local-first macOS app for call capture with session-based storage and deterministic on-device post-processing.

## Current status (March 2026)

- Capture and merge pipeline: functional.
- Import-audio flow is supported.
- Model management UI supports FluidAudio SDK-managed ASR provisioning and folder-based local models for diarization/summarization.
- Current design direction for Models settings is provider-first:
  - users download or install models
  - users select the active model per task
  - provider/runtime grouping stays explicit
- Inference architecture is backend-agnostic and stage-driven (`contracts -> runtime profile -> selector/factory -> backend modules`).
- ASR inference is FluidAudio-only in this branch. `FluidAudioASREngine` uses the FluidAudio SDK (v3, CoreML-based) through thin backend-local adapters.
- ASR model provisioning is SDK-managed via `FluidAudioASRModelProvider`. Models are downloaded and cached by the SDK, not picked from local `.bin` files.
- Legacy ASR preference keys (`selectedASRBackend`, `selectedASRLanguage`) are preserved for migration compatibility only and do not affect active runtime language/backend behavior.
- Default diarization inference is FluidAudio-based via `FluidAudioDiarizationEngine`, with degraded fallback when model/output is unavailable.
- Summarization inference is wired through llama.cpp-compatible runner (`main`/`llama-cli`) in `LlamaCppSummarizationEngine`. Falls back to template summary when LLM is unavailable.
- Per-stage backend switching point is localized in `DefaultInferenceComposition` + `DefaultInferenceEngineFactory`.
- Whisper / `whisper.cpp` is not part of the active ASR path in this branch.

## Reliability behavior

- Default system-path transcription currently requires the FluidAudio diarization package. If it is missing, auto-transcription can fail immediately before pipeline work starts.
- Degraded diarization behavior is still available in legacy/debug-oriented paths, but it is not the default system-path behavior.
- Summarization falls back to template summary if LLM path fails.
- ASR failure is a hard failure for transcription.
- Persisted transcript/srt/json artifacts and recovery flow remain unchanged.
- Transcription/summarization flows are recoverable.

## Prerequisites

- **llama.cpp CLI binary** (for LLM summarization): `main` or `llama-cli` on `PATH` (for example from `brew install llama.cpp`). Without it, summarization falls back to template output.

## Local models setup

1. Build and run app.
2. Open `Models` (top-right toolbar button).
3. Download the FluidAudio v3 model (one-time, SDK-managed).
4. Optionally select local model files for:
   - `Speaker Separation Model` (optional, improves remote speaker labeling)
   - `Summarization Model` (used by LLM summarization when `llama-cli` is available)
5. Start live-recording transcription, imported-audio transcription, or summarization.

Diarization and summarization models remain local-file based. Common discovery locations include:

- `/Users/Shared/RecordlyModels/diarization/diarization-enhanced-v1/`
- `/Users/Shared/RecordlyModels/summarization/summarization-compact-v1.bin`
- `~/Library/Application Support/Recordly/Models/<kind>/<model-id>/`
- `~/models/<kind>/`
- `<repo>/Models/` and `<repo>/models/`

Legacy diarization `.bin` selections are not auto-migrated and degrade cleanly.

## Storage locations

- Sessions:
  - `~/Library/Application Support/Recordly/recordings/<session-id>/`
- FluidAudio models (SDK-managed):
  - `~/Library/Application Support/FluidAudio/Models/<version>/`
- Local models (diarization, summarization):
  - `~/Library/Application Support/Recordly/Models/<kind>/<model-id>/`

## Audio format decisions

- Live capture does not arrive as `.caf` or `.wav` files. `ScreenCaptureKit` delivers microphone and system audio as `CMSampleBuffer` streams.
- The app normalizes those buffers into a single internal working format before persistence: `Float32 PCM`, `48 kHz`, `mono`, non-interleaved.
- Live capture writes temporary fast-path source artifacts `mic.raw.caf` and `system.raw.caf` in parallel with durable recovery artifacts `mic.m4a` and `system.m4a`.
- `CAF` remains the internal PCM working container for immediate post-capture processing; durable per-source `m4a` files are AAC-encoded and intended for recovery and reprocessing.
- Offline merge may still use an internal `merged-call.caf` intermediate, but `merged-call.m4a` is the normal persisted playback/export artifact.
- `merged-call.m4a` is the normal playback/export artifact. Source-track routing for ASR/diarization should not depend on it.
- Temporary `CAF` source files may be cleaned up after transcription reaches a terminal state; durable `m4a` source tracks remain the restart/recovery path.
- Do not switch the internal recording pipeline to `WAV` just to satisfy a downstream tool. If a consumer requires another format, adapt at that integration boundary.

## FluidAudio audio boundary

- Immediate live processing prefers persisted `CAF` PCM source tracks when they are present and valid.
- Recovery, later reprocessing, and durable live-capture fallback use per-source `m4a` artifacts.
- The active FluidAudio path explicitly loads persisted session artifacts from `CAF`, `FLAC`, or durable per-source `m4a` and prepares mono Float32 PCM inside the backend module before SDK calls.
- Do not document or reintroduce a `CAF -> WAV -> whisper-cli` path for current ASR behavior.

## Documentation

- `ARCHITECTURE.md` — file tree, inference architecture, orchestration boundaries
- `AGENTS.md` — agent rules, ownership boundaries, change routing, extension checklists
- `docs/model-integration.md` — model resolution, local model policy, runtime selection details
- `docs/inference-context.md` — compact canonical inference context for backend changes and agent prompts
- `docs/prompts/2026-03-11-model-settings-screen-redesign.md` — current Models settings redesign brief
- `docs/research/diarization-options.md` — diarization backend research (FluidAudio, sherpa-onnx, etc.)
- `docs/plans/` — completed implementation plans (historical)

## Acknowledgments

Recordly uses [FluidAudio](https://github.com/FluidInference/FluidAudio) for on-device speech recognition.

FluidAudio is developed by FluidInference and licensed under the Apache License 2.0. See `THIRD_PARTY_LICENSES.md` for attribution details.

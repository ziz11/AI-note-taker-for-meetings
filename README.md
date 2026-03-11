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
- ASR model provisioning is SDK-managed via `FluidAudioModelProvider`. Models are downloaded and cached by the SDK, not picked from local `.bin` files.
- Legacy ASR preference keys (`selectedASRBackend`, `selectedASRLanguage`) are preserved for migration compatibility only and do not affect active runtime language/backend behavior.
- Default diarization inference is FluidAudio-based via `FluidAudioDiarizationEngine`, with degraded fallback when model/output is unavailable.
- Summarization inference is wired through llama.cpp-compatible runner (`main`/`llama-cli`) in `LlamaCppSummarizationEngine`. Falls back to template summary when LLM is unavailable.
- Per-stage backend switching point is localized in `DefaultInferenceComposition` + `DefaultInferenceEngineFactory`.
- Whisper / `whisper.cpp` is not part of the active ASR path in this branch.

## Reliability behavior

- Transcription still succeeds when diarization is unavailable (degraded speaker mapping path).
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
- Those normalized working tracks are stored as `mic.raw.caf` and `system.raw.caf`. `CAF` is the internal container; `PCM` is the actual audio format stored inside it.
- `CAF` was chosen as the internal working container because the merge pipeline, drift accounting, and frame-offset math all assume a stable PCM format. The design goal is deterministic offline processing, not end-user interoperability at this stage.
- `merged-call.caf` is an intermediate merged artifact. The app then exports `merged-call.m4a` for normal playback/export when that export succeeds.
- Do not switch the internal recording pipeline to `WAV` just to satisfy a downstream tool. If a consumer requires another format, adapt at that integration boundary.

## FluidAudio audio boundary

- Internal capture remains `CAF + PCM`.
- The active FluidAudio path explicitly loads persisted session artifacts from `CAF` or `FLAC` and prepares mono Float32 PCM inside the backend module before SDK calls.
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

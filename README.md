# Recordly

Recordly is a local-first macOS app for call capture with session-based storage and deterministic on-device post-processing.

## Current status (March 2026)

- Capture and merge pipeline: functional.
- Import-audio flow is supported.
- Model management UI is folder-based and model-kind based (ASR / diarization / summarization).
- Model source in this build: local model files in model folders (`.bin` for ASR/diarization; `.bin`/`.gguf` for summarization).
- Inference architecture is now backend-agnostic and stage-driven (`contracts -> runtime profile -> selector/factory -> backend modules`).
- ASR inference is wired through `whisper-cli` runner in `WhisperCppASREngine` with automatic CAF→WAV conversion.
- Diarization inference is CLI-based (`diarization-main`) via `CliDiarizationEngine` with degraded fallback when model/binary/output is unavailable.
- Summarization inference is wired through llama.cpp-compatible runner (`main`/`llama-cli`) in `LlamaCppSummarizationEngine`. Falls back to template summary when LLM is unavailable.
- Per-stage backend switching point is localized in `DefaultInferenceComposition` + `DefaultInferenceEngineFactory`.

## Reliability behavior

- Transcription still succeeds when diarization is unavailable (degraded speaker mapping path).
- Summarization falls back to template summary if LLM path fails.
- ASR failure is a hard failure for transcription.
- Persisted transcript/srt/json artifacts and recovery flow remain unchanged.
- Transcription/summarization flows are recoverable.

## Prerequisites

- **llama.cpp CLI binary** (for LLM summarization): `main` or `llama-cli` on `PATH` (for example from `brew install llama.cpp`). Without it, summarization falls back to template output.

## Local models setup

1. Place model files on disk (outside app bundle) under `/Users/Shared/RecordlyModels/`.
2. Build and run app.
3. Open `Models` (top-right toolbar button).
4. Select model files for:
   - `Transcription Model` (required)
   - `Speaker Separation Model` (optional)
   - `Summarization Model` (used by LLM summarization when `llama-cli` is available)
5. Start transcription or summarization.

`model-registry.json` is still kept for legacy/metadata flow and local install scripts, but active model choice in UI is now folder-based.

Current development source layout:

- `/Users/Shared/RecordlyModels/asr/asr-compact-v1.bin`
- `/Users/Shared/RecordlyModels/asr/asr-balanced-v1.bin`
- `/Users/Shared/RecordlyModels/diarization/diarization-enhanced-v1.bin`
- `/Users/Shared/RecordlyModels/summarization/summarization-compact-v1.bin`

## Storage locations

- Sessions:
  - `~/Library/Application Support/Recordly/recordings/<session-id>/`
- Installed models:
  - `~/Library/Application Support/Recordly/Models/asr/<model-id>/`
  - `~/Library/Application Support/Recordly/Models/diarization/<model-id>/`
  - `~/Library/Application Support/Recordly/Models/summarization/<model-id>/`

## Audio format decisions

- Live capture does not arrive as `.caf` or `.wav` files. `ScreenCaptureKit` delivers microphone and system audio as `CMSampleBuffer` streams.
- The app normalizes those buffers into a single internal working format before persistence: `Float32 PCM`, `48 kHz`, `mono`, non-interleaved.
- Those normalized working tracks are stored as `mic.raw.caf` and `system.raw.caf`. `CAF` is the internal container; `PCM` is the actual audio format stored inside it.
- `CAF` was chosen as the internal working container because the merge pipeline, drift accounting, and frame-offset math all assume a stable PCM format. The design goal is deterministic offline processing, not end-user interoperability at this stage.
- `merged-call.caf` is an intermediate merged artifact. The app then exports `merged-call.m4a` for normal playback/export when that export succeeds.
- Do not switch the internal recording pipeline to `WAV` just to satisfy a downstream tool. If a consumer requires another format, adapt at that integration boundary.

## Whisper / transcription boundary

- `whisper.cpp` integration is treated as a boundary adapter, not as the source of truth for capture/storage format decisions.
- Internal capture remains `CAF + PCM`. `whisper-cli` only supports `wav/flac/mp3/ogg` and silently fails on `.caf` (exit code 0, no output).
- `ProcessWhisperCppRunner.convertToWAVIfNeeded()` converts `.caf` (and any other unsupported format) to a temporary `16kHz mono WAV` via `afconvert` before invoking whisper-cli, then cleans up the temp file.
- This keeps capture, offline merge, recovery, and session asset contracts stable while satisfying tool-specific input requirements.

## Documentation

- `ARCHITECTURE.md` — file tree, inference architecture, orchestration boundaries
- `AGENTS.md` — agent rules, ownership boundaries, change routing, extension checklists
- `docs/model-integration.md` — model resolution, local model policy, runtime selection details
- `docs/inference-context.md` — compact canonical inference context for backend changes and agent prompts
- `docs/research/diarization-options.md` — diarization backend research (FluidAudio, sherpa-onnx, etc.)
- `docs/plans/` — completed implementation plans (historical)

# Recordly

Recordly is a macOS app for local call capture with session-based storage and on-device post-processing.

## Current status (March 2026)

- Capture and merge pipeline: functional.
- Model management UI is folder-based and model-kind based (ASR / diarization / summarization).
- Model source in this build: local model files in model folders (`.bin` for ASR/diarization; `.bin`/`.gguf` for summarization).
- ASR inference is wired through `whisper-cli` runner in `WhisperCppEngine` with automatic CAF→WAV conversion.
- Diarization inference is CLI-based (`diarization-main`) with degraded fallback when model/binary/output is unavailable.
- Summarization inference is wired through llama.cpp-compatible runner (`main`/`llama-cli`) in `LlamaCppSummaryEngine`. Falls back to template summary when LLM is unavailable.

## Prerequisites

- **llama.cpp CLI binary** (for LLM summarization): `main` or `llama-cli` on `PATH` (for example from `brew install llama.cpp`). Without it, summarization falls back to template output.

## Local models setup

1. Place model files on disk (outside app bundle) under `/Users/Shared/CallRecorderProModels/`.
2. Build and run app.
3. Open `Models` (top-right toolbar button).
4. Select model files for:
   - `Transcription Model` (required)
   - `Speaker Separation Model` (optional)
   - `Summarization Model` (used by LLM summarization when `llama-cli` is available)
5. Start transcription or summarization.

`model-registry.json` is still kept for legacy/metadata flow and local install scripts, but active model choice in UI is now folder-based.

Current development source layout:

- `/Users/Shared/CallRecorderProModels/asr/asr-compact-v1.bin`
- `/Users/Shared/CallRecorderProModels/asr/asr-balanced-v1.bin`
- `/Users/Shared/CallRecorderProModels/diarization/diarization-enhanced-v1.bin`
- `/Users/Shared/CallRecorderProModels/summarization/summarization-compact-v1.bin`

## Storage locations

Recordly continues to use the legacy `CallRecorderPro` storage folder names for compatibility with existing installs.

- Sessions:
  - `~/Library/Application Support/CallRecorderPro/recordings/<session-id>/`
- Installed models:
  - `~/Library/Application Support/CallRecorderPro/Models/asr/<model-id>/`
  - `~/Library/Application Support/CallRecorderPro/Models/diarization/<model-id>/`
  - `~/Library/Application Support/CallRecorderPro/Models/summarization/<model-id>/`

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

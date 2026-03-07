# Recordly Product Context

## Product summary

Recordly is a local-first macOS app for call capture and deterministic post-processing with on-device transcription pipeline stages.

## Current product behavior

- Live recording captures microphone + system audio through `ScreenCaptureKit` when permissions are granted.
- Stop action finalizes capture, then offline merge completes in background.
- Playback prefers merged output when available.
- Import-audio flow is supported.
- Transcription pipeline is stage-based and resumable.

## Audio asset contract and rationale

- Live-capture sessions are built around normalized internal PCM tracks, not around preserving source-native stream formats.
- Primary working artifacts are `mic.raw.caf` and `system.raw.caf`; these are canonical raw tracks for internal processing.
- The merged working artifact may exist as `merged-call.caf`, while normal playback/export should prefer `merged-call.m4a`.
- `CAF` is used here as an internal macOS/Core Audio working container for PCM. It was chosen for a stable offline processing pipeline, not because external ML tools prefer it.
- When external tools such as `whisper-cli` need another file type, the intended architecture is boundary conversion near that tool, not changing the session storage contract.

## Model management behavior

Recordly intentionally keeps the legacy `CallRecorderPro` model storage folder names for compatibility with existing local installs.

- Models UI is now selection-based by model kind, not profile-install based.
- Available options are loaded dynamically from local folders:
  - `/Users/Shared/CallRecorderProModels/<kind>/`
  - `~/Library/Application Support/CallRecorderPro/Models/<kind>/`
- The menu has 3 blocks:
  - Transcription model (ASR, required)
  - Speaker separation model (diarization, optional)
  - Summarization model (used by LLM summarization engine when selected)
- Selected model IDs are persisted in user defaults.

## Local-only model source (v1)

- Model installation is local-only.
- `downloadURL` must be `file://` absolute path to an existing local model file.
- Network URLs are rejected in this build.
- Development source directory currently used: `/Users/Shared/CallRecorderProModels/`

## Inference pipeline status

All three inference stages are now wired to real CLI runners:

- **ASR**: `whisper-cli` runner in `WhisperCppEngine`. Parses JSON output. CAF-to-WAV boundary conversion is handled automatically.
- **Diarization**: `diarization-main` CLI runner in `CliSystemDiarizationService`. Parses structured JSON segments. Degrades gracefully on failure (fallback speaker labels).
- **Summarization**: `llama-cli` runner in `LlamaCppSummaryEngine`. Produces structured markdown summary with Topics/Decisions/Action Items/Risks. Falls back to template-based summary on any failure (binary missing, model missing, inference error, etc.).

The summarization fallback ensures the "Summarize" action always produces a `summary.md`, even when the LLM path is unavailable.

## Readiness snapshot (March 6, 2026)

- Transcription:
  - Pipeline stages, persistence, and output rendering are implemented.
  - ASR inference is integrated via whisper.cpp runner with automatic CAF→WAV conversion at the runner boundary.
- Speaker identification:
  - Mapping logic exists (ASR segments to diarization segments by overlap).
  - Diarization inference is integrated via CLI runner; on failure it degrades to fallback labels (`Remote`) without failing transcription.
- Summary:
  - `summary.md` output is generated via `LlamaCppSummaryEngine` when a summarization model is selected and `llama-cli` is available.
  - On any LLM failure, falls back to template-based summary from transcript/SRT timeline data.
  - `summarize(recording:)` is now `async throws` — call sites in `RecordingsStore` use `await`.
  - Structured `SummaryDocument` (topics, decisions, action items, risks) is kept in-memory; `rawMarkdown` is written to `summary.md`.
  - A 415MB summarization GGUF model is staged at `/Users/Shared/CallRecorderProModels/summarization/summarization-compact-v1.bin`.
  - Requires `llama-cli` installed (e.g., `/opt/homebrew/bin/llama-cli` via `brew install llama.cpp`).

## Development model set (March 6, 2026)

Prepared local source files and verified hashes:

- `asr-compact-v1` -> `/Users/Shared/CallRecorderProModels/asr/asr-compact-v1.bin`
- `asr-balanced-v1` -> `/Users/Shared/CallRecorderProModels/asr/asr-balanced-v1.bin`
- `diarization-enhanced-v1` -> `/Users/Shared/CallRecorderProModels/diarization/diarization-enhanced-v1.bin`
- `summarization-compact-v1` -> `/Users/Shared/CallRecorderProModels/summarization/summarization-compact-v1.bin`

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
    Summarization/
      SummaryEngine.swift
      SummaryPromptBuilder.swift
      SummaryOutputParser.swift
      LlamaCppRunner.swift
      LlamaCppSummaryEngine.swift
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

## Summarization architecture

```text
SummaryEngine (protocol)
    ↑
LlamaCppSummaryEngine ──→ LlamaCppRunner (protocol) ──→ LlamaProcessExecutor (protocol)
                              ↑                              ↑
                         ProcessLlamaCppRunner      FoundationLlamaProcessExecutor
```

Supporting pure functions: `SummaryPromptBuilder` (prompt construction + context trimming), `SummaryOutputParser` (regex-based section extraction).

- `SummaryEngine` protocol defines the summarization contract: transcript + SRT + title + config → `SummaryDocument`.
- `LlamaCppSummaryEngine` orchestrates guardrails (min transcript length, model file existence, cancellation) then delegates to `LlamaCppRunner`.
- `ProcessLlamaCppRunner` writes prompt to a temp file and invokes `llama-cli` with `--file`, `--no-display-prompt`, `-n 2048`, `--temp 0.3`, `-c 4096`.
- `resolveLlamaBinaryURL()` searches Bundle resources → `/usr/local/bin` → `/opt/homebrew/bin` → `$PATH` for `llama-cli`.
- `SummaryPromptBuilder` prefers SRT (has timestamps) over plain transcript, trims to 12K characters, and requests structured markdown with `## Topics`, `## Decisions`, `## Action Items`, `## Risks`.
- `SummaryOutputParser` extracts bullet lists under each heading into `SummaryDocument` fields; stores full output in `rawMarkdown`.

## Summarization dependency injection

- `RecordingWorkflowController` accepts an optional `summaryEngine: SummaryEngine?` via init.
- `RecordingsStore` injects `LlamaCppSummaryEngine()` when constructing the workflow controller.
- `summarize(recording:)` is `async throws`. It tries the LLM engine first (when engine and summarization model are both available), then falls back to the existing template-based `composeSummary()` on any failure.
- Summarization model is resolved via `modelManager.selectedLocalOption(kind: .summarization)` — no changes to `RequiredModelsResolution`.

## Reliability contracts

- Mutable model files are never read from app bundle.
- Incomplete/invalid installs are not treated as valid.
- Reinstall is idempotent when checksum and local artifacts are already valid.

## Capture and audio pipeline

- `ScreenCaptureKit` is the primary live-capture source for both system audio and microphone audio.
- Capture input arrives as `CMSampleBuffer`, not as ready-made audio files.
- `AudioCaptureService` converts input buffers into one canonical internal working format: `Float32 PCM`, `48 kHz`, `mono`, non-interleaved.
- Canonical raw tracks are persisted as:
  - `mic.raw.caf`
  - `system.raw.caf`
- `CAF` is an internal container choice for normalized PCM working audio. It is not a product requirement that user-facing outputs be `CAF`.
- `SessionMergeService` performs offline PCM merge into `merged-call.caf`, then exports `merged-call.m4a` for normal playback when export succeeds.
- Recovery logic may temporarily surface `merged-call.caf` if the `m4a` export is missing, but `m4a` remains the preferred playback artifact.

## Audio architecture decisions

- The source of truth for recorded session audio is canonical PCM, not the filename extension.
- The system deliberately normalizes capture before merge so drift detection, frame offsets, and deterministic mixing do not depend on variable input stream formats.
- Avoid broad refactors that replace internal `CAF` working files with `WAV` unless there is a strong pipeline-level reason. A downstream tool's file-format preference alone is not sufficient reason to rewrite capture/storage contracts.
- Prefer boundary adaptation: if a downstream binary or service requires `WAV`, `FLAC`, or another consumer format, convert at that boundary rather than changing the internal recording format.

## Current technical gap

- All three inference stages (ASR, diarization, summarization) are now wired to real CLI runners.
- ASR uses `whisper-cli`, diarization uses `diarization-main`, summarization uses `llama-cli`.
- No cloud/remote inference paths exist yet.
- Quality scoring and structured summary artifact (`summary.json`) are not implemented.

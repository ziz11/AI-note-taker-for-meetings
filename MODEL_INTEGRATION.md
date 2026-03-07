# Model Integration Notes

## Current status (March 6, 2026)

Model management is wired into Recordly with dynamic local folder discovery. All three model kinds now have real inference runners.

- Model selection is done by kind (`asr`, `diarization`, `summarization`) from local folders.
- Selected model IDs are persisted and used by transcription preflight/model resolution.
- `ASREngine` and `SystemDiarizationService` receive selected model URLs via config/DI.
- ASR inference is integrated through `WhisperCppEngine` + `whisper-main` runner.
- Diarization inference is integrated via CLI runner (`diarization-main`) with typed error mapping.
- Summarization inference is integrated via `LlamaCppSummaryEngine` + llama.cpp-compatible runner (`main`/`llama-cli`). Falls back to template summary on any failure.
- Local source files are staged under `/Users/Shared/RecordlyModels/`.

## Local model policy (v1)

This build is local-file based.

Recordly intentionally keeps the legacy `Recordly` storage folder names for compatibility with existing local installs.

- UI model catalog reads local model files from:
  - `/Users/Shared/RecordlyModels/<kind>/`
  - `~/Library/Application Support/Recordly/Models/<kind>/`
- Supported extensions:
  - ASR / diarization: `.bin`
  - Summarization: `.bin`, `.gguf`
- `model-registry.json` remains as metadata/legacy-install source; current active model selection is folder-based.

## Local source files staged for development

Current local source files prepared on disk:

- `/Users/Shared/RecordlyModels/asr/asr-compact-v1.bin`
- `/Users/Shared/RecordlyModels/asr/asr-balanced-v1.bin`
- `/Users/Shared/RecordlyModels/diarization/diarization-enhanced-v1.bin`
- `/Users/Shared/RecordlyModels/summarization/summarization-compact-v1.bin`

Verified metadata for these files:

- `asr-compact-v1`: `59,707,625` bytes, `sha256:422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898`
- `asr-balanced-v1`: `190,085,487` bytes, `sha256:ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb`
- `diarization-enhanced-v1`: `5,986,908` bytes, `sha256:057ee564753071c0b09b5b611648b50ac188d50846bff5f01e9f7bbf1591ea25`
- `summarization-compact-v1`: `415,182,688` bytes, `sha256:9ee36184e616dfc76df4f5dd66f908dbde6979524ae36e6cefb67f532f798cb8`

## Install source of truth

A model is treated as installed only when all checks pass:

1. installed file exists
2. checksum file exists and matches descriptor
3. recomputed SHA-256 matches descriptor checksum

If checksum fails, installation is rejected as invalid.

## Runtime behavior

- Runtime default is `CliSystemDiarizationService`.
- On diarization errors (`binaryMissing`, `modelMissing`, malformed/empty/non-zero exit), transcription pipeline remains successful and degrades speaker labels to `Remote`.
- Summarization uses `LlamaCppSummaryEngine` backed by `llama-cli` (llama.cpp). The engine is injected into `RecordingWorkflowController` via `SummaryEngine` protocol.
- Summarization model is resolved at runtime via `modelManager.selectedLocalOption(kind: .summarization)` — not through `RequiredModelsResolution`.
- On any summarization failure (binary missing, model missing, transcript too short, inference error, empty output, cancellation), the workflow falls back to template-based summary generation. Summarization errors never block the recording workflow.

## Summarization runner details

- Binary: `main` or `llama-cli` (llama.cpp-compatible), resolved from Bundle resources/current directory → `/usr/local/bin` → `/opt/homebrew/bin` → `$PATH`.
- Prompt is written to a temp file to avoid shell escaping and argument length limits.
- CLI args: `-m <model> --file <prompt> --no-display-prompt --ctx-size <N> --temp <T> --top-p <P>`.
- Runtime defaults are persisted in preferences: `ctx-size=8192`, `temp=0.3`, `top-p=0.9`.
- Prompt builder prefers SRT over plain transcript (SRT has timestamps), trims input to 12K characters.
- Output parser extracts `## Topics`, `## Decisions`, `## Action Items`, `## Risks` sections into `SummaryDocument`.
- `SummaryDocument` is kept in-memory only; the `rawMarkdown` field is written to `summary.md`.

## ASR audio input policy

- `WhisperCppEngine` sits at an integration boundary. It adapts app-owned audio artifacts to the format expected by the selected whisper binary.
- Current recording sessions persist canonical raw tracks as `CAF` containers with normalized PCM audio. That is an internal pipeline choice and remains independent from `whisper-cli` input quirks.
- `whisper-cli` (Homebrew `whisper-cpp`) only accepts `wav`, `flac`, `mp3`, `ogg`. It does **not** support `.caf`. It silently fails on `.caf` (exit code 0, no output file).
- `ProcessWhisperCppRunner.convertToWAVIfNeeded()` now handles this: when the input audio extension is not natively supported by whisper, it converts to a temporary `16kHz mono LEI16 WAV` via `/usr/bin/afconvert` before invoking the binary, then removes the temporary file after inference completes.
- Do not treat `WAV` support in the ASR runner as a reason to rewrite capture, merge, or repository asset contracts.
- Future agents changing ASR runners should first verify the actual accepted input formats of the target binary, rather than assuming feature parity across whisper builds.

## How to use local models now

1. Put model files on disk under `/Users/Shared/RecordlyModels/` using `asr/`, `diarization/`, and `summarization/` subfolders.
2. Ensure `llama-cli` is installed (e.g., `brew install llama.cpp`) for summarization.
3. Build and run app.
4. Open `Models` menu (top-right).
5. Select ASR/diarization/summarization models.
6. Run transcribe/summarize flows. Summarization will use the LLM when both `llama-cli` and a summarization model are available; otherwise it falls back to the template summary.

# CallRecorderPro Product Context

## Product summary

CallRecorderPro is a local-first macOS app for call capture and deterministic post-processing with on-device transcription pipeline stages.

## Current product behavior

- Live recording captures microphone + system audio through `ScreenCaptureKit` when permissions are granted.
- Stop action finalizes capture, then offline merge completes in background.
- Playback prefers merged output when available.
- Import-audio flow is supported.
- Transcription pipeline is stage-based and resumable.

## Model management behavior (new)

- App uses bundle manifest `CallRecorderPro/Resources/model-registry.json`.
- App installs model files into `Application Support` (not app bundle).
- Installation states exposed in UI:
  - `notInstalled`
  - `downloading`
  - `installed`
  - `failed`
  - `incompatible`
- Profile mapping:
  - `compact` -> compact ASR
  - `balanced` -> balanced ASR
  - `enhanced` -> enhanced ASR + optional diarization

## Local-only model source (v1)

- Model installation is local-only.
- `downloadURL` must be `file://` absolute path to an existing local model file.
- Network URLs are rejected in this build.

## Important limitation right now

Buttons and model installation flow are functional, but ASR/diarization engines are still placeholders:

- ASR engine currently validates model path and returns empty segments.
- Diarization service currently validates model path and returns empty segments.
- Summary generation is currently template-based from transcript/SRT and does not use semantic LLM summarization.

So pipeline wiring is real, but recognition quality is not production-ready until real engines are integrated.

## Readiness snapshot (March 6, 2026)

- Transcription:
  - Pipeline stages, persistence, and output rendering are implemented.
  - Real speech-to-text inference is not integrated yet.
- Speaker identification:
  - Mapping logic exists (ASR segments to diarization segments by overlap).
  - Real diarization inference is not integrated yet, so labels degrade to fallback names.
- Summary:
  - `summary.md` output exists and is generated from available transcript/timeline data.
  - No local summarization model is integrated yet.

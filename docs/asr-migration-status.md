# Recordly ASR migration status

> Reviewed 2026-10-16. Current reference. Evidence and open acceptance limits are tracked centrally. See [current project status](project-status.md).

## Delivered

- Active ASR is FluidAudio **0.17.7**, Parakeet Ultra by default with selectable Parakeet TDT 0.6B v3 through Core ML; Whisper/whisper.cpp is not an active backend.
- Separate SDK-managed ASR and diarization providers own model readiness/provisioning. The actual v3 package uses `Encoder.mlmodelc`, `Decoder.mlmodelc`, `JointDecisionv3.mlmodelc`, `Preprocessor.mlmodelc` and `parakeet_vocab.json`.
- Legacy backend/language preference keys are migration compatibility only. Active ASR profiles/cache identities have no user-selected ASR language field.
- New V2 sessions use bounded semantic windows: at most 60 seconds of PCM, with 50-second ownership and context. Whole-session preparation is not used for V2.
- Successful windows resume only when audio, runtime/settings and actual artifact provenance match. Independent failures preserve usable output.
- Lexical timing validation and temporal word reconciliation prevent duplicate boundary words and avoid unnecessary scans of prior text.
- Model-scoped speaker matching and saved names are implemented, with explicit local/unknown fallbacks.

## Remaining limits

- No live streaming transcript; processing is offline/on-device.
- Legacy imported/single-file paths may prepare a full input before backend-local windowing; V2 bounds do not imply that all legacy inputs use the same memory strategy.
- Ultra is the fresh default; v3 remains selectable in Models. Redux is not exposed. Model choice is separate from diarization; no annotated Ultra/v3 quality or energy benchmark has been established.
- Session speaker continuity is partial. After the alignment correction, 31 of 35 original remote windows contain session-attributed speech and 94.35% of remote tokens have session IDs; four original problem windows remain unresolved. Repeatability passed; annotated voice accuracy is not established.
- Summarization is disabled, including fallback generation.

The backend migration is delivered; next work is measured quality and reliability. See [project status](project-status.md), [SDK changelog](fluidaudio-upgrade-changelog.md), and [recording verification](recording-7C943EA0-verification.md).

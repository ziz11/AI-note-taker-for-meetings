# ASR Whisper Coupling Migration Plan

## Objective
Remove backend-specific assumptions from shared inference contracts and composition layers so ASR backend migration can proceed without touching workflow/persistence semantics.

## Current Coupling Audit (pre-patch)

1. `ASRLanguage` exposed `whisperCode`, used by shared `ASREngine` cache logic.
2. `DefaultInferenceEngineFactory` and `WhisperCppASREngine` carried Whisper-specific display/language text.
3. UI label in ASR settings described Whisper explicitly.
4. Default ASR routing is centralized in `StageRuntimeSelection.defaultLocal` (`.asr: .whisperCpp`), which is a policy decision and intentional, but can block quick backend switches.
5. Persistence is shared and clean; model discovery uses `.bin` + filename heuristics (`whisper`/`asr`) which is tolerable for model classification.

## Constraints

- No orchestration/persistence rewrite in this phase.
- Keep canonical session artifacts untouched.
- Preserve fallback/degrade behavior in `TranscriptionPipeline`.

## First Migration Patch (already applied)

1. Remove Whisper-only `whisperCode` from shared language enum.
2. Use `ASRLanguage.rawValue` in shared ASR fingerprinting.
3. Remove Whisper language/deep-coupled naming from:
   - `WhisperCppASREngine.displayName`
   - `WhisperCpp` language argument wiring
   - Factory ASR display name
   - ASR settings helper text

## Next Migration Phases (planned)

1. Introduce an explicit runtime preference surface for ASR backend selection (or profile) in the composition/persistence of stage selection.
2. Add a temporary compatibility layer so cached fingerprints include backend identity in a migration-safe way (if needed).
3. Expand tests around `DefaultInferenceRuntimeProfileSelector` and `DefaultInferenceEngineFactory` for backend selection behavior.
4. Add fallback policy verification for newly introduced ASR backend errors (transcription hard-fail remains unchanged).

## Risk Notes

- `ASRLanguage` currently only supports `ru`, `en`, `auto`. New backends with different language code taxonomies should map at adapter boundary, not through shared contracts.
- Keep this phase small so existing cached transcriptions still read.

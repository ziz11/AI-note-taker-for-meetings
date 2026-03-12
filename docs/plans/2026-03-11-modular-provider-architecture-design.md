# Modular Provider Architecture Design

## Context

Recordly is currently blocked by an unresolved merge in inference-related files. The work in flight mixes three concerns:

1. stage-based backend routing
2. FluidAudio ASR and diarization provisioning
3. newer UI and transcript/export work

The immediate product goal is stabilization without giving up the modular architecture. The desired end state is:

- user-visible provider selection in Settings
- separate provider choices for ASR, diarization, and summarization
- a shared audio-quality provider that prepares reusable inference inputs for ASR and diarization
- canonical capture artifacts and workflow contracts unchanged

## Approved Direction

Preserve the existing stage-driven architecture and formalize provider selection at the composition/runtime/factory layers.

- `RecordingWorkflowController`, `RecordingsStore`, and `TranscriptionPipeline` remain backend-agnostic.
- `DefaultInferenceComposition` owns default provider mapping.
- `DefaultInferenceRuntimeProfileSelector` resolves provider readiness and runtime artifacts.
- `DefaultInferenceEngineFactory` remains the only `stage + provider -> engine` instantiation point.
- shared audio preparation lives under `Recordly/Infrastructure/Inference/Audio/`, not inside a backend engine.

## Provider Model

Provider selection becomes explicit and user-visible for these concerns:

- audio quality
- ASR
- diarization
- summarization

Audio capture stays fixed as a platform/runtime concern and is not exposed as part of this provider UI.

For the current release, each provider list may expose only `Fluid`, but the architecture must not special-case Fluid in workflow or pipeline code. Future providers should be addable by:

1. implementing the relevant stage contract
2. registering routing in the factory
3. exposing availability in composition/runtime selection

## Audio Quality Stage

Introduce a shared audio-quality provider boundary that prepares derived inference inputs from canonical session artifacts.

Requirements:

- input source remains canonical persisted capture artifacts
- prepared outputs are reusable by both ASR and diarization
- preprocessing policy is shared and configurable by provider, not hidden inside ASR or diarization engines
- recovery must work after app restart using persisted canonical artifacts
- timestamps must remain stable enough for transcript/diarization alignment

This stage may apply denoise, normalization, and similar preparation, but it must not redefine the system-wide source of truth for stored session media.

## Runtime and Persistence Rules

- Keep `mic.raw.caf`, `system.raw.caf`, `merged-call.caf`, and `merged-call.m4a` as canonical artifacts.
- Do not make backend-local temporary exports part of required persisted session state.
- Keep degrade/fallback policy in workflow/pipeline.
- Runtime profile data stays configuration, not product policy.

## Settings Surface

Settings should expose provider selectors immediately, even if only one option is currently available.

Expected selectors:

- Audio Quality Provider
- ASR Provider
- Diarization Provider
- Summarization Provider

These selectors should reflect actual supported implementations only. If a provider implementation does not exist for a stage, it must not be advertised as available.

The Models settings screen also needs two explicit user actions per provider/task group:

- download or install models
- select the active model

The screen should be organized by provider/runtime first, then by task/stage inside each provider. This keeps SDK-managed and local-file-backed models understandable without collapsing everything into a flat model list.

See [docs/prompts/2026-03-11-model-settings-screen-redesign.md](/Users/nacnac/Documents/Other_Interner/Recordly/docs/prompts/2026-03-11-model-settings-screen-redesign.md) for the current redesign brief.

## Merge-Stabilization Strategy

Resolve the current merge in favor of the modular stage architecture and remove branch-specific inconsistencies that widened provider concerns into app/store code.

Order of operations:

1. resolve inference merge conflicts
2. stabilize provider selection types and defaults
3. add shared audio-quality boundary
4. wire Fluid implementations through selector/factory/composition
5. expose provider selectors in Settings
6. update routing, degrade, and recovery tests

## Risks

- summarization currently appears to be wired to `llama.cpp`; do not route summarization to Fluid unless a real Fluid summarization backend exists
- shared preprocessing can unintentionally degrade diarization if tuned only for ASR
- merge resolution can accidentally move backend policy into workflow/store if done hastily

## Acceptance Criteria

- merge conflicts are resolved cleanly
- app builds again
- provider selection is visible in Settings
- stage routing remains backend-agnostic outside selector/factory/backend modules
- shared audio-quality preparation is reusable by ASR and diarization
- existing recovery and persistence contracts remain intact

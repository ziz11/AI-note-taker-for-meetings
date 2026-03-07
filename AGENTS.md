# Recordly Agent Rules

## Purpose

This document defines how future agents should change Recordly.

Use it when modifying:

- inference backends
- stage routing or runtime selection
- audio preprocessing or audio-format adaptation
- transcription or summarization workflow behavior
- model resolution and runtime profile wiring
- persistence contracts tied to recordings or transcript artifacts

This is a rules document, not an infrastructure tour. When in doubt, preserve the current boundaries and change the narrowest layer that owns the behavior.

## Core Architectural Rules

- Keep orchestration stage-driven and backend-agnostic.
- Keep backend switching localized to composition, factory routing, and backend modules.
- Keep model discovery and model resolution separate from orchestration.
- Keep backend-specific input adaptation at the consumer boundary.
- Keep preprocessing separate from ASR or other backend implementations unless the behavior is truly backend-private.
- Keep persistence and recovery contracts stable unless the task explicitly requires a migration.

Short rationale: Recordly is designed so new backends, runtime mappings, and preprocessing steps can be added without rewriting workflow or storage contracts.

## Ownership Boundaries

### Workflow and pipeline

- `RecordingsStore`, `RecordingWorkflowController`, and `TranscriptionPipeline` own product flow.
- These layers own stage order, workflow state, recovery behavior, and degradation or fallback policy.
- These layers must not hardcode concrete backend classes, backend binaries, or backend-specific file-format assumptions.

### Runtime selection

- `DefaultInferenceRuntimeProfileSelector` owns runtime profile resolution.
- It may resolve stage selections, model artifacts, and runtime parameters.
- It must not run inference, instantiate backends, mutate session artifacts, or decide product fallback behavior.

### Factory and routing

- `DefaultInferenceEngineFactory` owns `stage + backend -> engine` routing.
- It may construct concrete engines and return typed unsupported-backend errors.
- It must not own fallback behavior, UI decisions, queueing policy, or recording-session state.

### Model layer

- `ModelManager` owns model discovery, install state, selected model IDs, artifact resolution, and runtime settings persistence.
- `ModelManager` must not become an orchestration center.
- Do not put stage order, fallback policy, or backend execution logic into the model layer.

### Backend modules

- Backend modules own inference execution, backend-specific parsing, and the minimum boundary adaptation needed to satisfy that backend.
- Backend modules must stay localized.
- They must not absorb product workflow logic, global model discovery, or application state management.

## Change Routing Rules

### If you are switching a backend

Change:

- `DefaultInferenceComposition`
- `DefaultInferenceEngineFactory`
- the relevant backend module under `Recordly/Infrastructure/Inference/Backends/`

Do not change:

- `RecordingsStore`
- `RecordingWorkflowController`
- `TranscriptionPipeline`

Exception: only touch orchestration if the stage contract itself changes.

### If you are adding preprocessing

Put the work in:

- `Recordly/Infrastructure/Inference/Audio/`
- or a dedicated preprocessing module with similarly narrow scope

Do not hide reusable preprocessing policy inside `WhisperCppASREngine` or another backend class.

### If you are adding a new stage

Decide first whether the capability is cross-backend or backend-private.

- If cross-backend, add a stable contract, runtime-selection support, factory routing, and pipeline integration only if the stage has standalone product meaning.
- If backend-private, keep it inside the backend module and do not expand the public orchestration API.

## Stable Contracts and Invariants

### Pipeline invariants

- The pipeline must depend on stage contracts, not concrete engines.
- Workflow and pipeline must remain backend-agnostic.
- Runtime profile data is configuration, not product policy.

### Audio invariants

- Live capture source of truth is the canonical internal audio artifacts, not a backend-preferred export format.
- Canonical live artifacts remain:
  - `mic.raw.caf`
  - `system.raw.caf`
  - `merged-call.caf`
  - `merged-call.m4a`
- Internal live-capture format remains normalized PCM in CAF.
- If a backend needs WAV, FLAC, PCM buffers, or another representation, adapt at the consumer boundary.

### Persistence invariants

- Do not change session folder layout without an explicit migration need.
- Do not rename canonical artifacts casually.
- Do not move transcript, SRT, JSON, or summary outputs without a migration-aware reason.
- New backends must adapt to the persistence contract more often than the persistence contract adapts to them.

### Model invariants

- Treat model artifact resolution and backend selection as separate concerns.
- Local model policy is the current default; do not spread remote-install logic through orchestration layers.

## Extension Checklists

### New backend checklist

Before adding a backend, confirm:

- which stages it actually supports
- which input forms it accepts (file-based, buffer-based, streaming)
- which failure modes it exposes
- whether it requires separate model artifacts
- whether it needs extra preprocessing
- whether it can fit the current persistence and recovery contracts

Implement by:

1. adding a backend module under `Recordly/Infrastructure/Inference/Backends/`
2. implementing the relevant stage contracts
3. adding factory routing
4. updating stage mapping in composition

Completion check: stage contracts unchanged or intentionally evolved; new backend localized in one module; routing added in factory; selection changed in composition; pipeline/workflow code does not become backend-aware.

### Preprocessing checklist

Before adding preprocessing, confirm:

- whether it is reusable across more than one backend
- whether it changes timestamps or segment alignment
- whether it helps one stage but harms another
- whether each stage needs different prepared inputs

Preferred shapes:

- `AudioProcessor`
- `AudioPreprocessingStage`
- `AudioProcessingPipeline`
- `AudioInput`-based preparation

Important: there is no universal "best processed audio" for all stages. ASR often benefits from denoise and silence trimming; diarization can get worse after aggressive denoise; timestamps may shift after trimming; summarization only depends on text. The architecture should allow different prepared inputs per stage when needed.

## Error Handling and Fallback Rules

- Backends return technical failures.
- Workflow and pipeline decide whether the product should fail, degrade, retry, or continue.
- Do not move fallback policy into selectors, factories, or backend modules.

Current behavior to preserve unless explicitly changed:

- diarization failure degrades speaker labeling but does not fail transcription
- summarization failure falls back to template summary
- ASR failure is generally a hard failure for transcription

## Recovery and Persistence Rules

- Recovery compatibility is more important than cleanup-motivated refactors.
- Do not break reprocessing of existing sessions to make a new backend cleaner.
- Do not rewrite persisted audio formats just because one backend prefers another input type.
- Reuse existing artifacts when possible instead of introducing parallel persistence schemes.

If recovery breaks after a change, inspect:

1. Did you change persisted artifact names or locations?
2. Did you introduce a new temporary artifact and accidentally make it mandatory?
3. Did you make a stage depend on a file that is not persisted across app restarts?
4. Did you move logic from orchestration into a backend where recovery no longer knows about it?
5. Did you turn an optional stage into a required one implicitly?

A new optimization or backend integration is not complete if it only works in the happy path and breaks resumability.

## Anti-Patterns

Do not:

- redesign the architecture around one backend
- let selector code execute inference
- let factory code decide feature fallback behavior
- turn `ModelManager` into an orchestration layer
- hide cross-backend preprocessing inside one ASR engine
- spread backend wiring across the app
- refactor storage formats for backend convenience alone
- add new protocols without a real replaceability or extension point

### Coupling detection smells

If you see any of these, coupling is leaking across layers:

- pipeline imports a concrete backend class
- workflow knows about model URLs
- selector starts creating engines
- factory starts deciding fallback behavior
- `ModelManager` starts controlling orchestration
- one backend's file format becomes the new global storage standard
- preprocessing is hidden inside a single engine but affects shared behavior

## Agent Playbook

This section is operational. Use it when the task is to change the system, not just understand it.

### Minimal safe change strategy

When in doubt, use this order:

1. Solve the issue inside the backend module, if it is truly backend-local.
2. If not enough, solve it in a boundary adapter.
3. If not enough, extend routing/selection.
4. Only then consider changing stage contracts.
5. Only then consider changing pipeline/workflow.
6. Change persistence/storage contracts last.

This order protects the architecture from accidental overreach.

### Adding a new backend

1. Identify which stage(s) the backend supports (ASR, diarization, summarization, VAD, capture).
2. Create a dedicated backend module under `Infrastructure/Inference/Backends/<BackendName>/`.
3. Implement the appropriate stable contracts only.
4. Keep backend-specific details inside that module (SDK wrappers, process invocation, parsing, temporary files, backend-specific config and input preparation).
5. Register the backend in `DefaultInferenceEngineFactory`.
6. Update stage mapping in `DefaultInferenceComposition`.
7. Leave `TranscriptionPipeline`, `RecordingWorkflowController`, and `RecordingsStore` unchanged unless the stable contracts themselves need to evolve.

Do not: wire the new backend directly into workflow code; make pipeline import backend-specific classes; make `ModelManager` instantiate the backend; change session storage format because the backend wants a different input format; put product fallback logic inside the backend module.

### Switching a stage from one backend to another

1. Confirm the target backend already implements the needed stage contract.
2. Update stage selection in `DefaultInferenceComposition`.
3. Confirm the factory can instantiate that backend for the selected stage.
4. Run tests for stage routing, pipeline success path, degrade/fallback path, and recovery path.

Switching a backend should feel like changing routing, not rewriting architecture.

### Adding preprocessing between capture and inference

1. Add the processor in an audio/preprocessing-focused area, not inside one backend module.
2. Make the processor accept and return `AudioInput` or another stage-safe boundary type.
3. Keep the result reusable across backends when possible.
4. If the processor is backend-specific, keep it inside that backend module.
5. Decide explicitly which stages consume the processed output.
6. Keep canonical session artifacts unchanged.
7. Validate timestamp implications.
8. Verify diarization is not accidentally degraded.

### Adding VAD

There is already a VAD extension point (`VoiceActivityDetectionEngine`).

1. Implement `VoiceActivityDetectionEngine` in a backend module.
2. Decide whether VAD is optional preprocessing, required for a performance mode, or a reusable stage.
3. Add routing in the factory and runtime selection if it becomes selectable.
4. Keep product policy outside the VAD backend.
5. Do not silently force VAD into all flows without validating timestamp and recovery implications.

### Changing the pipeline

This is the highest-risk type of change. Before editing pipeline flow:

1. Is this truly a pipeline concern, or just a backend concern?
2. Is this a new reusable stage, or only a special requirement of one engine?
3. Can this be solved in boundary adaptation instead?
4. Will this break recovery semantics?
5. Will this break persisted artifacts or naming conventions?
6. Will this force product workflows to become backend-aware?

Safe reasons: adding a genuinely reusable new stage; changing stage ordering for a cross-backend reason; introducing a new stage-level result that orchestration must understand.

Unsafe reasons: one backend wants a different temporary file format; one backend wants an extra local conversion step; one SDK has special initialization needs. Those should stay local to the backend or adapter layer.

### Evolving stage contracts

Stable contracts are the architectural seam. Change them carefully.

You may evolve a contract when: multiple backends need the same new capability; pipeline genuinely needs access to new stage-level information; the current contract blocks a real extension path.

You should not evolve a contract when: only one backend needs one extra parameter; the requirement can be hidden inside backend-specific config; a boundary adapter can solve the issue locally.

Before changing a contract, check: will at least two implementations benefit? Will pipeline/workflow consume the new information? Can the change remain backend-neutral? Can old behavior still be represented cleanly?

### Changing model handling

Safe: adding a new model kind; adding metadata; improving local discovery; supporting a new install location; refining artifact resolution.

Dangerous: making `ModelManager` create engines; making `ModelManager` choose stage ordering; making `ModelManager` decide product fallback behavior.

### Optimizing performance

Valid targets: preprocessing to reduce ASR work; switching backend for a specific stage; reducing redundant conversions; caching prepared inputs locally; improving stage-level parallelism where safe; introducing chunking/VAD where recovery semantics remain clear.

Before landing an optimization, verify: does it change stage boundaries? Does it change persistence or recovery semantics? Does it make pipeline/backend coupling worse? Can it be benchmarked per stage?

If possible, measure performance by stage: capture finalization, preprocessing, ASR, diarization, merge/mapping, summarization.

### Adding a brand new stage

Examples: translation, sentiment tagging, topic segmentation, speaker-name attribution, redaction.

Add a new stage only when: it has a meaningful input/output contract; multiple implementations could exist; orchestration or persistence cares about the result; it is not just a private helper for one engine.

Steps: add or evolve a stable contract; add runtime selection support if selectable; add factory routing; decide whether pipeline should always run it, run it conditionally, or expose it as optional; define persistence behavior if results must survive recovery; add tests for success, absence, failure, and recovery behavior.

### Quick recipes

**Add FluidAudio for ASR:**
- Create `Backends/FluidAudio/FluidAudioASREngine.swift`
- Implement `ASREngine`
- Add routing in `DefaultInferenceEngineFactory`
- Change ASR stage selection in `DefaultInferenceComposition`
- Run pipeline/workflow/recovery tests
- Do not rewrite orchestration

**Add ffmpeg silence trimming before ASR:**
- Create a preprocessing component outside ASR backend
- Accept/return `AudioInput`
- Wire it before ASR only
- Keep canonical session artifacts unchanged
- Validate timestamp implications
- Verify diarization is not accidentally degraded

**Add a backend-specific temporary WAV export:**
- Keep it inside backend/adaptation layer
- Do not expose WAV as the new system-wide source of truth

**Add a user-selectable backend setting later:**
- Introduce a stage map source read by composition/selector
- Do not move backend selection into workflow
- Keep the factory as the only instantiation point

## Mandatory Questions Before Any Non-Trivial Change

1. Which layer should own this change? (backend / adapter / selector / factory / pipeline / workflow / persistence)
2. Am I solving a reusable stage concern, or a one-backend detail?
3. Am I forcing one consumer's constraints onto canonical storage or stage APIs?
4. Will recovery still work after app restart?
5. Will optional stages remain optional?
6. Can this change be localized instead of widening contracts?

## Minimal Project Map

Use these files as the primary routing map for inference changes:

- App composition: `Recordly/App/RecordlyApp.swift`
- Inference composition: `Recordly/Infrastructure/Inference/Composition/DefaultInferenceComposition.swift`
- Runtime selection: `Recordly/Infrastructure/Inference/Runtime/DefaultInferenceRuntimeProfileSelector.swift`
- Engine routing: `Recordly/Infrastructure/Inference/Factory/DefaultInferenceEngineFactory.swift`
- Stage contracts: `Recordly/Infrastructure/Inference/Contracts/InferenceStageContracts.swift`
- Audio boundary types: `Recordly/Infrastructure/Inference/Audio/AudioInput.swift`
- Workflow orchestration: `Recordly/Features/Recordings/Application/RecordingWorkflowController.swift`
- Pipeline orchestration: `Recordly/Infrastructure/Transcription/TranscriptionPipeline.swift`
- Model layer: `Recordly/Infrastructure/Models/ModelManager.swift`
- Persistence layer: `Recordly/Infrastructure/Persistence/RecordingsRepository.swift`

Current backend modules:

- ASR: `WhisperCppASREngine`
- Diarization: `CliDiarizationEngine`
- Summarization: `LlamaCppSummarizationEngine`

## Final Operating Rule

When extending Recordly, preserve these four truths:

1. Canonical session artifacts belong to Recordly, not to one backend.
2. Workflow owns product behavior and fallback policy.
3. Selection and routing decide what runs; backend modules decide how it runs.
4. A new backend or preprocessing step should usually be a local addition, not a system-wide rewrite.

# Agent Rollout Plan for Whisper → FluidAudio Migration

## Purpose

This document defines how to use Codex and Claude during the Recordly migration from Whisper-based ASR to FluidAudio-based speech inference, while preserving the current architecture, session lifecycle, artifact model, and recovery semantics.

The goal is to replace the backend implementation, not to redesign the app.

## Migration Target

Replace Whisper ASR with FluidAudio ASR behind existing stage contracts.

Keep unchanged:
- session lifecycle
- session artifact model and naming
- capture and merge semantics
- processing stages and recovery rules
- summarization stage
- UI structure unless explicitly requested

Do later, only after ASR migration is stable:
- diarization
- VAD-based preprocessing
- any live/streaming UX improvements

## Core Principle

Treat this as a backend swap inside an already working system.

Do not:
- redesign the app architecture
- refactor unrelated modules during ASR migration
- combine ASR migration, diarization, VAD, and UI redesign into one patch
- change artifact naming or state semantics unless the task explicitly requires it

## Agent Role Split

### Codex
Use Codex for broad repo-level work:
- cross-file discovery
- dependency mapping
- architectural migration plans
- large refactors
- deletion planning
- cleanup after milestones

Codex is the right tool when the task spans many files and requires understanding how the whole repo hangs together.

### Claude
Use Claude for bounded implementation loops:
- service implementation
- adapters and mappers
- invariant-preserving edits
- test harnesses
- cleanup of local compile/runtime issues
- focused subagent-style decomposition

Claude is the right tool when the task is constrained, implementation-heavy, and sensitive to behavioral invariants.

## Repository Constraints for Both Agents

These rules are hard constraints unless explicitly overridden by a human task:

1. Do not change session artifact names casually.
2. Do not change session state machine semantics casually.
3. Do not fold summarization into the ASR stage.
4. Do not redesign the UI during backend migration.
5. Do not add live/streaming features during backend swap.
6. If a stage fails, preserve prior successful artifacts.
7. Prefer additive migration first, cleanup second.
8. Leave migration notes in docs.
9. Avoid introducing backend-specific assumptions into domain models.
10. Keep FluidAudio-specific handling behind adapter/runtime boundaries.

## Phase 0 — Preparation

Before agent-driven migration begins, ensure the repo contains stable guidance docs.

### Required docs
Create or update:
- `AGENTS.md` or `CLAUDE.md`
- `docs/architecture/inference.md`
- `docs/architecture/session-lifecycle.md`
- `docs/architecture/audio-artifacts.md`
- `docs/migrations/whisper-to-fluidaudio.md`

### These docs should define
- canonical session states
- artifact names and invariants
- stage contracts
- failure and retry rules
- recovery semantics
- boundaries between capture, storage, inference, and summary
- what may change in this migration and what must remain stable

### Deliverable
A clear one-paragraph migration statement:

> Replace Whisper ASR with FluidAudio ASR behind existing stage contracts. Keep session lifecycle, artifacts, merge semantics, and summarization unchanged. Add diarization only after ASR migration is stable. VAD is optional and must not block first end-to-end success.

## Phase 1 — Codex Repo Audit and Migration Plan

### Objective
Understand exactly where Whisper is coupled into Recordly and produce a concrete migration plan.

### Tasks for Codex
1. Inventory all Whisper-specific code.
2. Identify all runtime/profile wiring that references Whisper.
3. Identify all settings, enums, UI states, and docs that reference Whisper.
4. Separate code into:
   - must keep
   - must replace
   - can delete after migration
5. Identify insertion points for:
   - `FluidAudioASREngine`
   - audio input adapter
   - transcript mapper
6. Produce a file-by-file migration plan.

### Expected output
- `docs/migrations/whisper-to-fluidaudio.md`
- list of Whisper-coupled files
- list of new FluidAudio files to add
- first-pass patch proposal
- known risks / open questions

### Important constraint
Do not let Codex add diarization or VAD in the same patch as ASR migration.

## Phase 2 — Claude ASR Migration Implementation

### Objective
Swap Whisper out for FluidAudio ASR while preserving existing stage behavior.

### Tasks for Claude
1. Implement `FluidAudioASREngine`.
2. Implement audio conversion/loading required by FluidAudio.
3. Implement transcript mapping into the canonical transcript model.
4. Integrate the new backend into runtime selection or backend factory wiring.
5. Preserve existing processing states and persistence semantics.
6. Fix local compile/runtime issues caused by the swap.

### Files likely involved
- `Infrastructure/Inference/...`
- pipeline/runtime selection files
- transcript mapping layer
- model/runtime initialization code
- backend factory / selector logic

### Non-goals
- diarization
- VAD
- transcript domain redesign
- streaming/live transcript UX
- UI redesign

### Acceptance criteria
- one recorded session processes successfully end-to-end
- one imported audio file processes successfully end-to-end
- transcript is persisted in the existing canonical format
- recovery still works after restart/failure
- Whisper path is no longer required for success

## Phase 3 — Codex Cleanup After ASR Success

### Objective
After first successful end-to-end FluidAudio ASR runs, remove Whisper cleanly and simplify the repo.

### Tasks for Codex
1. Remove Whisper-specific files.
2. Remove dead runtime branches.
3. Remove dead settings/UI references.
4. Remove obsolete docs.
5. Normalize naming after backend swap.
6. Document the stable post-migration state.

### Deliverables
- cleaned repo with no dead Whisper branches
- updated architecture docs
- reduced compile graph / dependency surface

### Constraint
Cleanup must not alter behavior that was already validated in Phase 2.

## Phase 4 — Claude Diarization Branch

### Objective
Add diarization as a separate, non-blocking enrichment stage.

### Tasks for Claude
1. Implement `FluidAudioDiarizationEngine`.
2. Persist diarization output separately at first.
3. Implement alignment of diarization segments with ASR transcript segments.
4. Ensure diarization failure does not block transcript generation.
5. Add tests around alignment and fallback behavior.

### Product logic decisions to settle
- whether diarization applies only to merged/imported audio or also captured sessions
- when known channel ownership should override inferred speakers
- how to label speakers in UI
- how to handle overlap or timestamp disagreement

### Rules
- ASR success must still ship transcript even if diarization fails.
- Diarization should be modeled as enrichment, not as a prerequisite.
- Avoid mixing channel semantics and inferred speaker semantics carelessly.

## Phase 5 — Codex Cleanup After Diarization

### Objective
Remove temporary scaffolding and stabilize the code after diarization has proven out.

### Tasks for Codex
1. Collapse temporary adapters where appropriate.
2. Simplify runtime profiles.
3. Remove experimental branches left from migration.
4. Standardize naming and docs.
5. Review dead code created by the transition.

### Deliverable
A stable post-diarization architecture that is simpler than the transitional version.

## Phase 6 — Optional VAD Phase

### Objective
Add VAD only if there is a measurable reason.

### Valid reasons
- silence trimming before ASR
- chunk boundary generation for long audio
- live speech-state UI
- measurable speed/reliability improvements

### Invalid reason
- “we already have VAD support, so let’s wire it everywhere”

### Rule
VAD must be introduced for exactly one purpose at first:
- either silence trimming
- or chunk generation

Not both in the first pass.

### Constraint
VAD must not block already working ASR + summary flows.

## Recommended Execution Waves

### Wave 1
**Codex**
- audit Whisper coupling
- propose migration doc
- generate initial ASR migration patch

### Wave 2
**Claude**
- finish `FluidAudioASREngine`
- harden adapter and mapper
- fix compile/runtime edges
- add tests

### Wave 3
**Codex**
- remove Whisper dead code
- simplify runtime selection
- refresh docs

### Wave 4
**Claude**
- implement diarization
- implement alignment logic
- add regression tests

### Wave 5
**Codex**
- cleanup after diarization
- reduce transitional complexity
- normalize final architecture

### Wave 6
**Claude or Codex**
- VAD spike only if justified

## Suggested Claude Subagents / Workstreams

If using Claude in a subagent-style workflow, split responsibilities like this:

### `asr-adapter-agent`
Owns:
- `FluidAudioASREngine`
- audio loading and conversion
- transcript mapping

### `pipeline-guard-agent`
Owns:
- stage transitions
- persistence invariants
- retry/failure behavior
- recovery correctness

### `cleanup-agent`
Owns:
- Whisper removal
- dead config/settings cleanup
- stale docs cleanup

### `test-agent`
Owns:
- fixture sessions
- migration regressions
- smoke tests for processing pipeline

## Definition of Done by Milestone

### Milestone A — ASR Migration Done
- FluidAudio ASR is the working backend
- recorded session path works
- imported file path works
- transcript persistence works
- summary stage still works
- Whisper no longer required

### Milestone B — Whisper Fully Removed
- no dead Whisper compile path remains
- no stale docs/settings/UI mentions remain
- repo is simplified after migration

### Milestone C — Diarization Added Safely
- diarization enriches transcript when available
- diarization failure does not block transcript output
- alignment is tested

### Milestone D — VAD Added with Justification
- VAD is wired for one clear purpose
- VAD improves something measurable
- VAD does not destabilize the core pipeline

## Anti-Patterns to Avoid

1. Big-bang migration that swaps ASR, adds diarization, adds VAD, and redesigns UI together.
2. Letting backend-specific assumptions leak into domain models.
3. Reworking the session state machine during backend migration.
4. Reworking summary flow during ASR swap.
5. Treating diarization as mandatory for transcript success.
6. Adding streaming complexity before offline stability exists.
7. Keeping large amounts of dead Whisper code “just in case” after validation.

## Recommended Human Review Gates

A human should explicitly review and approve before moving between these checkpoints:

1. After Phase 1 migration plan.
2. After first successful ASR-only end-to-end run.
3. After Whisper removal cleanup.
4. After diarization alignment behavior is demonstrated.
5. Before any VAD work is merged.

## Short Version

Use **Codex** for repo-wide migration discovery, planning, and cleanup.

Use **Claude** for bounded implementation loops, adapters, tests, and invariant-sensitive work.

Do the migration in this order:
1. audit
2. ASR-only migration
3. cleanup
4. diarization
5. cleanup
6. optional VAD

Keep the architecture stable. Replace the backend, not the app.

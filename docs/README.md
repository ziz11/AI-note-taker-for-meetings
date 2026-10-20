# Recordly documentation index

Reviewed **2026-10-16**. [Project status](project-status.md) is the current delivery/acceptance summary. The [Markdown audit](documentation-audit-2026-10-10.md) covers every repository Markdown file, including preserved license/archive documents.

## Distribution preparation — 20 October 2026

[The GitHub Pages website is live](https://ziz11.github.io/Barkenson-Meeting-recorder-for-Mac/). See the [website publication record](distribution/2026-10-20-website-publication.md).

Barkenson is the confirmed public name. Internal Recordly namespaces remain for compatibility.

- [Coordination plan](plans/2026-10-20-barkenson-distribution.md) — final name, agent ownership, integration order and release gates.
- [Current app/icon integration](distribution/2026-10-20-app-icon-integration.md) — merged PRs, approved icon, fresh verification and remaining release acceptance.
- [Initial preparation result](distribution/integration-result.md) — earlier baseline evidence.
- [Capabilities](distribution/capabilities.md) — source-backed features and limits.
- [Identity preservation](distribution/identity-preservation.md) — data, settings, models, signing and permissions.
- [Release readiness](distribution/release-readiness.md) — standalone distribution and Pages acceptance.

## Current reference

- [Compute/performance diagnostics](performance-diagnostics-2026-10-16.md) — small chip popover, bounded local metrics, native Ultra timing and ANE/energy evidence limits.
- [Project status](project-status.md) — implemented behavior, source/release, verification and next priorities.
- [Product/setup README](../README.md) — running, signing, model provisioning and storage.
- [Architecture](../ARCHITECTURE.md) — source structure and ownership boundaries.
- [Agent rules](../AGENTS.md) — mandatory change-routing and persistence rules.
- [Inference context](inference-context.md) — active stage map, current summary placeholder policy and backend boundaries.
- [Model integration](model-integration.md) — separate SDK providers, canonical cache paths and compatibility behavior.
- [ASR migration status](asr-migration-status.md) — delivered migration and actual remaining limits.
- [SDK changelog](fluidaudio-upgrade-changelog.md) — pinned 0.14.0 → 0.17.7 upstream changes; enabled versus available features.
- [Ultra/model picker](ultra-model-selection-2026-10-16.md) — Ultra default, persisted v3 choice, table UI and native model checks.
- [Transcript spacing](transcript-spacing-fix-2026-10-16.md) — decoded boundaries preserved when assembling timed subword tokens.
- [SDK/speaker verification](fluid-speaker-verification.md) — matching constraints and native acceptance evidence.
- [Transcript speaker alignment](speaker-transcript-alignment.md) — fragmented-turn mapping, timed speaker changes and shared boundary continuity.
- [Requested recording verification](recording-7C943EA0-verification.md) — in-place repeats, saved-name probe, audio integrity and partial continuity.
- [Minimal Models panel](compact-model-panel-2026-10-16.md) — current 400×230-point panel, small controls and intrinsic-size state renders.
- [Previous catalog redesign](model-settings-redesign-2026-10-16.md) — superseded large-screen layout and download busy-state fix.
- [Historical diagnostics standalone](../releases/standalone-2026-10-16-performance-diagnostics/README.md) — build 4 record, not a current binary download or fresh verification.
- [Previous Ultra standalone](../releases/standalone-2026-10-16-ultra-models/README.md) — historical build record; binary rollback availability is unverified.
- [Third-party notices](../THIRD_PARTY_LICENSES.md) — licensed runtime dependencies.

## Delivered feature reports with historical measurements

- [Audio Pipeline V2](audio-pipeline-v2-report.md) — original A/B/C baseline; current follow-up explicitly supersedes old SDK/speaker/summary descriptions.
- [Progress and summary placeholders](progress-and-summary-placeholder-report.md) — counters, coalescing and disabled generation.
- [AAC allocation reclamation](aac-allocation-report.md) — byte-preserving disk allocation fix and original repair measurements.
- [Launch recovery UX](../PRODUCT-ISSUE-bulk-asr-launch-ux.md) — implemented prompt/queue policy versus GUI acceptance still pending.

## Compatibility pointers

[Inference architecture guide](inference-architecture-guide.md) and [inference extension rules](inference-extension-rules.md) both point to the current inference context.

## Historical plans, briefs and research

- [plans/](plans/) and [superpowers/](superpowers/) preserve dated requirements/design/implementation instructions. Review notices state delivered, superseded and unverified parts. Old checkboxes/test counts are snapshots, not the current task list.
- [Models UI brief](prompts/2026-03-11-model-settings-screen-redesign.md) is a design reference with current scope constraints, not a verified UI completion report.
- [Diarization research](research/diarization-options.md) retains its March research date, with the current Recordly decision noted separately; alternative SDKs were not re-benchmarked.
- [Migration rollout](migrations/agent-rollout-plan.md) is historical; the Whisper migration is delivered.
- [Recovered quality experiment](archive/2026-04-03-asr-diarization-quality/README.md) explains the untouched original plan/patch and their relationship to later work.
- [Previous standalone](../releases/standalone-2026-10-10/README.md) is a historical build record; binary rollback availability requires a separate local check.

Private audio, transcripts and voice embeddings remain outside Git. Local `/private/tmp` evidence paths may expire; committed aggregate reports are the durable documentation.

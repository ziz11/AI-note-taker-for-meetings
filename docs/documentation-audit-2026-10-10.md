# Markdown documentation audit — 2026-10-10

All **64 repository Markdown files** were inventoried. **56 existing project documents were updated**, **3 current documents added**, and **5 exact-source files reviewed and preserved** (four third-party Markdown license/notice files and the verbatim archived quality plan). Repeated historical test counts remain tied to their original runs; the current acceptance summary is in [project status](project-status.md).

## Scope and rules

- Current guidance matches FluidAudio 0.17.7, SDK-owned speech providers, V2 bounded AAC processing, disabled summary generation, latest fixed standalone and partial session speaker continuity.
- Dated plans/specs are original implementation records. Their review notices state the actual delivered/superseded/unverified scope; unchanged historical checklist boxes are not a new outstanding-task list.
- The original archived plan and upstream license text were compared byte-for-byte with release `18add9d`. No copyright/license terms were rewritten. The root attribution document received only an external review notice.
- Latest and rollback ZIP files, SHA256SUMS and release tags are fixed artifacts, not replaced by this documentation update.
- Private audio/transcript/embedding evidence stays outside Git; aggregate replay results are committed.
- Primary `main` checkout is not switched/reset. Documentation is delivered on develop/master, matching the user's delivery branches.

## Validation

The documentation audit checks every local Markdown target, balanced backtick fences, exact preserved-source bytes, inventory coverage, Markdown-only changed paths, and `git diff --check`. It checks current guide facts against composition/provider/store code and replay results. The installed app executable and release archive hashes are unchanged. This is a documentation-only update; the application test suite is not rerun solely for these Markdown edits. The last full/native test evidence is explicitly dated and retained in the current status.

## Complete inventory

| File | Review outcome |
|---|---|
| [AGENTS.md](../AGENTS.md) | Current guide/report; reviewed facts and links |
| [ARCHITECTURE.md](../ARCHITECTURE.md) | Current guide/report; reviewed facts and links |
| [PRODUCT-ISSUE-bulk-asr-launch-ux.md](../PRODUCT-ISSUE-bulk-asr-launch-ux.md) | Current guide/report; reviewed facts and links |
| [README.md](../README.md) | Current guide/report; reviewed facts and links |
| [Recordly/Resources/Binaries/README.md](../Recordly/Resources/Binaries/README.md) | Current guide/report; reviewed facts and links |
| [Recordly/Resources/Models/README.md](../Recordly/Resources/Models/README.md) | Current guide/report; reviewed facts and links |
| [Recordly/Resources/PreviewContent/README.md](../Recordly/Resources/PreviewContent/README.md) | Current guide/report; reviewed facts and links |
| [THIRD_PARTY_LICENSES.md](../THIRD_PARTY_LICENSES.md) | Current guide/report; reviewed facts and links |
| [docs/README.md](README.md) | Current guide/report; reviewed facts and links |
| [docs/aac-allocation-report.md](aac-allocation-report.md) | Current guide/report; reviewed facts and links |
| [docs/archive/2026-04-03-asr-diarization-quality/README.md](archive/2026-04-03-asr-diarization-quality/README.md) | Historical migration/archive; current interpretation added |
| [docs/archive/2026-04-03-asr-diarization-quality/original-plan.md](archive/2026-04-03-asr-diarization-quality/original-plan.md) | Preserved byte-for-byte; upstream license or verbatim archived source |
| [docs/asr-migration-status.md](asr-migration-status.md) | Current guide/report; reviewed facts and links |
| [docs/audio-pipeline-v2-report.md](audio-pipeline-v2-report.md) | Baseline evidence; explicit current supersession section |
| [docs/documentation-audit-2026-10-10.md](documentation-audit-2026-10-10.md) | Current full inventory and validation record |
| [docs/fluid-speaker-verification.md](fluid-speaker-verification.md) | Current guide/report; reviewed facts and links |
| [docs/fluidaudio-upgrade-changelog.md](fluidaudio-upgrade-changelog.md) | Current guide/report; reviewed facts and links |
| [docs/inference-architecture-guide.md](inference-architecture-guide.md) | Updated compatibility pointer |
| [docs/inference-context.md](inference-context.md) | Current guide/report; reviewed facts and links |
| [docs/inference-extension-rules.md](inference-extension-rules.md) | Updated compatibility pointer |
| [docs/migrations/agent-rollout-plan.md](migrations/agent-rollout-plan.md) | Historical migration/archive; current interpretation added |
| [docs/model-integration.md](model-integration.md) | Current guide/report; reviewed facts and links |
| [docs/plans/2026-03-06-model-management-implementation.md](plans/2026-03-06-model-management-implementation.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-03-06-screencapturekit-offline-merge-design.md](plans/2026-03-06-screencapturekit-offline-merge-design.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-03-06-screencapturekit-offline-merge-implementation.md](plans/2026-03-06-screencapturekit-offline-merge-implementation.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-03-07-recordly-rename-design.md](plans/2026-03-07-recordly-rename-design.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-03-07-recordly-rename.md](plans/2026-03-07-recordly-rename.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-03-08-asr-model-provider-abstraction.md](plans/2026-03-08-asr-model-provider-abstraction.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-03-08-asr-whisper-coupling-migration.md](plans/2026-03-08-asr-whisper-coupling-migration.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-03-09-speaker-role-semantics.md](plans/2026-03-09-speaker-role-semantics.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-03-11-caf-fast-path-m4a-durability-design.md](plans/2026-03-11-caf-fast-path-m4a-durability-design.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-03-11-caf-fast-path-m4a-durability.md](plans/2026-03-11-caf-fast-path-m4a-durability.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-03-11-modular-provider-architecture-design.md](plans/2026-03-11-modular-provider-architecture-design.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-03-11-modular-provider-architecture-implementation.md](plans/2026-03-11-modular-provider-architecture-implementation.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-03-12-auto-transcribe-precheck-and-compact-models-design.md](plans/2026-03-12-auto-transcribe-precheck-and-compact-models-design.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-03-12-auto-transcribe-precheck-and-compact-models.md](plans/2026-03-12-auto-transcribe-precheck-and-compact-models.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-03-12-distribution-packaging-design.md](plans/2026-03-12-distribution-packaging-design.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-04-24-fluid-audio-file-asr.md](plans/2026-04-24-fluid-audio-file-asr.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-07-31-capture-health-recovery-design.md](plans/2026-07-31-capture-health-recovery-design.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-07-31-capture-health-recovery.md](plans/2026-07-31-capture-health-recovery.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-07-31-recordly-app-icon-design.md](plans/2026-07-31-recordly-app-icon-design.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-07-31-recordly-app-icon.md](plans/2026-07-31-recordly-app-icon.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-08-05-stable-local-debug-signing-design.md](plans/2026-08-05-stable-local-debug-signing-design.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-08-05-stable-local-debug-signing.md](plans/2026-08-05-stable-local-debug-signing.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-10-09-audio-pipeline-v2-design.md](plans/2026-10-09-audio-pipeline-v2-design.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-10-09-audio-pipeline-v2-implementation.md](plans/2026-10-09-audio-pipeline-v2-implementation.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-10-09-audio-pipeline-v2-request.md](plans/2026-10-09-audio-pipeline-v2-request.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-10-09-transcription-progress.md](plans/2026-10-09-transcription-progress.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/plans/2026-10-10-fluid-sdk-speaker-continuity.md](plans/2026-10-10-fluid-sdk-speaker-continuity.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/progress-and-summary-placeholder-report.md](progress-and-summary-placeholder-report.md) | Current guide/report; reviewed facts and links |
| [docs/project-status.md](project-status.md) | New current status / native acceptance evidence |
| [docs/prompts/2026-03-11-model-settings-screen-redesign.md](prompts/2026-03-11-model-settings-screen-redesign.md) | Design reference; current scope added, GUI acceptance not claimed |
| [docs/recording-7C943EA0-verification.md](recording-7C943EA0-verification.md) | New current status / native acceptance evidence |
| [docs/research/diarization-options.md](research/diarization-options.md) | Dated research; current Recordly decision/limits added |
| [docs/superpowers/plans/2026-03-10-diarization-model-provisioning.md](superpowers/plans/2026-03-10-diarization-model-provisioning.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/superpowers/plans/2026-07-07-capture-energy-optimization.md](superpowers/plans/2026-07-07-capture-energy-optimization.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/superpowers/specs/2026-03-10-diarization-model-provisioning-design.md](superpowers/specs/2026-03-10-diarization-model-provisioning-design.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [docs/superpowers/specs/2026-07-07-capture-energy-optimization-design.md](superpowers/specs/2026-07-07-capture-energy-optimization-design.md) | Historical plan/spec; reviewed delivery, supersession and open acceptance notice |
| [releases/standalone-2026-10-10/README.md](../releases/standalone-2026-10-10/README.md) | Fixed previous release; rollback status added |
| [releases/standalone-2026-10-10-fluid-speakers/README.md](../releases/standalone-2026-10-10-fluid-speakers/README.md) | Current fixed release; installation/reprocessing evidence added |
| [third-party/FluidAudio-0.17.7/NemoTextProcessing-LICENSE.md](../third-party/FluidAudio-0.17.7/NemoTextProcessing-LICENSE.md) | Preserved byte-for-byte; upstream license or verbatim archived source |
| [third-party/FluidAudio-0.17.7/NemoTextProcessing-THIRD-PARTY-LICENSES.md](../third-party/FluidAudio-0.17.7/NemoTextProcessing-THIRD-PARTY-LICENSES.md) | Preserved byte-for-byte; upstream license or verbatim archived source |
| [third-party/FluidAudio-0.17.7/fastcluster-LICENSE.md](../third-party/FluidAudio-0.17.7/fastcluster-LICENSE.md) | Preserved byte-for-byte; upstream license or verbatim archived source |
| [third-party/FluidAudio-0.17.7/vbx-LICENSE.md](../third-party/FluidAudio-0.17.7/vbx-LICENSE.md) | Preserved byte-for-byte; upstream license or verbatim archived source |

## Speaker alignment follow-up

After the 64-file documentation snapshot above, two Markdown references were added: [speaker transcript alignment](speaker-transcript-alignment.md) and [its standalone manifest](../releases/standalone-2026-10-10-speaker-alignment/README.md). Project status, recording verification, README/index, SDK verification/changelog and the previous release's notice were updated with the corrected mapping, native repeat/name evidence and fixed archive integrity. Historical test counts and old release artifacts remain labeled as historical; vendor notices are unchanged.

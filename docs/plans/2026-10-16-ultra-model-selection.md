# FluidAudio Ultra and model selection implementation plan

> Execute sequentially in this session; user approved moving to Ultra and the Spokenly-style model table. Preserve the other agent's pending token-spacing fix.

**Goal:** Make Parakeet Ultra the default ASR and provide installed/downloadable Ultra and v3 selection inside Recordly.

**Architecture:** Keep FluidAudio/Core ML and the existing bounded Audio Pipeline V2. Provider owns exact per-model SDK caches, readiness, downloads and persistent choice; backend loads the version matching the resolved directory and fingerprints that identity. Models UI owns presentation only. Each transcription resolves one model URL before processing; switching affects the next job. Keep speaker SDK/artifacts and summaries unchanged.

**Tech stack:** Swift, SwiftUI, Combine, FluidAudio 0.17.7, Core ML / Neural Engine, XCTest.

## UX structure

Top: Models heading and local-transcription description. Main rounded table: selection control, model/name/description/actions, execution engine, features (no invented quality/speed scores). Rows: Ultra (recommended default) and v3 (existing option). Separate Download and Use controls; installation alone never changes the active choice. Installed inactive models can be removed only while no transcription work is queued/running. Current model cannot be removed. Download shows progress, setup state and retry on failure. No fake ratings, cloud tabs or nonfunctional Test buttons. Diarization remains separately grouped below; Summary remains unavailable.

## Style

Follow supplied Spokenly reference: dark neutral table, compact uppercase column headings, horizontal row dividers, blue selected row and radio selection, concise link-style download/remove actions. Use native SF Symbols rather than copying third-party logos. Support narrower sheet widths and large text with wrapping and accessible selection/status labels.

## Tasks

1. Add failing tests to FluidAudioASREngineTests for default Ultra, exact model-specific cache resolution, persisted installed-only selection, inactive-only removal, per-model progress/failure and cache identity. Existing explicit-v3 tests must select v3 deliberately. Run RED.
2. Add model catalog enum beside FluidAudioRuntimeIdentity, per-model SDK version/cache mapping, provider states/preferences and injected download runner. Download into the supplied SDK root and verify complete bundles. Implement minimal changes and run GREEN.
3. Load the selected model version in FluidAudioTranscriber; retain single-manager reuse and default ANE compute placement. Record explicit model identity in cache fingerprint; preserve existing v3 fingerprint compatibility.
4. Expose catalog states in ModelSettingsViewModel; implement table-style selector, progress, errors, use and safe removal. Keep operations backend-agnostic and reject deletion while processing. Add behavioral view-model tests and run focused checks.
5. Run combined full suite with the pending spacing correction. Native smoke-test installed Ultra against a temporary bounded audio excerpt; test both model identities and compare canonical tokens/spacing. Build a signed standalone containing both changes. Inspect a rendered model sheet where native UI permission allows; otherwise render the actual SwiftUI view to an artifact.
6. Apply only our files onto the other agent's completed fix without overwriting their files, verify combined build and tests, commit, update delivery docs, synchronize develop/master if baseline remains compatible, preserve release ZIP, install and launch. Do not race the other agent's app installation; wait for its completion first.

## Acceptance

Ultra is the fresh default; v3 remains explicitly selectable. A directory for another family cannot satisfy readiness. Download progress is real SDK byte progress; setup may remain indeterminate. Failed downloads never activate a model. SDK/model-version/path identify results and prevent stale ASR cache reuse. Existing user audio and speaker names stay intact. Energy efficiency is a hardware-measurement limitation, not a numerical claim inferred from ANE availability.

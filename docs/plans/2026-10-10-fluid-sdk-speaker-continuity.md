# FluidAudio update and session speaker continuity implementation plan

> Reviewed 2026-10-10. Historical plan/requirements. SDK 0.17.7, conservative session matching, tests, release and installation delivered. Original-recording replay is complete; annotated accuracy and full speaker continuity remain open. Original instructions and checklist/test counts below are a dated snapshot, not new execution instructions or current acceptance. See [current project status](../project-status.md).

> For implementers: use subagent-driven-development in this session, test-driven-development for behavior changes, and requesting-code-review before delivery.

**Goal:** Update FluidAudio from 0.14.0 to the verified 0.17.7 release and identify returning speakers across windows of one recording, preserving names and bounded AAC processing.

**Architecture:** Keep the existing offline Core ML diarizer and Parakeet v3. Preserve model-scoped voice evidence in the backend-independent diarization document, then resolve local groups to session identities in the segmented persistence layer. Strong matches reuse IDs; insufficient or ambiguous evidence stays explicitly window-local. Audio chunks and existing recordings remain compatible; no cross-meeting voice database or whole-session PCM export.

**Tech stack:** Swift, Core ML, FluidAudio 0.17.7, XCTest, existing signed standalone packaging.

## Task 1 — SDK and exact readiness

Files: Recordly.xcodeproj/project.pbxproj and Package.resolved; FluidAudioASRModelProvider.swift; FluidAudioDiarizationModelProvider.swift; FluidAudioTranscriptionService.swift; FluidAudioASREngine.swift; relevant provisioning/fingerprint tests.

1. Add failing tests: unrelated/empty model directories cannot make diarization Ready; ASR chooses the canonical v3 package rather than the alphabetically first valid package; SDK version participates in ASR inference cache identity.
2. Run focused tests with the old SDK to prove failures.
3. Pin 0.17.7, resolve in a separate package cache, adapt actual API changes, keep v3 and existing offline backend, and correct readiness checks against the actual required offline assets.
4. Run focused tests, then compile all test sources and Release. Record toolchain/platform and packaging consequences; do not change summarization placeholders.
5. Commit scoped verified changes.

## Task 2 — Preserve voice evidence and match session speakers

Files: Models/DiarizationDocument.swift; FluidAudioDiarizationModelProvider.swift; FluidAudioDiarizationEngine.swift; Segmented/WindowInferencePersistence.swift; Segmented/SegmentedTranscriptionPipeline.swift; Segmented/InferenceWindowPlan.swift; SegmentedInferenceTests.swift; backend diarization tests.

1. Add failing compatibility and identity tests: legacy documents without embeddings decode; returning voice after a long gap and relabeled groups reuse ID/name; co-occurring speakers cannot collapse; ambiguous/invalid/short evidence cannot force a match; different embedding model identities cannot match; cancellation/resume/cache reuse/reprocess preserve ownership and timing.
2. Run tests to establish RED.
3. Export normalized WeSpeaker voice embeddings from the SDK adapter; associate them with local labels and artifact identity. Persist only bounded representative evidence per session speaker, with exclusive voiced-duration checks and no transcript/audio payload duplication.
4. Resolve all speakers in a window once using conservative similarity plus runner-up margin and one-to-one/co-occurrence constraints. Keep existing turn-based local identity fallback for legacy or uncertain evidence. Preserve user names without matching on raw backend labels.
5. Rebuild mappings from current window evidence on reprocess; retain compatible named profiles as anchors, invalidate stale inference results when SDK/matching contracts change, and preserve recordings/recovery/copy behavior.
6. Set report continuity/degradation from actual evidence; emit readable speaker labels. Do not claim guaranteed personal identification or global certainty for unresolved groups.
7. Run focused tests and review behavior/quality before committing.

## Task 3 — Upstream changelog and acceptance

Files: docs/fluidaudio-upgrade-changelog.md; project changelog/readme links as appropriate; verification report.

1. Document official changes from v0.14.0 through v0.17.7, with release links, dates, relevance, and a clear distinction between SDK availability and features enabled in Recordly.
2. Include Ultra/Redux/Nemotron/new ASR/offline fixes, model and cache compatibility, platform constraints, and standalone size changes. Avoid copying whole upstream release notes.
3. Run the full suite and real Core ML diarization with installed models to verify evidence extraction and returning-voice behavior. Measure model load/processing/memory where possible; synthetic embeddings alone are not speech-quality validation.
4. Build and verify the signed standalone app and ZIP; record SHA-256/source commit and known limitations. Preserve the previous release as a rollback artifact.
5. Request independent spec review followed by code-quality review; fix material findings and rerun relevant checks. Commit and push the completed feature branch. Integrate develop/master and install the new app only when authorized scope and verified state permit.

## Verification commands

Use a dedicated package cache and derived-data directory to avoid changing the user's Xcode checkout/cache:

```sh
xcodebuild test -project Recordly.xcodeproj -scheme Recordly -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/recordly-speaker-sdk-tests -clonedSourcePackagesDirPath /private/tmp/recordly-speaker-sdk-packages CODE_SIGNING_ALLOWED=NO
RECORDLY_BUILD_DIR=/private/tmp/recordly-speaker-sdk-release RECORDLY_PACKAGE_CACHE=/private/tmp/recordly-speaker-sdk-packages ./scripts/build-standalone-local.sh
```

All release claims require the resulting exit code and logs. Voice similarity thresholds are engineering defaults requiring evaluation on real meeting audio; report false merges/splits and unknown groups, not just a reduced speaker count.

# Audio Pipeline V2 Implementation Plan

> Reviewed 2026-10-10. Historical plan/requirements. V2 A/B implemented and integrated into develop/master. Speaker continuity is now partial, not universally resolved. Original milestone C generation was subsequently disabled by user direction; hardware/long-session acceptance remains open. Original instructions and checklist/test counts below are a dated snapshot, not new execution instructions or current acceptance. See [current project status](../project-status.md).

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement the supplied A/B/C milestones without changing develop.
**Architecture:** Separate durable chunks, semantic timeline readers, inference window provenance and local model/runtime readiness. Preserve legacy session adapters and stage/backend ownership.
**Tech Stack:** Swift, AVFoundation, ScreenCaptureKit, CryptoKit, XCTest, FluidAudio 0.14.

For every task: add behavior tests first, run targeted xcodebuild tests to demonstrate missing behavior, implement, rerun targeted checks, then commit only verified changes. Use `/private/tmp/recordly-v2-verification` for derived data and macOS arm64 destination, CODE_SIGNING_ALLOWED=NO. Integration runs use real AAC files and controlled child processes.

1. A contracts and store: create `Recordly/Infrastructure/Capture/SessionAudioManifest.swift` and `RecordlyTests/SegmentedAudioTests.swift`. Test atomic commits, path validation, corrupt/missing manifests, orphan recovery and gaps. Register explicit Xcode sources.
2. A writer: create `SegmentedTrackWriter.swift`. Test small configured rotations, valid AAC tails, timing and bounded finalization. Adapt AudioCaptureService and microphone fallback; preserve health after committed writes. Commit separately.
3. A reader/playback: create semantic range reader and playlist playback; adapt RecordingSession assets, workflow recovery and repository availability without legacy migration. Test seek, mix, gaps and old sessions. Run full suite and document measurements.
4. B orchestration: create segmented transcription processor using existing engine factory. Test cross-chunk windows, offset/ownership, failure and cancellation.
5. B provenance/speakers: implement validated window caches and persistent speaker identities, with explicit unresolved continuity if FluidAudio has no validated bounded reconciliation. Test changed audio, timeline, model, backend, restart, rename.
6. C runtime/model: reproduce selection error, fix exact discovery/readiness failures with failing tests. Add explicit executable preference and preserve diagnostics. Review existing MLX separately.
7. C acceptance: build signed Release; launch via LaunchServices without PATH assumptions, test supported model generation if assets exist. Record unmet prerequisites precisely. Do not fabricate measurements or root causes.
8. Independent review and final checks: full suite, forced crash fixtures, Release build, architecture/README update and final report. Leave feature branch unmerged.

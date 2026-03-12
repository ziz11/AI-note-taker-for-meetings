# CAF Fast Path and M4A Durability Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make live capture write temporary `CAF PCM` source tracks for immediate auto-transcription while writing durable `m4a` source tracks for recovery, reprocessing, and long-term storage.

**Architecture:** Capture will dual-write source-track buffers into temporary `CAF` and durable `m4a` files. The transcription pipeline will explicitly choose `CAF` for immediate fast-path work when available and fall back to `m4a` for recovery and reprocessing. Provenance will be persisted in existing session metadata so the UI can show which source was used.

**Tech Stack:** Swift, AVFoundation, existing Recordly capture pipeline, session metadata JSON, XCTest.

---

### Task 1: Document current artifact and metadata touchpoints

**Files:**
- Modify: `Recordly/Infrastructure/Capture/AudioCaptureService.swift`
- Modify: `Recordly/Infrastructure/Transcription/TranscriptionPipeline.swift`
- Modify: `Recordly/Domain/Recordings/RecordingSession.swift`
- Modify: `Recordly/Infrastructure/Persistence/RecordingsRepository.swift`
- Test: `RecordlyTests/TranscriptionPipelineTests.swift`

**Step 1: Write a focused inventory note in comments or plan scratchpad**

Inspect and list:

- current live source artifact names returned by `CaptureArtifacts`
- where `session.json` stores playable/source files
- where `capture-session.json` is written and read
- where transcription source labels are derived today

**Step 2: Verify there is no hidden dependence on `.flac` names outside capture/pipeline**

Run: `rg -n "raw\\.flac|raw\\.caf|mic\\.m4a|system\\.m4a|merged-call\\.m4a" Recordly RecordlyTests`
Expected: all call sites are identified before code changes begin.

**Step 3: Commit**

```bash
git add docs/plans/2026-03-11-caf-fast-path-m4a-durability*.md
git commit -m "docs: add caf fast path and m4a durability plan"
```

### Task 2: Add failing tests for transcription source selection

**Files:**
- Test: `RecordlyTests/TranscriptionPipelineTests.swift`
- Modify: `Recordly/Infrastructure/Transcription/TranscriptionPipeline.swift`

**Step 1: Write a failing test for immediate fast-path preference**

Add a test that sets up a live-capture recording with both:

- `mic.raw.caf` and `system.raw.caf`
- `mic.m4a` and `system.m4a`

The test should assert that immediate transcription selects the `CAF` inputs first.

**Step 2: Write a failing test for recovery fallback**

Add a test that simulates missing or invalid `CAF` artifacts while `m4a` artifacts exist and asserts that the pipeline selects `m4a`.

**Step 3: Write a failing test for playback isolation**

Assert that `merged-call.m4a` is never chosen as an ASR input when source-track artifacts are present.

**Step 4: Run tests to verify they fail**

Run: `xcodebuild test -scheme Recordly -destination "platform=macOS" -only-testing:RecordlyTests/TranscriptionPipelineTests`
Expected: FAIL in the new source-selection cases.

**Step 5: Commit**

```bash
git add RecordlyTests/TranscriptionPipelineTests.swift
git commit -m "test: cover caf fast path and m4a fallback selection"
```

### Task 3: Add provenance types and persistence coverage

**Files:**
- Modify: `Recordly/Infrastructure/Capture/AudioCaptureService.swift`
- Modify: `Recordly/Domain/Recordings/RecordingSession.swift`
- Modify: `Recordly/Infrastructure/Persistence/RecordingsRepository.swift`
- Test: `RecordlyTests/TranscriptionPipelineTests.swift`

**Step 1: Write a failing test for provenance persistence**

Add a test that verifies a session can persist and reload a technical transcription provenance value such as:

```swift
enum TranscriptionAudioProvenance: String, Codable {
    case cafPcmFastPath
    case m4aRecovery
    case m4aReprocess
}
```

**Step 2: Add minimal model changes**

Extend the existing session metadata types with provenance fields that are backward-compatible when missing from older sessions.

**Step 3: Thread provenance through persistence**

Update repository/session mapping so the detail UI can read the persisted provenance without inventing a new metadata file.

**Step 4: Run focused tests**

Run: `xcodebuild test -scheme Recordly -destination "platform=macOS" -only-testing:RecordlyTests/TranscriptionPipelineTests`
Expected: PASS for provenance coverage, other new tests may still fail.

**Step 5: Commit**

```bash
git add Recordly/Infrastructure/Capture/AudioCaptureService.swift Recordly/Domain/Recordings/RecordingSession.swift Recordly/Infrastructure/Persistence/RecordingsRepository.swift RecordlyTests/TranscriptionPipelineTests.swift
git commit -m "feat: persist transcription audio provenance"
```

### Task 4: Add durable M4A source-track writers in capture

**Files:**
- Modify: `Recordly/Infrastructure/Capture/AudioCaptureService.swift`
- Possibly modify: `Recordly/Infrastructure/Capture/SessionMergeService.swift`

**Step 1: Write the failing capture test or add a focused seam for verification**

If there are existing capture tests, extend them. Otherwise add a small seam around writer creation so dual-write behavior can be verified without full device capture.

**Step 2: Implement minimal dual-write capture**

Add separate source-track outputs:

- temporary `mic.raw.caf`
- temporary `system.raw.caf`
- durable `mic.m4a`
- durable `system.m4a`

The same incoming microphone/system buffer should be appended to both writer types.

**Step 3: Keep `CaptureArtifacts` aligned to durable source files**

Ensure the recording/session model exposes `mic.m4a` and `system.m4a` as the persisted source-track artifacts used by later recovery and UI state.

**Step 4: Preserve existing merge behavior**

Keep `merged-call.m4a` generation isolated to playback output and do not feed it into source-track routing.

**Step 5: Run focused tests or build**

Run: `xcodebuild test -scheme Recordly -destination "platform=macOS" -only-testing:RecordlyTests/TranscriptionPipelineTests`
Expected: build succeeds and no existing artifact-name assumptions remain in touched tests.

**Step 6: Commit**

```bash
git add Recordly/Infrastructure/Capture/AudioCaptureService.swift Recordly/Infrastructure/Capture/SessionMergeService.swift
git commit -m "feat: dual-write caf and m4a source tracks"
```

### Task 5: Implement pipeline source selection and validation

**Files:**
- Modify: `Recordly/Infrastructure/Inference/Audio/AudioInput.swift`
- Modify: `Recordly/Infrastructure/Transcription/TranscriptionPipeline.swift`
- Possibly modify: `Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioSessionAudioLoader.swift`
- Test: `RecordlyTests/TranscriptionPipelineTests.swift`

**Step 1: Implement explicit source-selection helpers**

Add a small backend-agnostic selector that can answer:

- immediate live path: prefer `*.raw.caf`, fallback to `*.m4a`
- recovery/reprocess path: prefer `*.m4a`

**Step 2: Validate candidate input before committing to it**

Use the existing audio preparation/loading boundary to verify that the selected artifact exists and can be read as supported audio input.

**Step 3: Keep fallback policy in pipeline**

Do not move source fallback logic into `FluidAudioASREngine` or loader code. Backend code should prepare what it is given; pipeline chooses what to give it.

**Step 4: Run focused tests**

Run: `xcodebuild test -scheme Recordly -destination "platform=macOS" -only-testing:RecordlyTests/TranscriptionPipelineTests`
Expected: PASS for fast-path, fallback, and playback-isolation tests.

**Step 5: Commit**

```bash
git add Recordly/Infrastructure/Inference/Audio/AudioInput.swift Recordly/Infrastructure/Transcription/TranscriptionPipeline.swift Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioSessionAudioLoader.swift RecordlyTests/TranscriptionPipelineTests.swift
git commit -m "feat: prefer caf fast path and m4a recovery inputs"
```

### Task 6: Add terminal-state cleanup for temporary CAF artifacts

**Files:**
- Modify: `Recordly/Features/Recordings/Application/RecordingWorkflowController.swift`
- Modify: `Recordly/Infrastructure/Transcription/TranscriptionPipeline.swift`
- Modify: `Recordly/Infrastructure/Capture/AudioCaptureService.swift`
- Test: `RecordlyTests/TranscriptionPipelineTests.swift`

**Step 1: Write a failing test for cleanup timing**

Add a test that asserts temporary `CAF` files are not deleted before transcription reaches `ready` or `failed`.

**Step 2: Implement minimal cleanup hook**

Delete `mic.raw.caf` and `system.raw.caf` only after the transcription workflow records a terminal outcome and provenance has already been persisted.

**Step 3: Make cleanup best-effort**

Cleanup failure should append a note or debug warning, not fail the transcript job after it already completed.

**Step 4: Run focused tests**

Run: `xcodebuild test -scheme Recordly -destination "platform=macOS" -only-testing:RecordlyTests/TranscriptionPipelineTests`
Expected: PASS for cleanup timing and prior selection tests.

**Step 5: Commit**

```bash
git add Recordly/Features/Recordings/Application/RecordingWorkflowController.swift Recordly/Infrastructure/Transcription/TranscriptionPipeline.swift Recordly/Infrastructure/Capture/AudioCaptureService.swift RecordlyTests/TranscriptionPipelineTests.swift
git commit -m "feat: clean up temporary caf artifacts after transcription"
```

### Task 7: Surface provenance in UI metadata

**Files:**
- Modify: `Recordly/Domain/Recordings/RecordingSession.swift`
- Modify: `Recordly/Features/Recordings/Views/RecordingDetailView.swift`

**Step 1: Write a small failing view-model/domain test if coverage exists**

If there is domain/UI coverage for metadata labels, add a test for a debug-facing value such as:

- `CAF PCM fast path`
- `M4A recovery`
- `M4A reprocess`

**Step 2: Implement minimal label mapping**

Extend the existing metadata label surface so it can show the technical provenance alongside the existing high-level transcript source.

**Step 3: Keep UI copy explicitly debug-oriented**

Do not replace the current user-facing `Transcript Source` semantics if that would confuse end users. Add a second field or a more technical label if needed.

**Step 4: Run relevant tests or build**

Run: `xcodebuild test -scheme Recordly -destination "platform=macOS" -only-testing:RecordlyTests/TranscriptionPipelineTests`
Expected: existing tests stay green.

**Step 5: Commit**

```bash
git add Recordly/Domain/Recordings/RecordingSession.swift Recordly/Features/Recordings/Views/RecordingDetailView.swift
git commit -m "feat: show transcription audio provenance in details"
```

### Task 8: Final verification

**Files:**
- Modify: `Recordly/Infrastructure/Capture/AudioCaptureService.swift`
- Modify: `Recordly/Infrastructure/Transcription/TranscriptionPipeline.swift`
- Modify: `Recordly/Domain/Recordings/RecordingSession.swift`
- Modify: `Recordly/Infrastructure/Persistence/RecordingsRepository.swift`
- Modify: `Recordly/Features/Recordings/Application/RecordingWorkflowController.swift`
- Modify: `Recordly/Features/Recordings/Views/RecordingDetailView.swift`
- Test: `RecordlyTests/TranscriptionPipelineTests.swift`

**Step 1: Run targeted regression tests**

Run: `xcodebuild test -scheme Recordly -destination "platform=macOS" -only-testing:RecordlyTests/TranscriptionPipelineTests`
Expected: PASS

**Step 2: Run broader app tests if affordable**

Run: `xcodebuild test -scheme Recordly -destination "platform=macOS"`
Expected: PASS, or a clearly documented pre-existing failure outside this change.

**Step 3: Inspect artifact names and cleanup assumptions**

Run: `rg -n "raw\\.flac|raw\\.caf|mic\\.m4a|system\\.m4a|merged-call\\.m4a" Recordly RecordlyTests`
Expected: only intended references remain.

**Step 4: Review git diff**

Run: `git diff --stat` and `git diff -- docs/plans/2026-03-11-caf-fast-path-m4a-durability*.md`
Expected: changes match the approved design and no unrelated files were modified accidentally.

**Step 5: Commit**

```bash
git add Recordly RecordlyTests docs/plans/2026-03-11-caf-fast-path-m4a-durability*.md
git commit -m "feat: add caf fast path with durable m4a recovery"
```

Plan complete and saved to `docs/plans/2026-03-11-caf-fast-path-m4a-durability.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?

# Auto-Transcribe Precheck And Compact Models Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Block auto-transcription with a clear persisted reason and `Open Models` action when the FluidAudio diarization package is missing, and compact the Models settings UI without changing its structure.

**Architecture:** Keep transcription readiness decisions in workflow, keep runtime availability reporting in the selector layer, and keep Models compaction strictly in the settings UI. Do not change backend routing, canonical artifacts, or persistence layout beyond preserving the real failure reason.

**Tech Stack:** Swift, SwiftUI, XCTest, Xcode/macOS app flow, existing `RecordingWorkflowController` and `ModelSettingsView` structure.

---

### Task 1: Preserve the real transcription failure note

**Files:**
- Modify: `Recordly/Features/Recordings/Application/RecordingWorkflowController.swift`
- Test: `RecordlyTests/TranscriptionPipelineTests.swift`

**Step 1: Write the failing test**

Add a test proving offline merge recovery does not overwrite an existing transcription failure note on a failed recording.

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Recordly -destination 'platform=macOS' -only-testing:RecordlyTests/TranscriptionPipelineTests/<new_test_name>`

Expected: FAIL because recovery still rewrites the note to `Offline merge completed.`

**Step 3: Write minimal implementation**

Update merge-recovery logic in `RecordingWorkflowController` so it only writes `Offline merge completed.` when there is no higher-priority transcription failure already persisted.

**Step 4: Run test to verify it passes**

Run the same targeted command.

Expected: PASS

**Step 5: Commit**

```bash
git add Recordly/Features/Recordings/Application/RecordingWorkflowController.swift RecordlyTests/TranscriptionPipelineTests.swift
git commit -m "fix: preserve transcription failure notes during merge recovery"
```

### Task 2: Add explicit auto-transcribe precheck alert flow

**Files:**
- Modify: `Recordly/Features/Recordings/Application/RecordingWorkflowController.swift`
- Modify: `Recordly/Features/Recordings/Application/RecordingsStore.swift`
- Modify: `Recordly/App/ContentView.swift`
- Test: `RecordlyTests/TranscriptionPipelineTests.swift`

**Step 1: Write the failing test**

Add a workflow-level test covering:

- live capture completes
- transcription availability is `.degradedNoDiarization`
- auto-transcribe does not start pipeline work
- session ends with actionable failure note
- UI-facing state receives an `Open Models` capable alert payload

**Step 2: Run test to verify it fails**

Run the targeted test command for the new case.

Expected: FAIL because current flow throws/fails without a dedicated alert contract and without preserving a dedicated precheck path.

**Step 3: Write minimal implementation**

- Add a compact alert state owned by store/UI
- Populate it from the workflow when precheck blocks auto-transcribe
- Ensure the failure reason is persisted on the recording/session
- Ensure no pipeline processing starts in this path

**Step 4: Run test to verify it passes**

Run the same targeted command.

Expected: PASS

**Step 5: Commit**

```bash
git add Recordly/Features/Recordings/Application/RecordingWorkflowController.swift Recordly/Features/Recordings/Application/RecordingsStore.swift Recordly/App/ContentView.swift RecordlyTests/TranscriptionPipelineTests.swift
git commit -m "feat: block auto-transcribe when diarization package is missing"
```

### Task 3: Wire `Open Models` from the blocking alert

**Files:**
- Modify: `Recordly/Features/Recordings/Application/RecordingsStore.swift`
- Modify: `Recordly/App/ContentView.swift`
- Test: `RecordlyTests/RecordingsPhaseOneTests.swift`

**Step 1: Write the failing test**

Add a focused UI/store test that activating the alert primary action opens the Models window/panel path used by the existing app.

**Step 2: Run test to verify it fails**

Run the new targeted test.

Expected: FAIL because the alert action is not yet connected to Models presentation.

**Step 3: Write minimal implementation**

Use the existing Models presentation path in store/content view and wire the alert primary action to it. Avoid adding a second Models-opening mechanism.

**Step 4: Run test to verify it passes**

Run the same targeted test.

Expected: PASS

**Step 5: Commit**

```bash
git add Recordly/Features/Recordings/Application/RecordingsStore.swift Recordly/App/ContentView.swift RecordlyTests/RecordingsPhaseOneTests.swift
git commit -m "feat: open models from transcription precheck alert"
```

### Task 4: Compact the Models settings presentation

**Files:**
- Modify: `Recordly/Features/Settings/Models/ModelSettingsView.swift`
- Modify: `Recordly/Features/Settings/Models/ModelSettingsViewModel.swift` only if minor view-model shaping is needed
- Reference: `docs/prompts/2026-03-11-model-settings-screen-redesign.md`
- Test: `RecordlyTests/ModelSettingsViewModelTests.swift` if view-model output changes

**Step 1: Write the failing test**

If any view-model outputs or compact status labels change, add/adjust tests first. If the change is strictly visual and current tests do not cover layout-facing values, add the smallest testable assertion for the compact diarization package state text or action availability.

**Step 2: Run test to verify it fails**

Run the targeted model settings test command.

Expected: FAIL if any exposed values change; otherwise document that no red test is needed because the task is purely presentational and keep code changes minimal.

**Step 3: Write minimal implementation**

- Reduce section spacing
- Reduce card padding
- Tighten action row spacing
- Shorten visible secondary copy where needed
- Keep provider/runtime grouping and actions intact
- Make FluidAudio diarization status easy to scan in compact form

**Step 4: Run test to verify it passes**

Run the targeted model settings test command.

Expected: PASS

**Step 5: Commit**

```bash
git add Recordly/Features/Settings/Models/ModelSettingsView.swift Recordly/Features/Settings/Models/ModelSettingsViewModel.swift RecordlyTests/ModelSettingsViewModelTests.swift
git commit -m "style: compact models settings layout"
```

### Task 5: End-to-end verification

**Files:**
- No production changes required unless verification exposes a missed gap

**Step 1: Run focused automated verification**

Run:

```bash
xcodebuild test -scheme Recordly -destination 'platform=macOS' -only-testing:RecordlyTests/TranscriptionPipelineTests -only-testing:RecordlyTests/RecordingsPhaseOneTests -only-testing:RecordlyTests/ModelSettingsViewModelTests
```

Expected: PASS, 0 failures

**Step 2: Run manual workflow verification**

Manual scenario:

- make sure FluidAudio diarization package is not installed
- create a new live-capture recording with auto-transcribe enabled
- confirm recording saves successfully
- confirm transcription is blocked before pipeline start
- confirm compact blocking alert appears
- confirm `Open Models` navigates to Models
- confirm the recording/session note keeps the actionable reason

**Step 3: If manual verification exposes a bug, add the failing test first**

Do not patch behavior without a red test.

**Step 4: Commit final polish if needed**

```bash
git add <files>
git commit -m "test: verify transcription precheck and compact models flow"
```

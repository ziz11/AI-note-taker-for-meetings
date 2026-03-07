# ScreenCaptureKit Offline Merge Implementation Plan

> **Status:** Completed. File paths updated to reflect the Recordly rename (originally written when the project was named CallRecorderPro).

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace realtime CoreAudioTap merge with ScreenCaptureKit raw capture + deterministic offline merge and recovery.

**Architecture:** Capture service writes canonical per-track raw files and metadata stats. Stop transitions session into post-processing states. Merge service aligns by PTS offsets and renders deterministic merged CAF (optionally m4a). Workflow/store consume asynchronous state changes without blocking UI.

**Tech Stack:** SwiftUI app, ScreenCaptureKit, AVFoundation, JSON metadata persistence.

---

### Task 1: Platform + legacy cleanup
**Files:**
- Modify: `Recordly.xcodeproj/project.pbxproj`
- Modify: `Recordly/Infrastructure/Capture/AudioCaptureService.swift`

1. Raise deployment target to macOS 15.0.
2. Remove CoreAudio tap/aggregate connector path and related unsupported branches.
3. Ensure capture service uses ScreenCaptureKit-first orchestration.

### Task 2: Session metadata and status model
**Files:**
- Create: `Recordly/Domain/Recordings/CallRecordingSession.swift`
- Create: `Recordly/Infrastructure/Persistence/SessionMetadataStore.swift`
- Modify: `Recordly.xcodeproj/project.pbxproj`

1. Add status enum for `recording/finalizingTracks/readyForMix/mixing/ready/mixError`.
2. Add track stats model (`firstPTS`, `lastPTS`, `framesWritten`, `sampleRate`, diagnostics).
3. Add metadata store create/update/load helpers for `session.json` lifecycle.

### Task 3: Canonical PCM writing
**Files:**
- Create: `Recordly/Infrastructure/Capture/PCMTrackWriter.swift`
- Modify: `Recordly.xcodeproj/project.pbxproj`

1. Build canonical writer (Float32, 48k mono, non-interleaved CAF).
2. Accept CMSampleBuffer input, convert to canonical format, write frames.
3. Accumulate deterministic runtime stats and expose finish snapshot.

### Task 4: ScreenCapture service
**Files:**
- Create: `Recordly/Infrastructure/Capture/ScreenCaptureAudioService.swift`
- Modify: `Recordly/Infrastructure/Capture/AudioCaptureService.swift`
- Modify: `Recordly.xcodeproj/project.pbxproj`

1. Implement stream startup with system+mic outputs.
2. Route output callbacks to dedicated track writers.
3. Stop flow transitions metadata status and guarantees cleanup in `defer`.
4. Keep fallback diagnostics path if mic output is unavailable.

### Task 5: Offline merge
**Files:**
- Create: `Recordly/Infrastructure/Capture/SessionMergeService.swift`
- Modify: `Recordly.xcodeproj/project.pbxproj`

1. Load metadata + raw tracks, compute offsets from firstPTS.
2. Compute frame-based and PTS-based durations, write drift warnings.
3. Offline render merged CAF, then optional m4a export.
4. Keep merge idempotent (re-run replaces derived outputs only).

### Task 6: Workflow integration
**Files:**
- Modify: `Recordly/Features/Recordings/Application/RecordingWorkflowController.swift`
- Modify: `Recordly/Features/Recordings/Application/RecordingsStore.swift`
- Modify: `Recordly/Domain/Recordings/RecordingSession.swift`

1. Wire new status progression without treating absent merged file as immediate failure.
2. Keep UI responsive after stop while merge runs in background.
3. Reflect single-track success states in notes/labels.

### Task 7: Recovery + verification
**Files:**
- Create: `Recordly/Infrastructure/Capture/RecordingRecoveryService.swift`
- Modify: `Recordly/App/RecordlyApp.swift`
- Optional tests: add offset math / metadata transition test target if time permits.

1. Resume unfinished sessions on app launch.
2. Re-run merge for eligible statuses safely.
3. Run verification build command and report evidence.

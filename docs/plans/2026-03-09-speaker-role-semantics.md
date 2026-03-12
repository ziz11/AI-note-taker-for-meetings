# Speaker Role Semantics Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add explicit speaker-role semantics to transcript segments while keeping the current mic/system merge architecture and preserving compatibility with legacy transcript JSON.

**Architecture:** Extend `TranscriptSegment` with backend-neutral `speakerRole` and `speakerId`, then update only the transcript mapping boundary so mic segments always map to `me`, diarized system segments map to `remote`, and unresolved system segments map to `unknown`. Keep merge time-based, keep `speaker` as a display label, and make transcript decoding infer missing role/id data from legacy labels without changing persistence layout.

**Tech Stack:** Swift, Foundation, XCTest, Xcode project

**Test command:** `xcodebuild test -scheme Recordly -destination 'platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`

---

### Task 1: Lock in expected behavior with failing tests

**Files:**
- Modify: `RecordlyTests/SystemSpeakerMappingServiceTests.swift`
- Modify: `RecordlyTests/TranscriptMergeServiceTests.swift`
- Modify: `RecordlyTests/TranscriptionPipelineTests.swift`
- Create: `RecordlyTests/TranscriptDocumentCompatibilityTests.swift`

1. Add tests for mic role/id mapping, system diarized remote mapping, unresolved system mapping, merge preservation, and legacy transcript decoding.
2. Run the focused test targets and confirm failures are caused by missing `speakerRole` / `speakerId` semantics.

### Task 2: Implement explicit transcript speaker semantics

**Files:**
- Modify: `Recordly/Infrastructure/Transcription/Models/TranscriptDocument.swift`
- Modify: `Recordly/Infrastructure/Transcription/SystemSpeakerMappingService.swift`
- Modify: `Recordly/Infrastructure/Transcription/TranscriptionPipeline.swift`

1. Add `SpeakerRole` plus `speakerRole` / `speakerId` to `TranscriptSegment`.
2. Add custom decoding fallback for legacy transcript JSON.
3. Update mic and system mapping so runtime logic sets explicit roles and stable IDs without changing merge behavior.

### Task 3: Verify persistence and recovery compatibility

**Files:**
- Modify: `Recordly/Infrastructure/Persistence/RecordingsRepository.swift` only if needed for compatibility-safe display rendering
- Reuse: transcript decode path through `TranscriptDocument`

1. Confirm new JSON round-trips.
2. Confirm old JSON still loads through repository-backed transcript recovery without crashes.
3. Keep display rendering based on `speaker`.

### Task 4: Run verification and summarize

1. Run focused tests for the touched areas.
2. Run a broader regression test sweep if the focused run is clean.
3. Report modified files, target membership status, exact test results, and any compatibility caveats.

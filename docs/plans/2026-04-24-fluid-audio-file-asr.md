# FluidAudio File ASR Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move Recordly's FluidAudio ASR path from Recordly-owned manual VAD/30s buffer chunking to FluidAudio's native file/batch transcription path so the SDK owns long-audio chunking, disk-backed processing, model-specific decoding, and progress behavior.

**Architecture:** Keep `TranscriptionPipeline`, `RecordingWorkflowController`, and persistence unchanged. Localize the change inside the FluidAudio backend module by introducing a file-based transcription boundary and routing `FluidAudioASREngine` to call it with the existing canonical persisted audio URL. Keep `PreparedSessionAudio` and VAD code only where still needed by diarization or fallback paths; do not make WAV a canonical Recordly artifact.

**Tech Stack:** Swift, XCTest, FluidAudio `0.14.0`, CoreML/ANE, `AsrManager.transcribe(URL, decoderState:)`, `AsrModels.load(..., version: .v3)`.

---

## Current State

- Recordly already uses `InferenceBackend.fluidAudio` for ASR.
- `FluidAudioASRModelProvider` downloads/loads `AsrModels.downloadAndLoad(version: .v3)`, which corresponds to Parakeet TDT v3 CoreML.
- `FluidAudioTranscriptionService` currently loads the whole audio into `PreparedSessionAudio`, runs FluidAudio VAD, slices speech regions into `AVAudioPCMBuffer`s, and falls back to Recordly-owned 30s windows.
- FluidAudio `0.14.0` has file-based APIs: `AsrManager.transcribe(_ url: URL, decoderState: inout TdtDecoderState)`.
- That API internally chooses disk-backed processing for long files when `ASRConfig.streamingEnabled` and threshold conditions are met.

## Target Behavior

- For ASR, pass the durable Recordly audio file URL directly to FluidAudio.
- Let FluidAudio handle resampling, model chunking, overlap, decoder state, disk-backed processing, and progress.
- Keep Recordly responsible only for:
  - model resolution
  - backend routing
  - mapping `ASRResult` to `ASRDocument`
  - technical error mapping
  - persistence contracts
- Keep canonical artifacts unchanged: `mic.raw.caf`, `system.raw.caf`, `merged-call.caf`, `merged-call.m4a`.

## Non-Goals

- Do not add `parakeet-mlx`.
- Do not rename FluidAudio classes to MLX.
- Do not make `16k mono WAV` a persisted Recordly artifact.
- Do not change pipeline stage contracts.
- Do not change summary generation.
- Do not remove diarization fallback behavior.

---

### Task 1: Add File-Based Transcriber Contract

**Files:**
- Modify: `Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioTranscriptionService.swift`
- Test: `RecordlyTests/FluidAudioASREngineTests.swift`

**Step 1: Write the failing test**

Add a test proving ASR uses a file URL path instead of forcing `FluidAudioInputPreparer.prepareInput`.

```swift
func testEngineUsesFileBasedFluidAudioTranscriberWhenAvailable() async throws {
    let audioURL = try createAudioFile(named: "merged-call.m4a")
    let modelDirectory = try createFluidModelDirectory(named: "fluid-v3-file")
    let transcriber = RecordingFluidAudioFileTranscriber(
        output: FluidAudioRunnerOutput(
            language: "ru",
            segments: [
                FluidAudioSegment(
                    id: "seg-1",
                    startMs: 0,
                    endMs: 1_000,
                    text: "привет",
                    confidence: 0.9,
                    words: nil
                )
            ]
        )
    )
    let preparer = FailingFluidAudioInputPreparer()
    let engine = FluidAudioASREngine(
        transcriber: transcriber,
        inputPreparer: preparer
    )

    let document = try await engine.transcribe(
        audioURL: audioURL,
        channel: .mic,
        sessionID: UUID(),
        configuration: ASREngineConfiguration(modelURL: modelDirectory)
    )

    XCTAssertEqual(document.segments.first?.text, "привет")
    XCTAssertEqual(transcriber.lastAudioURL, audioURL)
    XCTAssertEqual(transcriber.lastChannel, .mic)
}
```

Add test helpers:

```swift
private final class RecordingFluidAudioFileTranscriber: FluidAudioTranscribing {
    var output: FluidAudioRunnerOutput
    var lastAudioURL: URL?
    var lastChannel: TranscriptChannel?

    init(output: FluidAudioRunnerOutput) {
        self.output = output
    }

    func transcribe(
        audioURL: URL,
        modelDirectoryURL: URL,
        channel: TranscriptChannel
    ) async throws -> FluidAudioRunnerOutput {
        lastAudioURL = audioURL
        lastChannel = channel
        return output
    }
}

private struct FailingFluidAudioInputPreparer: FluidAudioInputPreparing {
    func prepareInput(from audioURL: URL) throws -> AVAudioPCMBuffer {
        XCTFail("File-based ASR path should not prepare an in-memory buffer")
        throw ASREngineRuntimeError.unsupportedFormat(audioURL)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -scheme Recordly -destination "platform=macOS" -only-testing:RecordlyTests/FluidAudioASREngineTests/testEngineUsesFileBasedFluidAudioTranscriberWhenAvailable
```

Expected: FAIL because `FluidAudioTranscribing` does not yet expose `transcribe(audioURL:modelDirectoryURL:channel:)`.

**Step 3: Write minimal implementation**

Change `FluidAudioTranscribing` to file-based:

```swift
protocol FluidAudioTranscribing {
    func transcribe(
        audioURL: URL,
        modelDirectoryURL: URL,
        channel: TranscriptChannel
    ) async throws -> FluidAudioRunnerOutput
}
```

Temporarily keep buffer-based behavior inside a separate helper if needed by existing tests, but do not keep it as the ASR engine's primary path.

**Step 4: Run test to verify it passes**

Run the same targeted test. Expected: PASS.

**Step 5: Commit**

```bash
git add Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioTranscriptionService.swift RecordlyTests/FluidAudioASREngineTests.swift
git commit -m "test: define file-based FluidAudio ASR boundary"
```

---

### Task 2: Route FluidAudioASREngine To File-Based ASR

**Files:**
- Modify: `Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioASREngine.swift`
- Modify: `Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioTranscriptionService.swift`
- Test: `RecordlyTests/FluidAudioASREngineTests.swift`

**Step 1: Write the failing test**

Update existing tests that assert `inputPreparer` is called for ASR. Replace that expectation with a file-transcriber expectation.

Add a regression test:

```swift
func testEngineDoesNotLoadFullAudioIntoMemoryForASR() async throws {
    let audioURL = try createAudioFile(named: "long-call.m4a")
    let modelDirectory = try createFluidModelDirectory(named: "fluid-v3-long")
    let transcriber = RecordingFluidAudioFileTranscriber(
        output: FluidAudioRunnerOutput(language: "ru", segments: [])
    )
    let engine = FluidAudioASREngine(
        transcriber: transcriber,
        inputPreparer: FailingFluidAudioInputPreparer()
    )

    _ = try await engine.transcribe(
        audioURL: audioURL,
        channel: .system,
        sessionID: UUID(),
        configuration: ASREngineConfiguration(modelURL: modelDirectory)
    )

    XCTAssertEqual(transcriber.lastAudioURL, audioURL)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -scheme Recordly -destination "platform=macOS" -only-testing:RecordlyTests/FluidAudioASREngineTests
```

Expected: FAIL until `FluidAudioASREngine` stops calling `sessionAudioLoader.loadAudio(from:)` for ASR.

**Step 3: Write minimal implementation**

Change `FluidAudioASREngine.transcribe(...)` from:

```swift
let preparedAudio = try sessionAudioLoader.loadAudio(from: audioURL)
let output = try await transcriptionService.transcribe(
    preparedAudio: preparedAudio,
    modelDirectoryURL: configuration.modelURL,
    channel: channel
)
```

to:

```swift
let output = try await transcriptionService.transcribe(
    audioURL: audioURL,
    modelDirectoryURL: configuration.modelURL,
    channel: channel
)
```

Update `FluidAudioTranscriptionServicing`:

```swift
protocol FluidAudioTranscriptionServicing {
    func transcribe(
        audioURL: URL,
        modelDirectoryURL: URL,
        channel: TranscriptChannel
    ) async throws -> FluidAudioRunnerOutput
}
```

**Step 4: Run tests**

Run:

```bash
xcodebuild test -scheme Recordly -destination "platform=macOS" -only-testing:RecordlyTests/FluidAudioASREngineTests
```

Expected: PASS.

**Step 5: Commit**

```bash
git add Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioASREngine.swift Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioTranscriptionService.swift RecordlyTests/FluidAudioASREngineTests.swift
git commit -m "refactor: route FluidAudio ASR through file transcription"
```

---

### Task 3: Implement Native FluidAudio File Transcription

**Files:**
- Modify: `Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioTranscriptionService.swift`
- Test: `RecordlyTests/FluidAudioASREngineTests.swift`

**Step 1: Write the failing test**

Add a unit-level test around a fake transcriber or adapter seam proving decoder state is created per transcription call and manager cache is model-path keyed. If direct SDK calls are hard to unit-test, keep the test on the public `FluidAudioTranscribing` boundary and use integration build coverage for the SDK call.

Behavior to preserve:

```swift
XCTAssertEqual(engine.cacheFingerprint(configuration: config), "\(modelPath)|backend:fluidaudio|v3")
```

Behavior to add:

```swift
XCTAssertEqual(transcriber.callCount, 2)
XCTAssertEqual(transcriber.modelPaths, [modelDirectory.path, modelDirectory.path])
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -scheme Recordly -destination "platform=macOS" -only-testing:RecordlyTests/FluidAudioASREngineTests
```

Expected: FAIL if the adapter still calls buffer APIs.

**Step 3: Write minimal implementation**

In `FluidAudioTranscriber.transcribe(audioURL:modelDirectoryURL:channel:)`, call the SDK file API:

```swift
#if arch(arm64) && canImport(FluidAudio)
let manager = try await resolveManager(for: modelDirectoryURL)
var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
let rawResult = try await manager.transcribe(audioURL, decoderState: &decoderState)
return mapResult(rawResult)
#else
throw ASREngineRuntimeError.inferenceFailed(
    message: "FluidAudio SDK is not available. Add the FluidAudio Swift Package to Recordly target."
)
#endif
```

Keep `resolveManager`:

```swift
let models = try await AsrModels.load(from: modelDirectoryURL, configuration: nil, version: .v3)
let manager = AsrManager(config: .default, models: models)
```

**Step 4: Remove ASR-only manual chunking**

Remove or stop using these ASR-specific paths from `FluidAudioTranscriptionService`:

- `fullInputWindowDurationMs`
- `transcribeFullInput(...)`
- `transcribeRegions(...)`
- `makeFallbackWindows(...)`
- `offset(words:by:)`

Do not delete `PreparedSessionAudio` if diarization still uses it.

**Step 5: Run tests**

Run:

```bash
xcodebuild test -scheme Recordly -destination "platform=macOS" -only-testing:RecordlyTests/FluidAudioASREngineTests
xcodebuild test -scheme Recordly -destination "platform=macOS" -only-testing:RecordlyTests/DefaultInferenceEngineFactoryTests
xcodebuild test -scheme Recordly -destination "platform=macOS" -only-testing:RecordlyTests/DefaultInferenceRuntimeProfileSelectorTests
```

Expected: PASS.

**Step 6: Commit**

```bash
git add Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioTranscriptionService.swift RecordlyTests/FluidAudioASREngineTests.swift
git commit -m "feat: use FluidAudio native file ASR"
```

---

### Task 4: Preserve Diarization And Audio Boundary Behavior

**Files:**
- Inspect: `Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioDiarizationEngine.swift`
- Inspect: `Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioSessionAudioLoader.swift`
- Test: `RecordlyTests/DefaultInferenceEngineFactoryTests.swift`
- Test: `RecordlyTests/SummarizationTests.swift`

**Step 1: Verify ownership**

Confirm `FluidAudioSessionAudioLoader` remains used by diarization or other backend-local prep, not by ASR.

**Step 2: Write regression test if needed**

If `FluidAudioDiarizationEngine` depends on `PreparedSessionAudio`, add/keep a test proving diarization still loads session audio through `FluidAudioSessionAudioLoader`.

**Step 3: Run diarization tests**

Run:

```bash
xcodebuild test -scheme Recordly -destination "platform=macOS" -only-testing:RecordlyTests/DefaultInferenceEngineFactoryTests
```

Expected: PASS or documented skip for SDK-only diarization tests.

**Step 4: Commit**

Only commit if any test or code changes were needed:

```bash
git add Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioDiarizationEngine.swift RecordlyTests/DefaultInferenceEngineFactoryTests.swift
git commit -m "test: preserve FluidAudio diarization boundary"
```

---

### Task 5: Add Runtime Logging For Actual FluidAudio Path

**Files:**
- Modify: `Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioTranscriptionService.swift`
- Modify if needed: `Recordly/Infrastructure/Transcription/TranscriptionPipeline.swift`
- Test: `RecordlyTests/FluidAudioASREngineTests.swift`

**Step 1: Write the failing test**

If existing logs are testable, assert ASR metadata includes:

- backend: `FluidAudio`
- model: `Parakeet TDT v3`
- mode: `file`

If logs are not structured today, skip implementation and keep this task as manual verification.

**Step 2: Implement narrow logging**

Add backend-local log lines around the SDK call:

```swift
print("fluid_asr_mode=file model=parakeet-tdt-v3 audio=\(audioURL.lastPathComponent)")
```

Prefer existing app logging if available. Do not add product state or pipeline policy here.

**Step 3: Run tests**

Run:

```bash
xcodebuild test -scheme Recordly -destination "platform=macOS" -only-testing:RecordlyTests/FluidAudioASREngineTests
```

Expected: PASS.

**Step 4: Commit**

```bash
git add Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioTranscriptionService.swift
git commit -m "chore: log FluidAudio ASR execution mode"
```

---

### Task 6: Add Quality/Performance Comparison Script

**Files:**
- Create: `scripts/compare-fluid-asr-recording.sh`
- Create if useful: `docs/benchmarks/fluid-audio-asr-comparison.md`

**Step 1: Write script**

Create a script that accepts one Recordly recording directory and prints paths to:

- `merged-call.m4a`
- existing Recordly transcript
- existing `merged-call-diarized.txt` from `scribe`, if present
- new Recordly transcript after reprocess

Do not mutate recordings automatically in the script unless passed `--reprocess`.

**Step 2: Run manual comparison**

Run on one known recording:

```bash
scripts/compare-fluid-asr-recording.sh "/Users/nacnac/Library/Application Support/Recordly/recordings/<recording-id>"
```

Expected: prints available artifacts and next commands.

**Step 3: Document acceptance criteria**

Add to `docs/benchmarks/fluid-audio-asr-comparison.md`:

- sample recording ID
- old FluidAudio manual chunking transcript quality
- new FluidAudio file ASR transcript quality
- `scribe/parakeet-mlx` transcript quality
- rough runtime
- whether summary improved

**Step 4: Commit**

```bash
git add scripts/compare-fluid-asr-recording.sh docs/benchmarks/fluid-audio-asr-comparison.md
git commit -m "chore: add FluidAudio ASR comparison workflow"
```

---

### Task 7: Full Verification

**Files:**
- No source changes unless verification finds failures.

**Step 1: Run targeted tests**

```bash
xcodebuild test -scheme Recordly -destination "platform=macOS" -only-testing:RecordlyTests/FluidAudioASREngineTests
xcodebuild test -scheme Recordly -destination "platform=macOS" -only-testing:RecordlyTests/FluidAudioSystemChunkTranscriptionEngineTests
xcodebuild test -scheme Recordly -destination "platform=macOS" -only-testing:RecordlyTests/DefaultInferenceRuntimeProfileSelectorTests
xcodebuild test -scheme Recordly -destination "platform=macOS" -only-testing:RecordlyTests/DefaultInferenceEngineFactoryTests
```

Expected: PASS.

**Step 2: Run full build**

```bash
xcodebuild build -project Recordly.xcodeproj -scheme Recordly -destination "platform=macOS"
```

Expected: `BUILD SUCCEEDED`.

**Step 3: Manual app verification**

Use one real recording and verify:

- transcription completes
- transcript has many timestamped segments, not one huge segment
- summary uses transcript content, not fallback transcript snippets
- diarization failure still degrades instead of failing ASR
- existing recordings can be reprocessed

**Step 4: Final commit if fixes were needed**

```bash
git status --short
git add <changed-files>
git commit -m "fix: stabilize FluidAudio file ASR migration"
```

---

## Rollback Plan

If file-based SDK transcription regresses quality or timestamps:

1. Keep FluidAudio `0.14.0`.
2. Revert only the ASR path routing commits.
3. Restore `FluidAudioTranscriptionService` manual chunking.
4. Keep tests that prove both paths can be selected later if needed.

## Acceptance Criteria

- Recordly ASR calls FluidAudio's file API for normal recording transcription.
- Recordly no longer manually splits ASR into VAD regions or 30s windows.
- Canonical Recordly artifacts remain unchanged.
- FluidAudio v3 model remains SDK-managed.
- Diarization remains optional/degradable.
- Build passes.
- At least one real recording is compared against the old path and `scribe/parakeet-mlx`.

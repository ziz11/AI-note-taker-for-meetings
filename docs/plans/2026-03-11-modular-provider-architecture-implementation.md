# Modular Provider Architecture Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Stabilize the broken merge and land a modular provider architecture with user-visible provider selection for audio quality, ASR, diarization, and summarization while preserving Recordly's stage-driven boundaries.

**Architecture:** Keep workflow and pipeline backend-agnostic. Implement provider selection and routing in composition, runtime selection, factory, backend modules, and a shared audio-preprocessing boundary under `Infrastructure/Inference/Audio`.

**Tech Stack:** Swift, SwiftUI, XCTest, Recordly stage-driven inference architecture

---

### Task 1: Resolve the Current Merge Around Inference Wiring

**Files:**
- Modify: `Recordly/App/RecordlyApp.swift`
- Modify: `Recordly/Features/Recordings/Application/RecordingsStore.swift`
- Modify: `Recordly/Infrastructure/Inference/Composition/DefaultInferenceComposition.swift`
- Modify: `Recordly/Infrastructure/Inference/Factory/DefaultInferenceEngineFactory.swift`
- Modify: `Recordly/Infrastructure/Inference/Factory/InferenceEngineFactory.swift`
- Modify: `Recordly/Infrastructure/Inference/Runtime/DefaultInferenceRuntimeProfileSelector.swift`
- Modify: `Recordly.xcodeproj/project.pbxproj`
- Test: `RecordlyTests/DefaultInferenceRuntimeProfileSelectorTests.swift`
- Test: `RecordlyTests/RecordingsPhaseOneTests.swift`

**Step 1: Write the failing test**

Add or update tests in `RecordlyTests/DefaultInferenceRuntimeProfileSelectorTests.swift` to assert the selector can be constructed with explicit providers and returns a stable availability/profile result. Add or update tests in `RecordlyTests/RecordingsPhaseOneTests.swift` to ensure app/store composition still constructs correctly after the dependency reshaping.

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Recordly -only-testing:RecordlyTests/DefaultInferenceRuntimeProfileSelectorTests -only-testing:RecordlyTests/RecordingsPhaseOneTests`

Expected: FAIL while merge conflict markers or mismatched initializer signatures still exist.

**Step 3: Write minimal implementation**

Resolve conflicts in the listed files by:

- keeping the stage-driven composition path
- removing duplicate/contradictory initializer variants
- passing explicit provider dependencies through composition into store/view-model only where ownership requires them
- keeping factory responsibility limited to engine creation

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Recordly -only-testing:RecordlyTests/DefaultInferenceRuntimeProfileSelectorTests -only-testing:RecordlyTests/RecordingsPhaseOneTests`

Expected: PASS

**Step 5: Commit**

```bash
git add Recordly/App/RecordlyApp.swift Recordly/Features/Recordings/Application/RecordingsStore.swift Recordly/Infrastructure/Inference/Composition/DefaultInferenceComposition.swift Recordly/Infrastructure/Inference/Factory/DefaultInferenceEngineFactory.swift Recordly/Infrastructure/Inference/Factory/InferenceEngineFactory.swift Recordly/Infrastructure/Inference/Runtime/DefaultInferenceRuntimeProfileSelector.swift Recordly.xcodeproj/project.pbxproj RecordlyTests/DefaultInferenceRuntimeProfileSelectorTests.swift RecordlyTests/RecordingsPhaseOneTests.swift
git commit -m "fix: resolve inference merge wiring"
```

### Task 2: Introduce Explicit Provider Selection Types

**Files:**
- Modify: `Recordly/Infrastructure/Inference/Runtime/InferenceRuntimeProfile.swift`
- Modify: `Recordly/Infrastructure/Models/ModelManager.swift`
- Modify: `Recordly/Infrastructure/Inference/Composition/DefaultInferenceComposition.swift`
- Modify: `Recordly/Infrastructure/Inference/Runtime/DefaultInferenceRuntimeProfileSelector.swift`
- Test: `RecordlyTests/DefaultInferenceRuntimeProfileSelectorTests.swift`

**Step 1: Write the failing test**

Add tests asserting runtime selection can represent independent providers for:

- audio quality
- ASR
- diarization
- summarization

Also assert defaults are stable and backend-agnostic at the profile level.

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Recordly -only-testing:RecordlyTests/DefaultInferenceRuntimeProfileSelectorTests`

Expected: FAIL because the profile/selection model does not yet represent the new provider surface cleanly.

**Step 3: Write minimal implementation**

Refactor runtime-selection types to model explicit stage/provider choices, including a new audio-quality stage/provider. Persist user selections through model/preferences infrastructure without pushing policy into workflow.

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Recordly -only-testing:RecordlyTests/DefaultInferenceRuntimeProfileSelectorTests`

Expected: PASS

**Step 5: Commit**

```bash
git add Recordly/Infrastructure/Inference/Runtime/InferenceRuntimeProfile.swift Recordly/Infrastructure/Models/ModelManager.swift Recordly/Infrastructure/Inference/Composition/DefaultInferenceComposition.swift Recordly/Infrastructure/Inference/Runtime/DefaultInferenceRuntimeProfileSelector.swift RecordlyTests/DefaultInferenceRuntimeProfileSelectorTests.swift
git commit -m "feat: add modular provider selection types"
```

### Task 3: Add Shared Audio-Quality Provider Boundary

**Files:**
- Create: `Recordly/Infrastructure/Inference/Audio/AudioQualityProvider.swift`
- Create: `Recordly/Infrastructure/Inference/Audio/AudioPreparationArtifacts.swift`
- Create: `Recordly/Infrastructure/Inference/Audio/FluidAudioQualityProvider.swift`
- Modify: `Recordly/Infrastructure/Transcription/TranscriptionPipeline.swift`
- Modify: `Recordly/Infrastructure/Inference/Factory/InferenceEngineFactory.swift`
- Modify: `Recordly/Infrastructure/Inference/Factory/DefaultInferenceEngineFactory.swift`
- Test: `RecordlyTests/RecordingsPhaseOneTests.swift`
- Test: `RecordlyTests/SummarizationTests.swift`

**Step 1: Write the failing test**

Add tests covering:

- pipeline requests shared prepared audio before ASR/diarization
- canonical stored artifacts remain unchanged
- missing audio-quality provider degrades only where intended

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Recordly -only-testing:RecordlyTests/RecordingsPhaseOneTests -only-testing:RecordlyTests/SummarizationTests`

Expected: FAIL because the pipeline and factory do not yet support a shared preprocessing provider stage.

**Step 3: Write minimal implementation**

Add a shared provider protocol and artifacts type under `Infrastructure/Inference/Audio`. Wire the pipeline to request prepared inputs once and reuse them for ASR and diarization. Keep canonical session files as the source of truth and keep summarization text-only.

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Recordly -only-testing:RecordlyTests/RecordingsPhaseOneTests -only-testing:RecordlyTests/SummarizationTests`

Expected: PASS

**Step 5: Commit**

```bash
git add Recordly/Infrastructure/Inference/Audio/AudioQualityProvider.swift Recordly/Infrastructure/Inference/Audio/AudioPreparationArtifacts.swift Recordly/Infrastructure/Inference/Audio/FluidAudioQualityProvider.swift Recordly/Infrastructure/Transcription/TranscriptionPipeline.swift Recordly/Infrastructure/Inference/Factory/InferenceEngineFactory.swift Recordly/Infrastructure/Inference/Factory/DefaultInferenceEngineFactory.swift RecordlyTests/RecordingsPhaseOneTests.swift RecordlyTests/SummarizationTests.swift
git commit -m "feat: add shared audio quality provider"
```

### Task 4: Wire Fluid Providers Through Factory and Selector

**Files:**
- Modify: `Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioASREngine.swift`
- Modify: `Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioDiarizationEngine.swift`
- Modify: `Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioModelProvider.swift`
- Modify: `Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioDiarizationModelProvider.swift`
- Modify: `Recordly/Infrastructure/Inference/Factory/DefaultInferenceEngineFactory.swift`
- Modify: `Recordly/Infrastructure/Inference/Runtime/DefaultInferenceRuntimeProfileSelector.swift`
- Test: `RecordlyTests/FluidAudioDiarizationModelProviderTests.swift`
- Test: `RecordlyTests/DefaultInferenceRuntimeProfileSelectorTests.swift`

**Step 1: Write the failing test**

Add tests proving:

- factory routes Fluid correctly for each implemented stage
- selector reports unavailable/degraded/ready state from Fluid provisioning state
- diarization model provisioning remains isolated from workflow policy

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Recordly -only-testing:RecordlyTests/FluidAudioDiarizationModelProviderTests -only-testing:RecordlyTests/DefaultInferenceRuntimeProfileSelectorTests`

Expected: FAIL until factory and selector are aligned with the new provider model.

**Step 3: Write minimal implementation**

Update factory and selector so Fluid remains the only exposed provider for now, but the code paths are modular and stage-scoped. Do not advertise Fluid summarization unless a real summarization implementation exists.

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Recordly -only-testing:RecordlyTests/FluidAudioDiarizationModelProviderTests -only-testing:RecordlyTests/DefaultInferenceRuntimeProfileSelectorTests`

Expected: PASS

**Step 5: Commit**

```bash
git add Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioASREngine.swift Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioDiarizationEngine.swift Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioModelProvider.swift Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioDiarizationModelProvider.swift Recordly/Infrastructure/Inference/Factory/DefaultInferenceEngineFactory.swift Recordly/Infrastructure/Inference/Runtime/DefaultInferenceRuntimeProfileSelector.swift RecordlyTests/FluidAudioDiarizationModelProviderTests.swift RecordlyTests/DefaultInferenceRuntimeProfileSelectorTests.swift
git commit -m "feat: route modular fluid providers"
```

### Task 5: Expose Provider Selection in Settings

**Files:**
- Modify: `Recordly/Features/Settings/Models/ModelSettingsViewModel.swift`
- Modify: `Recordly/Features/Settings/Models/ModelSettingsView.swift`
- Modify: `Recordly/App/RecordlyApp.swift`
- Modify: `Recordly/Features/Recordings/Application/RecordingsStore.swift`
- Test: `RecordlyTests/RecordingsPhaseOneTests.swift`

**Step 1: Write the failing test**

Add tests asserting settings/view-model state includes provider selections for audio quality, ASR, diarization, and summarization, and that the selections round-trip through the store/model layer.

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Recordly -only-testing:RecordlyTests/RecordingsPhaseOneTests`

Expected: FAIL because the UI/view-model does not yet expose the provider-selection surface.

**Step 3: Write minimal implementation**

Update the settings view-model and view to show provider pickers/cards immediately, with only valid provider options exposed. Keep existing model download/provisioning cards where they still reflect real runtime behavior.

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Recordly -only-testing:RecordlyTests/RecordingsPhaseOneTests`

Expected: PASS

**Step 5: Commit**

```bash
git add Recordly/Features/Settings/Models/ModelSettingsViewModel.swift Recordly/Features/Settings/Models/ModelSettingsView.swift Recordly/App/RecordlyApp.swift Recordly/Features/Recordings/Application/RecordingsStore.swift RecordlyTests/RecordingsPhaseOneTests.swift
git commit -m "feat: expose provider selection in settings"
```

### Task 6: Run Full Verification

**Files:**
- Test: `RecordlyTests/DefaultInferenceRuntimeProfileSelectorTests.swift`
- Test: `RecordlyTests/FluidAudioDiarizationModelProviderTests.swift`
- Test: `RecordlyTests/RecordingsPhaseOneTests.swift`
- Test: `RecordlyTests/SummarizationTests.swift`

**Step 1: Run targeted tests**

Run: `xcodebuild test -scheme Recordly -only-testing:RecordlyTests/DefaultInferenceRuntimeProfileSelectorTests -only-testing:RecordlyTests/FluidAudioDiarizationModelProviderTests -only-testing:RecordlyTests/RecordingsPhaseOneTests -only-testing:RecordlyTests/SummarizationTests`

Expected: PASS

**Step 2: Run app build verification**

Run: `xcodebuild build -scheme Recordly`

Expected: BUILD SUCCEEDED

**Step 3: Inspect git state**

Run: `git status --short`

Expected: no unresolved conflicts and only intentional modifications remain

**Step 4: Commit**

```bash
git add -A
git commit -m "chore: verify modular provider stabilization"
```

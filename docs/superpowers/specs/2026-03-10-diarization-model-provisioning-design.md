# Diarization Model Provisioning Migration

**Date:** 2026-03-10
**Status:** Approved
**Scope:** Separate capability-specific model provisioning for ASR and diarization; remove legacy diarization `.bin` discovery

## Problem

Diarization routing defaults to `.fluidAudio`, but model resolution still goes through `ModelManager`, which discovers `.bin` files. The FluidAudio diarization engine (`FluidAudioDiarizationEngine`) expects a directory-based model or a ready `OfflineDiarizerManager`, not a `.bin` file path. These two systems disagree on what a diarization model looks like.

Additionally, `FluidAudioModelProvider` is named generically but only handles ASR. There is no provisioning path for FluidAudio diarization models.

## Design Decisions

1. **Separate providers per capability.** ASR and diarization have different SDK APIs (`AsrModels.downloadAndLoad` vs `OfflineDiarizerManager.prepareModels`), different model shapes (CoreML directory vs SDK-managed diarization models), and different return types (URL vs ready manager). No shared provisioning protocol.

2. **Provider owns the prepared `OfflineDiarizerManager`.** The provider creates the manager, calls `prepareModels(...)`, caches the ready manager, and hands it to the engine. The engine becomes a thin executor that calls `manager.process(audio:)`.

3. **SDK-managed provisioning as default.** The provider does not depend on knowing the SDK's on-disk cache layout. Manual directory-based initialization is kept only as an explicit override/test path.

4. **Clean break from ModelManager for diarization.** Remove diarization discovery, selection, and `.bin` scanning from `ModelManager`. It retains only summarization responsibility.

5. **Rename `FluidAudioModelProvider` to `FluidAudioASRModelProvider`.** Narrow, mechanical rename to make the ASR-only scope explicit.

## Architecture

### Provider Layer

#### `FluidAudioASRModelProvider` (rename of existing `FluidAudioModelProvider`)

- Protocol: `FluidAudioASRModelProviding` (rename of `FluidAudioModelProviding`)
- `resolveForRuntime() throws -> URL` (model directory)
- State: `FluidAudioModelProvisioningState` (shared enum, unchanged)
- Provisioning: `AsrModels.downloadAndLoad(version: .v3)`
- Behavior: identical to current implementation, name change only

#### `FluidAudioDiarizationModelProvider` (new)

- Protocol: `FluidAudioDiarizationModelProviding`
- `resolveForRuntime() throws -> OfflineDiarizerManager` (ready manager)
- `downloadDefaultModel() async throws`
- State: `FluidAudioModelProvisioningState` (same shared enum)
- Lifecycle:
  1. Creates `OfflineDiarizerManager(config: .default)`
  2. Calls `prepareModels(directory:configuration:forceRedownload:)` (follows actual SDK signature)
  3. Caches the prepared manager
  4. Subsequent `resolveForRuntime()` calls return the cached instance
- Idempotent: concurrent provision calls do not duplicate work
- Test path: `init(preparedManager:)` for injecting a pre-prepared manager

#### Shared state enum

`FluidAudioModelProvisioningState` remains unchanged (`.ready`, `.needsDownload`, `.downloading`, `.failed(message:)`). Both providers use it. No shared provider protocol.

### Engine Layer

#### `FluidAudioDiarizationEngine` (modified)

Current three-layer stack (`Runner` / `Service` / `Engine`) collapses to a single engine type:

- Receives a ready `OfflineDiarizerManager` via `init(manager:)`
- Loads/resamples audio to 16 kHz mono (via existing `FluidAudioSessionAudioLoader`)
- Calls `manager.process(audio:)` on the ready manager
- Maps SDK result segments to `DiarizationDocument`
- `DiarizationEngineConfiguration.modelURL` is ignored for this path (manager is already prepared)

#### Removed types

- `FluidAudioOfflineDiarizationRunner` / `FluidAudioOfflineDiarizationRunning` — provider owns this lifecycle now
- `FluidAudioDiarizationService` — intermediate layer no longer needed

#### `CliDiarizationEngine` (minor update)

Legacy explicit path. Updated to handle optional `modelURL`: unwrap at the start of `diarize(...)` and throw `DiarizationRuntimeError.modelMissing` if nil. Same applies to `PlaceholderDiarizationEngine` in the same file.

### Runtime Profile Selector

#### `DefaultInferenceRuntimeProfileSelector` (modified)

Holds:
- `asrModelProvider: any FluidAudioASRModelProviding` (renamed from `fluidAudioModelProvider`)
- `diarizationModelProvider: any FluidAudioDiarizationModelProviding` (new)
- `modelManager: ModelManager` (summarization only)

`resolveTranscriptionProfile`:
- ASR: `asrModelProvider.resolveForRuntime()` -> URL (unchanged behavior)
- Diarization: no longer pulls from `modelManager`. `InferenceModelArtifacts.diarizationModelURL` is `nil` for FluidAudio path; the manager is injected into the engine by the factory.

`resolveSummarizationProfile`:
- Currently reads `modelManager.selectedLocalOption(kind: .diarization)?.url` for `diarizationModelURL`. After removing diarization from ModelManager, this will return `nil`. This is correct — summarization profiles do not need diarization model artifacts. The field becomes explicitly `nil`.

`transcriptionAvailability`:
- ASR ready + diarization ready -> `.ready`
- ASR ready + diarization not ready -> `.degradedNoDiarization`
- ASR not ready -> `.unavailable`

### Factory

#### `DefaultInferenceEngineFactory` (modified)

Becomes stateful. Holds `diarizationModelProvider: any FluidAudioDiarizationModelProviding`.

`makeDiarizationEngine`:
- `.fluidAudio`: calls `diarizationModelProvider.resolveForRuntime()` -> gets ready manager -> creates `FluidAudioDiarizationEngine(manager:)`
- `.cliDiarization`: creates `CliDiarizationEngine()` (unchanged)

Factory does not own provisioning state; it resolves the dependency and constructs the engine.

### Contracts

#### `DiarizationEngineConfiguration`

`modelURL` becomes optional (`var modelURL: URL?`). FluidAudio engine ignores it (manager injected). CLI engine requires it.

### Pipeline Integration

#### `TranscriptionPipeline` (modified)

The pipeline currently guards on `configuration != nil` (line 518) and uses `configuration.modelURL.lastPathComponent` for logging (lines 536, 542, 548). With the FluidAudio path, `diarizationModelURL` is `nil` in the profile, which would cause the pipeline to skip diarization entirely.

**Fix:** The pipeline should always construct a `DiarizationEngineConfiguration` when a diarization engine is available, regardless of whether `diarizationModelURL` is set. The `modelURL` field is optional and only meaningful for CLI diarization. The pipeline's nil-configuration guard should check for engine availability, not model URL presence. Specifically:
- Remove the `guard let configuration` early return
- Always pass a `DiarizationEngineConfiguration` (with `modelURL: nil` for FluidAudio)
- Update `DiarizationLoadOutcome.modelUsed` to handle optional `modelURL` (use `"sdk-managed"` or similar when URL is nil)

### Composition Root

#### `DefaultInferenceComposition` (modified)

Currently creates `DefaultInferenceEngineFactory()` with no arguments. Must be updated to:
- Accept `FluidAudioDiarizationModelProviding` as a parameter
- Pass it to `DefaultInferenceEngineFactory(diarizationModelProvider:)`
- The composition root's callers (`RecordlyApp.swift`, `RecordingsStore.swift`) must pass the diarization provider

### UI Layer

#### `ModelSettingsViewModel` (modified)

- Adds: `diarizationModelProvider: any FluidAudioDiarizationModelProviding`
- Adds: `diarizationProvisioningState: FluidAudioModelProvisioningState`
- Adds: `downloadDiarizationModel()` — calls provider
- Removes: `diarizationModels: [LocalModelOption]`
- Removes: `selectedDiarizationModelID: String?`
- Removes: `selectDiarizationModel(_:)`
- Renames: `fluidAudioModelProvider` references to use `FluidAudioASRModelProviding`

#### `ModelSettingsView` (modified)

Replace the diarization `modelPickerCard` (file picker + folder buttons) with a **diarization provisioning card** matching the existing ASR provisioning card pattern:
- Shows diarization provider state (ready / needsDownload / downloading / failed)
- "Download Diarization Model" button
- No file picker, no folder buttons

### ModelManager Cleanup

Remove from `ModelManager`:
- `selectedDiarizationModelID` property
- `setSelectedModelID` / `selectedModelID` cases for `.diarization`
- `isModelCandidate` case for `.diarization` (`.bin`-only check)
- `supportedModelExtensions` case for `.diarization`
- `listLocalOptions(kind: .diarization)` returns `[]`
- `listAvailableModels()` iterates `[.summarization]` only
- `availability(for:)` — simplify or remove (diarization is no longer its concern)

Remove from `ModelPreferencesStore`:
- `selectedDiarizationModelID` key. Existing UserDefaults values are simply ignored.

## Test Strategy

### New tests: `FluidAudioDiarizationModelProviderTests` (~8-10 tests)

- `.needsDownload` initial state when no manager cached
- `downloadDefaultModel()` transitions to `.downloading` then `.ready`
- `downloadDefaultModel()` failure transitions to `.failed`
- `resolveForRuntime()` returns cached manager when ready
- `resolveForRuntime()` throws when not provisioned
- Idempotent: second `downloadDefaultModel()` while downloading is a no-op
- `init(preparedManager:)` test path starts in `.ready`
- Concurrent `resolveForRuntime()` calls return same manager instance

### Modified tests

- **`DefaultInferenceRuntimeProfileSelectorTests`**: inject both ASR and diarization provider mocks; remove ModelManager diarization expectations; test availability matrix
- **`DefaultInferenceEngineFactoryTests`**: update factory construction with mock diarization provider; test `.fluidAudio` creates engine with resolved manager
- **`TranscriptionPipelineTests`**: update wiring to use mock diarization provider instead of ModelManager
- **`FluidAudioASREngineTests`**: rename references from `FluidAudioModelProvider` to `FluidAudioASRModelProvider`

### Removed tests

- `ModelDiscoveryTests`: remove diarization `.bin` discovery assertions from `testListLocalOptionsDeduplicatesByBasenameUsingSourcePriority` and `testProjectLocalClassificationUsesExtensionAndFilenameHeuristics`

### Test boundaries

- Test provider behavior and state transitions, not FluidAudio SDK internals
- Use mocks/stubs around the `FluidAudioDiarizationModelProviding` protocol boundary
- Keep pipeline behavior tests focused on pipeline logic, not provisioning details

## File Changes Summary

### New files

| File | Purpose |
|---|---|
| `Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioDiarizationModelProvider.swift` | Diarization provider owning `OfflineDiarizerManager` lifecycle |
| `RecordlyTests/FluidAudioDiarizationModelProviderTests.swift` | Provider state/behavior tests |

### Renamed files

| From | To |
|---|---|
| `FluidAudioModelProvider.swift` | `FluidAudioASRModelProvider.swift` |

### Modified files

| File | Changes |
|---|---|
| `FluidAudioASRModelProvider.swift` | Rename class + protocol |
| `FluidAudioDiarizationEngine.swift` | Thin executor; receives ready manager; remove Runner/Service |
| `DefaultInferenceRuntimeProfileSelector.swift` | Holds both ASR + diarization providers; drops ModelManager for diarization |
| `DefaultInferenceEngineFactory.swift` | Stateful; holds diarization provider; injects manager |
| `InferenceStageContracts.swift` | `DiarizationEngineConfiguration.modelURL` becomes optional |
| `ModelManager.swift` | Remove diarization discovery/selection |
| `ModelPreferencesStore.swift` | Remove `selectedDiarizationModelID` |
| `ModelSettingsViewModel.swift` | Replace diarization file selection with provider state/actions |
| `ModelSettingsView.swift` | Replace diarization picker with provisioning card |
| `DefaultInferenceRuntimeProfileSelectorTests.swift` | Update for dual providers |
| `DefaultInferenceEngineFactoryTests.swift` | Update for stateful factory |
| `TranscriptionPipelineTests.swift` | Update wiring |
| `FluidAudioASREngineTests.swift` | Rename references |
| `ModelDiscoveryTests.swift` | Remove diarization `.bin` discovery assertions |
| `DefaultInferenceComposition.swift` | Accept and pass diarization provider |
| `RecordlyApp.swift` | Pass diarization provider to composition |
| `RecordingsStore.swift` | Update `FluidAudioModelProviding` references to `FluidAudioASRModelProviding` |
| `SummarizationTests.swift` | Update mock `DiarizationEngine` for optional `modelURL` |
| `TranscriptionPipeline.swift` | Remove nil-configuration guard; handle optional `modelURL` in logging |
| `InferenceEngineFactory.swift` | No protocol change needed (factory protocol is unchanged) |
| `CliDiarizationEngine.swift` | Handle optional `modelURL` (unwrap or throw); update `PlaceholderDiarizationEngine` |
| `RecordingsPhaseOneTests.swift` | Update `DefaultInferenceComposition.make` call for new signature |

### Removed types

| Type | File | Reason |
|---|---|---|
| `FluidAudioOfflineDiarizationRunner` | `FluidAudioDiarizationEngine.swift` | Provider owns manager lifecycle |
| `FluidAudioOfflineDiarizationRunning` | `FluidAudioDiarizationEngine.swift` | Protocol for removed runner |
| `FluidAudioDiarizationService` | `FluidAudioDiarizationEngine.swift` | Intermediate layer unnecessary |

### Unchanged

- `CliDiarizationEngine` — legacy explicit path (minor update for optional `modelURL` only)
- `InferenceRuntimeProfile.swift` — `StageRuntimeSelection`, `InferenceModelArtifacts` struct (`diarizationModelURL` is already `URL?`)
- `ModelTypes.swift` — `ModelKind.diarization` case retained
- `AppPaths.swift` — no changes
- `InferenceEngineFactory.swift` — protocol unchanged, only the concrete factory gains state
- Summarization handling — untouched

## Out of Scope

- Summarization model provisioning changes
- CLI diarization removal or deprecation
- Broad naming campaigns across the model system
- Settings screen redesign beyond the diarization card
- Online/streaming diarization support

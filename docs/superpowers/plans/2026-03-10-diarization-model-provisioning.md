# Diarization Model Provisioning Migration — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a separate `FluidAudioDiarizationModelProvider` that owns the `OfflineDiarizerManager` lifecycle, rename the existing provider to ASR-specific, remove diarization responsibility from `ModelManager`, and update all consumers.

**Architecture:** Each FluidAudio capability (ASR, diarization) gets its own provider that owns the SDK runtime object. The diarization provider creates, prepares, and caches an `OfflineDiarizerManager`; the engine becomes a thin executor. `ModelManager` retains only summarization.

**Tech Stack:** Swift, FluidAudio SDK, SwiftUI, XCTest

**Spec:** `docs/superpowers/specs/2026-03-10-diarization-model-provisioning-design.md`

**Build command:** `xcodebuild test -scheme Recordly -destination 'platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`

---

## Chunk 1: Contracts and Provider Foundation

### Task 1: Make `DiarizationEngineConfiguration.modelURL` optional

**Files:**
- Modify: `Recordly/Infrastructure/Inference/Contracts/InferenceStageContracts.swift:57-59`

- [ ] **Step 1: Update the struct**

In `InferenceStageContracts.swift`, change:

```swift
struct DiarizationEngineConfiguration: Sendable {
    var modelURL: URL?
}
```

- [ ] **Step 2: Update `CliDiarizationEngine` to unwrap**

In `Recordly/Infrastructure/Inference/Backends/CliDiarization/CliDiarizationEngine.swift`, update `CliDiarizationEngine.diarize(...)` to unwrap `modelURL` at the start:

```swift
func diarize(
    systemAudioURL: URL,
    sessionID: UUID,
    configuration: DiarizationEngineConfiguration
) async throws -> DiarizationDocument {
    if Task.isCancelled {
        throw DiarizationRuntimeError.cancelled
    }

    guard let modelURL = configuration.modelURL else {
        throw DiarizationRuntimeError.modelMissing(URL(fileURLWithPath: "<no model URL>"))
    }

    guard fileManager.fileExists(atPath: systemAudioURL.path) else {
        throw DiarizationRuntimeError.invalidInput
    }

    guard ["system.raw.caf", "system.raw.flac"].contains(systemAudioURL.lastPathComponent) else {
        throw DiarizationRuntimeError.invalidInput
    }

    guard fileManager.fileExists(atPath: modelURL.path) else {
        throw DiarizationRuntimeError.modelMissing(modelURL)
    }

    let runner = try runnerFactory()
    let output = try await runner.diarize(audioURL: systemAudioURL, modelURL: modelURL)

    if Task.isCancelled {
        throw DiarizationRuntimeError.cancelled
    }

    let segments = output.map {
        DiarizationSegment(
            id: $0.id ?? UUID().uuidString,
            speaker: $0.speakerID,
            startMs: $0.startMs,
            endMs: $0.endMs,
            confidence: $0.confidence
        )
    }

    return DiarizationDocument(
        version: 1,
        sessionID: sessionID,
        createdAt: Date(),
        segments: segments
    )
}
```

- [ ] **Step 3: Update `PlaceholderDiarizationEngine`**

In the same file, update `PlaceholderDiarizationEngine.diarize(...)`:

```swift
func diarize(
    systemAudioURL: URL,
    sessionID: UUID,
    configuration: DiarizationEngineConfiguration
) async throws -> DiarizationDocument {
    let exists = FileManager.default.fileExists(atPath: systemAudioURL.path)
    guard exists else {
        throw CocoaError(.fileNoSuchFile)
    }
    if let modelURL = configuration.modelURL {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
    }

    return DiarizationDocument(
        version: 1,
        sessionID: sessionID,
        createdAt: Date(),
        segments: []
    )
}
```

- [ ] **Step 4: Update `NoopDiarizationEngine` in SummarizationTests**

In `RecordlyTests/SummarizationTests.swift`, the `NoopDiarizationEngine` already ignores `modelURL` — just verify it compiles with the optional change. No code change needed if it doesn't access `configuration.modelURL`.

- [ ] **Step 5: Build to verify compilation**

Run: `xcodebuild build -scheme Recordly -destination 'platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Run tests**

Run: `xcodebuild test -scheme Recordly -destination 'platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`
Expected: All 103 tests pass

- [ ] **Step 7: Commit**

```bash
git add Recordly/Infrastructure/Inference/Contracts/InferenceStageContracts.swift \
       Recordly/Infrastructure/Inference/Backends/CliDiarization/CliDiarizationEngine.swift
git commit -m "refactor: make DiarizationEngineConfiguration.modelURL optional

CLI and placeholder engines now unwrap the optional URL, throwing
modelMissing when nil. FluidAudio engine will ignore it entirely."
```

---

### Task 2: Rename `FluidAudioModelProvider` to `FluidAudioASRModelProvider`

**Files:**
- Rename: `Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioModelProvider.swift` -> `FluidAudioASRModelProvider.swift`
- Modify: all files referencing old names

- [ ] **Step 1: Rename the file via git**

```bash
cd /Users/nacnac/Documents/Other_Interner/Recordly
git mv Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioModelProvider.swift \
       Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioASRModelProvider.swift
```

- [ ] **Step 2: Rename protocol and class in the file**

In `FluidAudioASRModelProvider.swift`:

Replace `FluidAudioModelProviding` with `FluidAudioASRModelProviding` (all occurrences).
Replace `FluidAudioModelProvider` with `FluidAudioASRModelProvider` (all occurrences).

- [ ] **Step 3: Update `DefaultInferenceRuntimeProfileSelector.swift`**

Replace `FluidAudioModelProviding` with `FluidAudioASRModelProviding`.

- [ ] **Step 4: Update `DefaultInferenceComposition.swift`**

Replace `FluidAudioModelProviding` with `FluidAudioASRModelProviding`.

- [ ] **Step 5: Update `ModelSettingsViewModel.swift`**

Replace `FluidAudioModelProviding` with `FluidAudioASRModelProviding`.

- [ ] **Step 6: Update `RecordingsStore.swift`**

Replace `FluidAudioModelProvider` with `FluidAudioASRModelProvider` (concrete type references).

- [ ] **Step 7: Update `RecordlyApp.swift`**

Replace `FluidAudioModelProvider()` with `FluidAudioASRModelProvider()`.

- [ ] **Step 8: Update `RecordingsPhaseOneTests.swift`**

Replace `FluidAudioModelProvider()` with `FluidAudioASRModelProvider()`.

- [ ] **Step 9: Update `DefaultInferenceRuntimeProfileSelectorTests.swift`**

Replace `FluidAudioModelProviding` with `FluidAudioASRModelProviding` in the `StubFluidAudioModelProvider` conformance.

- [ ] **Step 10: Update `FluidAudioASREngineTests.swift`**

Search and replace any `FluidAudioModelProvid` references.

- [ ] **Step 11: Update Xcode project file**

The `git mv` changed the filesystem name. Update `Recordly.xcodeproj/project.pbxproj` — replace the old filename reference with the new one. This may be automatic if Xcode regenerates, or may need a manual find/replace of `FluidAudioModelProvider.swift` with `FluidAudioASRModelProvider.swift` in the pbxproj.

- [ ] **Step 12: Build and test**

Run: `xcodebuild test -scheme Recordly -destination 'platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 13: Commit**

```bash
git add -A
git commit -m "refactor: rename FluidAudioModelProvider to FluidAudioASRModelProvider

Mechanical rename of class, protocol, and all references. No behavior
change. Makes the ASR-only scope explicit before adding the diarization
provider."
```

---

### Task 3: Create `FluidAudioDiarizationModelProvider`

**Files:**
- Create: `Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioDiarizationModelProvider.swift`
- Create: `RecordlyTests/FluidAudioDiarizationModelProviderTests.swift`

- [ ] **Step 1: Write the provider tests**

Create `RecordlyTests/FluidAudioDiarizationModelProviderTests.swift`:

```swift
import XCTest
@testable import Recordly

@MainActor
final class FluidAudioDiarizationModelProviderTests: XCTestCase {
    func testInitialStateIsNeedsDownload() {
        let provider = FluidAudioDiarizationModelProvider()
        XCTAssertEqual(provider.state, .needsDownload)
    }

    func testResolveForRuntimeThrowsWhenNotProvisioned() {
        let provider = FluidAudioDiarizationModelProvider()
        XCTAssertThrowsError(try provider.resolveForRuntime()) { error in
            XCTAssertEqual(
                error as? FluidAudioModelProvisioningError,
                .noModelProvisioned
            )
        }
    }

    func testPreparedManagerInitStartsReady() {
        let stub = StubOfflineDiarizationManaging()
        let provider = FluidAudioDiarizationModelProvider(preparedManager: stub)
        XCTAssertEqual(provider.state, .ready)
    }

    func testResolveForRuntimeReturnsPreparedManager() throws {
        let stub = StubOfflineDiarizationManaging()
        let provider = FluidAudioDiarizationModelProvider(preparedManager: stub)
        let resolved = try provider.resolveForRuntime()
        XCTAssertTrue(resolved === stub)
    }

    func testResolveForRuntimeReturnsSameInstanceOnMultipleCalls() throws {
        let stub = StubOfflineDiarizationManaging()
        let provider = FluidAudioDiarizationModelProvider(preparedManager: stub)
        let first = try provider.resolveForRuntime()
        let second = try provider.resolveForRuntime()
        XCTAssertTrue(first === second)
    }

    func testDownloadIdempotentWhenAlreadyReady() async {
        let stub = StubOfflineDiarizationManaging()
        let provider = FluidAudioDiarizationModelProvider(preparedManager: stub)
        XCTAssertEqual(provider.state, .ready)
        // Second download should be a no-op since manager is already cached
        await provider.downloadDefaultModel()
        XCTAssertEqual(provider.state, .ready)
    }

    func testRefreshStateReportsReadyWhenManagerCached() {
        let stub = StubOfflineDiarizationManaging()
        let provider = FluidAudioDiarizationModelProvider(preparedManager: stub)
        provider.refreshState()
        XCTAssertEqual(provider.state, .ready)
    }

    func testRefreshStateReportsNeedsDownloadWhenNoManager() {
        let provider = FluidAudioDiarizationModelProvider()
        provider.refreshState()
        XCTAssertEqual(provider.state, .needsDownload)
    }
}

private final class StubOfflineDiarizationManaging: OfflineDiarizationManaging {
    var prepareModelsCalled = false
    var processAudioCalled = false

    func prepareModels() async throws {
        prepareModelsCalled = true
    }

    func process(audio: [Float]) async throws -> DiarizationResult {
        processAudioCalled = true
        return DiarizationResult(segments: [])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Recordly -destination 'platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAIL"`
Expected: Compilation errors — `FluidAudioDiarizationModelProvider` not found

- [ ] **Step 3: Create the protocol wrapper for testability**

The `OfflineDiarizerManager` from the SDK is a concrete class. To test the provider without the real SDK, create a protocol. Add this to the top of `FluidAudioDiarizationModelProvider.swift`:

```swift
import Foundation

#if arch(arm64) && canImport(FluidAudio)
import FluidAudio
#endif

/// Protocol wrapper around OfflineDiarizerManager for testability.
/// Production code uses the real SDK manager; tests inject stubs.
protocol OfflineDiarizationManaging: AnyObject {
    func prepareModels() async throws
    func process(audio: [Float]) async throws -> DiarizationResult
}

#if arch(arm64) && canImport(FluidAudio)
extension OfflineDiarizerManager: OfflineDiarizationManaging {
    func prepareModels() async throws {
        try await prepareModels(directory: nil, configuration: nil, forceRedownload: false)
    }
}
#endif
```

**IMPORTANT:** Before writing this code, use Xcode's "Jump to Definition" on `OfflineDiarizerManager` to verify the exact `prepareModels(...)` signature. The existing codebase calls `manager.prepareModels(directory: modelDirectoryURL)` with a single parameter. The bridge method must match the SDK's actual API. If it takes only `directory:`, use:
```swift
func prepareModels() async throws {
    try await prepareModels(directory: nil)
}
```
Adjust as needed based on what the SDK actually exposes.

- [ ] **Step 4: Create the diarization result type if needed**

If `DiarizationResult` is not already exposed by the SDK protocol wrapper, define a lightweight struct:

```swift
struct DiarizationResult {
    struct Segment {
        var speakerId: String
        var startTimeSeconds: Float
        var endTimeSeconds: Float
        var qualityScore: Float
    }
    var segments: [Segment]
}
```

**IMPORTANT:** Before defining this type, check what `OfflineDiarizerManager.process(audio:)` actually returns. The existing engine code accesses `.segments[].speakerId`, `.startTimeSeconds`, `.endTimeSeconds`, `.qualityScore`. If the SDK returns a type like `DiarizerResult` or similar, use the SDK type directly in the protocol and skip this custom struct. The `OfflineDiarizationManaging` protocol's `process(audio:)` return type must match whatever the SDK uses.

- [ ] **Step 5: Write the provider protocol**

In the same file:

```swift
@MainActor
protocol FluidAudioDiarizationModelProviding: AnyObject {
    var state: FluidAudioModelProvisioningState { get }
    func refreshState()
    func downloadDefaultModel() async
    func resolveForRuntime() throws -> any OfflineDiarizationManaging
}
```

- [ ] **Step 6: Write the provider implementation**

```swift
@MainActor
final class FluidAudioDiarizationModelProvider: ObservableObject, FluidAudioDiarizationModelProviding {
    @Published private(set) var state: FluidAudioModelProvisioningState = .needsDownload

    private var cachedManager: (any OfflineDiarizationManaging)?

    init() {
        refreshState()
    }

    /// Test/manual override: inject a pre-prepared manager.
    init(preparedManager: any OfflineDiarizationManaging) {
        self.cachedManager = preparedManager
        self.state = .ready
    }

    func refreshState() {
        guard case .downloading = state else {
            state = cachedManager != nil ? .ready : .needsDownload
            return
        }
    }

    func downloadDefaultModel() async {
        guard !isDownloading, cachedManager == nil else { return }

        state = .downloading
        do {
            let manager = makeManager()
            try await manager.prepareModels()
            cachedManager = manager
            state = .ready
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    func resolveForRuntime() throws -> any OfflineDiarizationManaging {
        guard let manager = cachedManager else {
            throw FluidAudioModelProvisioningError.noModelProvisioned
        }
        return manager
    }

    private var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    private func makeManager() -> any OfflineDiarizationManaging {
#if arch(arm64) && canImport(FluidAudio)
        return OfflineDiarizerManager(config: .default)
#else
        fatalError("FluidAudio SDK is not available on this architecture.")
#endif
    }
}
```

- [ ] **Step 7: Add file to Xcode project**

Add `FluidAudioDiarizationModelProvider.swift` and `FluidAudioDiarizationModelProviderTests.swift` to the Xcode project. This may require editing `project.pbxproj` or using Xcode's file inspector.

- [ ] **Step 8: Run tests**

Run: `xcodebuild test -scheme Recordly -destination 'platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`
Expected: All new provider tests pass + all existing tests pass

- [ ] **Step 9: Commit**

```bash
git add Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioDiarizationModelProvider.swift \
       RecordlyTests/FluidAudioDiarizationModelProviderTests.swift \
       Recordly.xcodeproj/project.pbxproj
git commit -m "feat: add FluidAudioDiarizationModelProvider

Provider owns the OfflineDiarizerManager lifecycle: creates, prepares
models via SDK, caches the ready manager. Test path via
init(preparedManager:) for injection."
```

---

## Chunk 2: Engine, Factory, and Selector Rewiring

### Task 4: Simplify `FluidAudioDiarizationEngine` to thin executor

**Files:**
- Modify: `Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioDiarizationEngine.swift`

- [ ] **Step 1: Rewrite the engine**

Replace the entire file content with:

```swift
import Foundation

#if arch(arm64) && canImport(FluidAudio)
import FluidAudio
#endif

struct FluidAudioDiarizationEngine: DiarizationEngine {
    private let manager: any OfflineDiarizationManaging
    private let fileManager: FileManager
    private let sessionAudioLoader: FluidAudioSessionAudioLoading

    init(
        manager: any OfflineDiarizationManaging,
        fileManager: FileManager = .default,
        sessionAudioLoader: FluidAudioSessionAudioLoading = FluidAudioSessionAudioLoader()
    ) {
        self.manager = manager
        self.fileManager = fileManager
        self.sessionAudioLoader = sessionAudioLoader
    }

    func diarize(
        systemAudioURL: URL,
        sessionID: UUID,
        configuration: DiarizationEngineConfiguration
    ) async throws -> DiarizationDocument {
        guard fileManager.fileExists(atPath: systemAudioURL.path) else {
            throw DiarizationRuntimeError.invalidInput
        }

        guard ["system.raw.caf", "system.raw.flac"].contains(systemAudioURL.lastPathComponent) else {
            throw DiarizationRuntimeError.invalidInput
        }

        let preparedAudio = try sessionAudioLoader.loadAudio(from: systemAudioURL)
        let normalizedAudio = try preparedAudio.resampled(to: 16_000)
        let result = try await manager.process(audio: normalizedAudio.samples)

        guard !result.segments.isEmpty else {
            throw DiarizationRuntimeError.emptySegments
        }

        return DiarizationDocument(
            version: 1,
            sessionID: sessionID,
            createdAt: Date(),
            segments: result.segments.enumerated().map { index, segment in
                let startMs = max(0, Int((Double(segment.startTimeSeconds) * 1_000.0).rounded(.down)))
                return DiarizationSegment(
                    id: "dseg-\(index + 1)",
                    speaker: segment.speakerId,
                    startMs: startMs,
                    endMs: max(Int((Double(segment.endTimeSeconds) * 1_000.0).rounded(.up)), startMs + 1),
                    confidence: Double(segment.qualityScore)
                )
            }
        )
    }
}
```

This removes `FluidAudioDiarizationSegment`, `FluidAudioOfflineDiarizationRunning`, `FluidAudioOfflineDiarizationRunner`, `FluidAudioDiarizationService`, and the old `FluidAudioDiarizationEngine`.

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild build -scheme Recordly -destination 'platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (the factory still creates the old engine — that's fixed next)

Note: This may fail because `DefaultInferenceEngineFactory` creates `FluidAudioDiarizationEngine()` with no arguments. That's expected — Task 5 fixes this.

- [ ] **Step 3: Commit (after Task 5 if build fails here)**

Commit with Task 5 if needed.

---

### Task 5: Make `DefaultInferenceEngineFactory` stateful with diarization provider

**Files:**
- Modify: `Recordly/Infrastructure/Inference/Factory/DefaultInferenceEngineFactory.swift`
- Modify: `Recordly/Infrastructure/Inference/Composition/DefaultInferenceComposition.swift`

- [ ] **Step 1: Update the factory**

```swift
import Foundation

struct DefaultInferenceEngineFactory: InferenceEngineFactory {
    private let diarizationModelProvider: any FluidAudioDiarizationModelProviding

    init(diarizationModelProvider: any FluidAudioDiarizationModelProviding) {
        self.diarizationModelProvider = diarizationModelProvider
    }

    @MainActor
    func makeAudioCaptureEngine(for profile: InferenceRuntimeProfile) throws -> any AudioCaptureEngine {
        switch profile.stageSelection.backend(for: .audioCapture) {
        case .nativeCapture:
            return AudioCaptureService()
        case let backend:
            throw InferenceEngineFactoryError.unsupportedBackend(stage: .audioCapture, backend: backend)
        }
    }

    func makeASREngine(for profile: InferenceRuntimeProfile) throws -> any ASREngine {
        switch profile.stageSelection.backend(for: .asr) {
        case .fluidAudio:
            return FluidAudioASREngine()
        case let backend:
            throw InferenceEngineFactoryError.unsupportedBackend(stage: .asr, backend: backend)
        }
    }

    @MainActor
    func makeDiarizationEngine(for profile: InferenceRuntimeProfile) throws -> any DiarizationEngine {
        switch profile.stageSelection.backend(for: .diarization) {
        case .fluidAudio:
            let manager = try diarizationModelProvider.resolveForRuntime()
            return FluidAudioDiarizationEngine(manager: manager)
        case .cliDiarization:
            return CliDiarizationEngine()
        case let backend:
            throw InferenceEngineFactoryError.unsupportedBackend(stage: .diarization, backend: backend)
        }
    }

    func makeSummarizationEngine(for profile: InferenceRuntimeProfile) throws -> any SummarizationEngine {
        switch profile.stageSelection.backend(for: .summarization) {
        case .llamaCpp:
            return LlamaCppSummarizationEngine()
        case let backend:
            throw InferenceEngineFactoryError.unsupportedBackend(stage: .summarization, backend: backend)
        }
    }

    func makeVoiceActivityDetectionEngine(for profile: InferenceRuntimeProfile) throws -> (any VoiceActivityDetectionEngine)? {
        switch profile.stageSelection.backend(for: .vad) {
        case .disabled:
            return nil
        case let backend:
            throw InferenceEngineFactoryError.unsupportedBackend(stage: .vad, backend: backend)
        }
    }

    func transcriptionEngineDisplayName(for stageSelection: StageRuntimeSelection) -> String {
        switch stageSelection.backend(for: .asr) {
        case .fluidAudio:
            return "FluidAudio"
        default:
            return "ASR"
        }
    }
}
```

Note: `makeDiarizationEngine` now needs `@MainActor` because `resolveForRuntime()` is on a `@MainActor` protocol. If the `InferenceEngineFactory` protocol doesn't already mark this as `@MainActor`, the implementation can use `MainActor.assumeIsolated` or the call can be restructured. Check compilation and adjust as needed.

- [ ] **Step 2: Update `DefaultInferenceComposition`**

```swift
import Foundation

@MainActor
struct InferenceComposition {
    let runtimeProfileSelector: any InferenceRuntimeProfileSelecting
    let engineFactory: any InferenceEngineFactory
    let audioCaptureEngine: any AudioCaptureEngine
    let transcriptionEngineDisplayName: String
}

@MainActor
enum DefaultInferenceComposition {
    static func make(
        modelManager: ModelManager,
        asrModelProvider: any FluidAudioASRModelProviding,
        diarizationModelProvider: any FluidAudioDiarizationModelProviding
    ) -> InferenceComposition {
        let stageSelection = StageRuntimeSelection.defaultLocal
        let runtimeProfileSelector = DefaultInferenceRuntimeProfileSelector(
            modelManager: modelManager,
            asrModelProvider: asrModelProvider,
            diarizationModelProvider: diarizationModelProvider,
            stageSelection: stageSelection
        )
        let engineFactory = DefaultInferenceEngineFactory(
            diarizationModelProvider: diarizationModelProvider
        )
        let bootstrapProfile = InferenceRuntimeProfile(
            stageSelection: stageSelection,
            modelArtifacts: .empty,
            summarizationRuntimeSettings: modelManager.summarizationRuntimeSettings
        )
        let audioCaptureEngine = (try? engineFactory.makeAudioCaptureEngine(for: bootstrapProfile)) ?? AudioCaptureService()

        return InferenceComposition(
            runtimeProfileSelector: runtimeProfileSelector,
            engineFactory: engineFactory,
            audioCaptureEngine: audioCaptureEngine,
            transcriptionEngineDisplayName: engineFactory.transcriptionEngineDisplayName(for: stageSelection)
        )
    }
}
```

- [ ] **Step 3: Build (may fail until selector is updated in Task 6)**

Defer build verification to after Task 6.

---

### Task 6: Update `DefaultInferenceRuntimeProfileSelector` for dual providers

**Files:**
- Modify: `Recordly/Infrastructure/Inference/Runtime/DefaultInferenceRuntimeProfileSelector.swift`

- [ ] **Step 1: Rewrite the selector**

```swift
import Foundation

enum InferenceRuntimeProfileError: LocalizedError, Equatable {
    case missingFluidAudioModel
    case fluidAudioProvisioningFailed(message: String)
    case missingSummarizationModel
    case invalidFluidAudioModel(modelURL: URL)

    var errorDescription: String? {
        switch self {
        case .missingFluidAudioModel:
            return "No FluidAudio model is provisioned. Download FluidAudio v3 model in Models settings."
        case let .fluidAudioProvisioningFailed(message):
            return "FluidAudio model provisioning failed: \(message)"
        case .missingSummarizationModel:
            return "Select a summarization model before generating summary."
        case let .invalidFluidAudioModel(modelURL):
            return "FluidAudio requires a staged model directory (parakeet_vocab.json + CoreML bundles): \(modelURL.path)"
        }
    }
}

@MainActor
protocol InferenceRuntimeProfileSelecting {
    func transcriptionAvailability(for profile: ModelProfile) -> TranscriptionAvailability
    func resolveTranscriptionProfile(for profile: ModelProfile) throws -> InferenceRuntimeProfile
    func resolveSummarizationProfile(for profile: ModelProfile) throws -> InferenceRuntimeProfile
}

@MainActor
final class DefaultInferenceRuntimeProfileSelector: InferenceRuntimeProfileSelecting {
    private let modelManager: ModelManager
    private let asrModelProvider: any FluidAudioASRModelProviding
    private let diarizationModelProvider: any FluidAudioDiarizationModelProviding
    private let stageSelection: StageRuntimeSelection

    init(
        modelManager: ModelManager,
        asrModelProvider: any FluidAudioASRModelProviding,
        diarizationModelProvider: any FluidAudioDiarizationModelProviding,
        stageSelection: StageRuntimeSelection = .defaultLocal
    ) {
        self.modelManager = modelManager
        self.asrModelProvider = asrModelProvider
        self.diarizationModelProvider = diarizationModelProvider
        self.stageSelection = stageSelection
    }

    func transcriptionAvailability(for profile: ModelProfile) -> TranscriptionAvailability {
        asrModelProvider.refreshState()
        diarizationModelProvider.refreshState()

        switch asrModelProvider.state {
        case .ready:
            switch diarizationModelProvider.state {
            case .ready:
                return .ready
            case .needsDownload, .downloading, .failed:
                return .degradedNoDiarization
            }
        case .needsDownload, .downloading:
            return .unavailable(reason: InferenceRuntimeProfileError.missingFluidAudioModel.localizedDescription)
        case let .failed(message):
            return .unavailable(reason: InferenceRuntimeProfileError.fluidAudioProvisioningFailed(message: message).localizedDescription)
        }
    }

    func resolveTranscriptionProfile(for profile: ModelProfile) throws -> InferenceRuntimeProfile {
        let asrModelURL: URL
        do {
            asrModelURL = try asrModelProvider.resolveForRuntime()
        } catch let provisioningError as FluidAudioModelProvisioningError {
            switch provisioningError {
            case .noModelProvisioned:
                throw InferenceRuntimeProfileError.missingFluidAudioModel
            case let .downloadFailed(message):
                throw InferenceRuntimeProfileError.fluidAudioProvisioningFailed(message: message)
            case .sdkUnavailable:
                throw InferenceRuntimeProfileError.fluidAudioProvisioningFailed(message: provisioningError.localizedDescription)
            }
        }

        guard FluidAudioModelValidator.isValidModelDirectory(asrModelURL) else {
            throw InferenceRuntimeProfileError.invalidFluidAudioModel(modelURL: asrModelURL)
        }

        return InferenceRuntimeProfile(
            stageSelection: stageSelection,
            modelArtifacts: InferenceModelArtifacts(
                asrModelURL: asrModelURL,
                diarizationModelURL: nil,
                summarizationModelURL: nil
            ),
            summarizationRuntimeSettings: modelManager.summarizationRuntimeSettings
        )
    }

    func resolveSummarizationProfile(for profile: ModelProfile) throws -> InferenceRuntimeProfile {
        guard let summarizationOption = modelManager.selectedLocalOption(kind: .summarization) else {
            throw InferenceRuntimeProfileError.missingSummarizationModel
        }

        return InferenceRuntimeProfile(
            stageSelection: stageSelection,
            modelArtifacts: InferenceModelArtifacts(
                asrModelURL: nil,
                diarizationModelURL: nil,
                summarizationModelURL: summarizationOption.url
            ),
            summarizationRuntimeSettings: modelManager.summarizationRuntimeSettings
        )
    }
}
```

Key changes: `diarizationModelURL` is `nil` in both profiles. Diarization readiness is checked via the provider in `transcriptionAvailability`, and the manager is injected via the factory (not the profile).

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild build -scheme Recordly -destination 'platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`
Expected: May fail on callers not yet updated (RecordlyApp, RecordingsStore, tests). Continue to Task 7.

---

### Task 7: Update pipeline, app wiring, and callers

**Files:**
- Modify: `Recordly/Infrastructure/Transcription/TranscriptionPipeline.swift`
- Modify: `Recordly/App/RecordlyApp.swift`
- Modify: `Recordly/Features/Recordings/Application/RecordingsStore.swift`

- [ ] **Step 1: Update pipeline diarization invocation**

In `TranscriptionPipeline.swift`, around line 229, change:

```swift
configuration: runtimeProfile.modelArtifacts.diarizationModelURL.map {
    DiarizationEngineConfiguration(modelURL: $0)
},
```

To:

```swift
configuration: DiarizationEngineConfiguration(
    modelURL: runtimeProfile.modelArtifacts.diarizationModelURL
),
```

This always passes a configuration (with optional modelURL), so the pipeline no longer skips diarization when the URL is nil.

- [ ] **Step 2: Remove the nil-configuration guard in `loadOrRunDiarization`**

In the same file, around line 518, change the guard:

```swift
guard let configuration else {
    return DiarizationLoadOutcome(document: nil, degradedReason: "diarization model not selected", modelUsed: nil)
}
```

Remove this guard entirely since configuration is now always provided.

Update the method signature to make `configuration` non-optional:

Change `configuration: DiarizationEngineConfiguration?` to `configuration: DiarizationEngineConfiguration` in the `loadOrRunDiarization` method signature.

- [ ] **Step 3: Update `modelUsed` logging**

Around lines 536, 542, 548, change `configuration.modelURL.lastPathComponent` to:

```swift
configuration.modelURL?.lastPathComponent ?? "sdk-managed"
```

- [ ] **Step 4: Update `RecordlyApp.swift`**

```swift
init() {
    let modelManager = ModelManager()
    let asrModelProvider = FluidAudioASRModelProvider()
    let diarizationModelProvider = FluidAudioDiarizationModelProvider()
    let composition = DefaultInferenceComposition.make(
        modelManager: modelManager,
        asrModelProvider: asrModelProvider,
        diarizationModelProvider: diarizationModelProvider
    )
    let pipeline = TranscriptionPipeline()
    _recordingsStore = StateObject(
        wrappedValue: RecordingsStore(
            audioCaptureEngine: composition.audioCaptureEngine,
            transcriptionPipeline: pipeline,
            runtimeProfileSelector: composition.runtimeProfileSelector,
            inferenceEngineFactory: composition.engineFactory,
            transcriptionEngineDisplayName: composition.transcriptionEngineDisplayName,
            modelManager: modelManager,
            asrModelProvider: asrModelProvider,
            diarizationModelProvider: diarizationModelProvider
        )
    )
}
```

- [ ] **Step 5: Update `RecordingsStore.swift` init**

Update the main init signature to accept both providers:

Change `fluidAudioModelProvider: FluidAudioModelProvider` (or the renamed version) to:
- `asrModelProvider: FluidAudioASRModelProvider`
- `diarizationModelProvider: FluidAudioDiarizationModelProvider`

Update `ModelSettingsViewModel` construction at line 62:
```swift
self.modelSettingsViewModel = ModelSettingsViewModel(
    modelManager: modelManager,
    asrModelProvider: asrModelProvider,
    diarizationModelProvider: diarizationModelProvider
)
```

Update the convenience init (~line 102) similarly:
```swift
convenience init(previewMode: Bool = false) {
    let modelManager = ModelManager()
    let asrModelProvider = FluidAudioASRModelProvider()
    let diarizationModelProvider = FluidAudioDiarizationModelProvider()
    let composition = DefaultInferenceComposition.make(
        modelManager: modelManager,
        asrModelProvider: asrModelProvider,
        diarizationModelProvider: diarizationModelProvider
    )
    self.init(
        audioCaptureEngine: composition.audioCaptureEngine,
        transcriptionPipeline: TranscriptionPipeline(),
        runtimeProfileSelector: composition.runtimeProfileSelector,
        inferenceEngineFactory: composition.engineFactory,
        transcriptionEngineDisplayName: composition.transcriptionEngineDisplayName,
        modelManager: modelManager,
        asrModelProvider: asrModelProvider,
        diarizationModelProvider: diarizationModelProvider,
        repository: RecordingsRepository(),
        previewMode: previewMode
    )
}
```

- [ ] **Step 6: Build to verify compilation**

Run: `xcodebuild build -scheme Recordly -destination 'platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`
Expected: May still fail on tests and UI — continue to next tasks.

- [ ] **Step 7: Commit Tasks 4-7 together**

```bash
git add Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioDiarizationEngine.swift \
       Recordly/Infrastructure/Inference/Factory/DefaultInferenceEngineFactory.swift \
       Recordly/Infrastructure/Inference/Composition/DefaultInferenceComposition.swift \
       Recordly/Infrastructure/Inference/Runtime/DefaultInferenceRuntimeProfileSelector.swift \
       Recordly/Infrastructure/Transcription/TranscriptionPipeline.swift \
       Recordly/App/RecordlyApp.swift \
       Recordly/Features/Recordings/Application/RecordingsStore.swift
git commit -m "refactor: rewire diarization to provider-owned manager

FluidAudioDiarizationEngine is now a thin executor receiving a ready
OfflineDiarizerManager from the factory. DefaultInferenceEngineFactory
holds the diarization provider and resolves the manager at engine
creation time. Pipeline always passes DiarizationEngineConfiguration
regardless of modelURL presence."
```

---

## Chunk 3: ModelManager Cleanup, UI, and Test Updates

### Task 8: Remove diarization from `ModelManager` and `ModelPreferencesStore`

**Files:**
- Modify: `Recordly/Infrastructure/Models/ModelManager.swift`
- Modify: `Recordly/Infrastructure/Models/ModelPreferencesStore.swift`

- [ ] **Step 1: Remove from `ModelPreferencesStore`**

Remove the `selectedDiarizationModelID` property (lines 48-51) and the `Keys.selectedDiarizationModelID` constant (line 10).

- [ ] **Step 2: Remove from `ModelManager`**

Remove `selectedDiarizationModelID` property (lines 72-75).

In `setSelectedModelID(_:for:)`, remove the `.diarization` case (line 172-173). Replace with a return:
```swift
case .diarization:
    return
```

In `selectedModelID(for:)`, remove the `.diarization` case (line 183-184). Replace with:
```swift
case .diarization:
    return nil
```

In `listLocalOptions(kind:)`, the guard `kind != .asr` already returns `[]`. Add diarization to that guard:
```swift
guard kind != .asr && kind != .diarization else { return [] }
```

In `listAvailableModels()`, change `[ModelKind.diarization, ModelKind.summarization]` to `[ModelKind.summarization]`.

In `isModelCandidate(_:kind:)`, change the `.diarization` case to return `false`:
```swift
case .diarization:
    return false
```

In `supportedModelExtensions(for:)`, change `.diarization` to return `[]`:
```swift
case .diarization:
    return []
```

In `availability(for:)`, remove the diarization check. This method is called by `ModelOnboardingCoordinator.downloadAndContinue(profile:)` after installing non-ASR models. Since ModelManager no longer tracks diarization readiness, this should return `.ready` — which is correct because ASR/diarization availability is now checked by `DefaultInferenceRuntimeProfileSelector.transcriptionAvailability()`, not by `ModelManager`. Simplify to:
```swift
func availability(for profile: ModelProfile) -> TranscriptionAvailability {
    .ready
}
```
Note: `ModelOnboardingCoordinator` will continue to work correctly — it uses this method only to decide whether to dismiss after installing summarization models, and the coordinator's `presentIfNeeded(for:)` receives availability from the selector, not from `ModelManager`.

In `classifyModelKind(url:)`, remove the diarization classification logic (lines 352-356). Files with "diarization" in the name should now be classified as `.summarization` (or ignored — they won't match summarization extensions either). Simplest: remove the diarization name check entirely:
```swift
private func classifyModelKind(url: URL) -> ModelKind {
    let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
    if resourceValues?.isDirectory == true {
        return .summarization
    }

    let ext = url.pathExtension.lowercased()
    if ext == "gguf" {
        return .summarization
    }
    return .summarization
}
```

- [ ] **Step 3: Build and test**

Run: `xcodebuild test -scheme Recordly -destination 'platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`
Expected: Some test failures in ModelDiscoveryTests (diarization assertions) — fixed in Task 10.

- [ ] **Step 4: Commit**

```bash
git add Recordly/Infrastructure/Models/ModelManager.swift \
       Recordly/Infrastructure/Models/ModelPreferencesStore.swift
git commit -m "refactor: remove diarization responsibility from ModelManager

ModelManager no longer discovers, selects, or manages diarization
models. Diarization provisioning is now handled by
FluidAudioDiarizationModelProvider. ModelManager retains summarization
only."
```

---

### Task 9: Update `ModelSettingsViewModel` and `ModelSettingsView`

**Files:**
- Modify: `Recordly/Features/Settings/Models/ModelSettingsViewModel.swift`
- Modify: `Recordly/Features/Settings/Models/ModelSettingsView.swift`

- [ ] **Step 1: Update ViewModel**

```swift
import Foundation

@MainActor
final class ModelSettingsViewModel: ObservableObject {
    @Published private(set) var summarizationModels: [LocalModelOption] = []
    @Published var selectedSummarizationModelID: String?

    @Published private(set) var asrProvisioningState: FluidAudioModelProvisioningState = .needsDownload
    @Published private(set) var diarizationProvisioningState: FluidAudioModelProvisioningState = .needsDownload

    private let modelManager: ModelManager
    private let asrModelProvider: any FluidAudioASRModelProviding
    private let diarizationModelProvider: any FluidAudioDiarizationModelProviding

    init(
        modelManager: ModelManager,
        asrModelProvider: any FluidAudioASRModelProviding,
        diarizationModelProvider: any FluidAudioDiarizationModelProviding
    ) {
        self.modelManager = modelManager
        self.asrModelProvider = asrModelProvider
        self.diarizationModelProvider = diarizationModelProvider
        asrProvisioningState = asrModelProvider.state
        diarizationProvisioningState = diarizationModelProvider.state
    }

    func refresh() {
        summarizationModels = modelManager.listLocalOptions(kind: .summarization)
        selectedSummarizationModelID = modelManager.selectedLocalOption(kind: .summarization)?.id

        asrModelProvider.refreshState()
        asrProvisioningState = asrModelProvider.state

        diarizationModelProvider.refreshState()
        diarizationProvisioningState = diarizationModelProvider.state
    }

    func selectSummarizationModel(_ modelID: String?) {
        modelManager.setSelectedModelID(modelID, for: .summarization)
        refresh()
    }

    func folderURL(for kind: ModelKind, source: LocalModelOption.Source) -> URL? {
        modelManager.modelsDirectory(kind: kind, source: source)
    }

    func sourceLabel(_ source: LocalModelOption.Source) -> String {
        switch source {
        case .shared: return "Shared"
        case .appSupport: return "App Support"
        case .userLocal: return "User"
        case .projectLocal: return "Project"
        }
    }

    func modelLabel(for option: LocalModelOption) -> String {
        let size = ByteCountFormatter.string(fromByteCount: option.sizeBytes, countStyle: .file)
        return "\(option.displayName) • \(size)"
    }

    // MARK: - ASR Provisioning

    var canDownloadASRModel: Bool {
        !isDownloadingASRModel && !isASRModelReady
    }

    var isDownloadingASRModel: Bool {
        if case .downloading = asrProvisioningState { return true }
        return false
    }

    var isASRModelReady: Bool {
        if case .ready = asrProvisioningState { return true }
        return false
    }

    func downloadASRModel() {
        Task {
            await asrModelProvider.downloadDefaultModel()
            asrProvisioningState = asrModelProvider.state
            refresh()
        }
    }

    // MARK: - Diarization Provisioning

    var canDownloadDiarizationModel: Bool {
        !isDownloadingDiarizationModel && !isDiarizationModelReady
    }

    var isDownloadingDiarizationModel: Bool {
        if case .downloading = diarizationProvisioningState { return true }
        return false
    }

    var isDiarizationModelReady: Bool {
        if case .ready = diarizationProvisioningState { return true }
        return false
    }

    func downloadDiarizationModel() {
        Task {
            await diarizationModelProvider.downloadDefaultModel()
            diarizationProvisioningState = diarizationModelProvider.state
            refresh()
        }
    }
}
```

- [ ] **Step 2: Update View**

In `ModelSettingsView.swift`, make these surgical edits (do NOT replace the entire body — preserve any content not shown here):

1. Update the subtitle text (line 21) to mention diarization provisioning.
2. Remove the `modelPickerCard(title: "Speaker Separation Model", ...)` call (lines 32-42).
3. Add the `diarizationProvisioningCard` in its place.
4. Rename `fluidAudioProvisioningCard` to `asrProvisioningCard` and update its references.

The body should look like:

```swift
var body: some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Models")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            Text("FluidAudio SDK manages ASR and diarization model provisioning. Configure summarization models below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            asrProvisioningCard

            Text("Language override is not required — FluidAudio v3 is multilingual.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)

            diarizationProvisioningCard

            modelPickerCard(
                title: "Summarization Model",
                subtitle: "Used by local summarization via llama.cpp-compatible CLI binaries.",
                options: viewModel.summarizationModels,
                selection: Binding(
                    get: { viewModel.selectedSummarizationModelID },
                    set: { viewModel.selectSummarizationModel($0) }
                ),
                kind: .summarization,
                allowsNone: true
            )
        }
        .padding(18)
    }
    .frame(minWidth: 820, minHeight: 460)
    .onAppear { viewModel.refresh() }
}
```

Rename `fluidAudioProvisioningCard` to `asrProvisioningCard` and update its references:

```swift
private var asrProvisioningCard: some View {
    VStack(alignment: .leading, spacing: 10) {
        Text("FluidAudio ASR Model")
            .font(.headline)
        Text("FluidAudio uses SDK-managed provisioning (v3). Download once, then transcribe immediately.")
            .font(.caption)
            .foregroundStyle(.secondary)

        switch viewModel.asrProvisioningState {
        case .ready:
            Text("FluidAudio v3 ASR model is installed and ready.")
                .font(.caption)
                .foregroundStyle(.green)
        case .needsDownload:
            Text("No ASR model installed.")
                .font(.caption)
                .foregroundStyle(.orange)
        case .downloading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading FluidAudio v3 ASR model...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text("Download failed: \(message)")
                .font(.caption)
                .foregroundStyle(.red)
        }

        Button("Download ASR Model") {
            viewModel.downloadASRModel()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!viewModel.canDownloadASRModel)
    }
    .padding(14)
    .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.04))
    )
}
```

Add the new diarization provisioning card:

```swift
private var diarizationProvisioningCard: some View {
    VStack(alignment: .leading, spacing: 10) {
        Text("Diarization Model")
            .font(.headline)
        Text("Speaker separation model. Optional — improves remote speaker labeling.")
            .font(.caption)
            .foregroundStyle(.secondary)

        switch viewModel.diarizationProvisioningState {
        case .ready:
            Text("Diarization model is installed and ready.")
                .font(.caption)
                .foregroundStyle(.green)
        case .needsDownload:
            Text("No diarization model installed.")
                .font(.caption)
                .foregroundStyle(.orange)
        case .downloading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading diarization model...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text("Download failed: \(message)")
                .font(.caption)
                .foregroundStyle(.red)
        }

        Button("Download Diarization Model") {
            viewModel.downloadDiarizationModel()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!viewModel.canDownloadDiarizationModel)
    }
    .padding(14)
    .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.04))
    )
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild build -scheme Recordly -destination 'platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`

- [ ] **Step 4: Commit**

```bash
git add Recordly/Features/Settings/Models/ModelSettingsViewModel.swift \
       Recordly/Features/Settings/Models/ModelSettingsView.swift
git commit -m "feat: replace diarization file picker with provisioning card

ModelSettingsViewModel now uses FluidAudioDiarizationModelProviding
for diarization state and download actions. The view shows a
provisioning card matching the ASR card pattern."
```

---

### Task 10: Update all tests

**Files:**
- Modify: `RecordlyTests/DefaultInferenceRuntimeProfileSelectorTests.swift`
- Modify: `RecordlyTests/DefaultInferenceEngineFactoryTests.swift`
- Modify: `RecordlyTests/TranscriptionPipelineTests.swift`
- Modify: `RecordlyTests/ModelDiscoveryTests.swift`
- Modify: `RecordlyTests/RecordingsPhaseOneTests.swift`
- Modify: `RecordlyTests/SummarizationTests.swift`

- [ ] **Step 1: Update `DefaultInferenceRuntimeProfileSelectorTests`**

Rewrite the test file to use dual providers:

```swift
import XCTest
@testable import Recordly

@MainActor
final class DefaultInferenceRuntimeProfileSelectorTests: XCTestCase {
    private var tempDirectory: URL!
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DefaultInferenceRuntimeProfileSelectorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defaultsSuiteName = "DefaultInferenceRuntimeProfileSelectorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        if let defaultsSuiteName {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        defaultsSuiteName = nil
        defaults = nil
    }

    func testResolveTranscriptionProfileUsesExpectedBackendsAndArtifacts() throws {
        let fluidDirectory = try createFluidModelDirectory(named: "fluid-asr-default")
        let manager = makeModelManager()
        let asrProvider = StubASRProvider(modelURL: fluidDirectory)
        let diarizationProvider = StubDiarizationProvider(ready: true)
        let selector = DefaultInferenceRuntimeProfileSelector(
            modelManager: manager,
            asrModelProvider: asrProvider,
            diarizationModelProvider: diarizationProvider
        )
        let profile = try selector.resolveTranscriptionProfile(for: .balanced)

        XCTAssertEqual(profile.stageSelection.backend(for: .asr), .fluidAudio)
        XCTAssertEqual(profile.stageSelection.backend(for: .diarization), .fluidAudio)
        XCTAssertEqual(
            profile.modelArtifacts.asrModelURL?.resolvingSymlinksInPath().path,
            fluidDirectory.resolvingSymlinksInPath().path
        )
        XCTAssertNil(profile.modelArtifacts.diarizationModelURL)
    }

    func testResolveTranscriptionProfileRejectsInvalidModelDirectory() throws {
        let invalidDir = tempDirectory.appendingPathComponent("not-a-fluid-model", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidDir, withIntermediateDirectories: true)
        let manager = makeModelManager()
        let asrProvider = StubASRProvider(modelURL: invalidDir)
        let diarizationProvider = StubDiarizationProvider(ready: true)
        let selector = DefaultInferenceRuntimeProfileSelector(
            modelManager: manager,
            asrModelProvider: asrProvider,
            diarizationModelProvider: diarizationProvider
        )

        XCTAssertThrowsError(try selector.resolveTranscriptionProfile(for: .balanced)) { error in
            guard case .invalidFluidAudioModel = error as? InferenceRuntimeProfileError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testResolveSummarizationProfileUsesLlamaCppAndRuntimeSettings() throws {
        _ = try writeModel(named: "summarization-compact-v1.gguf")
        let manager = makeModelManager()
        manager.summarizationRuntimeSettings = SummarizationRuntimeSettings(
            contextSize: 4096,
            temperature: 0.2,
            topP: 0.8
        )
        let summarizationOption = try XCTUnwrap(manager.listLocalOptions(kind: .summarization).first)
        manager.setSelectedModelID(summarizationOption.id, for: .summarization)

        let asrProvider = StubASRProvider(modelURL: nil)
        let diarizationProvider = StubDiarizationProvider(ready: false)
        let selector = DefaultInferenceRuntimeProfileSelector(
            modelManager: manager,
            asrModelProvider: asrProvider,
            diarizationModelProvider: diarizationProvider
        )
        let profile = try selector.resolveSummarizationProfile(for: .balanced)

        XCTAssertEqual(profile.stageSelection.backend(for: .summarization), .llamaCpp)
        XCTAssertEqual(
            profile.modelArtifacts.summarizationModelURL?.resolvingSymlinksInPath().path,
            summarizationOption.url.resolvingSymlinksInPath().path
        )
        XCTAssertNil(profile.modelArtifacts.diarizationModelURL)
        XCTAssertEqual(profile.summarizationRuntimeSettings.contextSize, 4096)
    }

    func testTranscriptionAvailabilityReportsNeedsDownload() {
        let manager = makeModelManager()
        let asrProvider = StubASRProvider(modelURL: nil)
        let diarizationProvider = StubDiarizationProvider(ready: false)
        let selector = DefaultInferenceRuntimeProfileSelector(
            modelManager: manager,
            asrModelProvider: asrProvider,
            diarizationModelProvider: diarizationProvider
        )

        let availability = selector.transcriptionAvailability(for: .balanced)
        XCTAssertEqual(
            availability,
            .unavailable(reason: InferenceRuntimeProfileError.missingFluidAudioModel.localizedDescription)
        )
    }

    func testTranscriptionAvailabilityReportsDegradedWhenDiarizationMissing() throws {
        let fluidDirectory = try createFluidModelDirectory(named: "fluid-asr-v3")
        let manager = makeModelManager()
        let asrProvider = StubASRProvider(modelURL: fluidDirectory)
        let diarizationProvider = StubDiarizationProvider(ready: false)
        let selector = DefaultInferenceRuntimeProfileSelector(
            modelManager: manager,
            asrModelProvider: asrProvider,
            diarizationModelProvider: diarizationProvider
        )

        let availability = selector.transcriptionAvailability(for: .balanced)
        XCTAssertEqual(availability, .degradedNoDiarization)
    }

    func testTranscriptionAvailabilityReportsReadyWhenBothProvisioned() throws {
        let fluidDirectory = try createFluidModelDirectory(named: "fluid-asr-v3")
        let manager = makeModelManager()
        let asrProvider = StubASRProvider(modelURL: fluidDirectory)
        let diarizationProvider = StubDiarizationProvider(ready: true)
        let selector = DefaultInferenceRuntimeProfileSelector(
            modelManager: manager,
            asrModelProvider: asrProvider,
            diarizationModelProvider: diarizationProvider
        )

        let availability = selector.transcriptionAvailability(for: .balanced)
        XCTAssertEqual(availability, .ready)
    }

    // MARK: - Helpers

    private func makeModelManager() -> ModelManager {
        ModelManager(
            preferences: ModelPreferencesStore(defaults: defaults),
            discoveryPaths: ModelDiscoveryPaths(
                appSupportDirectory: { _ in nil },
                sharedDirectory: { _ in nil },
                userDirectory: { _ in nil },
                projectDirectories: { [self.tempDirectory] }
            )
        )
    }

    private func writeModel(named name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try Data("model".utf8).write(to: url)
        return url
    }

    private func createFluidModelDirectory(named name: String) throws -> URL {
        let directory = tempDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for marker in FluidAudioModelValidator.requiredMarkers {
            let markerURL = directory.appendingPathComponent(marker)
            if marker.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: markerURL, withIntermediateDirectories: true)
            } else {
                try Data("marker".utf8).write(to: markerURL)
            }
        }
        return directory
    }

    private final class StubASRProvider: FluidAudioASRModelProviding {
        private(set) var state: FluidAudioModelProvisioningState
        private let modelURL: URL?

        init(modelURL: URL?) {
            self.modelURL = modelURL
            self.state = modelURL != nil ? .ready : .needsDownload
        }

        func refreshState() {}
        func downloadDefaultModel() async {}

        func resolveForRuntime() throws -> URL {
            guard let modelURL else {
                throw FluidAudioModelProvisioningError.noModelProvisioned
            }
            return modelURL
        }
    }

    private final class StubDiarizationProvider: FluidAudioDiarizationModelProviding {
        private(set) var state: FluidAudioModelProvisioningState

        init(ready: Bool) {
            self.state = ready ? .ready : .needsDownload
        }

        func refreshState() {}
        func downloadDefaultModel() async {}

        func resolveForRuntime() throws -> any OfflineDiarizationManaging {
            guard case .ready = state else {
                throw FluidAudioModelProvisioningError.noModelProvisioned
            }
            return StubOfflineDiarizationManager()
        }
    }

    private final class StubOfflineDiarizationManager: OfflineDiarizationManaging {
        func prepareModels() async throws {}
        func process(audio: [Float]) async throws -> DiarizationResult {
            DiarizationResult(segments: [])
        }
    }
}
```

- [ ] **Step 2: Update `DefaultInferenceEngineFactoryTests`**

```swift
import XCTest
@testable import Recordly

final class DefaultInferenceEngineFactoryTests: XCTestCase {
    @MainActor
    func testFactoryBuildsExpectedEnginesForDefaultLocalProfile() throws {
        let diarizationProvider = StubDiarizationProvider(ready: true)
        let factory = DefaultInferenceEngineFactory(diarizationModelProvider: diarizationProvider)
        let profile = InferenceRuntimeProfile(
            stageSelection: .defaultLocal,
            modelArtifacts: InferenceModelArtifacts(
                asrModelURL: URL(fileURLWithPath: "/tmp/asr-fluid"),
                diarizationModelURL: nil,
                summarizationModelURL: URL(fileURLWithPath: "/tmp/summary.gguf")
            ),
            summarizationRuntimeSettings: .default
        )

        let asrEngine = try factory.makeASREngine(for: profile)
        let diarizationEngine = try factory.makeDiarizationEngine(for: profile)
        let summarizationEngine = try factory.makeSummarizationEngine(for: profile)

        XCTAssertEqual(String(describing: type(of: asrEngine)), "FluidAudioASREngine")
        XCTAssertEqual(String(describing: type(of: diarizationEngine)), "FluidAudioDiarizationEngine")
        XCTAssertEqual(String(describing: type(of: summarizationEngine)), "LlamaCppSummarizationEngine")
    }

    @MainActor
    func testFactoryThrowsWhenBackendNotSupportedForStage() {
        let diarizationProvider = StubDiarizationProvider(ready: false)
        let factory = DefaultInferenceEngineFactory(diarizationModelProvider: diarizationProvider)
        var selection = StageRuntimeSelection.defaultLocal
        selection.setBackend(.llamaCpp, for: .asr)
        let profile = InferenceRuntimeProfile(
            stageSelection: selection,
            modelArtifacts: InferenceModelArtifacts(
                asrModelURL: URL(fileURLWithPath: "/tmp/asr.bin"),
                diarizationModelURL: nil,
                summarizationModelURL: nil
            ),
            summarizationRuntimeSettings: .default
        )

        XCTAssertThrowsError(try factory.makeASREngine(for: profile)) { error in
            XCTAssertEqual(
                error as? InferenceEngineFactoryError,
                .unsupportedBackend(stage: .asr, backend: .llamaCpp)
            )
        }
    }

    @MainActor
    func testFactoryBuildsFluidAudioEngineWhenASRBackendIsFluidAudio() throws {
        let diarizationProvider = StubDiarizationProvider(ready: false)
        let factory = DefaultInferenceEngineFactory(diarizationModelProvider: diarizationProvider)
        var selection = StageRuntimeSelection.defaultLocal
        selection.setBackend(.fluidAudio, for: .asr)
        let profile = InferenceRuntimeProfile(
            stageSelection: selection,
            modelArtifacts: InferenceModelArtifacts(
                asrModelURL: URL(fileURLWithPath: "/tmp/asr-fluid"),
                diarizationModelURL: nil,
                summarizationModelURL: nil
            ),
            summarizationRuntimeSettings: .default
        )

        let asrEngine = try factory.makeASREngine(for: profile)

        XCTAssertEqual(String(describing: type(of: asrEngine)), "FluidAudioASREngine")
        XCTAssertEqual(factory.transcriptionEngineDisplayName(for: selection), "FluidAudio")
    }
}

// MARK: - Test Stubs

private final class StubDiarizationProvider: FluidAudioDiarizationModelProviding {
    private(set) var state: FluidAudioModelProvisioningState

    init(ready: Bool) {
        self.state = ready ? .ready : .needsDownload
    }

    func refreshState() {}
    func downloadDefaultModel() async {}

    func resolveForRuntime() throws -> any OfflineDiarizationManaging {
        guard case .ready = state else {
            throw FluidAudioModelProvisioningError.noModelProvisioned
        }
        return StubManager()
    }

    private final class StubManager: OfflineDiarizationManaging {
        func prepareModels() async throws {}
        func process(audio: [Float]) async throws -> DiarizationResult {
            DiarizationResult(segments: [])
        }
    }
}
```

- [ ] **Step 3: Update `ModelDiscoveryTests`**

In `testListLocalOptionsDeduplicatesByBasenameUsingSourcePriority`: This test creates `diarization-enhanced.bin` in three directories and asserts dedup. Since `listLocalOptions(kind: .diarization)` now returns `[]`, change the test to verify summarization dedup instead. Either:
- Replace `diarization-enhanced.bin` with a summarization model (e.g., `summary.gguf`) and test `listLocalOptions(kind: .summarization)`, or
- Delete the test entirely if no other model kind needs dedup testing.

In `testProjectLocalClassificationUsesExtensionAndFilenameHeuristics`: Remove `diarization-enhanced.bin` from the test setup and remove the assertion:
```swift
XCTAssertEqual(
    Set(manager.listLocalOptions(kind: .diarization).map { $0.url.lastPathComponent }),
    ["diarization-enhanced.bin"]
)
```
Replace with:
```swift
XCTAssertTrue(manager.listLocalOptions(kind: .diarization).isEmpty)
```
The `diarization-enhanced.bin` file can be removed from the setup since it won't match any kind now. Update the summarization expected set to include any files that were previously classified as diarization but now fall through to summarization.

- [ ] **Step 4: Update `RecordingsPhaseOneTests`**

In `makeStore(repository:)`, update to use the new composition signature:

```swift
private func makeStore(repository: InMemoryRecordingsRepository) -> RecordingsStore {
    let modelManager = ModelManager()
    let asrProvider = FluidAudioASRModelProvider()
    let diarizationProvider = FluidAudioDiarizationModelProvider()
    let composition = DefaultInferenceComposition.make(
        modelManager: modelManager,
        asrModelProvider: asrProvider,
        diarizationModelProvider: diarizationProvider
    )
    return RecordingsStore(
        audioCaptureEngine: composition.audioCaptureEngine,
        transcriptionPipeline: TranscriptionPipeline(),
        runtimeProfileSelector: composition.runtimeProfileSelector,
        inferenceEngineFactory: composition.engineFactory,
        transcriptionEngineDisplayName: composition.transcriptionEngineDisplayName,
        modelManager: modelManager,
        asrModelProvider: asrProvider,
        diarizationModelProvider: diarizationProvider,
        repository: repository,
        previewMode: false
    )
}
```

- [ ] **Step 5: Update `TranscriptionPipelineTests`**

Search for any mock diarization engines or `DiarizationEngineConfiguration` constructions that use non-optional `modelURL`. Update to use the optional form. This is primarily mechanical — find all `DiarizationEngineConfiguration(modelURL: ...)` and verify they still compile.

Also update any test mock `DiarizationEngine` conformers to handle optional `modelURL`.

- [ ] **Step 6: Update `SummarizationTests`**

The `NoopDiarizationEngine` already ignores `configuration.modelURL`, so it should compile without changes. Verify.

- [ ] **Step 7: Run all tests**

Run: `xcodebuild test -scheme Recordly -destination 'platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 8: Commit**

```bash
git add RecordlyTests/
git commit -m "test: update all tests for diarization provider migration

Selector tests use dual ASR + diarization provider stubs. Factory
tests inject mock diarization provider. ModelDiscovery tests remove
diarization .bin assertions. Pipeline and integration tests updated
for optional modelURL and new composition signatures."
```

---

### Task 11: Final verification and cleanup

- [ ] **Step 1: Full test run**

Run: `xcodebuild test -scheme Recordly -destination 'platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: All tests pass, no warnings related to the migration

- [ ] **Step 2: Verify no stale references**

Search for any remaining references to old names:

```bash
grep -r "FluidAudioModelProviding\b" --include="*.swift" Recordly/ RecordlyTests/ | grep -v "ASRModelProviding\|DiarizationModelProviding"
grep -r "FluidAudioModelProvider\b" --include="*.swift" Recordly/ RecordlyTests/ | grep -v "ASRModelProvider\|DiarizationModelProvider"
grep -r "selectedDiarizationModelID" --include="*.swift" Recordly/ RecordlyTests/
```

Expected: No matches (all references updated)

- [ ] **Step 3: Verify ModelManager no longer handles diarization**

```bash
grep -n "\.diarization" Recordly/Infrastructure/Models/ModelManager.swift
```

Expected: Only `return false`, `return []`, `return nil`, or `return` lines

- [ ] **Step 4: Commit if any cleanup was needed**

Only if Step 2 or 3 found issues to fix.

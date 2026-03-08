# ASR Model Provider Abstraction — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Introduce backend-scoped ASR model providers so FluidAudio gets SDK-managed model provisioning (download/status/resolve) while WhisperCpp keeps its local-file flow, with backend-specific persisted selection and split settings UX.

**Architecture:** New `ASRModelProvider` protocol with two implementations: `LocalFileASRModelProvider` (WhisperCpp — scans folders for `.bin` files, persists selection by path) and `FluidAudioModelProvider` (checks SDK cache, downloads via `AsrModels.downloadAndLoad()`, persists selection by version). `DefaultInferenceRuntimeProfileSelector` calls the active provider's `resolveModelURL()` instead of the generic `selectedLocalOption(kind: .asr)`. Settings view renders backend-specific sections: file picker for WhisperCpp, install/status for FluidAudio.

**Tech Stack:** Swift, SwiftUI, FluidAudio SDK (`AsrModels`), UserDefaults, XCTest

**Test command:** `xcodebuild test -scheme Recordly -destination 'platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`

---

## Task 1: Define ASRModelProvider protocol and types

**Files:**
- Create: `Recordly/Infrastructure/Inference/ASRModelProvider/ASRModelProvider.swift`
- Test: `RecordlyTests/ASRModelProviderTests.swift`

**Step 1: Create the protocol and supporting types**

```swift
// Recordly/Infrastructure/Inference/ASRModelProvider/ASRModelProvider.swift
import Foundation

enum ASRModelProvisioningState: Equatable {
    case ready
    case notInstalled
    case downloading(progress: Double)
    case error(String)
}

struct ASRModelInfo: Identifiable, Equatable {
    let id: String
    let displayName: String
    let url: URL
    let sizeBytes: Int64
}

enum ASRModelResolutionError: LocalizedError, Equatable {
    case noModelInstalled(backend: ASRBackend)
    case downloadRequired(backend: ASRBackend)
    case modelFileNotFound(path: String)

    var errorDescription: String? {
        switch self {
        case .noModelInstalled(let backend):
            return "No \(backend.displayName) model is installed. Download or select a model in Settings."
        case .downloadRequired(let backend):
            return "\(backend.displayName) requires a model download before transcription."
        case .modelFileNotFound(let path):
            return "Model file not found: \(path)"
        }
    }
}

@MainActor
protocol ASRModelProvider {
    var backend: ASRBackend { get }
    var provisioningState: ASRModelProvisioningState { get }
    var availableModels: [ASRModelInfo] { get }
    var selectedModel: ASRModelInfo? { get }
    func selectModel(_ id: String)
    func resolveModelURL() throws -> URL
    func refresh()
}
```

**Step 2: Verify build succeeds**

Run: full build command
Expected: BUILD SUCCEEDED (new file compiles, nothing uses it yet)

**Step 3: Commit**

```
feat(asr): define ASRModelProvider protocol and supporting types
```

---

## Task 2: Implement LocalFileASRModelProvider (WhisperCpp)

**Files:**
- Create: `Recordly/Infrastructure/Inference/ASRModelProvider/LocalFileASRModelProvider.swift`
- Test: `RecordlyTests/ASRModelProviderTests.swift`

**Step 1: Write failing tests**

```swift
// RecordlyTests/ASRModelProviderTests.swift
import XCTest
@testable import Recordly

final class LocalFileASRModelProviderTests: XCTestCase {
    private var tempDirectory: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFileASRModelProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "LocalFileASRModelProviderTests-\(UUID().uuidString)")!
    }

    override func tearDownWithError() throws {
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        if let defaults { defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first ?? "") }
    }

    @MainActor
    func testDiscoversBinFilesInScanDirectories() throws {
        let asrDir = tempDirectory.appendingPathComponent("asr", isDirectory: true)
        try FileManager.default.createDirectory(at: asrDir, withIntermediateDirectories: true)
        try Data("m1".utf8).write(to: asrDir.appendingPathComponent("whisper-small.bin"))
        try Data("m2".utf8).write(to: asrDir.appendingPathComponent("podlodka.bin"))
        try Data("m3".utf8).write(to: asrDir.appendingPathComponent("summary.gguf")) // not .bin

        let provider = LocalFileASRModelProvider(
            scanDirectories: [asrDir],
            preferences: ModelPreferencesStore(defaults: defaults)
        )
        provider.refresh()

        XCTAssertEqual(provider.backend, .whisperCpp)
        XCTAssertEqual(provider.availableModels.count, 2)
        XCTAssertTrue(provider.availableModels.allSatisfy { $0.url.pathExtension == "bin" })
    }

    @MainActor
    func testProvisioningStateReadyWhenModelsExist() throws {
        let asrDir = tempDirectory.appendingPathComponent("asr", isDirectory: true)
        try FileManager.default.createDirectory(at: asrDir, withIntermediateDirectories: true)
        try Data("m".utf8).write(to: asrDir.appendingPathComponent("model.bin"))

        let provider = LocalFileASRModelProvider(
            scanDirectories: [asrDir],
            preferences: ModelPreferencesStore(defaults: defaults)
        )
        provider.refresh()

        XCTAssertEqual(provider.provisioningState, .ready)
    }

    @MainActor
    func testProvisioningStateNotInstalledWhenEmpty() {
        let provider = LocalFileASRModelProvider(
            scanDirectories: [tempDirectory],
            preferences: ModelPreferencesStore(defaults: defaults)
        )
        provider.refresh()

        XCTAssertEqual(provider.provisioningState, .notInstalled)
    }

    @MainActor
    func testSelectModelPersistsAndResolves() throws {
        let asrDir = tempDirectory.appendingPathComponent("asr", isDirectory: true)
        try FileManager.default.createDirectory(at: asrDir, withIntermediateDirectories: true)
        let modelURL = asrDir.appendingPathComponent("podlodka.bin")
        try Data("m".utf8).write(to: modelURL)

        let provider = LocalFileASRModelProvider(
            scanDirectories: [asrDir],
            preferences: ModelPreferencesStore(defaults: defaults)
        )
        provider.refresh()
        provider.selectModel(modelURL.path)

        XCTAssertEqual(provider.selectedModel?.id, modelURL.path)
        XCTAssertEqual(try provider.resolveModelURL(), modelURL)
    }

    @MainActor
    func testResolveModelURLThrowsWhenNoneSelected() {
        let provider = LocalFileASRModelProvider(
            scanDirectories: [tempDirectory],
            preferences: ModelPreferencesStore(defaults: defaults)
        )
        provider.refresh()

        XCTAssertThrowsError(try provider.resolveModelURL()) { error in
            guard case ASRModelResolutionError.noModelInstalled(.whisperCpp) = error else {
                return XCTFail("Expected noModelInstalled, got \(error)")
            }
        }
    }

    @MainActor
    func testAutoSelectsFirstModelWhenNoPriorSelection() throws {
        let asrDir = tempDirectory.appendingPathComponent("asr", isDirectory: true)
        try FileManager.default.createDirectory(at: asrDir, withIntermediateDirectories: true)
        try Data("m".utf8).write(to: asrDir.appendingPathComponent("alpha.bin"))
        try Data("m".utf8).write(to: asrDir.appendingPathComponent("beta.bin"))

        let provider = LocalFileASRModelProvider(
            scanDirectories: [asrDir],
            preferences: ModelPreferencesStore(defaults: defaults)
        )
        provider.refresh()

        XCTAssertNotNil(provider.selectedModel)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: test command with `-only-testing:RecordlyTests/LocalFileASRModelProviderTests`
Expected: FAIL — `LocalFileASRModelProvider` not found

**Step 3: Implement LocalFileASRModelProvider**

```swift
// Recordly/Infrastructure/Inference/ASRModelProvider/LocalFileASRModelProvider.swift
import Foundation

@MainActor
final class LocalFileASRModelProvider: ASRModelProvider {
    let backend: ASRBackend = .whisperCpp

    private(set) var provisioningState: ASRModelProvisioningState = .notInstalled
    private(set) var availableModels: [ASRModelInfo] = []
    private(set) var selectedModel: ASRModelInfo?

    private let scanDirectories: [URL]
    private let preferences: ModelPreferencesStore
    private let fileManager: FileManager

    init(
        scanDirectories: [URL],
        preferences: ModelPreferencesStore,
        fileManager: FileManager = .default
    ) {
        self.scanDirectories = scanDirectories
        self.preferences = preferences
        self.fileManager = fileManager
    }

    func refresh() {
        var models: [ASRModelInfo] = []
        var seen = Set<String>()

        for directory in scanDirectories {
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            let urls = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                guard isFile, url.pathExtension.lowercased() == "bin" else { continue }
                let basename = url.deletingPathExtension().lastPathComponent.lowercased()
                guard !basename.contains("diarization"),
                      !basename.contains("summarization"),
                      !basename.contains("summary") else { continue }
                guard seen.insert(url.path).inserted else { continue }

                let size = ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
                let displayName = url.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
                    .capitalized

                models.append(ASRModelInfo(id: url.path, displayName: displayName, url: url, sizeBytes: size))
            }
        }

        availableModels = models
        provisioningState = models.isEmpty ? .notInstalled : .ready

        // Restore persisted selection
        if let savedID = preferences.selectedWhisperModelID,
           let match = models.first(where: { $0.id == savedID }) {
            selectedModel = match
        } else if let first = models.first {
            selectedModel = first
            preferences.selectedWhisperModelID = first.id
        } else {
            selectedModel = nil
        }
    }

    func selectModel(_ id: String) {
        if let match = availableModels.first(where: { $0.id == id }) {
            selectedModel = match
            preferences.selectedWhisperModelID = id
        }
    }

    func resolveModelURL() throws -> URL {
        guard let model = selectedModel else {
            throw ASRModelResolutionError.noModelInstalled(backend: .whisperCpp)
        }
        guard fileManager.fileExists(atPath: model.url.path) else {
            throw ASRModelResolutionError.modelFileNotFound(path: model.url.path)
        }
        return model.url
    }
}
```

**Step 4: Add `selectedWhisperModelID` to ModelPreferencesStore**

In `Recordly/Infrastructure/Models/ModelPreferencesStore.swift`, add to Keys:
```swift
static let selectedWhisperModelID = "model.selectedWhisperModelID"
```

Add property:
```swift
var selectedWhisperModelID: String? {
    get { defaults.string(forKey: Keys.selectedWhisperModelID) }
    set { defaults.set(newValue, forKey: Keys.selectedWhisperModelID) }
}
```

**Step 5: Run tests to verify they pass**

Run: test command with `-only-testing:RecordlyTests/LocalFileASRModelProviderTests`
Expected: 6 tests PASS

**Step 6: Commit**

```
feat(asr): implement LocalFileASRModelProvider for WhisperCpp
```

---

## Task 3: Implement FluidAudioModelProvider

**Files:**
- Create: `Recordly/Infrastructure/Inference/ASRModelProvider/FluidAudioModelProvider.swift`
- Test: `RecordlyTests/FluidAudioModelProviderTests.swift`

**Step 1: Write failing tests**

```swift
// RecordlyTests/FluidAudioModelProviderTests.swift
import XCTest
@testable import Recordly

final class FluidAudioModelProviderTests: XCTestCase {
    private var tempDirectory: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidAudioModelProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "FluidAudioModelProviderTests-\(UUID().uuidString)")!
    }

    override func tearDownWithError() throws {
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
    }

    @MainActor
    func testBackendIsFluidAudio() {
        let provider = FluidAudioModelProvider(
            sdkCacheDirectory: tempDirectory,
            preferences: ModelPreferencesStore(defaults: defaults)
        )
        XCTAssertEqual(provider.backend, .fluidAudio)
    }

    @MainActor
    func testNotInstalledWhenCacheDirectoryEmpty() {
        let provider = FluidAudioModelProvider(
            sdkCacheDirectory: tempDirectory,
            preferences: ModelPreferencesStore(defaults: defaults)
        )
        provider.refresh()

        XCTAssertEqual(provider.provisioningState, .notInstalled)
        XCTAssertTrue(provider.availableModels.isEmpty)
    }

    @MainActor
    func testDiscoversValidStagedModelDirectory() throws {
        let modelDir = tempDirectory.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml", isDirectory: true)
        try createFluidModelDirectory(at: modelDir)

        let provider = FluidAudioModelProvider(
            sdkCacheDirectory: tempDirectory,
            preferences: ModelPreferencesStore(defaults: defaults)
        )
        provider.refresh()

        XCTAssertEqual(provider.provisioningState, .ready)
        XCTAssertEqual(provider.availableModels.count, 1)
        XCTAssertNotNil(provider.selectedModel)
    }

    @MainActor
    func testResolveModelURLReturnsDirectoryURL() throws {
        let modelDir = tempDirectory.appendingPathComponent("parakeet-v3", isDirectory: true)
        try createFluidModelDirectory(at: modelDir)

        let provider = FluidAudioModelProvider(
            sdkCacheDirectory: tempDirectory,
            preferences: ModelPreferencesStore(defaults: defaults)
        )
        provider.refresh()

        let resolved = try provider.resolveModelURL()
        XCTAssertEqual(resolved, modelDir)
    }

    @MainActor
    func testResolveThrowsDownloadRequiredWhenNotInstalled() {
        let provider = FluidAudioModelProvider(
            sdkCacheDirectory: tempDirectory,
            preferences: ModelPreferencesStore(defaults: defaults)
        )
        provider.refresh()

        XCTAssertThrowsError(try provider.resolveModelURL()) { error in
            guard case ASRModelResolutionError.downloadRequired(.fluidAudio) = error else {
                return XCTFail("Expected downloadRequired, got \(error)")
            }
        }
    }

    @MainActor
    func testSkipsDirectoriesWithoutRequiredMarkers() throws {
        let invalidDir = tempDirectory.appendingPathComponent("some-random-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: invalidDir.appendingPathComponent("parakeet_vocab.json"))
        // Missing .mlmodelc bundles

        let provider = FluidAudioModelProvider(
            sdkCacheDirectory: tempDirectory,
            preferences: ModelPreferencesStore(defaults: defaults)
        )
        provider.refresh()

        XCTAssertEqual(provider.provisioningState, .notInstalled)
        XCTAssertTrue(provider.availableModels.isEmpty)
    }

    private func createFluidModelDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for marker in FluidAudioModelValidator.requiredMarkers {
            let markerURL = url.appendingPathComponent(marker)
            if marker.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: markerURL, withIntermediateDirectories: true)
            } else {
                try Data("marker".utf8).write(to: markerURL)
            }
        }
    }
}
```

**Step 2: Run tests to verify they fail**

Run: test command with `-only-testing:RecordlyTests/FluidAudioModelProviderTests`
Expected: FAIL — `FluidAudioModelProvider` not found

**Step 3: Implement FluidAudioModelProvider**

```swift
// Recordly/Infrastructure/Inference/ASRModelProvider/FluidAudioModelProvider.swift
import Foundation

#if arch(arm64) && canImport(FluidAudio)
import FluidAudio
#endif

@MainActor
final class FluidAudioModelProvider: ASRModelProvider {
    let backend: ASRBackend = .fluidAudio

    private(set) var provisioningState: ASRModelProvisioningState = .notInstalled
    private(set) var availableModels: [ASRModelInfo] = []
    private(set) var selectedModel: ASRModelInfo?

    private let sdkCacheDirectory: URL
    private let preferences: ModelPreferencesStore
    private let fileManager: FileManager

    init(
        sdkCacheDirectory: URL? = nil,
        preferences: ModelPreferencesStore,
        fileManager: FileManager = .default
    ) {
        self.sdkCacheDirectory = sdkCacheDirectory ?? Self.defaultSDKCacheDirectory()
        self.preferences = preferences
        self.fileManager = fileManager
    }

    func refresh() {
        var models: [ASRModelInfo] = []

        if fileManager.fileExists(atPath: sdkCacheDirectory.path) {
            let urls = (try? fileManager.contentsOfDirectory(
                at: sdkCacheDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard FluidAudioModelValidator.isValidModelDirectory(url, fileManager: fileManager) else { continue }
                let displayName = url.lastPathComponent
                    .replacingOccurrences(of: "-", with: " ")
                    .capitalized
                models.append(ASRModelInfo(id: url.path, displayName: displayName, url: url, sizeBytes: 0))
            }
        }

        availableModels = models
        provisioningState = models.isEmpty ? .notInstalled : .ready

        if let savedID = preferences.selectedFluidModelID,
           let match = models.first(where: { $0.id == savedID }) {
            selectedModel = match
        } else if let first = models.first {
            selectedModel = first
            preferences.selectedFluidModelID = first.id
        } else {
            selectedModel = nil
        }
    }

    func selectModel(_ id: String) {
        if let match = availableModels.first(where: { $0.id == id }) {
            selectedModel = match
            preferences.selectedFluidModelID = id
        }
    }

    func resolveModelURL() throws -> URL {
        guard let model = selectedModel else {
            throw ASRModelResolutionError.downloadRequired(backend: .fluidAudio)
        }
        guard FluidAudioModelValidator.isValidModelDirectory(model.url, fileManager: fileManager) else {
            throw ASRModelResolutionError.downloadRequired(backend: .fluidAudio)
        }
        return model.url
    }

    func downloadModel() async throws {
        provisioningState = .downloading(progress: 0)
        do {
#if arch(arm64) && canImport(FluidAudio)
            _ = try await AsrModels.downloadAndLoad(version: .v3)
#else
            throw ASRModelResolutionError.noModelInstalled(backend: .fluidAudio)
#endif
            provisioningState = .ready
            refresh()
        } catch {
            provisioningState = .error(error.localizedDescription)
            throw error
        }
    }

    private static func defaultSDKCacheDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }
}
```

**Step 4: Add `selectedFluidModelID` to ModelPreferencesStore**

In `Recordly/Infrastructure/Models/ModelPreferencesStore.swift`, add to Keys:
```swift
static let selectedFluidModelID = "model.selectedFluidModelID"
```

Add property:
```swift
var selectedFluidModelID: String? {
    get { defaults.string(forKey: Keys.selectedFluidModelID) }
    set { defaults.set(newValue, forKey: Keys.selectedFluidModelID) }
}
```

**Step 5: Run tests to verify they pass**

Run: test command with `-only-testing:RecordlyTests/FluidAudioModelProviderTests`
Expected: 6 tests PASS

**Step 6: Commit**

```
feat(asr): implement FluidAudioModelProvider with SDK-managed download
```

---

## Task 4: Create ASRModelProviderFactory and wire into ModelManager

**Files:**
- Create: `Recordly/Infrastructure/Inference/ASRModelProvider/ASRModelProviderFactory.swift`
- Modify: `Recordly/Infrastructure/Models/ModelManager.swift`
- Test: `RecordlyTests/ASRModelProviderTests.swift` (append)

**Step 1: Write failing tests**

Append to `RecordlyTests/ASRModelProviderTests.swift`:

```swift
final class ASRModelProviderFactoryTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: "ASRModelProviderFactoryTests-\(UUID().uuidString)")!
    }

    @MainActor
    func testFactoryReturnsCorrectProviderForBackend() {
        let preferences = ModelPreferencesStore(defaults: defaults)
        let factory = ASRModelProviderFactory(preferences: preferences)

        let whisper = factory.provider(for: .whisperCpp)
        XCTAssertEqual(whisper.backend, .whisperCpp)

        let fluid = factory.provider(for: .fluidAudio)
        XCTAssertEqual(fluid.backend, .fluidAudio)
    }

    @MainActor
    func testFactoryReturnsSameInstanceForSameBackend() {
        let preferences = ModelPreferencesStore(defaults: defaults)
        let factory = ASRModelProviderFactory(preferences: preferences)

        let a = factory.provider(for: .fluidAudio)
        let b = factory.provider(for: .fluidAudio)
        XCTAssertTrue(a === b)
    }
}
```

**Step 2: Implement ASRModelProviderFactory**

```swift
// Recordly/Infrastructure/Inference/ASRModelProvider/ASRModelProviderFactory.swift
import Foundation

@MainActor
final class ASRModelProviderFactory {
    private let preferences: ModelPreferencesStore
    private let discoveryPaths: ModelDiscoveryPaths
    private var cached: [ASRBackend: ASRModelProvider] = [:]

    init(
        preferences: ModelPreferencesStore,
        discoveryPaths: ModelDiscoveryPaths = .live()
    ) {
        self.preferences = preferences
        self.discoveryPaths = discoveryPaths
    }

    func provider(for backend: ASRBackend) -> ASRModelProvider {
        if let existing = cached[backend] { return existing }
        let provider: ASRModelProvider
        switch backend {
        case .whisperCpp:
            provider = LocalFileASRModelProvider(
                scanDirectories: whisperScanDirectories(),
                preferences: preferences
            )
        case .fluidAudio:
            provider = FluidAudioModelProvider(preferences: preferences)
        }
        cached[backend] = provider
        return provider
    }

    func activeProvider(for backend: ASRBackend) -> ASRModelProvider {
        let p = provider(for: backend)
        p.refresh()
        return p
    }

    private func whisperScanDirectories() -> [URL] {
        var dirs: [URL] = []
        if let appSupport = discoveryPaths.appSupportDirectory(.asr) { dirs.append(appSupport) }
        if let shared = discoveryPaths.sharedDirectory(.asr) { dirs.append(shared) }
        if let user = discoveryPaths.userDirectory(.asr) { dirs.append(user) }
        dirs.append(contentsOf: discoveryPaths.projectDirectories())
        return dirs
    }
}
```

**Step 3: Add `asrModelProviderFactory` to ModelManager**

In `Recordly/Infrastructure/Models/ModelManager.swift`, add a property after the `discoveryPaths` property:

```swift
private(set) lazy var asrModelProviderFactory: ASRModelProviderFactory = ASRModelProviderFactory(
    preferences: preferences,
    discoveryPaths: discoveryPaths
)
```

And add a convenience accessor:

```swift
func asrModelProvider(for backend: ASRBackend? = nil) -> ASRModelProvider {
    let b = backend ?? selectedASRBackend
    return asrModelProviderFactory.activeProvider(for: b)
}
```

**Step 4: Run tests**

Run: test command with `-only-testing:RecordlyTests/ASRModelProviderFactoryTests`
Expected: 2 tests PASS

**Step 5: Commit**

```
feat(asr): add ASRModelProviderFactory and wire into ModelManager
```

---

## Task 5: Refactor RuntimeProfileSelector to use ASRModelProvider

**Files:**
- Modify: `Recordly/Infrastructure/Inference/Runtime/DefaultInferenceRuntimeProfileSelector.swift`
- Modify: `Recordly/Infrastructure/Inference/Composition/DefaultInferenceComposition.swift`
- Modify: `RecordlyTests/DefaultInferenceRuntimeProfileSelectorTests.swift`

**Step 1: Update DefaultInferenceRuntimeProfileSelector**

Replace the current `resolveTranscriptionProfile` and `validateASRSelection` with provider-based resolution.

Change the init to accept an `ASRModelProvider`:

```swift
@MainActor
final class DefaultInferenceRuntimeProfileSelector: InferenceRuntimeProfileSelecting {
    private let modelManager: ModelManager
    private let stageSelection: StageRuntimeSelection

    init(
        modelManager: ModelManager,
        stageSelection: StageRuntimeSelection = .defaultLocal
    ) {
        self.modelManager = modelManager
        self.stageSelection = stageSelection
    }

    func resolveTranscriptionProfile(for profile: ModelProfile) throws -> InferenceRuntimeProfile {
        let selectedASRBackend = modelManager.selectedASRBackend
        let provider = modelManager.asrModelProvider(for: selectedASRBackend)
        let asrModelURL = try provider.resolveModelURL()

        let diarizationOption = modelManager.selectedLocalOption(kind: .diarization)
        var resolvedStageSelection = stageSelection
        resolvedStageSelection.setBackend(inferenceBackend(for: selectedASRBackend), for: .asr)
        let asrLanguage: ASRLanguage = selectedASRBackend == .fluidAudio ? .auto : modelManager.selectedASRLanguage

        return InferenceRuntimeProfile(
            stageSelection: resolvedStageSelection,
            modelArtifacts: InferenceModelArtifacts(
                asrModelURL: asrModelURL,
                diarizationModelURL: diarizationOption?.url,
                summarizationModelURL: nil
            ),
            asrLanguage: asrLanguage,
            summarizationRuntimeSettings: modelManager.summarizationRuntimeSettings
        )
    }
    // ... rest unchanged (resolveSummarizationProfile, inferenceBackend)
}
```

Remove the `validateASRSelection` method entirely — the provider handles validation.

**Step 2: Update error handling in RecordingWorkflowController**

In `RecordingWorkflowController.performTranscription()` (around line 477), add catch for `ASRModelResolutionError`:

```swift
} catch let error as ASRModelResolutionError {
    throw RecordingWorkflowError.transcriptionUnavailable(.unavailable(reason: error.localizedDescription))
}
```

**Step 3: Update DefaultInferenceComposition.make()**

No changes needed — it already creates `DefaultInferenceRuntimeProfileSelector(modelManager:, stageSelection:)` which now internally uses the provider.

**Step 4: Update existing tests**

Update `DefaultInferenceRuntimeProfileSelectorTests` to set up models through the provider factory. The test's `makeModelManager` helper creates a `ModelManager` with custom `ModelDiscoveryPaths`. Since `ModelManager` now has `asrModelProviderFactory` as a lazy property derived from its own `preferences` and `discoveryPaths`, the existing tests should still pass — the provider factory will scan the same directories the tests already set up.

Run the existing selector tests first to see which pass/fail, then adjust.

**Step 5: Run all selector tests**

Run: test command with `-only-testing:RecordlyTests/DefaultInferenceRuntimeProfileSelectorTests`
Expected: 6 tests PASS

**Step 6: Commit**

```
refactor(asr): runtime profile selector uses ASRModelProvider for model resolution
```

---

## Task 6: Refactor ModelSettingsViewModel for backend-specific state

**Files:**
- Modify: `Recordly/Features/Settings/Models/ModelSettingsViewModel.swift`

**Step 1: Rewrite ModelSettingsViewModel to expose provider state**

Replace the current ASR model handling with provider-delegated state:

```swift
import Foundation

#if arch(arm64) && canImport(FluidAudio)
import FluidAudio
#endif

@MainActor
final class ModelSettingsViewModel: ObservableObject {
    // Backend selection
    @Published var selectedASRBackend: ASRBackend = .fluidAudio

    // WhisperCpp state (from LocalFileASRModelProvider)
    @Published private(set) var whisperModels: [ASRModelInfo] = []
    @Published var selectedWhisperModelID: String?

    // FluidAudio state (from FluidAudioModelProvider)
    @Published private(set) var fluidModels: [ASRModelInfo] = []
    @Published var selectedFluidModelID: String?
    @Published private(set) var fluidProvisioningState: ASRModelProvisioningState = .notInstalled

    // Language
    @Published var selectedASRLanguage: ASRLanguage = .ru

    // Other stages (unchanged)
    @Published private(set) var diarizationModels: [LocalModelOption] = []
    @Published private(set) var summarizationModels: [LocalModelOption] = []
    @Published var selectedDiarizationModelID: String?
    @Published var selectedSummarizationModelID: String?

    private let modelManager: ModelManager

    init(modelManager: ModelManager) {
        self.modelManager = modelManager
        refresh()
    }

    func refresh() {
        selectedASRBackend = modelManager.selectedASRBackend

        // Refresh WhisperCpp provider
        let whisperProvider = modelManager.asrModelProvider(for: .whisperCpp)
        whisperModels = whisperProvider.availableModels
        selectedWhisperModelID = whisperProvider.selectedModel?.id

        // Refresh FluidAudio provider
        let fluidProvider = modelManager.asrModelProvider(for: .fluidAudio)
        fluidModels = fluidProvider.availableModels
        selectedFluidModelID = fluidProvider.selectedModel?.id
        fluidProvisioningState = fluidProvider.provisioningState

        // Language
        selectedASRLanguage = modelManager.selectedASRLanguage

        // Other stages
        diarizationModels = modelManager.listLocalOptions(kind: .diarization)
        summarizationModels = modelManager.listLocalOptions(kind: .summarization)
        selectedDiarizationModelID = modelManager.selectedLocalOption(kind: .diarization)?.id
        selectedSummarizationModelID = modelManager.selectedLocalOption(kind: .summarization)?.id
    }

    var isASRLanguageEditable: Bool {
        selectedASRBackend == .whisperCpp
    }

    func selectASRBackend(_ backend: ASRBackend) {
        modelManager.selectedASRBackend = backend
        refresh()
    }

    func selectWhisperModel(_ id: String?) {
        guard let id else { return }
        modelManager.asrModelProvider(for: .whisperCpp).selectModel(id)
        refresh()
    }

    func selectFluidModel(_ id: String?) {
        guard let id else { return }
        modelManager.asrModelProvider(for: .fluidAudio).selectModel(id)
        refresh()
    }

    func selectASRLanguage(_ language: ASRLanguage) {
        modelManager.selectedASRLanguage = language
        refresh()
    }

    func downloadFluidAudioModel() {
        guard let provider = modelManager.asrModelProvider(for: .fluidAudio) as? FluidAudioModelProvider else { return }
        fluidProvisioningState = .downloading(progress: 0)
        Task {
            do {
                try await provider.downloadModel()
                refresh()
            } catch {
                fluidProvisioningState = .error(error.localizedDescription)
            }
        }
    }

    var isDownloadingFluid: Bool {
        if case .downloading = fluidProvisioningState { return true }
        return false
    }

    var fluidDownloadError: String? {
        if case .error(let msg) = fluidProvisioningState { return msg }
        return nil
    }

    // Unchanged: diarization/summarization
    func selectDiarizationModel(_ modelID: String?) {
        modelManager.setSelectedModelID(modelID, for: .diarization)
        refresh()
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

    func fluidModelLabel(for model: ASRModelInfo) -> String {
        return model.displayName
    }
}
```

**Step 2: Build and verify compilation**

Run: full build
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```
refactor(settings): ModelSettingsViewModel uses backend-specific providers
```

---

## Task 7: Rewrite ModelSettingsView with backend-split ASR sections

**Files:**
- Modify: `Recordly/Features/Settings/Models/ModelSettingsView.swift`

**Step 1: Replace the single ASR model picker with backend-specific sections**

Replace the `modelPickerCard` call for ASR (lines 54-64) and the FluidAudio download button logic with two distinct sections:

```swift
// After the backend picker card, replace the Transcription Model picker with:

if viewModel.selectedASRBackend == .whisperCpp {
    whisperModelSection
} else {
    fluidAudioModelSection
}
```

Add two computed properties to the view:

```swift
private var whisperModelSection: some View {
    VStack(alignment: .leading, spacing: 10) {
        Text("Transcription Model")
            .font(.headline)
        Text("Select a local WhisperCpp .bin model file.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Picker("Transcription Model", selection: Binding(
            get: { viewModel.selectedWhisperModelID },
            set: { viewModel.selectWhisperModel($0) }
        )) {
            ForEach(viewModel.whisperModels) { model in
                Text(model.displayName).tag(String?.some(model.id))
            }
        }
        .pickerStyle(.menu)

        if viewModel.whisperModels.isEmpty {
            Text("No .bin model files found. Place WhisperCpp models in ~/models/asr/ or the project Models/ folder.")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let selected = viewModel.whisperModels.first(where: { $0.id == viewModel.selectedWhisperModelID }) {
            Text("Selected: \(selected.url.lastPathComponent)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    .padding(14)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
}

private var fluidAudioModelSection: some View {
    VStack(alignment: .leading, spacing: 10) {
        Text("FluidAudio Model")
            .font(.headline)
        Text("FluidAudio models are downloaded and managed by the SDK.")
            .font(.caption)
            .foregroundStyle(.secondary)

        switch viewModel.fluidProvisioningState {
        case .ready:
            if viewModel.fluidModels.count > 1 {
                Picker("FluidAudio Model", selection: Binding(
                    get: { viewModel.selectedFluidModelID },
                    set: { viewModel.selectFluidModel($0) }
                )) {
                    ForEach(viewModel.fluidModels) { model in
                        Text(model.displayName).tag(String?.some(model.id))
                    }
                }
                .pickerStyle(.menu)
            }

            if let selected = viewModel.fluidModels.first(where: { $0.id == viewModel.selectedFluidModelID }) {
                Label(selected.displayName, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

        case .notInstalled:
            Text("No FluidAudio model installed.")
                .font(.caption)
                .foregroundStyle(.orange)
            Button("Download FluidAudio v3 Model") {
                viewModel.downloadFluidAudioModel()
            }
            .buttonStyle(.borderedProminent)

        case .downloading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading FluidAudio model...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .error(let message):
            Text("Download failed: \(message)")
                .font(.caption)
                .foregroundStyle(.red)
            Button("Retry Download") {
                viewModel.downloadFluidAudioModel()
            }
            .buttonStyle(.bordered)
        }
    }
    .padding(14)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
}
```

**Step 2: Build and verify**

Run: full build
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```
feat(settings): split ASR model section by backend — file picker vs SDK download
```

---

## Task 8: Update TranscriptionAvailability to use provider

**Files:**
- Modify: `Recordly/Infrastructure/Models/ModelManager.swift` — `availability(for:)` method

**Step 1: Update availability check**

Change the `availability(for:)` method to use the active provider:

```swift
func availability(for profile: ModelProfile) -> TranscriptionAvailability {
    let provider = asrModelProvider()
    guard (try? provider.resolveModelURL()) != nil else {
        return .requiresASRModel(profileOptions: ModelProfile.allCases)
    }

    if selectedLocalOption(kind: .diarization) == nil {
        return .degradedNoDiarization
    }

    return .ready
}
```

**Step 2: Run full test suite**

Run: full test command (all tests)
Expected: All tests PASS (some existing tests may need minor adjustment if they relied on the old `selectedLocalOption(kind: .asr)` path for availability checks)

**Step 3: Commit**

```
refactor(asr): ModelManager.availability uses ASRModelProvider
```

---

## Task 9: Clean up old model-selection code paths for ASR

**Files:**
- Modify: `Recordly/Infrastructure/Models/ModelManager.swift`
- Modify: `Recordly/Features/Settings/Models/ModelSettingsViewModel.swift`

**Step 1: Remove dead ASR selection from old generic path**

The old `selectedLocalOption(kind: .asr)` and `setSelectedModelID(_, for: .asr)` are now only needed by the `availability` and `ensureRequiredModelsInstalled` methods. Update `ensureRequiredModelsInstalled` to use the provider:

```swift
func ensureRequiredModelsInstalled(for profile: ModelProfile) throws -> RequiredModelsResolution {
    let provider = asrModelProvider()
    let asrModelURL = try provider.resolveModelURL()
    let diarization = selectedLocalOption(kind: .diarization)
    return RequiredModelsResolution(asrModelURL: asrModelURL, diarizationModelURL: diarization?.url)
}
```

**Step 2: Remove `isModelCompatible`, `canDownloadFluidModel` from ViewModel**

These were temporary hacks from the previous session — the provider abstraction replaces them.

**Step 3: Run full test suite**

Run: full test command
Expected: All PASS

**Step 4: Commit**

```
refactor(asr): remove old generic ASR selection in favor of provider
```

---

## Task 10: End-to-end verification

**Step 1: Build and run the app**

Run: `open Recordly.xcodeproj` or Cmd+R from Xcode

**Step 2: Verify WhisperCpp path**

1. Open Settings → Models
2. Select WhisperCpp backend
3. Verify local .bin models appear in picker (podlodka, asr-balanced, etc.)
4. Select a model
5. Record a short session → verify transcript artifacts produced

**Step 3: Verify FluidAudio path**

1. Switch to FluidAudio backend
2. Verify "No FluidAudio model installed" message appears
3. Click "Download FluidAudio v3 Model"
4. Wait for download to complete
5. Verify model appears with green checkmark
6. Record a short session → verify these artifacts are created:
   - `mic.asr.json`
   - `system.asr.json`
   - `transcript.json`
   - `transcript.txt`
   - `transcript.srt`

**Step 4: Verify backend switching**

1. Switch between WhisperCpp and FluidAudio
2. Each should show its own model state independently
3. Selections should persist across app restarts

**Step 5: Final commit**

```
test(asr): verify end-to-end transcription with both backends
```

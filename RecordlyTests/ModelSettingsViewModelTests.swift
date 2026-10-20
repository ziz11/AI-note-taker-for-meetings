import XCTest
import Combine
import AppKit
import SwiftUI
@testable import Recordly

@MainActor
final class ModelSettingsViewModelTests: XCTestCase {
    private var tempDirectory: URL!
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ModelSettingsViewModelTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defaultsSuiteName = "ModelSettingsViewModelTests.\(UUID().uuidString)"
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

    func testRefreshBuildsASRCatalogAndPreservesDisabledSummaryPreferences() throws {
        let asrDirectory = tempDirectory.appendingPathComponent("asr", isDirectory: true)
        let summarizationDirectory = tempDirectory.appendingPathComponent("summarization", isDirectory: true)
        try FileManager.default.createDirectory(at: asrDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: summarizationDirectory, withIntermediateDirectories: true)

        try Data("asr".utf8).write(to: asrDirectory.appendingPathComponent("podlodka-turbo-v1.bin"))
        try Data("summary".utf8).write(to: summarizationDirectory.appendingPathComponent("meeting-summary.gguf"))

        let manager = makeModelManager(
            asrDirectory: asrDirectory,
            summarizationDirectory: summarizationDirectory
        )
        let selectedSummarization = try XCTUnwrap(manager.listLocalOptions(kind: .summarization).first)
        manager.setSelectedModelID(selectedSummarization.id, for: .summarization)

        let viewModel = ModelSettingsViewModel(
            modelManager: manager,
            fluidAudioModelProvider: StubFluidAudioASRModelProvider(state: .ready),
            fluidAudioDiarizationModelProvider: StubFluidAudioDiarizationModelProvider(state: .failed(message: "offline prepare failed"))
        )

        viewModel.refresh()

        XCTAssertEqual(viewModel.fluidProvisioningState, .ready)
        XCTAssertEqual(viewModel.fluidDiarizationProvisioningState, .failed(message: "offline prepare failed"))
        XCTAssertEqual(viewModel.localASRModels.count, 1)
        XCTAssertEqual(viewModel.localASRModels.first?.sourceLabel, "User")
        XCTAssertFalse(viewModel.localASRModels.first?.supportsSelection ?? true)
        XCTAssertEqual(manager.selectedSummarizationModelID, selectedSummarization.id)
    }

    func testDownloadFluidDiarizationModelUpdatesProvisioningState() async {
        let provider = StubFluidAudioDiarizationModelProvider(state: .needsDownload)
        let viewModel = ModelSettingsViewModel(
            modelManager: makeModelManager(asrDirectory: nil, summarizationDirectory: nil),
            fluidAudioModelProvider: StubFluidAudioASRModelProvider(state: .needsDownload),
            fluidAudioDiarizationModelProvider: provider
        )

        viewModel.downloadFluidDiarizationModel()
        await Task.yield()

        XCTAssertEqual(provider.downloadCallCount, 1)
        XCTAssertEqual(viewModel.fluidDiarizationProvisioningState, .ready)
        XCTAssertTrue(viewModel.isFluidDiarizationModelReady)
    }

    func testDiarizationDownloadShowsBusyStateUntilCompletionAndIgnoresRepeatedClicks() async {
        let provider = StubFluidAudioDiarizationModelProvider(state: .needsDownload)
        let started = expectation(description: "Download started")
        let finished = expectation(description: "Download state published")
        var completions: [CheckedContinuation<Void, Never>] = []
        provider.beforeCompletion = {
            await withCheckedContinuation { continuation in
                completions.append(continuation)
                if completions.count == 1 { started.fulfill() }
            }
        }
        let vm = ModelSettingsViewModel(
            modelManager: makeModelManager(asrDirectory: nil, summarizationDirectory: nil),
            fluidAudioModelProvider: StubFluidAudioASRModelProvider(state: .ready),
            fluidAudioDiarizationModelProvider: provider)
        let observation = vm.$fluidDiarizationProvisioningState.filter { $0 == .ready }.prefix(1).sink { _ in finished.fulfill() }
        defer { observation.cancel() }
        vm.downloadFluidDiarizationModel()
        XCTAssertEqual(vm.fluidDiarizationProvisioningState, .downloading)
        XCTAssertFalse(vm.canDownloadFluidDiarizationModel)
        await fulfillment(of: [started], timeout: 2)
        vm.downloadFluidDiarizationModel()
        await Task.yield()
        XCTAssertEqual(provider.downloadCallCount, 1)
        for completion in completions { completion.resume() }
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(vm.isFluidDiarizationModelReady)
    }

    func testModelRemovalIsBlockedWhileWorkflowHasPendingJobs() throws {
        let provider = FluidAudioASRModelProvider(modelsRoot: { self.tempDirectory }, defaults: defaults)
        for model in FluidAudioASRModel.allCases { try writeModel(model) }
        provider.refreshState()
        let vm = ModelSettingsViewModel(
            modelManager: makeModelManager(asrDirectory: nil, summarizationDirectory: nil),
            fluidAudioModelProvider: provider,
            fluidAudioDiarizationModelProvider: StubFluidAudioDiarizationModelProvider(state: .ready))
        vm.refresh()
        XCTAssertEqual(vm.speechModels.count, 2)
        vm.canRemoveModels = { false }
        vm.selectSpeechModel(.v3)
        XCTAssertEqual(provider.selectedModel, .v3)
        vm.removeSpeechModel(.ultra)
        XCTAssertNotNil(vm.modelActionError)
        XCTAssertEqual(provider.state(for: .ultra), .ready)
        vm.canRemoveModels = { true }
        vm.removeSpeechModel(.ultra)
        XCTAssertNil(vm.modelActionError)
        XCTAssertEqual(vm.speechModels.first?.state, .needsDownload)
    }

    func testRenderModelPickerForReview() throws {
        guard let output = ProcessInfo.processInfo.environment["RECORDLY_MODEL_PICKER_RENDER"] else {
            throw XCTSkip("Opt-in SwiftUI visual review artifact")
        }
        for model in FluidAudioASRModel.allCases { try writeModel(model) }
        let provider = FluidAudioASRModelProvider(modelsRoot: { self.tempDirectory }, defaults: defaults)
        let vm = ModelSettingsViewModel(
            modelManager: makeModelManager(asrDirectory: nil, summarizationDirectory: nil),
            fluidAudioModelProvider: provider,
            fluidAudioDiarizationModelProvider: StubFluidAudioDiarizationModelProvider(state: .ready))
        vm.refresh()
        let outputURL = URL(fileURLWithPath: output)
        let variant = ProcessInfo.processInfo.environment["RECORDLY_MODEL_PICKER_VARIANT"]
        if variant == nil {
            try render(vm, to: outputURL)
            try render(vm, scheme: .light, to: variantURL(outputURL, "light"))
            let store = RecordingsStore(previewMode: true)
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .light ? "light" : "dark"
                try renderView(ModelOnboardingView { _ in }, scheme: scheme,
                               to: variantURL(outputURL, "welcome-" + suffix))
                if let recording = store.recordings.first {
                    try renderView(RecordingDetailView(recording: recording)
                        .environmentObject(store).frame(width: 800, height: 900),
                        scheme: scheme, to: variantURL(outputURL, "recording-" + suffix))
                }
            }

        }
        let states: [(String, FluidAudioModelProvisioningState, FluidAudioModelProvisioningState)] = [
            ("missing", .needsDownload, .needsDownload),
            ("downloading", .downloading, .downloading),
            ("failed", .failed(message: "Could not download Encoder.mlmodelc. Check your connection and try again."),
                       .failed(message: "Speaker models could not be downloaded. Please try again."))
        ]
        for (name, asrState, diarizationState) in states where variant == nil || variant == name {
            let stub = StubFluidAudioASRModelProvider(state: asrState)
            if name == "downloading" {
                stub.downloadProgress = .init(fraction: 0.42, detail: "Encoder.mlmodelc · 42%")
            }
            let stateVM = ModelSettingsViewModel(
                modelManager: makeModelManager(asrDirectory: nil, summarizationDirectory: nil),
                fluidAudioModelProvider: stub,
                fluidAudioDiarizationModelProvider: StubFluidAudioDiarizationModelProvider(state: diarizationState))
            stateVM.refresh()
            try render(stateVM, to: variantURL(outputURL, name))
            if name == "downloading" {
                stub.downloadProgress = nil
                stateVM.refresh()
                try render(stateVM, to: variantURL(outputURL, "preparing"))
            }
        }
    }

    private func variantURL(_ output: URL, _ name: String) -> URL {
        output.deletingPathExtension().appendingPathExtension(name + ".png")
    }

    private func render(_ viewModel: ModelSettingsViewModel,
                        scheme: ColorScheme = .dark, to output: URL) throws {
        try renderView(ModelSettingsView(viewModel: viewModel), scheme: scheme, to: output)
    }

    private func renderView<Content: View>(_ content: Content,
                                           scheme: ColorScheme, to output: URL) throws {
        let host = NSHostingView(rootView: content.environment(\.colorScheme, scheme))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = window.contentView!.bounds
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output)
    }

    private func writeModel(_ model: FluidAudioASRModel) throws {
        let root = tempDirectory.appendingPathComponent(model.cacheFolder)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for marker in FluidAudioModelValidator.requiredMarkers {
            let url = root.appendingPathComponent(marker)
            if marker.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try Data([1]).write(to: url.appendingPathComponent("coremldata.bin"))
            } else { try Data("{}".utf8).write(to: url) }
        }
    }

    private func makeModelManager(
        asrDirectory: URL?,
        summarizationDirectory: URL?
    ) -> ModelManager {
        ModelManager(
            preferences: ModelPreferencesStore(defaults: defaults),
            discoveryPaths: ModelDiscoveryPaths(
                appSupportDirectory: { _ in nil },
                sharedDirectory: { _ in nil },
                userDirectory: { kind in
                    switch kind {
                    case .asr:
                        return asrDirectory
                    case .summarization:
                        return summarizationDirectory
                    case .diarization:
                        return nil
                    }
                },
                projectDirectories: { [] }
            )
        )
    }
}

private final class StubFluidAudioASRModelProvider: FluidAudioASRModelProviding {
    private(set) var state: FluidAudioModelProvisioningState
    var downloadProgress: FluidAudioModelDownloadProgress?

    func progress(for model: FluidAudioASRModel) -> FluidAudioModelDownloadProgress? {
        model == selectedModel ? downloadProgress : nil
    }

    init(state: FluidAudioModelProvisioningState) {
        self.state = state
    }

    func refreshState() {}
    func downloadDefaultModel() async {
        state = .ready
    }

    func resolveForRuntime() throws -> URL {
        throw FluidAudioModelProvisioningError.noModelProvisioned
    }
}

private final class StubFluidAudioDiarizationModelProvider: FluidAudioDiarizationModelProviding {
    private(set) var state: FluidAudioModelProvisioningState
    private(set) var downloadCallCount = 0
    var beforeCompletion: (() async -> Void)?

    init(state: FluidAudioModelProvisioningState) {
        self.state = state
    }

    func refreshState() {}

    func downloadDefaultModel() async {
        downloadCallCount += 1
        state = .downloading
        await beforeCompletion?()
        state = .ready
    }

    func resolveForRuntime() throws -> any OfflineDiarizationManaging {
        throw FluidAudioModelProvisioningError.noModelProvisioned
    }
}

import XCTest
@testable import Recordly

#if arch(arm64) && canImport(FluidAudio)
import FluidAudio
#endif

@MainActor
final class DefaultInferenceEngineFactoryTests: XCTestCase {
    func testFactoryBuildsExpectedEnginesForDefaultLocalProfile() throws {
        let factory = DefaultInferenceEngineFactory(
            diarizationModelProvider: StubFluidAudioDiarizationModelProvider()
        )
        let profile = InferenceRuntimeProfile(
            stageSelection: .defaultLocal,
            modelArtifacts: InferenceModelArtifacts(
                asrModelURL: URL(fileURLWithPath: "/tmp/asr-fluid"),
                diarizationModelURL: URL(fileURLWithPath: "/tmp/diarization.bin"),
                summarizationModelURL: URL(fileURLWithPath: "/tmp/summary.gguf")
            ),
            summarizationRuntimeSettings: .default
        )

        let asrEngine = try factory.makeASREngine(for: profile)
        let systemChunkEngine = try XCTUnwrap(factory.makeSystemChunkTranscriptionEngine(for: profile))
        let diarizationEngine = try factory.makeDiarizationEngine(for: profile)
        let summarizationEngine = try factory.makeSummarizationEngine(for: profile)

        XCTAssertEqual(String(describing: type(of: asrEngine)), "FluidAudioASREngine")
        XCTAssertEqual(String(describing: type(of: systemChunkEngine)), "FluidAudioSystemChunkTranscriptionEngine")
        XCTAssertEqual(String(describing: type(of: diarizationEngine)), "FluidAudioDiarizationEngine")
        XCTAssertEqual(String(describing: type(of: summarizationEngine)), "LlamaCppSummarizationEngine")
    }

    func testFactoryThrowsWhenBackendNotSupportedForStage() {
        let factory = DefaultInferenceEngineFactory(
            diarizationModelProvider: StubFluidAudioDiarizationModelProvider()
        )
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

    func testFactoryBuildsFluidAudioEngineWhenASRBackendIsFluidAudio() throws {
        let factory = DefaultInferenceEngineFactory(
            diarizationModelProvider: StubFluidAudioDiarizationModelProvider()
        )
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

    func testSDKDiarizationEngineRunsEndToEnd() async throws {
#if arch(arm64) && canImport(FluidAudio)
        let provider = FluidAudioDiarizationModelProvider()
        provider.refreshState()
        if provider.state != .ready {
            await provider.downloadDefaultModel()
        }

        guard provider.state == .ready else {
            throw XCTSkip("FluidAudio diarization model is not ready: \(provider.state)")
        }

        let systemAudioURL = try makeSynthesizedSpeechCAF()
        let factory = DefaultInferenceEngineFactory(diarizationModelProvider: provider)
        let profile = InferenceRuntimeProfile(
            stageSelection: .defaultLocal,
            modelArtifacts: .empty,
            summarizationRuntimeSettings: .default
        )

        let engine = try factory.makeDiarizationEngine(for: profile)
        let document = try await engine.diarize(
            systemAudioURL: systemAudioURL,
            sessionID: UUID(),
            configuration: DiarizationEngineConfiguration(modelURL: nil)
        )

        XCTAssertFalse(document.segments.isEmpty)
#else
        throw XCTSkip("FluidAudio SDK diarization requires arm64 macOS.")
#endif
    }

    func testFluidAudioDiarizationEngineThrowsBinaryMissingWhenSDKUnavailable() async throws {
#if arch(arm64) && canImport(FluidAudio)
        throw XCTSkip("This regression only covers the non-FluidAudio runtime path.")
#else
        let systemAudioURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "system.raw.caf"
        )
        let engine = FluidAudioDiarizationEngine(
            manager: StubOfflineDiarizationManager(),
            sessionAudioLoader: StubFluidAudioSessionAudioLoader()
        )

        do {
            _ = try await engine.diarize(
                systemAudioURL: systemAudioURL,
                sessionID: UUID(),
                configuration: DiarizationEngineConfiguration(modelURL: nil)
            )
            XCTFail("Expected binaryMissing on non-FluidAudio runtimes")
        } catch {
            XCTAssertEqual(error as? DiarizationRuntimeError, .binaryMissing)
        }
#endif
    }

    func testFluidAudioDiarizationEngineMapsSDKOutputToDocument() async throws {
#if arch(arm64) && canImport(FluidAudio)
        let systemAudioURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "system.raw.caf"
        )
        FileManager.default.createFile(atPath: systemAudioURL.path, contents: Data("caf".utf8))
        defer { try? FileManager.default.removeItem(at: systemAudioURL) }

        let manager = RecordingOfflineDiarizationManager(
            result: OfflineDiarizationResult(
                segments: [
                    OfflineDiarizationSegment(
                        speakerId: "Speaker 1",
                        startTimeSeconds: 1.25,
                        endTimeSeconds: 2.75,
                        qualityScore: 0.9
                    )
                ]
            )
        )
        let loader = StubFluidAudioSessionAudioLoader(
            preparedAudio: PreparedSessionAudio(
                samples: [0.0, 0.2, -0.1, 0.3],
                sampleRate: 16_000,
                durationMs: 250,
                sourceURL: systemAudioURL
            )
        )
        let engine = FluidAudioDiarizationEngine(
            manager: manager,
            sessionAudioLoader: loader
        )

        let document = try await engine.diarize(
            systemAudioURL: systemAudioURL,
            sessionID: UUID(),
            configuration: DiarizationEngineConfiguration(modelURL: nil)
        )

        XCTAssertEqual(loader.loadedURLs, [systemAudioURL])
        XCTAssertEqual(manager.processedAudio, [[0.0, 0.2, -0.1, 0.3]])
        XCTAssertEqual(document.segments.count, 1)
        XCTAssertEqual(document.segments[0].id, "dseg-1")
        XCTAssertEqual(document.segments[0].speaker, "Speaker 1")
        XCTAssertEqual(document.segments[0].startMs, 1250)
        XCTAssertEqual(document.segments[0].endMs, 2750)
        XCTAssertEqual(document.segments[0].confidence ?? 0, 0.9, accuracy: 0.0001)
#else
        throw XCTSkip("FluidAudio SDK diarization mapping requires arm64 macOS.")
#endif
    }

    private final class StubFluidAudioDiarizationModelProvider: FluidAudioDiarizationModelProviding {
        let state: FluidAudioModelProvisioningState = .ready

        func refreshState() {}
        func downloadDefaultModel() async {}
        func resolveForRuntime() throws -> any OfflineDiarizationManaging {
            StubOfflineDiarizationManager()
        }
    }

    private final class StubOfflineDiarizationManager: OfflineDiarizationManaging, @unchecked Sendable {
        func prepareModels() async throws {}

        func process(audio: [Float]) async throws -> OfflineDiarizationResult {
            OfflineDiarizationResult(segments: [])
        }
    }

    #if arch(arm64) && canImport(FluidAudio)
    private final class RecordingOfflineDiarizationManager: OfflineDiarizationManaging, @unchecked Sendable {
        let result: OfflineDiarizationResult
        private(set) var processedAudio: [[Float]] = []

        init(result: OfflineDiarizationResult) {
            self.result = result
        }

        func prepareModels() async throws {}

        func process(audio: [Float]) async throws -> OfflineDiarizationResult {
            processedAudio.append(audio)
            return result
        }
    }
    #endif

    private final class StubFluidAudioSessionAudioLoader: FluidAudioSessionAudioLoading {
        let preparedAudio: PreparedSessionAudio
        private(set) var loadedURLs: [URL] = []

        init(preparedAudio: PreparedSessionAudio = PreparedSessionAudio(
            samples: [0, 0, 0, 0],
            sampleRate: 16_000,
            durationMs: 1,
            sourceURL: URL(fileURLWithPath: "/tmp/system.raw.caf")
        )) {
            self.preparedAudio = preparedAudio
        }

        func loadAudio(from audioURL: URL) throws -> PreparedSessionAudio {
            loadedURLs.append(audioURL)
            return PreparedSessionAudio(
                samples: preparedAudio.samples,
                sampleRate: preparedAudio.sampleRate,
                durationMs: preparedAudio.durationMs,
                sourceURL: audioURL
            )
        }
    }

    private func makeSynthesizedSpeechCAF() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Recordly-Diarization-E2E-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let aiffURL = directory.appendingPathComponent("speech.aiff")
        let cafURL = directory.appendingPathComponent("system.raw.caf")
        try runProcess(
            executable: "/usr/bin/say",
            arguments: [
                "-v", "Samantha",
                "-o", aiffURL.path,
                "Hello this is a diarization integration test. The speaker keeps talking for long enough to produce segments."
            ]
        )
        try runProcess(
            executable: "/usr/bin/afconvert",
            arguments: [
                "-f", "caff",
                "-d", "LEI16@16000",
                "-c", "1",
                aiffURL.path,
                cafURL.path
            ]
        )
        return cafURL
    }

    private func runProcess(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "unknown"
            throw XCTSkip("Command failed: \(executable) \(arguments.joined(separator: " ")) :: \(message)")
        }
    }
}

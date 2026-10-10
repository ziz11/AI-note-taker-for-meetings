import CryptoKit
import XCTest
@testable import Recordly

#if arch(arm64) && canImport(FluidAudio)
import FluidAudio
#endif

/// Explicit opt-in acceptance against local audio. CI never needs user data or models.
@MainActor
final class NativeFluidAcceptanceTests: XCTestCase {
    func testCopiedRecordingWithNativeModelsAndCacheWarmRename() async throws {
#if arch(arm64) && canImport(FluidAudio)
        let environment = ProcessInfo.processInfo.environment
        guard let sourcePath = environment["RECORDLY_NATIVE_RECORDING_PATH"],
              let modelsPath = environment["RECORDLY_NATIVE_MODELS_ROOT"],
              let outputPath = environment["RECORDLY_NATIVE_FULL_OUTPUT"] else {
            throw XCTSkip("Set native recording, isolated models root and output paths to run local acceptance.")
        }
        let source = URL(fileURLWithPath: sourcePath, isDirectory: true).standardizedFileURL
        let requestedOutput = URL(fileURLWithPath: outputPath, isDirectory: true).standardizedFileURL
        let models = URL(fileURLWithPath: modelsPath, isDirectory: true)
        XCTAssertNotEqual(source, requestedOutput)
        guard source != requestedOutput, !requestedOutput.path.hasPrefix(source.path + "/"),
              !FileManager.default.fileExists(atPath: requestedOutput.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let sourceHashes = try audioHashes(in: source)
        try FileManager.default.copyItem(at: source, to: requestedOutput)
        // Foundation resolves existing /private/tmp files to /tmp but can retain
        // the alias for absent pending files. Use one canonical root for this fixture.
        let output = URL(fileURLWithPath: requestedOutput.resolvingSymlinksInPath().standardizedFileURL.path,
                         isDirectory: true)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let recording = try decoder.decode(RecordingSession.self,
            from: Data(contentsOf: output.appendingPathComponent("session.json")))
        // Fail before recovery can rewrite an incompatible acceptance fixture.
        let inputManifest = try SessionAudioStore(directory: output, sessionID: recording.id).load()
        XCTAssertFalse(inputManifest.segments.isEmpty)
        let adapter = FluidAudioOfflineDiarizationManagerAdapter(modelsRoot: models)
        try await adapter.prepareModels()
        let provider = FluidAudioDiarizationModelProvider(preparedManager: adapter, modelsRoot: { models })
        var stages = StageRuntimeSelection.defaultLocal
        stages.setBackend(.disabled, for: .summarization)
        let profile = InferenceRuntimeProfile(stageSelection: stages,
            modelArtifacts: .init(asrModelURL: models.appendingPathComponent(FluidAudioRuntimeIdentity.asrCacheFolder),
                diarizationModelURL: adapter.modelDirectoryURL, summarizationModelURL: nil),
            summarizationRuntimeSettings: .default)
        let factory = DefaultInferenceEngineFactory(diarizationModelProvider: provider)
        let savedLevel = AppLogger.minimumLevel
        let savedConsole = AppLogger.mirrorsToConsole
        AppLogger.minimumLevel = .error
        AppLogger.mirrorsToConsole = false
        defer { AppLogger.minimumLevel = savedLevel; AppLogger.mirrorsToConsole = savedConsole }
        let started = Date()
        let first = try await TranscriptionPipeline().process(recording: recording, in: output,
            runtimeProfile: profile, engineFactory: factory)
        let firstSeconds = Date().timeIntervalSince(started)
        XCTAssertEqual(first.state, .ready)
        let store = SessionSpeakerIdentityStore(directory: output, sessionID: recording.id)
        let identities = try store.load()
        let voiceIDs = Set((identities.voiceProfiles ?? [:]).keys)
        XCTAssertFalse(voiceIDs.isEmpty, "Native bounded windows must supply usable session voice evidence")
        let firstTranscript = try decoder.decode(TranscriptDocument.self,
            from: Data(contentsOf: output.appendingPathComponent("transcript.json")))
        if environment["RECORDLY_NATIVE_COMPARE_CACHED_WORDS"] == "1" {
            let baseline = try decoder.decode(TranscriptDocument.self,
                from: Data(contentsOf: source.appendingPathComponent("transcript.json")))
            func timedWords(_ document: TranscriptDocument) -> [String] {
                document.segments.flatMap { segment in (segment.words ?? []).map {
                    "\(segment.channel.rawValue)|\($0.startMs):\($0.endMs)|\($0.word)"
                } }.sorted()
            }
            XCTAssertEqual(timedWords(firstTranscript), timedWords(baseline), "Speaker splitting must preserve every cached token and its timing")
            let baselineVoiceIDs = Set(baseline.segments.compactMap(\.speakerId).filter { $0.hasPrefix("remote_voice_") })
            XCTAssertTrue(baselineVoiceIDs.isSubset(of: voiceIDs), "Existing session voice IDs must survive alignment changes")
        }
        let originalEvents = firstTranscript.segments.map { "\($0.id):\($0.speakerId ?? ""):\($0.startMs):\($0.endMs)" }
        let selectedID = try XCTUnwrap(firstTranscript.segments.compactMap(\.speakerId).first { voiceIDs.contains($0) })
        try store.rename(speakerID: selectedID, to: "Native acceptance speaker")
        let secondStarted = Date()
        let second = try await TranscriptionPipeline().process(recording: recording, in: output,
            runtimeProfile: profile, engineFactory: factory)
        let secondSeconds = Date().timeIntervalSince(secondStarted)
        XCTAssertEqual(second.state, .ready)
        let secondTranscript = try decoder.decode(TranscriptDocument.self,
            from: Data(contentsOf: output.appendingPathComponent("transcript.json")))
        XCTAssertEqual(secondTranscript.segments.map { "\($0.id):\($0.speakerId ?? ""):\($0.startMs):\($0.endMs)" }, originalEvents)
        XCTAssertEqual(try store.load().identities[selectedID]?.displayName, "Native acceptance speaker")
        XCTAssertTrue(secondTranscript.segments.filter { $0.speakerId == selectedID }.allSatisfy { $0.speaker == "Native acceptance speaker" })
        let report = try decoder.decode(SegmentedInferenceReport.self,
            from: Data(contentsOf: output.appendingPathComponent("inference/report.json")))
        XCTAssertGreaterThan(report.reusedASRWindows, 0)
        XCTAssertGreaterThan(report.reusedDiarizationWindows, 0)
        XCTAssertLessThanOrEqual(report.maximumMaterializedFrames, SessionAudioRangeReader.maximumFrames)
        XCTAssertEqual(try audioHashes(in: output), sourceHashes)
        XCTAssertEqual(try audioHashes(in: source), sourceHashes)
        let metrics: [String: Any] = [
            "firstProcessingSeconds": firstSeconds, "cacheWarmProcessingSeconds": secondSeconds,
            "audioFilesUnchanged": sourceHashes.count, "voiceProfiles": voiceIDs.count,
            "transcriptSegments": secondTranscript.segments.count,
            "speakerContinuity": report.speakerContinuity.rawValue,
            "reusedASRWindows": report.reusedASRWindows,
            "reusedDiarizationWindows": report.reusedDiarizationWindows,
            "windowFailures": report.windowFailures.count,
            "maximumMaterializedFrames": report.maximumMaterializedFrames
        ]
        try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-acceptance-metrics.json"), options: .atomic)
#else
        throw XCTSkip("Native FluidAudio acceptance requires Apple Silicon.")
#endif
    }

    private func audioHashes(in directory: URL) throws -> [String: String] {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let audio = directory.appendingPathComponent("audio")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: audio,
            includingPropertiesForKeys: [.isRegularFileKey]))
        var hashes: [String: String] = [:]
        for case let file as URL in enumerator where file.pathExtension == "m4a" {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty { hash.update(data: data) }
            let path = file.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { throw SessionAudioError.invalidMetadata }
            hashes[String(path.dropFirst(root.count))] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertFalse(hashes.isEmpty)
        return hashes
    }
}

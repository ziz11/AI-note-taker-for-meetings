import AVFoundation
import Combine
import XCTest
@testable import Recordly

final class SegmentedInferenceTests: XCTestCase {
    @MainActor
    func testProgressCountsActualWorkAndNeverRegressesAcrossStages() async throws {
        try addAudio(track: .microphone, startSeconds: 0, seconds: 130)
        try addAudio(track: .system, startSeconds: 0, seconds: 130)
        var updates: [TranscriptProcessingProgress] = []
        _ = try await process(asr: SegmentedTestASREngine(), onProgress: { updates.append($0) })
        let final = try XCTUnwrap(updates.last)
        XCTAssertEqual(final.asr.total, 6)
        XCTAssertEqual(final.asr.handled, 6)
        XCTAssertEqual(final.diarization.total, 3)
        XCTAssertEqual(final.diarization.handled, 3)
        XCTAssertEqual(final.overallFraction, 1)
        XCTAssertEqual(final.state, .ready)
        XCTAssertTrue(zip(updates, updates.dropFirst()).allSatisfy { $0.overallFraction <= $1.overallFraction })
        XCTAssertTrue(updates.contains { $0.state == .queued && $0.asr.total == 6 })
    }

    @MainActor
    func testProgressAccountsForCachedASRAndFailedDiarization() async throws {
        try addAudio(track: .system, startSeconds: 0, seconds: 2)
        let asr = SegmentedTestASREngine()
        _ = try await process(asr: asr)
        var updates: [TranscriptProcessingProgress] = []
        _ = try await process(asr: asr, diarization: SegmentedTestDiarizationEngine(fails: true), onProgress: { updates.append($0) })
        let final = try XCTUnwrap(updates.last)
        XCTAssertEqual(final.asr.handled, 1)
        XCTAssertEqual(final.asr.reused, 1)
        XCTAssertEqual(final.diarization.handled, 1)
        XCTAssertEqual(final.diarization.failed, 1)
        XCTAssertTrue(final.diagnosticsLabel.contains("1 failed"))
        XCTAssertEqual(final.overallFraction, 1)
    }

    @MainActor
    func testProgressPublishesTrailingStageWhileBackendIsStillWorking() async throws {
        let delivered = expectation(description: "Latest counters and active stage delivered")
        var updates: [TranscriptProcessingProgress] = []
        let publisher = TranscriptProgressPublisher { snapshot in
            updates.append(snapshot)
            if snapshot.state == .diarizingSystem { delivered.fulfill() }
        }
        var snapshot = TranscriptProcessingProgress(asr: .init(total: 1), diarization: .init(total: 1))
        publisher.publish(snapshot, force: true)
        // Fast cache/stage changes, followed by no further backend callbacks.
        for _ in 0..<100 { publisher.publish(snapshot) }
        snapshot.asr.handled = 1
        snapshot.asr.reused = 1
        snapshot.state = .diarizingSystem
        publisher.publish(snapshot)
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates.last?.asr.handled, 1)
        XCTAssertEqual(updates.last?.asr.reused, 1)
        XCTAssertEqual(updates.last?.diarization.handled, 0)
    }

    @MainActor
    func testProgressKeepsFailureAndCancellationCountersBelowCompletion() async throws {
        try addAudio(track: .system, startSeconds: 0, seconds: 2)
        var updates: [TranscriptProcessingProgress] = []
        do {
            _ = try await process(asr: SegmentedTestASREngine(failingChannel: .system), onProgress: { updates.append($0) })
            XCTFail("Expected all-ASR failure")
        } catch { XCTAssertFalse(error is CancellationError) }
        let failure = try XCTUnwrap(updates.last)
        XCTAssertEqual(failure.state, .failed)
        XCTAssertEqual(failure.asr.handled, 1)
        XCTAssertEqual(failure.asr.failed, 1)
        XCTAssertLessThan(failure.overallFraction, 1)
        updates = []
        do {
            _ = try await process(asr: SegmentedTestASREngine(), diarization: .init(cancels: true), onProgress: { updates.append($0) })
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        let cancellation = try XCTUnwrap(updates.last)
        XCTAssertTrue(cancellation.isCancelled)
        XCTAssertEqual(cancellation.asr.handled, 1)
        XCTAssertEqual(cancellation.diarization.handled, 0)
        XCTAssertLessThan(cancellation.overallFraction, 1)
    }

    @MainActor
    func testProgressCountsMissingOwnedAudioAndUnavailableDiarizationAsSkipped() async throws {
        try addAudio(track: .system, startSeconds: 0, seconds: 2)
        try addAudio(track: .system, startSeconds: 120, seconds: 2)
        var updates: [TranscriptProcessingProgress] = []
        _ = try await process(asr: .init(), diarizationModelURL: directory.appendingPathComponent("missing"), onProgress: { updates.append($0) })
        let final = try XCTUnwrap(updates.last)
        XCTAssertEqual(final.asr.total, 3)
        XCTAssertEqual(final.asr.handled, 3)
        XCTAssertEqual(final.asr.skipped, 1)
        XCTAssertEqual(final.diarization.total, 3)
        XCTAssertEqual(final.diarization.handled, 3)
        XCTAssertEqual(final.diarization.skipped, 3)
        XCTAssertEqual(final.overallFraction, 1)
    }

    @MainActor
    func testStoreVisibleProgressStartsAtZeroAndKeepsCountersThroughCompletion() async throws {
        try addAudio(track: .microphone, startSeconds: 0, seconds: 2)
        let modelURL = directory.appendingPathComponent("store-model")
        try Data("model".utf8).write(to: modelURL)
        let recording = RecordingSession(id: sessionID, title: "Progress", createdAt: Date(), duration: 2,
            lifecycleState: .ready, transcriptState: .idle, source: .liveCapture, notes: "",
            assets: .init(audioManifestFile: "audio-manifest.json", audioTracks: ["microphone"]))
        let repository = InMemoryRecordingsRepository(recordings: [recording], sessionDirectories: [sessionID: directory])
        let profile = InferenceRuntimeProfile(stageSelection: .defaultLocal,
            modelArtifacts: .init(asrModelURL: modelURL, diarizationModelURL: nil, summarizationModelURL: nil),
            summarizationRuntimeSettings: .default)
        let manager = ModelManager(discoveryPaths: .init(appSupportDirectory: { _ in nil },
            sharedDirectory: { _ in nil }, userDirectory: { _ in nil }, projectDirectories: { [] }))
        let store = RecordingsStore(audioCaptureEngine: StubAudioCaptureEngine(artifacts: .init()),
            transcriptionPipeline: .init(), runtimeProfileSelector: ProgressTestProfileSelector(profile: profile),
            inferenceEngineFactory: SegmentedTestEngineFactory(asr: .init(), diarization: .init()),
            transcriptionEngineDisplayName: "Test", modelManager: manager,
            fluidAudioModelProvider: FluidAudioASRModelProvider(),
            fluidAudioDiarizationModelProvider: FluidAudioDiarizationModelProvider(), repository: repository)
        // Let startup recovery finish before intentionally queueing this recording.
        await Task.yield()
        store.pauseTranscriptionQueue()
        let finished = expectation(description: "Store forwards completed progress")
        var fractions: [Double] = []
        var final: TranscriptProcessingProgress?
        let subscription = store.$viewState.sink { state in
            guard let job = state.runtime.processingJobs.first(where: { $0.kind == .transcription }) else { return }
            fractions.append(job.progress)
            if job.transcriptionDetail?.state == .ready && final == nil {
                final = job.transcriptionDetail
                finished.fulfill()
            }
        }
        await store.transcribeSelectedRecording()
        XCTAssertEqual(store.processingJobs.first?.progress, 0)
        store.resumeTranscriptionQueue()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(fractions.first, 0)
        XCTAssertTrue(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertEqual(final?.asr.handled, 1)
        XCTAssertEqual(final?.asr.total, 1)
        XCTAssertEqual(final?.overallFraction, 1)
        subscription.cancel()
        store.cancelAllProcessingJobs()
    }

    @MainActor
    func testProgressFlushesCancellationDuringFinalization() async throws {
        try addAudio(track: .microphone, startSeconds: 0, seconds: 2)
        var updates: [TranscriptProcessingProgress] = []
        var task: Task<TranscriptionResult, Error>?
        task = Task {
            try await process(asr: .init(), onProgress: { snapshot in
                updates.append(snapshot)
                if snapshot.state == .merging { task?.cancel() }
            })
        }
        do { _ = try await task!.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try XCTUnwrap(updates.last).isCancelled)
        XCTAssertLessThan(try XCTUnwrap(updates.last).overallFraction, 1)
        XCTAssertTrue(zip(updates, updates.dropFirst()).allSatisfy { $0.overallFraction <= $1.overallFraction })
    }

    @MainActor
    func testProgressFlushesOutputFailureWithoutRegressingFinishingWork() async throws {
        try addAudio(track: .microphone, startSeconds: 0, seconds: 2)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("transcript.txt"), withIntermediateDirectories: true)
        var updates: [TranscriptProcessingProgress] = []
        do {
            _ = try await process(asr: .init(), onProgress: { updates.append($0) })
            XCTFail("Expected output write failure")
        } catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertEqual(updates.last?.state, .failed)
        XCTAssertEqual(updates.last?.asr.handled, 1)
        XCTAssertLessThan(try XCTUnwrap(updates.last).overallFraction, 1)
        XCTAssertTrue(zip(updates, updates.dropFirst()).allSatisfy { $0.overallFraction <= $1.overallFraction })
    }

    @MainActor
    func testForcedBoundaryCannotLetCancelledTimerFlushNewSnapshotEarly() async throws {
        let delivered = expectation(description: "Next snapshot respects new boundary interval")
        var boundaryTime: TimeInterval = 0
        let publisher = TranscriptProgressPublisher { snapshot in
            if snapshot.state == .renderingOutputs {
                XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - boundaryTime, 0.08)
                delivered.fulfill()
            }
        }
        var snapshot = TranscriptProcessingProgress()
        publisher.publish(snapshot, force: true)
        snapshot.state = .diarizingSystem
        publisher.publish(snapshot)
        try await Task.sleep(nanoseconds: 10_000_000)
        // Leave the old timer's continuation queued on the main actor.
        Self.blockMainActorForTimerFixture()
        snapshot.state = .merging
        publisher.publish(snapshot, force: true)
        boundaryTime = ProcessInfo.processInfo.systemUptime
        snapshot.state = .renderingOutputs
        publisher.publish(snapshot)
        await fulfillment(of: [delivered], timeout: 2)
    }

    @MainActor
    private static func blockMainActorForTimerFixture() {
        Thread.sleep(forTimeInterval: 0.15)
    }

    private var directory: URL!
    private let sessionID = UUID()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SegmentedInferenceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testSegmentedRecordingUsesIndependentBoundedInferenceWindows() async throws {
        try addAudio(track: .microphone, startSeconds: 0, seconds: 130)
        let asr = SegmentedTestASREngine()
        let result = try await process(asr: asr)
        XCTAssertEqual(result.state, .ready)
        XCTAssertEqual(asr.durations.count, 3)
        XCTAssertLessThanOrEqual(asr.durations.max() ?? .infinity, 60)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("merged-call.caf").path))
        let transcript = try readTranscript()
        XCTAssertTrue(transcript.segments.allSatisfy { $0.speakerId == "me" })
        XCTAssertTrue(transcript.segments.contains { $0.startMs >= 50_000 })
    }

    func testMicrophoneFailureStillProducesSystemTranscript() async throws {
        try addAudio(track: .microphone, startSeconds: 0, seconds: 2)
        try addAudio(track: .system, startSeconds: 0, seconds: 2)
        let asr = SegmentedTestASREngine(failingChannel: .mic)
        let result = try await process(asr: asr)
        XCTAssertEqual(result.state, .ready)
        XCTAssertTrue(try readTranscript().segments.contains { $0.channel == .system })
        XCTAssertFalse(result.degradedReasons.isEmpty)
    }

    func testDiarizationFailurePreservesSystemASRWithUnknownRemote() async throws {
        try addAudio(track: .system, startSeconds: 0, seconds: 2)
        let result = try await process(asr: SegmentedTestASREngine(), diarization: SegmentedTestDiarizationEngine(fails: true))
        XCTAssertEqual(result.state, .ready)
        XCTAssertFalse(try readTranscript().segments.isEmpty)
        XCTAssertTrue(try readTranscript().segments.allSatisfy { $0.channel == .system && $0.speakerId != "me" && $0.speakerRole == .unknown })
        XCTAssertTrue(result.degradedReasons.contains(.diarizationDegraded))
    }

    func testMissingDiarizationArtifactPreservesSystemASR() async throws {
        try addAudio(track: .system, startSeconds: 0, seconds: 2)
        let result = try await process(asr: SegmentedTestASREngine(),
            diarizationModelURL: directory.appendingPathComponent("missing-diarization-model"))
        XCTAssertEqual(result.state, .ready)
        XCTAssertTrue(result.degradedReasons.contains(.diarizationDegraded))
        XCTAssertTrue(try readTranscript().segments.allSatisfy { $0.speakerId == "remote_unknown" })
        XCTAssertTrue(try readReport().windowFailures.contains { $0.stage == "diarization" })
    }

    func testOptionalDiarizationMaterializationFailurePreservesCachedSystemASR() async throws {
        try addAudio(track: .system, startSeconds: 0, seconds: 2)
        let asr = SegmentedTestASREngine()
        _ = try await process(asr: asr)
        let temporaryDirectory = directory.appendingPathComponent("inference/temporary")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: temporaryDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporaryDirectory.path) }
        let result = try await process(asr: asr)
        XCTAssertEqual(result.state, .ready)
        XCTAssertEqual(asr.durations.count, 1)
        XCTAssertFalse(try readTranscript().segments.isEmpty)
        XCTAssertTrue(try readTranscript().segments.allSatisfy { $0.speakerId == "remote_unknown" })
        XCTAssertTrue(result.degradedReasons.contains(.diarizationDegraded))
        XCTAssertTrue(try readReport().windowFailures.contains { $0.stage == "diarization" })
        XCTAssertEqual(try readReport().reusedASRWindows, 1)
    }

    func testASRCancellationPropagatesInsteadOfPartialSuccess() async throws {
        try addAudio(track: .microphone, startSeconds: 0, seconds: 2)
        try addAudio(track: .system, startSeconds: 0, seconds: 2)
        do {
            _ = try await process(asr: SegmentedTestASREngine(cancels: true))
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testUnchangedWindowsReuseASRAndKeepStableEventIDs() async throws {
        try addAudio(track: .microphone, startSeconds: 0, seconds: 130)
        let asr = SegmentedTestASREngine()
        _ = try await process(asr: asr)
        let firstIDs = try readTranscript().segments.map(\.id)
        _ = try await process(asr: asr)
        XCTAssertEqual(asr.durations.count, 3)
        XCTAssertEqual(try readTranscript().segments.map(\.id), firstIDs)
        XCTAssertEqual(try readReport().reusedASRWindows, 3)
    }

    func testChangedModelBytesInvalidateSamePathCache() async throws {
        try addAudio(track: .microphone, startSeconds: 0, seconds: 60)
        let asr = SegmentedTestASREngine()
        _ = try await process(asr: asr)
        _ = try await process(asr: asr, modelBytes: "model-v2")
        XCTAssertEqual(asr.durations.count, 4)
        XCTAssertEqual(try readReport().reusedASRWindows, 0)
    }

    func testMicrophoneCacheIgnoresUnrelatedDiarizationConfiguration() throws {
        let manifest = SessionAudioManifest(sessionID: sessionID, hostTimeOrigin: 0)
        let window = try XCTUnwrap(InferenceWindowPlanner().windows(track: .microphone, durationFrames: 48_000).first)
        var profile = InferenceRuntimeProfile(stageSelection: .defaultLocal, modelArtifacts: .empty,
            summarizationRuntimeSettings: .default)
        let first = WindowInferenceProvenance(manifest: manifest, window: window, profile: profile,
            asrArtifactFingerprint: "same-asr", asrEngineFingerprint: "same-settings", diarizationArtifactFingerprint: "dia-v1",
            settings: InferenceWindowSettings())
        profile.stageSelection.setBackend(.cliDiarization, for: .diarization)
        var settings = InferenceWindowSettings()
        settings.diarizationSettingsIdentity = "changed-diarization-settings"
        let second = WindowInferenceProvenance(manifest: manifest, window: window, profile: profile,
            asrArtifactFingerprint: "same-asr", asrEngineFingerprint: "same-settings", diarizationArtifactFingerprint: "dia-v2",
            settings: settings)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try first.fingerprint, try second.fingerprint)
    }

    func testTimelineChangeInvalidatesOnlyAffectedWindows() async throws {
        try addAudio(track: .microphone, startSeconds: 0, seconds: 60)
        try addAudio(track: .microphone, startSeconds: 120, seconds: 60)
        let asr = SegmentedTestASREngine()
        _ = try await process(asr: asr)
        let unaffected = try readTranscript().segments.filter { $0.startMs < 100_000 }.map(\.id)
        let store = SessionAudioStore(directory: directory, sessionID: sessionID)
        var manifest = try store.load()
        let last = try XCTUnwrap(manifest.segments.indices.last)
        manifest.segments[last].startFrame = 240 * 48_000
        try store.save(manifest)
        _ = try await process(asr: asr)
        XCTAssertEqual(asr.durations.count, 6)
        XCTAssertEqual(try readTranscript().segments.filter { $0.startMs < 100_000 }.map(\.id), unaffected)
        XCTAssertEqual(try readReport().reusedASRWindows, 2)
        XCTAssertTrue(try readReport().windowFailures.contains { $0.stage == "audio" })
    }

    func testMissingChunkRemovesStaleEventsButPreservesOtherWindows() async throws {
        try addAudio(track: .microphone, startSeconds: 0, seconds: 60)
        try addAudio(track: .microphone, startSeconds: 120, seconds: 60)
        let asr = SegmentedTestASREngine()
        _ = try await process(asr: asr)
        let unaffected = try readTranscript().segments.filter { $0.startMs < 100_000 }.map(\.id)
        let store = SessionAudioStore(directory: directory, sessionID: sessionID)
        let last = try XCTUnwrap(store.load().segments.last)
        try FileManager.default.removeItem(at: store.finalURL(for: last))
        let result = try await process(asr: asr)
        XCTAssertEqual(asr.durations.count, 4)
        XCTAssertEqual(try readTranscript().segments.map(\.id), unaffected)
        XCTAssertTrue(result.degradedReasons.contains(.captureDiagnostics))
        XCTAssertTrue(try readReport().windowFailures.contains { $0.startFrame >= 100 * 48_000 })
    }

    func testLongRecordingKeepsEveryMaterializationBounded() async throws {
        try addAudio(track: .microphone, startSeconds: 0, seconds: 180)
        try addAudio(track: .microphone, startSeconds: 180, seconds: 180)
        try addAudio(track: .microphone, startSeconds: 360, seconds: 10)
        let asr = SegmentedTestASREngine()
        _ = try await process(asr: asr)
        let report = try readReport()
        XCTAssertEqual(report.materializedWindowCount, 8)
        XCTAssertLessThanOrEqual(report.maximumMaterializedFrames, 60 * 48_000)
        XCTAssertEqual(asr.durations.count, 8)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("inference/temporary").path).isEmpty)
        let windows = try InferenceWindowPlanner().windows(track: .microphone, durationFrames: 8 * 60 * 60 * 48_000)
        XCTAssertEqual(windows.count, 576)
        XCTAssertTrue(windows.allSatisfy { $0.frameCount <= 60 * 48_000 })
    }

    func testWordTimingAssignsSpeechCrossingOwnershipBoundaryExactlyOnce() async throws {
        try addAudio(track: .microphone, startSeconds: 0, seconds: 100)
        let asr = SegmentedTestASREngine()
        asr.customSegments = { url, _, _ in
            let offset = Self.inputOffsetMs(url)
            return [ASRSegment(id: "same", startMs: 49_800 - offset, endMs: 50_300 - offset, text: "Hello world", confidence: nil, language: "en",
                words: [ASRWord(word: "Hello", startMs: 49_800 - offset, endMs: 49_900 - offset, confidence: nil),
                        ASRWord(word: "world", startMs: 50_200 - offset, endMs: 50_300 - offset, confidence: nil)])]
        }
        _ = try await process(asr: asr)
        let words = try readTranscript().segments.flatMap { $0.words ?? [] }
        XCTAssertEqual(words.map(\.word), ["Hello", "world"])
        XCTAssertEqual(words.map(\.startMs), [49_800, 50_200])
    }

    func testJitteredWordTimingAcrossBoundaryDoesNotDuplicateToken() async throws {
        try addAudio(track: .microphone, startSeconds: 0, seconds: 100)
        let asr = SegmentedTestASREngine()
        asr.customSegments = { url, _, _ in
            let offset = Self.inputOffsetMs(url)
            let lower = offset == 0 ? 49_880 : 49_920
            return [ASRSegment(id: "same", startMs: lower - offset, endMs: lower + 200 - offset, text: "Hello", confidence: nil, language: "en",
                words: [ASRWord(word: "Hello", startMs: lower - offset, endMs: lower + 200 - offset, confidence: nil)])]
        }
        _ = try await process(asr: asr)
        let words = try readTranscript().segments.flatMap { $0.words ?? [] }
        XCTAssertEqual(words.map(\.word), ["Hello"])
        XCTAssertEqual((words.first?.endMs ?? 0) - (words.first?.startMs ?? 0), 200)
    }

    func testReversedJitterAcrossBoundaryRetainsExactlyOneToken() async throws {
        try addAudio(track: .microphone, startSeconds: 0, seconds: 100)
        let asr = SegmentedTestASREngine()
        asr.customSegments = { url, _, _ in
            let offset = Self.inputOffsetMs(url)
            let lower = offset == 0 ? 49_920 : 49_880
            return [ASRSegment(id: "same", startMs: lower - offset, endMs: lower + 200 - offset, text: "Hello", confidence: nil, language: "en",
                words: [ASRWord(word: "Hello", startMs: lower - offset, endMs: lower + 200 - offset, confidence: nil)])]
        }
        _ = try await process(asr: asr)
        let words = try readTranscript().segments.flatMap { $0.words ?? [] }
        XCTAssertEqual(words.map(\.word), ["Hello"])
        XCTAssertEqual((words.first?.endMs ?? 0) - (words.first?.startMs ?? 0), 200)
    }

    func testUntimedBoundaryAlternativesDoNotDropUtteranceWhenMidpointsDisagree() async throws {
        try addAudio(track: .microphone, startSeconds: 0, seconds: 100)
        let asr = SegmentedTestASREngine()
        asr.customSegments = { url, _, _ in
            let offset = Self.inputOffsetMs(url)
            let lower = offset == 0 ? 48_000 : 47_000
            return [ASRSegment(id: "same", startMs: lower - offset, endMs: lower + 4_000 - offset, text: "Speech across boundary", confidence: nil, language: "en", words: nil)]
        }
        _ = try await process(asr: asr)
        XCTAssertEqual(try readTranscript().segments.count, 1)
        XCTAssertEqual(try readTranscript().segments.first?.text, "Speech across boundary")
        XCTAssertEqual((try readTranscript().segments.first?.endMs ?? 0) - (try readTranscript().segments.first?.startMs ?? 0), 4_000)
    }

    func testIdenticalTextAtDifferentTimesIsPreserved() async throws {
        try addAudio(track: .microphone, startSeconds: 0, seconds: 130)
        let asr = SegmentedTestASREngine()
        asr.customSegments = { _, _, _ in [ASRSegment(id: "same", startMs: 10_000, endMs: 10_500, text: "Yes", confidence: nil, language: "en", words: nil)] }
        _ = try await process(asr: asr)
        XCTAssertEqual(try readTranscript().segments.map(\.text), ["Yes", "Yes", "Yes"])
    }

    func testReturningBackendLabelIsExplicitlyUnresolvedAcrossWindows() async throws {
        try addAudio(track: .system, startSeconds: 0, seconds: 130)
        _ = try await process(asr: SegmentedTestASREngine())
        let transcript = try readTranscript()
        XCTAssertEqual(Set(transcript.segments.compactMap(\.speakerId)).count, 3)
        XCTAssertTrue(transcript.segments.allSatisfy { $0.speakerId != "me" })
        XCTAssertEqual(try readReport().speakerContinuity, .unresolvedAcrossWindows)
        let identityDocument = try SessionSpeakerIdentityStore(directory: directory, sessionID: sessionID).load()
        XCTAssertEqual(identityDocument.aliases.count, 3)
    }

    func testLocalRenameSurvivesReprocessingAndBackendLabelPermutation() async throws {
        try addAudio(track: .system, startSeconds: 0, seconds: 2)
        let asr = SegmentedTestASREngine()
        _ = try await process(asr: asr)
        let speakerID = try XCTUnwrap(readTranscript().segments.first?.speakerId)
        let identities = SessionSpeakerIdentityStore(directory: directory, sessionID: sessionID)
        try identities.rename(speakerID: speakerID, to: "Alice")
        _ = try await process(asr: asr, diarization: SegmentedTestDiarizationEngine(rawLabel: "speaker_7"))
        XCTAssertEqual(try readTranscript().segments.first?.speakerId, speakerID)
        XCTAssertEqual(try readTranscript().segments.first?.speaker, "Alice")
        XCTAssertEqual(asr.durations.count, 1)
        XCTAssertEqual(try identities.load().aliases.count, 1,
            "Aliases describe the current rebuild; exact-turn identity and rename survive independently")
    }

    func testLocalRenameSurvivesASRModelChangeWithUnchangedDiarizationTurns() async throws {
        try addAudio(track: .system, startSeconds: 0, seconds: 2)
        let asr = SegmentedTestASREngine()
        _ = try await process(asr: asr)
        let speakerID = try XCTUnwrap(readTranscript().segments.first?.speakerId)
        let identities = SessionSpeakerIdentityStore(directory: directory, sessionID: sessionID)
        try identities.rename(speakerID: speakerID, to: "Alice")
        _ = try await process(asr: asr, modelBytes: "model-v2")
        XCTAssertEqual(try readTranscript().segments.first?.speakerId, speakerID)
        XCTAssertEqual(try readTranscript().segments.first?.speaker, "Alice")
        XCTAssertEqual(asr.durations.count, 2)
    }

    func testDuplicatedProcessedRecordingReprocessesAndPreservesLocalRename() async throws {
        try addAudio(track: .system, startSeconds: 0, seconds: 2)
        let asr = SegmentedTestASREngine()
        _ = try await process(asr: asr)
        let speakerID = try XCTUnwrap(readTranscript().segments.first?.speakerId)
        let identities = SessionSpeakerIdentityStore(directory: directory, sessionID: sessionID)
        try identities.rename(speakerID: speakerID, to: "Alice")
        let sourceIdentityBytes = try Data(contentsOf: identities.url)
        let sourceCacheURL = directory.appendingPathComponent("inference/windows/system-0.json")
        let sourceCacheBytes = try Data(contentsOf: sourceCacheURL)
        let sourceDirectory = directory!
        let sourceTemporaryURL = directory.appendingPathComponent("inference/temporary/system-0-\(UUID()).caf")
        try Data("unfinished temporary export".utf8).write(to: sourceTemporaryURL)
        let copiedID = UUID()
        // The copy is placed alongside the source so its tree cannot copy itself.
        let copyRoot = directory.deletingLastPathComponent().appendingPathComponent("SegmentedInferenceCopy-\(copiedID)")
        defer { try? FileManager.default.removeItem(at: copyRoot) }
        let isolatedRepository = RecordingsRepository(sessionDirectoryProvider: { id in
            let value = id == self.sessionID ? sourceDirectory : copyRoot
            try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
            return value
        })
        try isolatedRepository.duplicateSessionContents(from: sessionID, to: copiedID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyRoot.appendingPathComponent("inference/temporary").path),
            "Transient inference audio must be excluded from duplication")
        let result = try await process(asr: asr, overrideDirectory: copyRoot, overrideSessionID: copiedID)
        XCTAssertEqual(result.state, .ready)
        let copiedTranscript = try readTranscript(in: copyRoot)
        XCTAssertEqual(copiedTranscript.sessionID, copiedID)
        XCTAssertEqual(copiedTranscript.segments.first?.speakerId, speakerID)
        XCTAssertEqual(copiedTranscript.segments.first?.speaker, "Alice")
        XCTAssertEqual(asr.durations.count, 2, "Original-session inference cache must not be reused")
        XCTAssertEqual(try Data(contentsOf: identities.url), sourceIdentityBytes)
        XCTAssertEqual(try Data(contentsOf: sourceCacheURL), sourceCacheBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceTemporaryURL.path))
        let copiedIdentities = try SessionSpeakerIdentityStore(directory: copyRoot, sessionID: copiedID).load()
        XCTAssertEqual(copiedIdentities.sessionID, copiedID)
        XCTAssertEqual(copiedIdentities.identities[speakerID]?.displayName, "Alice")
        var changedManifest = try SessionAudioStore(directory: copyRoot, sessionID: copiedID).load()
        changedManifest.hostTimeOrigin += 1
        try SessionAudioStore(directory: copyRoot, sessionID: copiedID).save(changedManifest)
        _ = try await process(asr: asr, overrideDirectory: copyRoot, overrideSessionID: copiedID)
        let changedTranscript = try readTranscript(in: copyRoot)
        XCTAssertNotEqual(changedTranscript.segments.first?.speakerId, speakerID,
            "Copy lineage must not match speakers after timeline evidence changes")
        XCTAssertNotEqual(changedTranscript.segments.first?.speaker, "Alice")
        XCTAssertEqual(try Data(contentsOf: identities.url), sourceIdentityBytes)
        XCTAssertEqual(try Data(contentsOf: sourceCacheURL), sourceCacheBytes)
    }

    func testOverlappingLocalGroupsWithIdenticalTurnTimesStayDistinct() async throws {
        try addAudio(track: .system, startSeconds: 0, seconds: 2)
        let diarization = SegmentedTestDiarizationEngine()
        diarization.customSegments = [DiarizationSegment(id: "a", speaker: "speaker_0", startMs: 0, endMs: 2_000, confidence: nil),
                                      DiarizationSegment(id: "b", speaker: "speaker_1", startMs: 0, endMs: 2_000, confidence: nil)]
        _ = try await process(asr: SegmentedTestASREngine(), diarization: diarization)
        XCTAssertEqual(try SessionSpeakerIdentityStore(directory: directory, sessionID: sessionID).load().identities.count, 2)
    }

    func testDiarizationCancellationPropagatesAndKeepsCompletedASRWindowCache() async throws {
        try addAudio(track: .system, startSeconds: 0, seconds: 2)
        do {
            _ = try await process(asr: SegmentedTestASREngine(), diarization: SegmentedTestDiarizationEngine(cancels: true))
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try readReport().status, "cancelled")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("inference/windows/system-0.json").path))
    }

    func testPartialWindowFailureRetainsOtherWindowsAndReportsExactRange() async throws {
        try addAudio(track: .microphone, startSeconds: 0, seconds: 130)
        let asr = SegmentedTestASREngine()
        asr.failingAttempts = [2]
        let result = try await process(asr: asr)
        XCTAssertEqual(result.state, .ready)
        XCTAssertEqual(try readTranscript().segments.count, 2)
        let failed = try XCTUnwrap(readReport().windowFailures.first { $0.stage == "asr" })
        XCTAssertEqual(failed.startFrame, 50 * 48_000)
        XCTAssertEqual(failed.endFrame, 100 * 48_000)
        XCTAssertTrue(result.degradedReasons.contains(.windowInferenceFailed))
        asr.failingAttempts = []
        _ = try await process(asr: asr)
        XCTAssertEqual(asr.attempts, 4)
        XCTAssertEqual(try readTranscript().segments.count, 3)
    }

    func testFluidAudioAcceptsBoundedSystemSemanticCAF() async throws {
        let url = directory.appendingPathComponent("neutral-window-name.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        buffer.floatChannelData![0].initialize(repeating: 0.02, count: 48_000)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer); file.close()
        let engine = FluidAudioDiarizationEngine(manager: SegmentedOfflineDiarizationManager())
        _ = try await engine.diarize(window: PreparedDiarizationWindow(audioURL: url, track: .system, startFrame: 0, frameCount: 48_000),
            sessionID: sessionID, configuration: DiarizationEngineConfiguration(modelURL: nil))
        do {
            _ = try await engine.diarize(window: PreparedDiarizationWindow(audioURL: url, track: .microphone, startFrame: 0, frameCount: 48_000),
                sessionID: sessionID, configuration: DiarizationEngineConfiguration(modelURL: nil))
            XCTFail("Microphone track metadata must be rejected regardless of filename")
        } catch { XCTAssertEqual(error as? DiarizationRuntimeError, .invalidInput) }
    }

    func testFilenameAloneCannotAuthorizeSemanticDiarizationWindow() async throws {
        let url = try makeShortCAF(named: "system-untrusted.caf")
        let engine = FluidAudioDiarizationEngine(manager: SegmentedOfflineDiarizationManager())
        do {
            _ = try await engine.diarize(systemAudioURL: url, sessionID: sessionID, configuration: DiarizationEngineConfiguration(modelURL: nil))
            XCTFail("A system-prefixed arbitrary CAF is not a prepared window")
        } catch { XCTAssertEqual(error as? DiarizationRuntimeError, .invalidInput) }
    }

    func testRetryRemovesOnlyOwnedStaleInferenceAudio() async throws {
        try addAudio(track: .microphone, startSeconds: 0, seconds: 2)
        let asr = SegmentedTestASREngine()
        _ = try await process(asr: asr)
        let temp = directory.appendingPathComponent("inference/temporary")
        let stale = temp.appendingPathComponent("microphone-0-\(UUID()).caf")
        let unrelated = temp.appendingPathComponent("notes.caf")
        try Data("partial audio before kill".utf8).write(to: stale)
        try Data("unrelated file".utf8).write(to: unrelated)
        _ = try await process(asr: asr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(asr.attempts, 1)
    }

    func testCancellationResistantManagerNeverRunsConcurrentlyAfterTimeout() async throws {
        let url = try makeShortCAF(named: "system.m4a")
        let manager = CancellationResistantDiarizationManager()
        for _ in 0..<3 {
            let engine = FluidAudioDiarizationEngine(manager: manager, timeoutSeconds: 1)
            do {
                _ = try await engine.diarize(systemAudioURL: url, sessionID: sessionID, configuration: DiarizationEngineConfiguration(modelURL: nil))
                XCTFail("Expected timeout or quarantine")
            } catch { XCTAssertTrue(error is DiarizationRuntimeError) }
        }
        XCTAssertEqual(manager.callCount, 1)
        XCTAssertLessThanOrEqual(manager.maxActive, 1)
        manager.finishAll()
        try await Task.sleep(nanoseconds: 50_000_000)
        let retry = FluidAudioDiarizationEngine(manager: manager, timeoutSeconds: 1)
        do {
            _ = try await retry.diarize(systemAudioURL: url, sessionID: sessionID, configuration: DiarizationEngineConfiguration(modelURL: nil))
            XCTFail("A timed out SDK manager remains quarantined until restart")
        } catch { XCTAssertTrue(error.localizedDescription.lowercased().contains("restart")) }
        manager.finishAll()
        XCTAssertEqual(manager.callCount, 1)
    }

    func testCallerCancellationQuarantinesResistantManagerEvenAfterReturn() async throws {
        let url = try makeShortCAF(named: "system.m4a")
        let manager = CancellationResistantDiarizationManager()
        defer { manager.finishAll() }
        let engine = FluidAudioDiarizationEngine(manager: manager, timeoutSeconds: 10)
        let task = Task {
            try await engine.diarize(systemAudioURL: url, sessionID: sessionID, configuration: DiarizationEngineConfiguration(modelURL: nil))
        }
        for _ in 0..<100 {
            if manager.callCount > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(manager.callCount, 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? DiarizationRuntimeError, .cancelled) }
        manager.finishAll()
        try await Task.sleep(nanoseconds: 50_000_000)
        do {
            _ = try await FluidAudioDiarizationEngine(manager: manager).diarize(systemAudioURL: url,
                sessionID: sessionID, configuration: DiarizationEngineConfiguration(modelURL: nil))
            XCTFail("Cancelled SDK manager must remain quarantined")
        } catch { XCTAssertEqual(error as? DiarizationRuntimeError, .runtimeQuarantined) }
        XCTAssertEqual(manager.callCount, 1)
        XCTAssertLessThanOrEqual(manager.maxActive, 1)
    }

    func testImmediateManagerCanProcessRepeatedSuccessfulWindowsWithoutFalseBusy() async throws {
        let url = directory.appendingPathComponent("system.m4a")
        let manager = SegmentedOfflineDiarizationManager()
        for _ in 0..<500 {
            let engine = FluidAudioDiarizationEngine(manager: manager,
                fileManager: SegmentedAlwaysExistingFileManager(), sessionAudioLoader: SegmentedImmediateAudioLoader(), timeoutSeconds: 1)
            let document = try await engine.diarize(systemAudioURL: url, sessionID: sessionID,
                configuration: DiarizationEngineConfiguration(modelURL: nil))
            XCTAssertEqual(document.segments.count, 1)
        }
    }

    func testTimedOutDiarizationStopsRemainingWindowsAndKeepsASR() async throws {
        try addAudio(track: .system, startSeconds: 0, seconds: 130)
        let diarization = SegmentedTestDiarizationEngine()
        diarization.timesOut = true
        let result = try await process(asr: SegmentedTestASREngine(), diarization: diarization)
        XCTAssertEqual(result.state, .ready)
        XCTAssertEqual(diarization.attempts, 1)
        XCTAssertTrue(result.summary.lowercased().contains("restart"), "The restart requirement must be visible in recording notes")
        XCTAssertEqual(try readTranscript().segments.count, 3)
        XCTAssertTrue(try readTranscript().segments.allSatisfy { $0.speakerId == "remote_unknown" })
    }

    func testReturningVoiceAfterLongAbsenceRemainsUnresolvedAndKeepsUnrelatedRename() async throws {
        for index in 0..<6 { try addAudio(track: .system, startSeconds: index * 50, seconds: 50) }
        let asr = SegmentedTestASREngine()
        asr.customSegments = { url, _, _ in
            let index = (Self.inputOffsetMs(url) + 5_000) / 50_000
            let voice = index == 0 || index == 5 ? "A" : "B"
            return [ASRSegment(id: "local", startMs: 10_000, endMs: 11_000, text: "Voice \(voice)", confidence: nil, language: nil, words: nil)]
        }
        _ = try await process(asr: asr)
        let first = try readTranscript()
        XCTAssertEqual(first.segments.map(\.text), ["Voice A", "Voice B", "Voice B", "Voice B", "Voice B", "Voice A"])
        XCTAssertEqual(Set(first.segments.compactMap(\.speakerId)).count, 6)
        XCTAssertNotEqual(first.segments.first?.speakerId, first.segments.last?.speakerId)
        XCTAssertEqual(try readReport().speakerContinuity, .unresolvedAcrossWindows)
        let firstID = try XCTUnwrap(first.segments.first?.speakerId)
        try SessionSpeakerIdentityStore(directory: directory, sessionID: sessionID).rename(speakerID: firstID, to: "Alice")
        let store = SessionAudioStore(directory: directory, sessionID: sessionID)
        var manifest = try store.load()
        let middle = try XCTUnwrap(manifest.segments.firstIndex { $0.startFrame == 150 * 48_000 })
        manifest.segments[middle].gaps = [AudioTimelineGap(startFrame: 150 * 48_000, frameCount: 480, reason: "fixture gap")]
        try store.save(manifest)
        _ = try await process(asr: asr)
        XCTAssertEqual(try readTranscript().segments.first?.speakerId, firstID)
        XCTAssertEqual(try readTranscript().segments.first?.speaker, "Alice")
        XCTAssertNotEqual(try readTranscript().segments.last?.speaker, "Alice")
        XCTAssertEqual(try readReport().speakerContinuity, .unresolvedAcrossWindows)
    }

    private func makeShortCAF(named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        buffer.floatChannelData![0].initialize(repeating: 0.02, count: 48_000)
        let outputSettings = url.pathExtension == "m4a" ? PCMTrackWriter.fileSettings(for: url) : format.settings
        let file = try AVAudioFile(forWriting: url, settings: outputSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer); file.close()
        return url
    }

    func testLegacyMicrophoneFailureStillKeepsValidSystemTranscript() async throws {
        let result = try await processLegacy(asr: SegmentedTestASREngine(failingChannel: .mic))
        XCTAssertEqual(result.state, .ready)
        XCTAssertTrue(try readTranscript().segments.contains { $0.channel == .system })
        XCTAssertTrue(result.degradedReasons.contains(.micASRFailedFallbackUsed))
    }

    func testLegacySystemASRCancellationDoesNotBecomeMicrophoneOnlySuccess() async throws {
        let asr = SegmentedTestASREngine()
        asr.cancellingChannel = .system
        do {
            _ = try await processLegacy(asr: asr)
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testLegacyDiarizationCancellationDoesNotBecomeDegradedSuccess() async throws {
        do {
            _ = try await processLegacy(asr: SegmentedTestASREngine(), diarization: SegmentedTestDiarizationEngine(cancels: true))
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    // The JSON boundary deliberately exercises compatibility with old persisted documents.
    func testVoiceEvidenceReturningAfterTwentyMinutesReusesRenamedIdentity() throws {
        let store = SessionSpeakerIdentityStore(directory: directory, sessionID: sessionID)
        var identities = try store.load()
        let a = try voiceDocument(label: "S1", vector: unitVoice(0))
        let first = try store.identity(rawLabel: "S1", diarization: a, runID: UUID(),
            provenance: voiceProvenance(startMs: 0), document: &identities)
        identities.identities[first.id]?.displayName = "Alice"
        try store.save(identities)
        identities = try store.load()
        let returning = try store.identity(rawLabel: "S7", diarization: voiceDocument(label: "S7", vector: unitVoice(0)),
            runID: UUID(), provenance: voiceProvenance(startMs: 1_200_000), document: &identities)
        XCTAssertEqual(returning.id, first.id)
        XCTAssertEqual(returning.displayName, "Alice")
        XCTAssertEqual(first.defaultLabel, "Speaker 1")
    }

    func testVoiceDocumentRetainsEvidenceAndLegacyDocumentStillDecodes() throws {
        let document = try voiceDocument(label: "S1", vector: unitVoice(0))
        let encoded = try JSONEncoder().encode(document)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(json["voiceObservations"])
        let legacy = DiarizationDocument(version: 1, sessionID: sessionID, createdAt: Date(), segments: [])
        XCTAssertEqual(try JSONDecoder().decode(DiarizationDocument.self, from: JSONEncoder().encode(legacy)), legacy)
    }

    func testVoiceProfilesSeparateDifferentVoicesAndRejectModelChanges() throws {
        let store = SessionSpeakerIdentityStore(directory: directory, sessionID: sessionID)
        var identities = try store.load()
        func resolve(_ axis: Int, _ start: Int, _ artifact: String? = "diarizer-model-a") throws -> SessionSpeakerIdentity {
            try store.identity(rawLabel: "S1", diarization: voiceDocument(label: "S1", vector: unitVoice(axis)),
                runID: UUID(), provenance: voiceProvenance(startMs: start, artifact: artifact), document: &identities)
        }
        let a = try resolve(0, 0)
        let b = try resolve(1, 50_000)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(try resolve(0, 100_000).id, a.id)
        XCTAssertNotEqual(try resolve(0, 150_000, "different-model").id, a.id)
        XCTAssertTrue(try resolve(0, 200_000, nil).id.hasPrefix("remote_local_"))
    }

    func testCooccurringGroupsNeverCollapseEvenWithIdenticalVectors() throws {
        let store = SessionSpeakerIdentityStore(directory: directory, sessionID: sessionID)
        var identities = try store.load()
        let first = try store.identity(rawLabel: "S1", diarization: voiceDocument(label: "S1", vector: unitVoice(0)),
            runID: UUID(), provenance: voiceProvenance(startMs: 0), document: &identities)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            try voiceDocument(label: "S1", vector: unitVoice(0)))) as? [String: Any])
        json["segments"] = [
            ["id": "a", "speaker": "S1", "startMs": 0, "endMs": 10_000],
            ["id": "b", "speaker": "S2", "startMs": 15_000, "endMs": 25_000]]
        json["voiceObservations"] = [
            ["speaker": "S1", "startMs": 0, "endMs": 10_000, "embedding": unitVoice(0)],
            ["speaker": "S2", "startMs": 15_000, "endMs": 25_000, "embedding": unitVoice(0)]]
        let document = try JSONDecoder().decode(DiarizationDocument.self, from: JSONSerialization.data(withJSONObject: json))
        let run = UUID(), provenance = try voiceProvenance(startMs: 50_000)
        let a = try store.identity(rawLabel: "S1", diarization: document, runID: run, provenance: provenance, document: &identities)
        let b = try store.identity(rawLabel: "S2", diarization: document, runID: run, provenance: provenance, document: &identities)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.id, first.id, "Conflicting proposals cannot greedily assign one group to the known voice")
        XCTAssertNotEqual(b.id, first.id)
    }

    func testVoiceMatcherDoesNotForceShortInvalidOrOverlapOnlyEvidence() throws {
        let store = SessionSpeakerIdentityStore(directory: directory, sessionID: sessionID)
        var identities = try store.load()
        _ = try store.identity(rawLabel: "S1", diarization: voiceDocument(label: "S1", vector: unitVoice(0)),
            runID: UUID(), provenance: voiceProvenance(startMs: 0), document: &identities)
        for (index, vector) in [[Float](repeating: 0, count: 256), [Float](repeating: 1, count: 128), unitVoice(0)].enumerated() {
            let value = try store.identity(rawLabel: "S1", diarization: voiceDocument(label: "S1", vector: vector, endMs: index == 2 ? 500 : 10_000),
                runID: UUID(), provenance: voiceProvenance(startMs: (index + 1) * 50_000), document: &identities)
            XCTAssertTrue(value.id.hasPrefix("remote_local_"))
        }
        var document = try voiceDocument(label: "S1", vector: unitVoice(0))
        document.segments.append(.init(id: "overlap", speaker: "unsupported", startMs: 0, endMs: 10_000, confidence: nil))
        let overlap = try store.identity(rawLabel: "S1", diarization: document, runID: UUID(),
            provenance: voiceProvenance(startMs: 250_000), document: &identities)
        XCTAssertTrue(overlap.id.hasPrefix("remote_local_"))
    }

    func testAmbiguousRunnerUpDoesNotForceVoiceMatch() throws {
        let store = SessionSpeakerIdentityStore(directory: directory, sessionID: sessionID)
        var identities = try store.load()
        _ = try store.identity(rawLabel: "A", diarization: voiceDocument(label: "A", vector: unitVoice(0)),
            runID: UUID(), provenance: voiceProvenance(startMs: 0), document: &identities)
        var b = unitVoice(0); b[0] = 0.7; b[1] = sqrt(1 - 0.7 * 0.7)
        _ = try store.identity(rawLabel: "B", diarization: voiceDocument(label: "B", vector: b),
            runID: UUID(), provenance: voiceProvenance(startMs: 50_000), document: &identities)
        var ambiguous = unitVoice(0); ambiguous[0] = 0.92; ambiguous[1] = sqrt(1 - 0.92 * 0.92)
        let value = try store.identity(rawLabel: "C", diarization: voiceDocument(label: "C", vector: ambiguous),
            runID: UUID(), provenance: voiceProvenance(startMs: 100_000), document: &identities)
        XCTAssertTrue(value.id.hasPrefix("remote_local_"))
    }

    func testVoiceCacheWarmReprocessingKeepsNamesAndDoesNotDuplicateProfiles() async throws {
        try addAudio(track: .system, startSeconds: 0, seconds: 130)
        let model = directory.appendingPathComponent("diarization-model")
        try Data("diarization".utf8).write(to: model)
        let diarizer = SegmentedTestDiarizationEngine()
        diarizer.customDocument = try voiceDocument(label: "S1", vector: unitVoice(0), endMs: 55_000)
        diarizer.customDocument?.embeddingArtifactFingerprint = try InferenceFingerprint.artifact(at: model)
        _ = try await process(asr: SegmentedTestASREngine(), diarization: diarizer, diarizationModelURL: model)
        let first = try readTranscript()
        XCTAssertEqual(Set(first.segments.compactMap(\.speakerId)).count, 1)
        let store = SessionSpeakerIdentityStore(directory: directory, sessionID: sessionID)
        let id = try XCTUnwrap(first.segments.first?.speakerId)
        try store.rename(speakerID: id, to: "Alice")
        _ = try await process(asr: SegmentedTestASREngine(), diarization: diarizer, diarizationModelURL: model)
        XCTAssertEqual(diarizer.attempts, 3)
        XCTAssertTrue(try readTranscript().segments.allSatisfy { $0.speakerId == id && $0.speaker == "Alice" })
        XCTAssertEqual(try readReport().speakerContinuity.rawValue, "sessionMatched")
    }

    func testVoiceRebuildRemovesReplacedWindowContributionsAndRetainsCompatibleNameAnchor() throws {
        let store = SessionSpeakerIdentityStore(directory: directory, sessionID: sessionID)
        var identities = try store.load()
        let firstProvenance = try voiceProvenance(startMs: 0)
        let first = try store.identity(rawLabel: "S1", diarization: voiceDocument(label: "S1", vector: unitVoice(0)),
            runID: UUID(), provenance: firstProvenance, document: &identities)
        identities.identities[first.id]?.displayName = "Alice"
        _ = try store.identity(rawLabel: "S1", diarization: voiceDocument(label: "S1", vector: unitVoice(0)),
            runID: UUID(), provenance: voiceProvenance(startMs: 50_000), document: &identities)
        XCTAssertEqual(identities.voiceProfiles?[first.id]?.samples.count, 2)
        try store.beginRebuild(provenances: [firstProvenance], document: &identities)
        XCTAssertEqual(identities.voiceProfiles?[first.id]?.samples.count, 0)
        XCTAssertEqual(identities.voiceProfiles?[first.id]?.anchors.count, 1)
        let returned = try store.identity(rawLabel: "S7", diarization: voiceDocument(label: "S7", vector: unitVoice(0)),
            runID: UUID(), provenance: firstProvenance, document: &identities)
        XCTAssertEqual(returned.id, first.id)
        XCTAssertEqual(returned.displayName, "Alice")
        try store.beginRebuild(provenances: [voiceProvenance(startMs: 0, artifact: "replacement-model")], document: &identities)
        XCTAssertTrue(identities.voiceProfiles?.isEmpty == true)
        XCTAssertEqual(identities.identities[first.id]?.displayName, "Alice", "Keep old renames without applying them to incompatible evidence")
    }

    func testVoiceMatchingRejectsNaNAndDuplicateShortEvidence() throws {
        let store = SessionSpeakerIdentityStore(directory: directory, sessionID: sessionID)
        var identities = try store.load()
        var invalid = try voiceDocument(label: "S1", vector: unitVoice(0))
        invalid.voiceObservations?[0].embedding[3] = .nan
        let identity = try store.identity(rawLabel: "S1", diarization: invalid, runID: UUID(),
            provenance: voiceProvenance(startMs: 0), document: &identities)
        XCTAssertTrue(identity.id.hasPrefix("remote_local_"))
        var short = try voiceDocument(label: "S1", vector: unitVoice(0), endMs: 500)
        short.voiceObservations = Array(repeating: try XCTUnwrap(short.voiceObservations?.first), count: 128)
        let repeated = try store.identity(rawLabel: "S1", diarization: short, runID: UUID(),
            provenance: voiceProvenance(startMs: 50_000), document: &identities)
        XCTAssertTrue(repeated.id.hasPrefix("remote_local_"), "Overlapping feature windows cannot manufacture voiced duration")
    }

    func testOptionalNativeVoiceEvidenceReturnsAfterTwentyMinutesAndKeepsDistinctGroups() throws {
        guard let path = ProcessInfo.processInfo.environment["RECORDLY_NATIVE_EVIDENCE_JSON"] else {
            throw XCTSkip("Set RECORDLY_NATIVE_EVIDENCE_JSON to locally measured SDK results; no private audio/vectors are fixtures.")
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let runs = try XCTUnwrap(json["runs"] as? [[String: Any]])
        func document(_ index: Int) throws -> DiarizationDocument {
            let run = runs[index]
            let segments = try XCTUnwrap(run["segments"] as? [[String: Any]]).enumerated().map { index, value in
                DiarizationSegment(id: "native-\(index)", speaker: value["speaker"] as! String,
                    startMs: Int((value["start"] as! Double) * 1_000), endMs: Int((value["end"] as! Double) * 1_000), confidence: nil)
            }
            let labels = Set(segments.map(\.speaker))
            let observations = try XCTUnwrap(run["embeddings"] as? [[String: Any]]).compactMap { value -> DiarizationVoiceObservation? in
                let label = value["speaker"] as! String
                guard labels.contains(label) else { return nil }
                return .init(speaker: label, startMs: Int((value["start"] as! Double) * 1_000),
                    endMs: Int((value["end"] as! Double) * 1_000), embedding: (value["embedding"] as! [Double]).map(Float.init))
            }
            return DiarizationDocument(version: 1, sessionID: sessionID, createdAt: Date(), segments: segments,
                voiceObservations: observations, embeddingSpace: "native-wespeaker-256-l2", embeddingArtifactFingerprint: "diarizer-model-a")
        }
        let store = SessionSpeakerIdentityStore(directory: directory, sessionID: sessionID)
        var identities = try store.load()
        let first = try store.resolveWindow(diarization: document(0), runID: UUID(), provenance: voiceProvenance(startMs: 0), document: &identities)
        let firstID = try XCTUnwrap(first.identities.values.first?.id)
        XCTAssertTrue(firstID.hasPrefix("remote_voice_"))
        identities.identities[firstID]?.displayName = "Test speaker"
        // Different measured clip, rather than an exact repeat, exercises voice
        // matching across observations. This is not speaker accuracy ground truth.
        let differentObservation = try store.resolveWindow(diarization: document(1), runID: UUID(),
            provenance: voiceProvenance(startMs: 50_000), document: &identities)
        XCTAssertEqual(differentObservation.identities.values.first?.id, firstID)
        XCTAssertEqual(differentObservation.identities.values.first?.displayName, "Test speaker")
        let returning = try store.resolveWindow(diarization: document(2), runID: UUID(), provenance: voiceProvenance(startMs: 1_200_000), document: &identities)
        XCTAssertEqual(returning.identities.values.first?.id, firstID)
        XCTAssertEqual(returning.identities.values.first?.displayName, "Test speaker")
        let mic = try store.resolveWindow(diarization: document(3), runID: UUID(), provenance: voiceProvenance(startMs: 1_250_000), document: &identities)
        XCTAssertFalse(mic.identities.values.contains { $0.id == firstID })
        let far = try store.resolveWindow(diarization: document(4), runID: UUID(), provenance: voiceProvenance(startMs: 2_100_000), document: &identities)
        XCTAssertEqual(far.identities.count, 2)
        XCTAssertEqual(Set(far.identities.values.map(\.id)).count, 2)
    }

    func testRenameDuringReprocessingSurvivesPersistenceAndFinalRendering() async throws {
        try addAudio(track: .system, startSeconds: 0, seconds: 130)
        _ = try await process(asr: SegmentedTestASREngine())
        let id = try XCTUnwrap(readTranscript().segments.first?.speakerId)
        let store = SessionSpeakerIdentityStore(directory: directory, sessionID: sessionID)
        try store.rename(speakerID: id, to: "Alice")
        let asr = SegmentedTestASREngine()
        var calls = 0
        asr.customSegments = { _, _, _ in
            calls += 1
            if calls == 2 { try? store.rename(speakerID: id, to: "Bob") }
            return [.init(id: "speech", startMs: 10_000, endMs: 10_500, text: "Speech", confidence: nil, language: "en", words: nil)]
        }
        _ = try await process(asr: asr, modelBytes: "changed-asr")
        XCTAssertEqual(try store.load().identities[id]?.displayName, "Bob")
        XCTAssertEqual(try readTranscript().segments.first?.speaker, "Bob")
    }

    func testMissingLoadedEmbeddingArtifactCannotClaimSessionIdentity() throws {
        let store = SessionSpeakerIdentityStore(directory: directory, sessionID: sessionID)
        var identities = try store.load()
        var document = try voiceDocument(label: "S1", vector: unitVoice(0))
        document.embeddingArtifactFingerprint = nil
        let result = try store.identity(rawLabel: "S1", diarization: document, runID: UUID(),
            provenance: voiceProvenance(startMs: 0), document: &identities)
        XCTAssertTrue(result.id.hasPrefix("remote_local_"))
    }

    func testRebuildReconsidersCachedAmbiguousGroupAfterCompetingProfileDisappears() throws {
        let store = SessionSpeakerIdentityStore(directory: directory, sessionID: sessionID)
        var identities = try store.load()
        let firstProvenance = try voiceProvenance(startMs: 0)
        let first = try store.identity(rawLabel: "A", diarization: voiceDocument(label: "A", vector: unitVoice(0)),
            runID: UUID(), provenance: firstProvenance, document: &identities)
        identities.identities[first.id]?.displayName = "Alice"
        var competing = unitVoice(0); competing[0] = 0.7; competing[1] = sqrt(1 - 0.7 * 0.7)
        _ = try store.identity(rawLabel: "B", diarization: voiceDocument(label: "B", vector: competing),
            runID: UUID(), provenance: voiceProvenance(startMs: 50_000), document: &identities)
        var ambiguous = unitVoice(0); ambiguous[0] = 0.92; ambiguous[1] = sqrt(1 - 0.92 * 0.92)
        let group = try voiceDocument(label: "C", vector: ambiguous)
        let cachedRun = UUID(), cachedProvenance = try voiceProvenance(startMs: 100_000)
        let before = try store.resolveWindow(diarization: group, runID: cachedRun, provenance: cachedProvenance, document: &identities)
        XCTAssertTrue(try XCTUnwrap(before.identities["C"]).id.hasPrefix("remote_local_"))
        try store.beginRebuild(provenances: [firstProvenance, cachedProvenance], document: &identities)
        let after = try store.resolveWindow(diarization: group, runID: cachedRun, provenance: cachedProvenance, document: &identities)
        XCTAssertEqual(after.identities["C"]?.id, first.id)
        XCTAssertEqual(after.identities["C"]?.displayName, "Alice")
        XCTAssertEqual(after.voicedGroups, 1)
        XCTAssertEqual(after.unresolvedGroups, 0)
    }

    func testPaddingOnlyGroupDoesNotCountAsUnresolvedOwnedSpeech() throws {
        let store = SessionSpeakerIdentityStore(directory: directory, sessionID: sessionID)
        var identities = try store.load()
        var document = try voiceDocument(label: "S1", vector: unitVoice(0))
        document.segments.append(.init(id: "context", speaker: "S2", startMs: 52_000, endMs: 54_000, confidence: nil))
        document.voiceObservations?.append(.init(speaker: "S2", startMs: 52_000, endMs: 54_000, embedding: unitVoice(1)))
        var provenance = try voiceProvenance(startMs: 0)
        provenance.window.inputEndFrame = 55_000 * 48
        let run = UUID()
        let first = try store.resolveWindow(diarization: document, runID: run, provenance: provenance, document: &identities)
        XCTAssertEqual(first.voicedGroups, 1)
        XCTAssertEqual(first.unresolvedGroups, 0)
        XCTAssertNotEqual(first.identities["S1"]?.id, first.identities["S2"]?.id)
        let subsequentConsumer = try store.resolveWindow(diarization: document, runID: run, provenance: provenance, document: &identities)
        XCTAssertEqual(subsequentConsumer.voicedGroups, 1)
        XCTAssertEqual(subsequentConsumer.unresolvedGroups, 0)
    }

    func testRenameDuringMergingCallbackIsPublishedInAllTranscriptOutputs() async throws {
        try await assertRenameDuringPublicationCallback(.merging)
    }

    func testRenameDuringRenderingCallbackIsPublishedInAllTranscriptOutputs() async throws {
        try await assertRenameDuringPublicationCallback(.renderingOutputs)
    }

    private func assertRenameDuringPublicationCallback(_ state: TranscriptPipelineState) async throws {
        try addAudio(track: .system, startSeconds: 0, seconds: 2)
        _ = try await process(asr: SegmentedTestASREngine())
        let id = try XCTUnwrap(readTranscript().segments.first?.speakerId)
        let store = SessionSpeakerIdentityStore(directory: directory, sessionID: sessionID)
        try store.rename(speakerID: id, to: "Alice")
        var callbackInvoked = false
        _ = try await process(asr: SegmentedTestASREngine(), onStateChange: { observed in
            if observed == state {
                callbackInvoked = true
                try? store.rename(speakerID: id, to: "Bob")
            }
        })
        XCTAssertTrue(callbackInvoked)
        XCTAssertEqual(try store.load().identities[id]?.displayName, "Bob")
        XCTAssertEqual(try readTranscript().segments.first?.speaker, "Bob")
        for name in ["transcript.txt", "transcript.srt"] {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(text.contains("Bob"), "\(name) must agree with the latest published speaker name")
            XCTAssertFalse(text.contains("Alice"), "\(name) must not retain the pre-callback name")
        }
    }

    func testWordLookupKeepsLongOverlapBehindExpiredInterveningWord() async throws {
        try addAudio(track: .microphone, startSeconds: 0, seconds: 100)
        let asr = SegmentedTestASREngine()
        asr.customSegments = { url, _, _ in
            let words: [ASRWord]
            if Self.inputOffsetMs(url) == 0 {
                words = [.init(word: "Long", startMs: 49_000, endMs: 52_000, confidence: nil),
                         .init(word: "long", startMs: 49_500, endMs: 50_000, confidence: nil)]
            } else {
                words = [.init(word: "LONG", startMs: 5_000, endMs: 8_000, confidence: nil)]
            }
            return [.init(id: "words", startMs: words[0].startMs, endMs: words.last!.endMs,
                text: "long", confidence: nil, language: "en", words: words)]
        }
        _ = try await process(asr: asr)
        let words = try readTranscript().segments.flatMap { $0.words ?? [] }.sorted { $0.startMs < $1.startMs }
        XCTAssertEqual(words.map(\.startMs), [49_500, 50_000])
        XCTAssertEqual(words.map(\.endMs), [50_000, 53_000])
    }

    func testWordLookupReplacementUsesUpdatedWindowForFollowingWord() async throws {
        try addAudio(track: .microphone, startSeconds: 0, seconds: 100)
        let asr = SegmentedTestASREngine()
        asr.customSegments = { url, _, _ in
            let words: [ASRWord] = Self.inputOffsetMs(url) == 0 ?
                [.init(word: "Long", startMs: 49_000, endMs: 52_000, confidence: nil)] :
                [.init(word: "long", startMs: 5_000, endMs: 8_000, confidence: nil),
                 .init(word: "LONG", startMs: 6_000, endMs: 9_000, confidence: nil)]
            return [.init(id: "words", startMs: words[0].startMs, endMs: words.last!.endMs,
                text: "long", confidence: nil, language: "en", words: words)]
        }
        _ = try await process(asr: asr)
        let words = try readTranscript().segments.flatMap { $0.words ?? [] }.sorted { $0.startMs < $1.startMs }
        XCTAssertEqual(words.map(\.startMs), [50_000, 51_000])
        XCTAssertEqual(words.map(\.endMs), [53_000, 54_000])
    }

    func testWordLookupPreservesRepeatedTextInNonoverlappingRanges() async throws {
        try addAudio(track: .microphone, startSeconds: 0, seconds: 100)
        let asr = SegmentedTestASREngine()
        asr.customSegments = { url, _, _ in
            let start = Self.inputOffsetMs(url) == 0 ? 10_000 : 15_000
            return [.init(id: "words", startMs: start, endMs: start + 1_000,
                text: "Yes", confidence: nil, language: "en", words: [
                    .init(word: "Yes", startMs: start, endMs: start + 1_000, confidence: nil)])]
        }
        _ = try await process(asr: asr)
        let words = try readTranscript().segments.flatMap { $0.words ?? [] }.sorted { $0.startMs < $1.startMs }
        XCTAssertEqual(words.map(\.word), ["Yes", "Yes"])
        XCTAssertEqual(words.map(\.startMs), [10_000, 60_000])
    }

    private func unitVoice(_ index: Int) -> [Float] {
        var value = [Float](repeating: 0, count: 256); value[index] = 1; return value
    }

    private func voiceDocument(label: String, vector: [Float], startMs: Int = 0, endMs: Int = 10_000) throws -> DiarizationDocument {
        let base = DiarizationDocument(version: 1, sessionID: sessionID, createdAt: Date(), segments: [
            DiarizationSegment(id: label, speaker: label, startMs: startMs, endMs: endMs, confidence: 0.9)])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        json["embeddingArtifactFingerprint"] = "diarizer-model-a"
        json["embeddingSpace"] = "test-wespeaker-256-v1"
        json["voiceObservations"] = [["speaker": label, "startMs": startMs, "endMs": endMs, "embedding": vector]]
        return try JSONDecoder().decode(DiarizationDocument.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func voiceProvenance(startMs: Int, artifact: String? = "diarizer-model-a") throws -> WindowInferenceProvenance {
        let manifest = SessionAudioManifest(sessionID: sessionID, hostTimeOrigin: 0)
        let window = InferenceWindow(track: .system, ownershipStartFrame: Int64(startMs) * 48,
            ownershipEndFrame: Int64(startMs + 50_000) * 48, inputStartFrame: Int64(startMs) * 48,
            inputEndFrame: Int64(startMs + 50_000) * 48)
        let profile = InferenceRuntimeProfile(stageSelection: .defaultLocal,
            modelArtifacts: .init(asrModelURL: nil, diarizationModelURL: nil, summarizationModelURL: nil),
            summarizationRuntimeSettings: .default)
        return WindowInferenceProvenance(manifest: manifest, window: window, profile: profile,
            asrArtifactFingerprint: "asr", asrEngineFingerprint: "asr", diarizationArtifactFingerprint: artifact,
            settings: InferenceWindowSettings())
    }

    private func processLegacy(asr: SegmentedTestASREngine, diarization: SegmentedTestDiarizationEngine = SegmentedTestDiarizationEngine()) async throws -> TranscriptionResult {
        try addAudio(track: .microphone, startSeconds: 0, seconds: 2)
        try addAudio(track: .system, startSeconds: 0, seconds: 2)
        let store = SessionAudioStore(directory: directory, sessionID: sessionID)
        for segment in try store.load().segments {
            try FileManager.default.copyItem(at: store.finalURL(for: segment), to: directory.appendingPathComponent(segment.track == .microphone ? "mic.m4a" : "system.m4a"))
        }
        let model = directory.appendingPathComponent("legacy-model")
        try Data("model".utf8).write(to: model)
        let recording = RecordingSession(id: sessionID, title: "Legacy", createdAt: Date(), duration: 2,
            lifecycleState: .processing, transcriptState: .queued, source: .liveCapture, notes: "",
            assets: RecordingAssets(microphoneFile: "mic.m4a", systemAudioFile: "system.m4a"))
        let profile = InferenceRuntimeProfile(stageSelection: .defaultLocal,
            modelArtifacts: InferenceModelArtifacts(asrModelURL: model, diarizationModelURL: nil, summarizationModelURL: nil), summarizationRuntimeSettings: .default)
        return try await TranscriptionPipeline(mode: .legacyFullFileDebug).process(recording: recording, in: directory,
            runtimeProfile: profile, engineFactory: SegmentedTestEngineFactory(asr: asr, diarization: diarization))
    }

    private static func inputOffsetMs(_ url: URL) -> Int {
        let ownerFrame = Int64(url.deletingPathExtension().lastPathComponent.split(separator: "-")[1]) ?? 0
        return Int(max(0, ownerFrame / 48 - 5_000))
    }

    private func readReport() throws -> SegmentedInferenceReport {
        try JSONDecoder().decode(SegmentedInferenceReport.self, from: Data(contentsOf: directory.appendingPathComponent("inference/report.json")))
    }

    private func process(asr: SegmentedTestASREngine, diarization: SegmentedTestDiarizationEngine = SegmentedTestDiarizationEngine(), modelBytes: String = "model-v1", diarizationModelURL: URL? = nil, overrideDirectory: URL? = nil, overrideSessionID: UUID? = nil, onProgress: (@MainActor (TranscriptProcessingProgress) -> Void)? = nil, onStateChange: (@MainActor (TranscriptPipelineState) -> Void)? = nil) async throws -> TranscriptionResult {
        let directory = overrideDirectory ?? self.directory!
        let sessionID = overrideSessionID ?? self.sessionID
        let model = directory.appendingPathComponent("test-model")
        try Data(modelBytes.utf8).write(to: model)
        let recording = RecordingSession(id: sessionID, title: "Segmented", createdAt: Date(), duration: 130,
            lifecycleState: .processing, transcriptState: .queued, source: .liveCapture, notes: "",
            assets: RecordingAssets(audioManifestFile: "audio-manifest.json", audioTracks: ["microphone", "system"]))
        let profile = InferenceRuntimeProfile(stageSelection: .defaultLocal,
            modelArtifacts: InferenceModelArtifacts(asrModelURL: model, diarizationModelURL: diarizationModelURL, summarizationModelURL: nil),
            summarizationRuntimeSettings: .default)
        return try await TranscriptionPipeline().process(recording: recording, in: directory, runtimeProfile: profile,
            engineFactory: SegmentedTestEngineFactory(asr: asr, diarization: diarization), onStateChange: onStateChange, onProgress: onProgress)
    }

    private func readTranscript(in overrideDirectory: URL? = nil) throws -> TranscriptDocument {
        let directory = overrideDirectory ?? self.directory!
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptDocument.self, from: Data(contentsOf: directory.appendingPathComponent("transcript.json")))
    }

    private func addAudio(track: TrackKind, startSeconds: Int, seconds: Int) throws {
        let store = SessionAudioStore(directory: directory, sessionID: sessionID)
        let segment = SessionAudioSegment(track: track, index: startSeconds, startFrame: Int64(startSeconds) * 48_000, frameCount: Int64(seconds) * 48_000)
        try store.prepare(segment)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for i in 0..<48_000 { buffer.floatChannelData![0][i] = 0.05 * sin(Float(i) * 0.01) }
        let file = try AVAudioFile(forWriting: store.pendingURL(for: segment), settings: PCMTrackWriter.fileSettings(for: store.pendingURL(for: segment)), commonFormat: .pcmFormatFloat32, interleaved: false)
        for _ in 0..<seconds { try file.write(from: buffer) }
        file.close()
        try store.publish(segment)
    }
}

private final class SegmentedTestASREngine: ASREngine {
    let displayName = "Segmented test ASR"
    var durations: [Double] = []
    let failingChannel: TranscriptChannel?
    let cancels: Bool
    var attempts = 0
    var cancellingChannel: TranscriptChannel?
    var failingAttempts = Set<Int>()
    var customSegments: ((URL, TranscriptChannel, Double) -> [ASRSegment])?
    init(failingChannel: TranscriptChannel? = nil, cancels: Bool = false) { self.failingChannel = failingChannel; self.cancels = cancels }
    func transcribe(audioURL: URL, channel: TranscriptChannel, sessionID: UUID, configuration: ASREngineConfiguration) async throws -> ASRDocument {
        attempts += 1
        if cancels || cancellingChannel == channel { throw ASREngineRuntimeError.cancelled }
        if failingAttempts.contains(attempts) { throw ASREngineRuntimeError.inferenceFailed(message: "window fixture failure") }
        if failingChannel == channel { throw ASREngineRuntimeError.inferenceFailed(message: "fixture failure") }
        let audio = try AVAudioFile(forReading: audioURL)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        durations.append(duration)
        let start = min(Int(duration * 500), 10_000)
        return ASRDocument(version: 1, sessionID: sessionID, channel: channel, createdAt: Date(), segments: customSegments?(audioURL, channel, duration) ?? [
            ASRSegment(id: "backend-reused-id", startMs: start, endMs: start + 500, text: "Window \(durations.count) speech", confidence: nil, language: "en", words: nil)
        ])
    }
}

private final class SegmentedTestDiarizationEngine: DiarizationEngine {
    var fails: Bool
    var cancels: Bool
    var rawLabel: String
    var customSegments: [DiarizationSegment]?
    var customDocument: DiarizationDocument?
    var timesOut = false
    var attempts = 0
    init(fails: Bool = false, cancels: Bool = false, rawLabel: String = "speaker_0") {
        self.fails = fails; self.cancels = cancels; self.rawLabel = rawLabel
    }
    func diarize(systemAudioURL: URL, sessionID: UUID, configuration: DiarizationEngineConfiguration) async throws -> DiarizationDocument {
        attempts += 1
        if timesOut { throw DiarizationRuntimeError.timedOut }
        if cancels { throw DiarizationRuntimeError.cancelled }
        if fails { throw DiarizationRuntimeError.nonZeroExit(code: 1, stderr: "fixture diarization failure") }
        if var customDocument { customDocument.sessionID = sessionID; return customDocument }
        return DiarizationDocument(version: 1, sessionID: sessionID, createdAt: Date(), segments: customSegments ?? [DiarizationSegment(id: "local-0", speaker: rawLabel, startMs: 0, endMs: 60_000, confidence: 0.9)])
    }
}

private final class CancellationResistantDiarizationManager: OfflineDiarizationManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<OfflineDiarizationResult, Error>] = []
    private var active = 0
    private var calls = 0
    private var maximum = 0
    var callCount: Int { lock.withLock { calls } }
    var maxActive: Int { lock.withLock { maximum } }
    func prepareModels() async throws {}
    func process(audio: [Float]) async throws -> OfflineDiarizationResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                calls += 1; active += 1; maximum = max(maximum, active)
                continuations.append(continuation)
            }
        }
    }
    func finishAll() {
        let pending = lock.withLock { let values = continuations; continuations = []; active = 0; return values }
        for continuation in pending { continuation.resume(returning: OfflineDiarizationResult(segments: [
            OfflineDiarizationSegment(speakerId: "speaker_0", startTimeSeconds: 0, endTimeSeconds: 1, qualityScore: 0.9)])) }
    }
}

private struct SegmentedTestEngineFactory: InferenceEngineFactory {
    let asr: SegmentedTestASREngine
    let diarization: SegmentedTestDiarizationEngine
    @MainActor func makeAudioCaptureEngine(for profile: InferenceRuntimeProfile) throws -> any AudioCaptureEngine { throw InferenceEngineFactoryError.unsupportedBackend(stage: .audioCapture, backend: .disabled) }
    func makeASREngine(for profile: InferenceRuntimeProfile) throws -> any ASREngine { asr }
    @MainActor func makeDiarizationEngine(for profile: InferenceRuntimeProfile) throws -> any DiarizationEngine { diarization }
    func makeSystemChunkTranscriptionEngine(for profile: InferenceRuntimeProfile) throws -> (any SystemChunkTranscriptionEngine)? { nil }
    func makeSummarizationEngine(for profile: InferenceRuntimeProfile) throws -> any SummarizationEngine { throw InferenceEngineFactoryError.unsupportedBackend(stage: .summarization, backend: .disabled) }
    func makeVoiceActivityDetectionEngine(for profile: InferenceRuntimeProfile) throws -> (any VoiceActivityDetectionEngine)? { nil }
    func transcriptionEngineDisplayName(for stageSelection: StageRuntimeSelection) -> String { "Fixture" }
}

private final class SegmentedOfflineDiarizationManager: OfflineDiarizationManaging, @unchecked Sendable {
    func prepareModels() async throws {}
    func process(audio: [Float]) async throws -> OfflineDiarizationResult {
        OfflineDiarizationResult(segments: [OfflineDiarizationSegment(speakerId: "speaker_0", startTimeSeconds: 0, endTimeSeconds: 1, qualityScore: 0.9)])
    }
}

private final class SegmentedAlwaysExistingFileManager: FileManager, @unchecked Sendable {
    override func fileExists(atPath path: String) -> Bool { true }
}

private struct SegmentedImmediateAudioLoader: FluidAudioSessionAudioLoading {
    func loadAudio(from audioURL: URL) throws -> PreparedSessionAudio {
        PreparedSessionAudio(samples: [0.1, 0.2], sampleRate: 16_000, durationMs: 1, sourceURL: audioURL)
    }
}

@MainActor
private struct ProgressTestProfileSelector: InferenceRuntimeProfileSelecting {
    let profile: InferenceRuntimeProfile
    func transcriptionAvailability(for profile: ModelProfile) -> TranscriptionAvailability { .ready }
    func resolveTranscriptionProfile(for profile: ModelProfile) throws -> InferenceRuntimeProfile { self.profile }
    func resolveSummarizationProfile(for profile: ModelProfile) throws -> InferenceRuntimeProfile {
        XCTFail("Summarization must not be resolved by transcription")
        return self.profile
    }
}

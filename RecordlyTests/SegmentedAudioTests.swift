import AVFoundation
import XCTest
@testable import Recordly

final class SegmentedAudioTests: XCTestCase {
    func testSlowPublicationHasBoundedBacklogAndStopDrainsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = DispatchSemaphore(value: 0)
        var store = SessionAudioStore(directory: root, sessionID: UUID())
        store.faultInjector = { point in if point == "before-rename" { gate.wait() } }
        let writer = SegmentedTrackWriter(kind: .system, store: store, committer: SessionAudioCommitter(store: store), chunkDuration: 0.1, maximumPendingFinalizations: 1)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        buffer.floatChannelData![0].initialize(repeating: 0.1, count: 4_800)
        try await writer.append(pcmBuffer: buffer, presentationTime: .zero)
        try await writer.append(pcmBuffer: buffer, presentationTime: CMTime(seconds: 0.1, preferredTimescale: 48_000))
        do {
            try await writer.append(pcmBuffer: buffer, presentationTime: CMTime(seconds: 0.2, preferredTimescale: 48_000))
            XCTFail("Unbounded publication backlog must not be accepted")
        } catch SessionAudioError.rotationBacklog { }
        gate.signal()
        gate.signal()
        let stats = await writer.finalize()
        XCTAssertTrue(stats.diagnostics.isEmpty)
        XCTAssertEqual(try store.load().segments.count, 2)
    }

    func testRotationWriteFailurePreservesReadablePrefix() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionAudioStore(directory: root, sessionID: UUID())
        let writer = SegmentedTrackWriter(kind: .system, store: store, committer: SessionAudioCommitter(store: store), chunkDuration: 0.1)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        buffer.floatChannelData![0].initialize(repeating: 0.1, count: 4_800)
        try await writer.append(pcmBuffer: buffer, presentationTime: .zero)
        let trackDirectory = root.appendingPathComponent("audio/system")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: trackDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: trackDirectory.path) }
        do {
            try await writer.append(pcmBuffer: buffer, presentationTime: CMTime(seconds: 0.1, preferredTimescale: 48_000))
            XCTFail("Expected a real filesystem write failure")
        } catch { XCTAssertTrue(CaptureWriteFailurePolicy.isTerminal(error)) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: trackDirectory.path)
        let stats = await writer.finalize()
        XCTAssertEqual(stats.framesWritten, 4_800)
        XCTAssertEqual(try store.load().segments.count, 1)
        XCTAssertEqual(try store.reconcile().segments.first?.state, .committed)
    }

    func testAACChunkBoundaryWaveformMatchesContinuousReference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionAudioStore(directory: root, sessionID: UUID())
        let writer = SegmentedTrackWriter(kind: .system, store: store, committer: SessionAudioCommitter(store: store), chunkDuration: 0.25, maximumPendingFinalizations: 4)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let full = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        full.frameLength = 48_000
        for frame in 0..<48_000 { full.floatChannelData![0][frame] = Float(sin(Double(frame) * 2 * .pi * 220 / 48_000)) * 0.1 }
        for index in 0..<4 {
            let part = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12_000)!
            part.frameLength = 12_000
            part.floatChannelData![0].update(from: full.floatChannelData![0] + index * 12_000, count: 12_000)
            try await writer.append(pcmBuffer: part, presentationTime: CMTime(seconds: Double(index) * 0.25, preferredTimescale: 48_000))
        }
        _ = await writer.finalize()
        let referenceURL = root.appendingPathComponent("reference.m4a")
        let referenceWriter = try PCMTrackWriter(kind: .system, fileName: "reference.m4a", fileURL: referenceURL)
        try await referenceWriter.append(pcmBuffer: full)
        _ = await referenceWriter.finalize()
        let reference = try AVAudioFile(forReading: referenceURL)
        let expected = AVAudioPCMBuffer(pcmFormat: reference.processingFormat, frameCapacity: 48_000)!
        try reference.read(into: expected)
        let actual = try SessionAudioRangeReader(manifest: store.load(), directory: root).read(track: .system, startFrame: 0, frameCount: 48_000)
        var squares: Double = 0
        for frame in 0..<48_000 { let delta = Double(actual.floatChannelData![0][frame] - expected.floatChannelData![0][frame]); squares += delta * delta }
        XCTAssertEqual(actual.frameLength, expected.frameLength)
        XCTAssertLessThan(sqrt(squares / 48_000), 0.01, "Chunk priming must not shift the waveform on the session timeline")
    }
    @MainActor
    func testPlaybackReloadsAfterManifestAddsRecoveredAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let store = SessionAudioStore(directory: root, sessionID: id)
        let first = SessionAudioSegment(track: .system, index: 0, startFrame: 0, frameCount: 4_800)
        try store.prepare(first)
        try writeAudio(to: store.pendingURL(for: first), frames: 4_800)
        try store.publish(first)
        var recording = RecordingSession.draft(index: 1)
        recording = RecordingSession(id: id, title: "Reload", createdAt: Date(), duration: 0.1, lifecycleState: .ready,
                                     transcriptState: .idle, source: .liveCapture, notes: "", assets: RecordingAssets(audioManifestFile: "audio-manifest.json", audioTracks: ["system"]))
        let repository = InMemoryRecordingsRepository(recordings: [recording], sessionDirectories: [id: root])
        let controller = PlaybackController(repository: repository, previewMode: false)
        controller.syncSelection(recording)
        try await controller.seek(for: recording, to: 0)
        XCTAssertEqual(controller.state.duration, 0.1, accuracy: 0.001)
        let second = SessionAudioSegment(track: .system, index: 1, startFrame: 4_800, frameCount: 4_800)
        try store.prepare(second)
        try writeAudio(to: store.pendingURL(for: second), frames: 4_800)
        try store.publish(second)
        controller.syncSelection(recording)
        try await controller.seek(for: recording, to: 0.75)
        XCTAssertEqual(controller.state.duration, 0.2, accuracy: 0.001)
        XCTAssertEqual(controller.state.currentTime, 0.15, accuracy: 0.005)
        controller.stop(resetPosition: true)
    }
    func testMetadataFailuresCannotBypassSourceStopOrEitherWriterClose() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        buffer.floatChannelData![0].initialize(repeating: 0.1, count: 4_800)
        var writers: [MirroredTrackWriter] = []
        for kind in [TrackKind.microphone, .system] {
            let writer = try PCMTrackWriter(kind: kind, fileName: "\(kind.rawValue).m4a", fileURL: root.appendingPathComponent("\(kind.rawValue).m4a"))
            try await writer.append(pcmBuffer: buffer)
            writers.append(MirroredTrackWriter(temporary: writer, durable: nil))
        }
        var stopped = false
        var drained = false
        let result = await CaptureFinalizationCoordinator.finish(stopSources: { stopped = true }, drainSources: { drained = true }, beginMetadata: {
            XCTAssertTrue(stopped)
            throw CocoaError(.fileWriteOutOfSpace)
        }, writers: writers, updateMetadata: { _ in
            XCTAssertTrue(stopped && drained)
            throw CocoaError(.fileWriteOutOfSpace)
        })
        XCTAssertEqual(result.tracks.count, 2)
        XCTAssertEqual(result.persistenceDiagnostics.count, 3)
        for kind in [TrackKind.microphone, .system] { XCTAssertEqual(try AVAudioFile(forReading: root.appendingPathComponent("\(kind.rawValue).m4a")).length, 4_800) }
        XCTAssertFalse(CaptureWriteFailurePolicy.isTerminal(SessionAudioError.invalidInput))
        XCTAssertTrue(CaptureWriteFailurePolicy.isTerminal(SessionAudioError.invalidMetadata))
        XCTAssertFalse(CaptureWriteFailurePolicy.isTerminal(PCMWriterError.conversionFailed))
        XCTAssertTrue(CaptureWriteFailurePolicy.isTerminal(CocoaError(.fileWriteOutOfSpace)))
    }
    func testFractionalResamplingDoesNotAccumulateFrameDrift() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionAudioStore(directory: root, sessionID: UUID())
        let writer = SegmentedTrackWriter(kind: .microphone, store: store, committer: SessionAudioCommitter(store: store))
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_048)!
        buffer.frameLength = 2_048
        buffer.floatChannelData![0].initialize(repeating: 0.1, count: 2_048)
        for index in 0..<100 {
            try await writer.append(pcmBuffer: buffer, presentationTime: CMTime(seconds: Double(index * 2_048) / 44_100, preferredTimescale: 1_000_000_000))
        }
        let stats = await writer.finalize()
        XCTAssertEqual(Double(stats.framesWritten), (100 * 2_048 * 48_000.0 / 44_100).rounded(), accuracy: 1)
        XCTAssertTrue(stats.diagnostics.isEmpty, "\(stats.diagnostics)")
    }
    func testResampledCaptureKeepsFullDurationAcrossCallbacksAndStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionAudioStore(directory: root, sessionID: UUID())
        let writer = SegmentedTrackWriter(kind: .microphone, store: store, committer: SessionAudioCommitter(store: store))
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)!
        buffer.frameLength = 4_410
        for frame in 0..<4_410 { buffer.floatChannelData![0][frame] = Float(sin(Double(frame) * 0.1)) * 0.1 }
        for index in 0..<10 { try await writer.append(pcmBuffer: buffer, presentationTime: CMTime(seconds: Double(index) * 0.1, preferredTimescale: 48_000)) }
        let stats = await writer.finalize()
        XCTAssertEqual(stats.framesWritten, 48_000)
        XCTAssertTrue(stats.diagnostics.isEmpty, "\(stats.diagnostics)")
    }
    func testLargeCaptureBufferAndFormatChangeKeepValidFrames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionAudioStore(directory: root, sessionID: UUID())
        let writer = SegmentedTrackWriter(kind: .microphone, store: store, committer: SessionAudioCommitter(store: store))
        let mono = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let first = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 48_000)!
        first.frameLength = 48_000
        first.floatChannelData![0].initialize(repeating: 0.1, count: 48_000)
        try await writer.append(pcmBuffer: first, presentationTime: .zero)
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let second = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4_800)!
        second.frameLength = 4_800
        for channel in 0..<2 { second.floatChannelData![channel].initialize(repeating: 0.1, count: 4_800) }
        try await writer.append(pcmBuffer: second, presentationTime: CMTime(seconds: 1, preferredTimescale: 48_000))
        let stats = await writer.finalize()
        XCTAssertEqual(stats.framesWritten, 52_800)
        XCTAssertTrue(stats.diagnostics.isEmpty)
        XCTAssertEqual(try store.load().segments.first?.frameCount, 52_800)
    }

    func testDefaultAACStorageAndRotationMeasurements() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionAudioStore(directory: root, sessionID: UUID())
        let committer = SessionAudioCommitter(store: store)
        let writers = [SegmentedTrackWriter(kind: .microphone, store: store, committer: committer),
                       SegmentedTrackWriter(kind: .system, store: store, committer: committer)]
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        for frame in 0..<4_800 { buffer.floatChannelData![0][frame] = Float(sin(Double(frame) * 0.1)) * 0.1 }
        var ordinary: [Double] = []
        var rotations: [Double] = []
        let began = Date()
        for index in 0..<1_810 {
            for writer in writers {
                let started = Date()
                try await writer.append(pcmBuffer: buffer, presentationTime: CMTime(value: Int64(index * 4_800), timescale: 48_000))
                let milliseconds = Date().timeIntervalSince(started) * 1_000
                if index == 1_800 { rotations.append(milliseconds) }
                else { ordinary.append(milliseconds) }
            }
        }
        for writer in writers {
            let stats = await writer.finalize()
            XCTAssertTrue(stats.diagnostics.isEmpty)
        }
        let manifest = try store.load()
        XCTAssertEqual(manifest.segments.count, 4)
        XCTAssertEqual(manifest.durationFrames, 48_000 * 181)
        let bytes = try manifest.segments.reduce(0) { sum, segment in sum + (try store.finalURL(for: segment).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        ordinary.sort()
        let perHour = Double(bytes) / 181 * 3_600 / 1_000_000
        print("V2_MEASURE fixture_seconds=181 tracks=2 bytes=\(bytes) MB_per_hour=\(perHour) encode_wall_seconds=\(Date().timeIntervalSince(began)) append_p95_ms=\(ordinary[Int(Double(ordinary.count - 1) * 0.95)]) rotation_max_ms=\(rotations.max() ?? 0)")
        XCTAssertLessThan(perHour, 150)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("mic.raw.caf").path))
    }
    func testForcedProcessCrashRetainsCommittedPrefixAndRecoversOrphans() async throws {
        for point in ["active-write", "rotation-handoff", "before-rename", "after-rename", "before-manifest"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let id = UUID()
            let child = Process()
            child.executableURL = try XCTUnwrap(Bundle.main.executableURL)
            var environment = ProcessInfo.processInfo.environment
            environment["RECORDLY_CRASH_FIXTURE_DIRECTORY"] = root.path
            environment["RECORDLY_CRASH_FIXTURE_POINT"] = point
            environment["RECORDLY_CRASH_FIXTURE_ID"] = id.uuidString
            environment.removeValue(forKey: "XCTestConfigurationFilePath")
            child.environment = environment
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            for _ in 0..<1_000 {
                if !child.isRunning { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            if child.isRunning { child.terminate(); XCTFail("Crash fixture hung at \(point)") }
            child.waitUntilExit()
            XCTAssertEqual(child.terminationReason, .uncaughtSignal, point)
            XCTAssertEqual(child.terminationStatus, 9, point)
            let recovered = try SessionAudioStore(directory: root, sessionID: id).reconcile()
            XCTAssertEqual(recovered.segments.first?.state, .committed, point)
            XCTAssertEqual(recovered.segments.first?.frameCount, 4_800, point)
            if !["active-write", "rotation-handoff"].contains(point) {
                XCTAssertEqual(recovered.segments.filter { $0.state == .committed }.count, 2, point)
            }
            let repeated = try SessionAudioStore(directory: root, sessionID: id).reconcile()
            XCTAssertEqual(repeated.segments, recovered.segments, "Recovery must be idempotent: \(point)")
        }
    }
    func testCompositionPreservesLateTrackGapAndMissingTail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionAudioStore(directory: root, sessionID: UUID())
        for (index, start) in [Int64(4_800), Int64(14_400)].enumerated() {
            let segment = SessionAudioSegment(track: .system, index: index, startFrame: start, frameCount: 4_800)
            try store.prepare(segment)
            try writeAudio(to: store.pendingURL(for: segment), frames: 4_800)
            try store.publish(segment)
        }
        var manifest = try store.load()
        var tail = SessionAudioSegment(track: .system, index: 2, startFrame: 19_200, frameCount: 4_800)
        tail.state = .missing
        manifest.segments.append(tail)
        let composition = try await SessionAudioComposition.make(manifest: manifest, directory: root, source: .system)
        let duration = try await composition.load(.duration)
        XCTAssertEqual(duration.seconds, 0.5, accuracy: 1.0 / 48_000)
        let tracks = try await composition.loadTracks(withMediaType: .audio)
        let segments = try await tracks[0].load(.segments)
        XCTAssertEqual(segments.filter { !$0.isEmpty }.count, 2)
        XCTAssertEqual(segments.filter { !$0.isEmpty }.map { $0.timeMapping.target.start.seconds }, [0.1, 0.3])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("merged-call.m4a").path))
        let exported = root.appendingPathComponent("requested-export.m4a")
        try await SessionAudioComposition.export(manifest: manifest, directory: root, to: exported)
        XCTAssertEqual(try AVAudioFile(forReading: exported).length, 24_000)
    }
    func testRangeReaderPreservesGapBetweenChunks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionAudioStore(directory: root, sessionID: UUID())
        for (index, start) in [Int64(0), Int64(9_600)].enumerated() {
            let segment = SessionAudioSegment(track: .system, index: index, startFrame: start, frameCount: 4_800)
            try store.prepare(segment)
            try writeAudio(to: store.pendingURL(for: segment), frames: 4_800)
            try store.publish(segment)
        }
        let reader = SessionAudioRangeReader(manifest: try store.load(), directory: root)
        let buffer = try reader.read(track: .system, startFrame: 0, frameCount: 14_400)
        XCTAssertEqual(buffer.frameLength, 14_400)
        XCTAssertGreaterThan(abs(buffer.floatChannelData![0][100]), 0.001)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0] + 4_800, count: 4_800)), Array(repeating: 0, count: 4_800))
        XCTAssertGreaterThan(abs(buffer.floatChannelData![0][9_700]), 0.001)
        XCTAssertThrowsError(try reader.read(track: .system, startFrame: 0, frameCount: 48_000 * 61))
    }

    func testWriterRotatesAACAndPreservesLateTrackOffset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionAudioStore(directory: root, sessionID: UUID(), hostTimeOrigin: 100)
        let writer = SegmentedTrackWriter(kind: .microphone, store: store,
                                         committer: SessionAudioCommitter(store: store), chunkDuration: 0.05,
                                         maximumPendingFinalizations: 4)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        for i in 0..<4 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_400)!
            buffer.frameLength = 2_400
            for f in 0..<2_400 { buffer.floatChannelData![0][f] = 0.1 }
            do {
                try await writer.append(pcmBuffer: buffer, presentationTime: CMTime(seconds: 101 + Double(i) * 0.05, preferredTimescale: 48_000))
            } catch {
                _ = await writer.finalize()
                XCTFail("Append \(i) failed: \(error)")
                return
            }
        }
        let stats = await writer.finalize()
        XCTAssertTrue(stats.diagnostics.isEmpty, "\(stats.diagnostics)")
        let manifest = try store.load()
        XCTAssertEqual(manifest.segments.count, 4)
        XCTAssertEqual(manifest.segments.first?.startFrame, 48_000)
        XCTAssertEqual(manifest.segments.map(\.frameCount), [2_400, 2_400, 2_400, 2_400])
        XCTAssertEqual(manifest.durationFrames, 57_600)
        for segment in manifest.segments {
            let audio = try AVAudioFile(forReading: store.finalURL(for: segment))
            XCTAssertEqual(audio.length, segment.frameCount, "AAC valid frames must trim priming/padding")
        }
    }

    func testRecoveredOrphanKeepsSessionOffsetWithMissingManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionAudioStore(directory: root, sessionID: UUID())
        let segment = SessionAudioSegment(track: .system, index: 0, startFrame: 48_000, frameCount: 4_800)
        try store.prepare(segment)
        try writeAudio(to: store.pendingURL(for: segment), frames: 4_800)
        try store.publish(segment)
        try FileManager.default.removeItem(at: store.manifestURL)
        let recovered = try store.reconcile()
        XCTAssertEqual(recovered.segments.count, 1)
        XCTAssertEqual(recovered.segments[0].startFrame, 48_000)
        XCTAssertEqual(recovered.segments[0].frameCount, 4_800)
        XCTAssertEqual(recovered.segments[0].state, .committed)
    }

    func testReopeningStorePreservesOriginalTimelineOrigin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let store = SessionAudioStore(directory: root, sessionID: id, hostTimeOrigin: 100)
        let segment = SessionAudioSegment(track: .system, index: 0, startFrame: 0, frameCount: 4_800)
        try store.prepare(segment)
        try writeAudio(to: store.pendingURL(for: segment), frames: 4_800)
        try store.publish(segment)
        let reopened = SessionAudioStore(directory: root, sessionID: id)
        _ = try reopened.reconcile()
        try FileManager.default.removeItem(at: reopened.manifestURL)
        XCTAssertEqual(try reopened.reconcile().hostTimeOrigin, 100)
    }

    func testMissingChunkRemainsAnExplicitGap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionAudioStore(directory: root, sessionID: UUID())
        let segment = SessionAudioSegment(track: .microphone, index: 0, startFrame: 0, frameCount: 4_800)
        try store.prepare(segment)
        try writeAudio(to: store.pendingURL(for: segment), frames: 4_800)
        try store.publish(segment)
        try FileManager.default.removeItem(at: store.finalURL(for: segment))
        let recovered = try store.reconcile()
        XCTAssertEqual(recovered.segments[0].state, .missing)
        XCTAssertEqual(recovered.durationFrames, 4_800)
    }

    func testUnsafeSegmentPathIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionAudioStore(directory: root, sessionID: UUID())
        var segment = SessionAudioSegment(track: .system, index: 0, startFrame: 0, frameCount: 1)
        segment.fileName = "../outside.m4a"
        XCTAssertThrowsError(try store.prepare(segment))
    }

    func testDeclaredFrameMismatchCannotBeCommitted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionAudioStore(directory: root, sessionID: UUID())
        let segment = SessionAudioSegment(track: .system, index: 0, startFrame: 0, frameCount: 9_600)
        try store.prepare(segment)
        try writeAudio(to: store.pendingURL(for: segment), frames: 4_800)
        XCTAssertThrowsError(try store.publish(segment))
        XCTAssertEqual(try store.reconcile().segments[0].state, .invalid)
    }

    func testDuplicateTimestampIsRejectedWithoutExtendingTimeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionAudioStore(directory: root, sessionID: UUID())
        let writer = SegmentedTrackWriter(kind: .system, store: store, committer: SessionAudioCommitter(store: store))
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        for f in 0..<4_800 { buffer.floatChannelData![0][f] = 0.1 }
        try await writer.append(pcmBuffer: buffer, presentationTime: .zero)
        do {
            try await writer.append(pcmBuffer: buffer, presentationTime: .zero)
            XCTFail("Duplicate capture buffer must not extend audio")
        } catch {}
        _ = await writer.finalize()
        XCTAssertEqual(try store.load().durationFrames, 4_800)
    }

    func testOrphanWithoutTimingSidecarIsReportedAndPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionAudioStore(directory: root, sessionID: UUID())
        let segment = SessionAudioSegment(track: .system, index: 0, startFrame: 48_000, frameCount: 4_800)
        try store.prepare(segment)
        try writeAudio(to: store.pendingURL(for: segment), frames: 4_800)
        try store.publish(segment)
        try FileManager.default.removeItem(at: store.manifestURL)
        try FileManager.default.removeItem(at: store.finalURL(for: segment).appendingPathExtension("json"))
        let manifest = try store.reconcile()
        XCTAssertTrue(manifest.diagnostics.contains { $0.contains("Unplaced audio") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.finalURL(for: segment).path))
    }

    private func writeAudio(to url: URL, frames: AVAudioFrameCount) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.1)) * 0.1 }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000
        ])
        try file.write(from: buffer)
        file.close()
    }
}

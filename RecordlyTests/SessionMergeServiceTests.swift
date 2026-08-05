import AVFoundation
import XCTest
@testable import Recordly

final class SessionMergeServiceTests: XCTestCase {
    private var directory: URL!
    private var metadataStore: SessionMetadataStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionMergeServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        metadataStore = SessionMetadataStore()
        try await metadataStore.createSession(id: UUID(), in: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private static let sampleRate = PCMTrackWriter.canonicalSampleRate
    private static let sampleAccuracy: Float = 0.05
    private static let edgeSkipFrames = 2048

    @discardableResult
    private func writeAudioFile(
        named fileName: String,
        frames: Int,
        value: Float,
        settings: [String: Any]? = nil
    ) throws -> URL {
        let url = directory.appendingPathComponent(fileName)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: PCMTrackWriter.canonicalChannels,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
           let channel = buffer.floatChannelData?[0] else {
            throw DirectPCMMixService.MixError.invalidOutputFormat
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: settings ?? PCMTrackWriter.fileSettings(for: url),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        buffer.frameLength = AVAudioFrameCount(frames)
        channel.initialize(repeating: value, count: frames)
        try file.write(from: buffer)
        return url
    }

    private func seedTrack(
        kind: TrackKind,
        fileName: String,
        frames: Int64,
        firstPTS: Double = 0,
        lastPTS: Double? = nil,
        diagnostics: [String] = []
    ) async throws {
        try await metadataStore.updateTrack(
            TrackRuntimeStats(
                kind: kind,
                fileName: fileName,
                firstPTS: firstPTS,
                lastPTS: lastPTS ?? (firstPTS + Double(frames) / Self.sampleRate),
                framesWritten: frames,
                sampleRate: Self.sampleRate,
                bufferCount: 1,
                fallback: false,
                diagnostics: diagnostics
            ),
            in: directory
        )
    }

    private func readAllSamples(at url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw DirectPCMMixService.MixError.invalidOutputFormat
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw DirectPCMMixService.MixError.invalidOutputFormat
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private func assertRegion(
        _ samples: [Float],
        from start: Int,
        to end: Int,
        equals expected: Float,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let safeStart = max(start + Self.edgeSkipFrames, 0)
        let safeEnd = min(end - Self.edgeSkipFrames, samples.count)
        guard safeStart < safeEnd else {
            XCTFail("Region [\(start), \(end)) too small to assert", file: file, line: line)
            return
        }
        let region = samples[safeStart..<safeEnd]
        XCTAssertEqual(region.min() ?? 0, expected, accuracy: Self.sampleAccuracy, file: file, line: line)
        XCTAssertEqual(region.max() ?? 0, expected, accuracy: Self.sampleAccuracy, file: file, line: line)
    }

    private func temporaryDirectorySnapshot() -> Set<String> {
        let contents = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        )) ?? []
        return Set(contents.filter {
            $0.hasPrefix("merge-input-") || $0.hasPrefix("merged-call-")
        })
    }

    private func sessionPendingFiles() -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.filter { $0.hasPrefix("merged-call.pending-") }
    }

    // MARK: - Tests

    func testMergeFromDurableM4AProducesUsableMergedM4A() async throws {
        let frames = 48_000
        try writeAudioFile(named: "mic.m4a", frames: frames, value: 0.25)
        try writeAudioFile(named: "system.m4a", frames: frames, value: 0.25)
        try await seedTrack(kind: .microphone, fileName: "mic.raw.caf", frames: Int64(frames))
        try await seedTrack(kind: .system, fileName: "system.raw.caf", frames: Int64(frames))

        let service = SessionMergeService(metadataStore: metadataStore)
        let result = try await service.mergeSession(in: directory)

        XCTAssertEqual(result.mergedM4AFileName, "merged-call.m4a")
        XCTAssertEqual(result.mergeMode, .dualTrack)

        let mergedURL = directory.appendingPathComponent("merged-call.m4a")
        let mergedFile = try AVAudioFile(forReading: mergedURL)
        XCTAssertGreaterThan(mergedFile.length, 0)

        let samples = try readAllSamples(at: mergedURL)
        assertRegion(samples, from: 0, to: samples.count, equals: 0.5)

        let metadata = try await metadataStore.load(in: directory)
        XCTAssertEqual(metadata.status, .ready)
    }

    func testMergeLeavesNoTemporaryOrPendingFiles() async throws {
        let frames = 24_000
        try writeAudioFile(named: "mic.m4a", frames: frames, value: 0.25)
        try await seedTrack(kind: .microphone, fileName: "mic.raw.caf", frames: Int64(frames))

        // A crashed previous merge may leave a pending file; it must be swept.
        try Data("stale".utf8).write(to: directory.appendingPathComponent("merged-call.pending-stale.m4a"))

        let temporarySnapshot = temporaryDirectorySnapshot()
        let service = SessionMergeService(metadataStore: metadataStore)
        _ = try await service.mergeSession(in: directory)

        XCTAssertTrue(sessionPendingFiles().isEmpty)
        XCTAssertEqual(temporaryDirectorySnapshot(), temporarySnapshot)
    }

    func testMergeFallsBackToRawCAFTracks() async throws {
        let frames = 24_000
        let int16Settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Int(PCMTrackWriter.canonicalChannels),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let float32Settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Int(PCMTrackWriter.canonicalChannels),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        // Old sessions carry Float32 raw CAFs, new ones Int16 — both must merge.
        try writeAudioFile(named: "mic.raw.caf", frames: frames, value: 0.25, settings: float32Settings)
        try writeAudioFile(named: "system.raw.caf", frames: frames, value: 0.25, settings: int16Settings)
        try await seedTrack(kind: .microphone, fileName: "mic.raw.caf", frames: Int64(frames))
        try await seedTrack(kind: .system, fileName: "system.raw.caf", frames: Int64(frames))

        let service = SessionMergeService(metadataStore: metadataStore)
        let result = try await service.mergeSession(in: directory)

        XCTAssertEqual(result.mergeMode, .dualTrack)
        let samples = try readAllSamples(at: directory.appendingPathComponent("merged-call.m4a"))
        assertRegion(samples, from: 0, to: samples.count, equals: 0.5)
    }

    func testMergeHonorsPTSOffsetBetweenTracks() async throws {
        let micFrames = 48_000
        let systemFrames = 24_000
        try writeAudioFile(named: "mic.m4a", frames: micFrames, value: 0.25)
        try writeAudioFile(named: "system.m4a", frames: systemFrames, value: 0.25)
        try await seedTrack(kind: .microphone, fileName: "mic.raw.caf", frames: Int64(micFrames), firstPTS: 0)
        try await seedTrack(kind: .system, fileName: "system.raw.caf", frames: Int64(systemFrames), firstPTS: 0.5)

        let service = SessionMergeService(metadataStore: metadataStore)
        _ = try await service.mergeSession(in: directory)

        let mergedURL = directory.appendingPathComponent("merged-call.m4a")
        let samples = try readAllSamples(at: mergedURL)
        let offsetFrames = 24_000
        assertRegion(samples, from: 0, to: offsetFrames, equals: 0.25)
        assertRegion(samples, from: offsetFrames, to: micFrames, equals: 0.5)

        let mergedFile = try AVAudioFile(forReading: mergedURL)
        let duration = Double(mergedFile.length) / mergedFile.processingFormat.sampleRate
        XCTAssertEqual(duration, 1.0, accuracy: 0.05)
    }

    func testMergeUsesRawCAFForTrackWhoseDurableM4AIsMissing() async throws {
        let frames = 48_000
        // Mic has a durable m4a; system only has its raw CAF (durable export failed).
        try writeAudioFile(named: "mic.m4a", frames: frames, value: 0.25)
        try writeAudioFile(named: "system.raw.caf", frames: frames, value: 0.25)
        try await seedTrack(kind: .microphone, fileName: "mic.raw.caf", frames: Int64(frames))
        try await seedTrack(kind: .system, fileName: "system.raw.caf", frames: Int64(frames))

        let service = SessionMergeService(metadataStore: metadataStore)
        let result = try await service.mergeSession(in: directory)

        XCTAssertEqual(result.mergeMode, .dualTrack)
        let samples = try readAllSamples(at: directory.appendingPathComponent("merged-call.m4a"))
        assertRegion(samples, from: 0, to: samples.count, equals: 0.5)
    }

    func testMergePrefersCompleteRawCAFAfterDurableMirrorFailure() async throws {
        let frames = 48_000
        try writeAudioFile(named: "mic.raw.caf", frames: frames, value: 0.25)
        try writeAudioFile(named: "mic.m4a", frames: 4_800, value: 0.75)
        try await seedTrack(
            kind: .microphone,
            fileName: "mic.raw.caf",
            frames: Int64(frames),
            diagnostics: ["durable mirror append failed: test"]
        )

        let service = SessionMergeService(metadataStore: metadataStore)
        let result = try await service.mergeSession(in: directory)

        XCTAssertEqual(result.mergeMode, .micOnly)
        let samples = try readAllSamples(at: directory.appendingPathComponent("merged-call.m4a"))
        assertRegion(samples, from: 0, to: samples.count, equals: 0.25)
        let mergedFile = try AVAudioFile(
            forReading: directory.appendingPathComponent("merged-call.m4a")
        )
        XCTAssertEqual(
            Double(mergedFile.length) / mergedFile.processingFormat.sampleRate,
            1,
            accuracy: 0.05
        )
    }

    func testMergeFailureSetsMixErrorAndLeavesNoArtifacts() async throws {
        try await seedTrack(kind: .microphone, fileName: "mic.raw.caf", frames: 0)

        let service = SessionMergeService(metadataStore: metadataStore)
        do {
            _ = try await service.mergeSession(in: directory)
            XCTFail("Expected mergeSession to throw")
        } catch {
            // expected
        }

        let metadata = try await metadataStore.load(in: directory)
        XCTAssertEqual(metadata.status, .mixError)
        XCTAssertEqual(metadata.mergeMode, .unavailable)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("merged-call.m4a").path
        ))
        XCTAssertTrue(sessionPendingFiles().isEmpty)
    }
}

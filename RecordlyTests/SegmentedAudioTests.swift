import AVFoundation
import XCTest
@testable import Recordly

final class SegmentedAudioTests: XCTestCase {
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

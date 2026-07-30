import AVFoundation
import XCTest
@testable import Recordly

final class DirectPCMMixServiceTests: XCTestCase {
    private actor FailingTrackWriter: TrackWriting {
        private enum Failure: Error {
            case appendFailed
        }

        func append(sampleBuffer: CMSampleBuffer) throws {
            throw Failure.appendFailed
        }

        func append(pcmBuffer: AVAudioPCMBuffer, presentationTime: CMTime?) throws {
            throw Failure.appendFailed
        }

        func finalize() -> TrackRuntimeStats {
            TrackRuntimeStats(
                kind: .system,
                fileName: "durable.m4a",
                firstPTS: nil,
                lastPTS: nil,
                framesWritten: 0,
                sampleRate: PCMTrackWriter.canonicalSampleRate,
                bufferCount: 0,
                fallback: false,
                diagnostics: []
            )
        }

        func recordDiagnostic(_ diagnostic: String) {}
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectPCMMixServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private static let sampleRate = PCMTrackWriter.canonicalSampleRate
    /// AAC is lossy and has encoder priming at file edges; keep assertions away from them.
    private static let edgeSkipFrames = 2048
    private static let sampleAccuracy: Float = 0.05
    private static let durationAccuracy = 0.05

    @discardableResult
    private func makePCMFile(
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
        ) else {
            throw DirectPCMMixService.MixError.invalidOutputFormat
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: settings ?? PCMTrackWriter.fileSettings(for: url),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else {
            throw DirectPCMMixService.MixError.invalidOutputFormat
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        channel.initialize(repeating: value, count: frames)
        try file.write(from: buffer)
        return url
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
        accuracy: Float = DirectPCMMixServiceTests.sampleAccuracy,
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
        let minValue = region.min() ?? 0
        let maxValue = region.max() ?? 0
        XCTAssertEqual(minValue, expected, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(maxValue, expected, accuracy: accuracy, file: file, line: line)
    }

    private func assertDuration(
        of url: URL,
        equalsFrames expectedFrames: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let audioFile = try AVAudioFile(forReading: url)
        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        let expected = Double(expectedFrames) / Self.sampleRate
        XCTAssertEqual(duration, expected, accuracy: Self.durationAccuracy, file: file, line: line)
    }

    private func inputTrack(
        kind: TrackKind,
        url: URL,
        offsetFrames: AVAudioFramePosition = 0,
        expectedFrames: AVAudioFramePosition
    ) -> DirectPCMMixService.InputTrack {
        DirectPCMMixService.InputTrack(
            kind: kind,
            fileURL: url,
            offsetFrames: offsetFrames,
            expectedFrames: expectedFrames
        )
    }

    // MARK: - Tests

    func testMixSumsTwoTracksWithUnityGain() throws {
        let frames = 48_000
        let micURL = try makePCMFile(named: "mic.caf", frames: frames, value: 0.25)
        let systemURL = try makePCMFile(named: "system.caf", frames: frames, value: 0.25)
        let outputURL = directory.appendingPathComponent("merged.caf")

        let result = try DirectPCMMixService().mix(
            tracks: [
                inputTrack(kind: .microphone, url: micURL, expectedFrames: AVAudioFramePosition(frames)),
                inputTrack(kind: .system, url: systemURL, expectedFrames: AVAudioFramePosition(frames))
            ],
            outputURL: outputURL
        )

        XCTAssertEqual(result.mergeMode, .dualTrack)
        let samples = try readAllSamples(at: outputURL)
        assertRegion(samples, from: 0, to: frames, equals: 0.5)
        try assertDuration(of: outputURL, equalsFrames: frames)
    }

    func testMixHonorsOffsetPlacement() throws {
        let micFrames = 48_000
        let systemFrames = 24_000
        let offset = 24_000
        let micURL = try makePCMFile(named: "mic.caf", frames: micFrames, value: 0.25)
        let systemURL = try makePCMFile(named: "system.caf", frames: systemFrames, value: 0.25)
        let outputURL = directory.appendingPathComponent("merged.caf")

        let result = try DirectPCMMixService().mix(
            tracks: [
                inputTrack(kind: .microphone, url: micURL, expectedFrames: AVAudioFramePosition(micFrames)),
                inputTrack(
                    kind: .system,
                    url: systemURL,
                    offsetFrames: AVAudioFramePosition(offset),
                    expectedFrames: AVAudioFramePosition(systemFrames)
                )
            ],
            outputURL: outputURL
        )

        XCTAssertEqual(result.mergeMode, .dualTrack)
        let samples = try readAllSamples(at: outputURL)
        assertRegion(samples, from: 0, to: offset, equals: 0.25)
        assertRegion(samples, from: offset, to: micFrames, equals: 0.5)
        try assertDuration(of: outputURL, equalsFrames: micFrames)
    }

    func testMixClampsClippingToUnity() throws {
        let frames = 24_000
        let micURL = try makePCMFile(named: "mic.caf", frames: frames, value: 0.8)
        let systemURL = try makePCMFile(named: "system.caf", frames: frames, value: 0.8)
        let outputURL = directory.appendingPathComponent("merged.caf")

        _ = try DirectPCMMixService().mix(
            tracks: [
                inputTrack(kind: .microphone, url: micURL, expectedFrames: AVAudioFramePosition(frames)),
                inputTrack(kind: .system, url: systemURL, expectedFrames: AVAudioFramePosition(frames))
            ],
            outputURL: outputURL
        )

        let samples = try readAllSamples(at: outputURL)
        assertRegion(samples, from: 0, to: frames, equals: 1.0)
        XCTAssertLessThanOrEqual(samples.max() ?? 0, 1.0 + Self.sampleAccuracy)
    }

    func testMixTruncatesToExpectedFrames() throws {
        let fileFrames = 48_000
        let expectedFrames = 24_000
        let micURL = try makePCMFile(named: "mic.caf", frames: fileFrames, value: 0.25)
        let outputURL = directory.appendingPathComponent("merged.caf")

        let result = try DirectPCMMixService().mix(
            tracks: [
                inputTrack(kind: .microphone, url: micURL, expectedFrames: AVAudioFramePosition(expectedFrames))
            ],
            outputURL: outputURL
        )

        XCTAssertEqual(result.totalFrames, AVAudioFramePosition(expectedFrames))
        try assertDuration(of: outputURL, equalsFrames: expectedFrames)
    }

    func testMixReportsMicOnlyMergeMode() throws {
        let frames = 24_000
        let micURL = try makePCMFile(named: "mic.caf", frames: frames, value: 0.25)
        let outputURL = directory.appendingPathComponent("merged.caf")

        let result = try DirectPCMMixService().mix(
            tracks: [inputTrack(kind: .microphone, url: micURL, expectedFrames: AVAudioFramePosition(frames))],
            outputURL: outputURL
        )

        XCTAssertEqual(result.mergeMode, .micOnly)
    }

    func testMixReportsSystemOnlyMergeMode() throws {
        let frames = 24_000
        let systemURL = try makePCMFile(named: "system.caf", frames: frames, value: 0.25)
        let outputURL = directory.appendingPathComponent("merged.caf")

        let result = try DirectPCMMixService().mix(
            tracks: [inputTrack(kind: .system, url: systemURL, expectedFrames: AVAudioFramePosition(frames))],
            outputURL: outputURL
        )

        XCTAssertEqual(result.mergeMode, .systemOnly)
    }

    func testMixWritesUsableM4ADirectly() throws {
        let frames = 48_000
        let micURL = try makePCMFile(named: "mic.caf", frames: frames, value: 0.25)
        let systemURL = try makePCMFile(named: "system.caf", frames: frames, value: 0.25)
        let outputURL = directory.appendingPathComponent("merged.m4a")

        let result = try DirectPCMMixService().mix(
            tracks: [
                inputTrack(kind: .microphone, url: micURL, expectedFrames: AVAudioFramePosition(frames)),
                inputTrack(kind: .system, url: systemURL, expectedFrames: AVAudioFramePosition(frames))
            ],
            outputURL: outputURL
        )

        XCTAssertEqual(result.mergeMode, .dualTrack)
        let file = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(file.fileFormat.settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        let samples = try readAllSamples(at: outputURL)
        assertRegion(samples, from: 0, to: samples.count, equals: 0.5)
        try assertDuration(of: outputURL, equalsFrames: frames)
    }

    func testMixAcceptsInt16CAFAndAACM4AInputs() throws {
        let frames = 48_000
        let int16Settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Int(PCMTrackWriter.canonicalChannels),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let micURL = try makePCMFile(named: "mic.caf", frames: frames, value: 0.25, settings: int16Settings)
        let systemURL = try makePCMFile(named: "system.m4a", frames: frames, value: 0.25)
        let outputURL = directory.appendingPathComponent("merged.m4a")

        let result = try DirectPCMMixService().mix(
            tracks: [
                inputTrack(kind: .microphone, url: micURL, expectedFrames: AVAudioFramePosition(frames)),
                inputTrack(kind: .system, url: systemURL, expectedFrames: AVAudioFramePosition(frames))
            ],
            outputURL: outputURL
        )

        XCTAssertEqual(result.mergeMode, .dualTrack)
        let samples = try readAllSamples(at: outputURL)
        assertRegion(samples, from: 0, to: samples.count, equals: 0.5)
    }

    // MARK: - PCMTrackWriter output format

    private func makeSourceBuffer(frames: Int, fill: (Int) -> Float) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: PCMTrackWriter.canonicalChannels,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
           let channel = buffer.floatChannelData?[0] else {
            throw DirectPCMMixService.MixError.invalidOutputFormat
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames {
            channel[index] = fill(index)
        }
        return buffer
    }

    private func writeThroughTrackWriter(
        fileName: String,
        to url: URL,
        buffer: AVAudioPCMBuffer
    ) async throws -> TrackRuntimeStats {
        let writer = try PCMTrackWriter(kind: .microphone, fileName: fileName, fileURL: url)
        try await writer.append(pcmBuffer: buffer)
        return await writer.finalize()
    }

    /// finalize() must close the file so the container (esp. AAC/m4a) is complete
    /// while the writer is still alive — stop-time validation depends on it.
    func testTrackWriterM4AIsUsableImmediatelyAfterFinalizeWhileWriterAlive() async throws {
        let url = directory.appendingPathComponent("mic.m4a")
        let buffer = try makeSourceBuffer(frames: 48_000) { _ in 0.25 }
        let writer = try PCMTrackWriter(kind: .microphone, fileName: "mic.m4a", fileURL: url)
        try await writer.append(pcmBuffer: buffer)
        let stats = await writer.finalize()

        // Writer intentionally still referenced here.
        let file = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(file.length, 0)
        XCTAssertEqual(stats.framesWritten, 48_000)
        withExtendedLifetime(writer) {}
    }

    func testTrackWriterWritesInt16CAF() async throws {
        let frames = 48_000
        let url = directory.appendingPathComponent("mic.raw.caf")
        let buffer = try makeSourceBuffer(frames: frames) { index in
            0.5 * sin(2 * .pi * 440 * Float(index) / Float(Self.sampleRate))
        }

        let stats = try await writeThroughTrackWriter(fileName: "mic.raw.caf", to: url, buffer: buffer)
        XCTAssertEqual(stats.framesWritten, Int64(frames))

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.commonFormat, .pcmFormatInt16)

        let fileSize = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(Double(fileSize), Double(frames * 2), accuracy: Double(frames) * 0.2)

        let samples = try readAllSamples(at: url)
        XCTAssertEqual(samples.count, frames)
        guard let channel = buffer.floatChannelData?[0] else {
            throw DirectPCMMixService.MixError.invalidOutputFormat
        }
        for index in stride(from: 0, to: frames, by: 997) {
            XCTAssertEqual(samples[index], channel[index], accuracy: 1e-3)
        }
    }

    func testTrackWriterStillWritesAACForM4A() async throws {
        let url = directory.appendingPathComponent("mic.m4a")
        let buffer = try makeSourceBuffer(frames: 48_000) { _ in 0.25 }

        _ = try await writeThroughTrackWriter(fileName: "mic.m4a", to: url, buffer: buffer)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
    }

    func testMirroredWriterReportsDurableFailureAfterCanonicalCAFWriteSucceeds() async throws {
        let frames = 4_800
        let canonicalURL = directory.appendingPathComponent("canonical.caf")
        let buffer = try makeSourceBuffer(frames: frames) { _ in 0.25 }
        let canonical = try PCMTrackWriter(
            kind: .system,
            fileName: "canonical.caf",
            fileURL: canonicalURL
        )
        let mirrored = MirroredTrackWriter(
            temporary: canonical,
            durable: FailingTrackWriter()
        )

        let durableFailure = try await mirrored.appendPreservingCanonical(pcmBuffer: buffer)
        let stats = await mirrored.finalize()

        XCTAssertNotNil(durableFailure)
        XCTAssertEqual(stats.first?.framesWritten, Int64(frames))
        XCTAssertTrue(CaptureArtifactValidator.isUsableAudioFile(canonicalURL))
    }

    func testMixThrowsWhenNoTracksProvided() {
        let outputURL = directory.appendingPathComponent("merged.caf")

        XCTAssertThrowsError(try DirectPCMMixService().mix(tracks: [], outputURL: outputURL)) { error in
            guard case DirectPCMMixService.MixError.noUsableTracks = error else {
                XCTFail("Expected noUsableTracks, got \(error)")
                return
            }
        }
    }

    func testMixThrowsWhenAllTracksAreEmpty() throws {
        let micURL = try makePCMFile(named: "mic.caf", frames: 24_000, value: 0.25)
        let outputURL = directory.appendingPathComponent("merged.caf")

        XCTAssertThrowsError(
            try DirectPCMMixService().mix(
                tracks: [inputTrack(kind: .microphone, url: micURL, expectedFrames: 0)],
                outputURL: outputURL
            )
        ) { error in
            guard case DirectPCMMixService.MixError.noUsableTracks = error else {
                XCTFail("Expected noUsableTracks, got \(error)")
                return
            }
        }
    }
}

import XCTest
@testable import Recordly

final class AudioInputAdapterTests: XCTestCase {
    func testPassthroughAdapterResolvesSessionAsset() throws {
        let sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioInputAdapterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        let audioURL = sessionDirectory.appendingPathComponent("mic.raw.caf")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data())

        let adapter = PassthroughAudioInputAdapter()
        let prepared = try adapter.prepare(
            .sessionAsset(fileName: "mic.raw.caf", channel: .mic),
            in: sessionDirectory
        )

        XCTAssertEqual(prepared?.url, audioURL)
        XCTAssertEqual(prepared?.channel, .mic)
    }

    func testPassthroughAdapterReturnsNilWhenAssetMissing() throws {
        let sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioInputAdapterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        let adapter = PassthroughAudioInputAdapter()
        let prepared = try adapter.prepare(
            .sessionAsset(fileName: "missing.raw.caf", channel: .system),
            in: sessionDirectory
        )

        XCTAssertNil(prepared)
    }
}

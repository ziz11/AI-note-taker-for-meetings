import AVFoundation
import CryptoKit
import Foundation

enum SessionAudioError: Error {
    case invalidMetadata, unsupportedVersion, invalidAudio, invalidInput, publicationFailed, rotationBacklog
}

enum AudioSegmentState: String, Codable, Sendable {
    case writing, committed, missing, invalid
}

struct SessionAudioSegment: Codable, Equatable, Sendable {
    var id = UUID()
    var track: TrackKind
    var index: Int
    // All timeline positions are integer frames at manifest.timelineSampleRate.
    var startFrame: Int64
    var frameCount: Int64
    var sampleRate = 48_000
    var codec = "aac"
    var fileName: String
    var state: AudioSegmentState = .writing
    var firstCapturePTS: Double?
    var lastCapturePTS: Double?
    var contentHash: String?
    var gaps: [AudioTimelineGap] = []

    init(track: TrackKind, index: Int, startFrame: Int64, frameCount: Int64 = 0) {
        self.track = track
        self.index = index
        self.startFrame = startFrame
        self.frameCount = frameCount
        self.fileName = "audio/\(track.rawValue)/\(String(format: "%06d", index))-\(id.uuidString).m4a"
    }

    var endFrame: Int64 { startFrame + frameCount }
}

struct AudioTimelineGap: Codable, Equatable, Sendable {
    var startFrame: Int64
    var frameCount: Int64
    var reason: String
}

struct SessionAudioManifest: Codable, Sendable {
    var version = 2
    var sessionID: UUID
    var timelineSampleRate = 48_000
    var hostTimeOrigin: Double = 0
    var segments: [SessionAudioSegment] = []
    var diagnostics: [String] = []
    var captureEndFrame: Int64? = nil
    var durationFrames: Int64 { max(segments.map(\.endFrame).max() ?? 0, captureEndFrame ?? 0) }
}

private struct AudioChunkSidecar: Codable {
    var version = 2
    var sessionID: UUID
    var hostTimeOrigin: Double
    var segment: SessionAudioSegment
}

/// Filesystem mutations are serialized by SessionAudioCommitter in production.
/// Sidecars retain independent timing provenance if the manifest is lost.
struct SessionAudioStore {
    let directory: URL
    let sessionID: UUID
    var hostTimeOrigin: Double = 0
    var faultInjector: (@Sendable (String) -> Void)? = nil
    var manifestURL: URL { directory.appendingPathComponent("audio-manifest.json") }

    func finalURL(for segment: SessionAudioSegment) -> URL { directory.appendingPathComponent(segment.fileName) }
    func pendingURL(for segment: SessionAudioSegment) -> URL { finalURL(for: segment).deletingPathExtension().appendingPathExtension("pending.m4a") }
    private func sidecarURL(for segment: SessionAudioSegment) -> URL { finalURL(for: segment).appendingPathExtension("json") }

    func prepare(_ segment: SessionAudioSegment) throws {
        try validate(segment)
        try FileManager.default.createDirectory(at: finalURL(for: segment).deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeSidecar(segment)
    }

    func load() throws -> SessionAudioManifest {
        let manifest = try JSONDecoder().decode(SessionAudioManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.version == 2, manifest.timelineSampleRate == 48_000 else { throw SessionAudioError.unsupportedVersion }
        guard manifest.sessionID == sessionID else { throw SessionAudioError.invalidMetadata }
        guard manifest.hostTimeOrigin.isFinite, Set(manifest.segments.map(\.id)).count == manifest.segments.count else { throw SessionAudioError.invalidMetadata }
        for segment in manifest.segments { try validate(segment) }
        return manifest
    }

    func save(_ manifest: SessionAudioManifest) throws {
        guard manifest.sessionID == sessionID, manifest.version == 2, manifest.hostTimeOrigin.isFinite,
              Set(manifest.segments.map(\.id)).count == manifest.segments.count else { throw SessionAudioError.invalidMetadata }
        for segment in manifest.segments { try validate(segment) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    func publish(_ original: SessionAudioSegment) throws {
        try validate(original)
        var segment = original
        let pending = pendingURL(for: segment)
        guard let file = try? AVAudioFile(forReading: pending), file.length > 0 else { throw SessionAudioError.invalidAudio }
        if segment.frameCount == 0 { segment.frameCount = file.length }
        guard file.length == segment.frameCount else { throw SessionAudioError.invalidAudio }
        segment.state = .committed
        segment.contentHash = try hash(pending)
        // Persist full timing before publication; recovery recognizes a readable pending file too.
        try writeSidecar(segment)
        faultInjector?("before-rename")
        try FileManager.default.moveItem(at: pending, to: finalURL(for: segment))
        faultInjector?("after-rename")
        var manifest: SessionAudioManifest
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            manifest = try load()
        } else {
            manifest = SessionAudioManifest(sessionID: sessionID, hostTimeOrigin: hostTimeOrigin)
        }
        manifest.segments.removeAll { $0.id == segment.id }
        manifest.segments.append(segment)
        manifest.segments.sort { ($0.startFrame, $0.track.rawValue, $0.index) < ($1.startFrame, $1.track.rawValue, $1.index) }
        faultInjector?("before-manifest")
        try save(manifest)
    }

    func reconcile() throws -> SessionAudioManifest {
        var manifest: SessionAudioManifest
        var recoveredOrigin: Double?
        do { manifest = try load(); recoveredOrigin = manifest.hostTimeOrigin }
        catch SessionAudioError.unsupportedVersion { throw SessionAudioError.unsupportedVersion }
        catch {
            manifest = SessionAudioManifest(sessionID: sessionID, hostTimeOrigin: hostTimeOrigin)
            if FileManager.default.fileExists(atPath: manifestURL.path) { manifest.diagnostics.append("Unreadable manifest; reconstructed from chunk sidecars.") }
        }
        let enumerator = FileManager.default.enumerator(at: directory.appendingPathComponent("audio"), includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.lastPathComponent.hasSuffix(".m4a.json") else { continue }
            do {
                let sidecar = try JSONDecoder().decode(AudioChunkSidecar.self, from: Data(contentsOf: url))
                guard sidecar.version == 2, sidecar.sessionID == sessionID, sidecar.hostTimeOrigin.isFinite,
                      recoveredOrigin == nil || recoveredOrigin == sidecar.hostTimeOrigin else { throw SessionAudioError.invalidMetadata }
                try validate(sidecar.segment)
                guard url.standardizedFileURL == sidecarURL(for: sidecar.segment).standardizedFileURL else { throw SessionAudioError.invalidMetadata }
                if !manifest.segments.contains(where: { $0.id == sidecar.segment.id }) { manifest.segments.append(sidecar.segment) }
                manifest.hostTimeOrigin = sidecar.hostTimeOrigin
                recoveredOrigin = sidecar.hostTimeOrigin
            } catch { manifest.diagnostics.append("Invalid sidecar: \(url.lastPathComponent)") }
        }
        for index in manifest.segments.indices {
            try Task.checkCancellation()
            var segment = manifest.segments[index]
            let final = finalURL(for: segment)
            let pending = pendingURL(for: segment)
            let candidate = FileManager.default.fileExists(atPath: final.path) ? final : pending
            if let file = try? AVAudioFile(forReading: candidate), file.length > 0 {
                let actualHash = try hash(candidate)
                if (segment.frameCount > 0 && segment.frameCount != file.length) || (segment.contentHash != nil && segment.contentHash != actualHash) {
                    segment.state = .invalid
                    manifest.diagnostics.append("Chunk content changed: \(segment.id)")
                } else {
                    if segment.frameCount == 0 { segment.frameCount = file.length }
                    segment.contentHash = actualHash
                    segment.state = .committed
                    if candidate == pending { try FileManager.default.moveItem(at: pending, to: final) }
                    try writeSidecar(segment, origin: manifest.hostTimeOrigin)
                }
            } else {
                segment.state = FileManager.default.fileExists(atPath: candidate.path) ? .invalid : .missing
                manifest.diagnostics.append("Unreadable or missing chunk: \(segment.id)")
            }
            manifest.segments[index] = segment
        }
        let audioEnumerator = FileManager.default.enumerator(at: directory.appendingPathComponent("audio"), includingPropertiesForKeys: nil)
        let knownFiles = Set(manifest.segments.flatMap { [finalURL(for: $0).standardizedFileURL.path, pendingURL(for: $0).standardizedFileURL.path] })
        while let url = audioEnumerator?.nextObject() as? URL {
            if url.pathExtension == "m4a", !knownFiles.contains(url.standardizedFileURL.path) {
                manifest.diagnostics.append("Unplaced audio retained; missing trustworthy timeline metadata: \(url.lastPathComponent)")
            }
        }
        manifest.segments.sort { ($0.startFrame, $0.track.rawValue, $0.index) < ($1.startFrame, $1.track.rawValue, $1.index) }
        manifest.diagnostics = Array(Set(manifest.diagnostics)).sorted()
        try save(manifest)
        return manifest
    }

    private func validate(_ segment: SessionAudioSegment) throws {
        let components = segment.fileName.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3, components[0] == "audio", components[1] == Substring(segment.track.rawValue),
              components[2] != "..", !components[2].isEmpty, segment.fileName.hasSuffix(".m4a"),
              segment.startFrame >= 0, segment.frameCount >= 0, segment.startFrame <= Int64.max - segment.frameCount,
              segment.index >= 0, segment.sampleRate == 48_000, segment.codec == "aac" else { throw SessionAudioError.invalidMetadata }
        guard hostTimeOrigin.isFinite, segment.firstCapturePTS?.isFinite != false, segment.lastCapturePTS?.isFinite != false,
              segment.gaps.allSatisfy({ $0.startFrame >= 0 && $0.frameCount >= 0 && $0.startFrame <= Int64.max - $0.frameCount }) else { throw SessionAudioError.invalidMetadata }
        // Never follow symlinks outside the session when recovering or reading user files.
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard [finalURL(for: segment), pendingURL(for: segment), sidecarURL(for: segment)].allSatisfy({ $0.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) }) else { throw SessionAudioError.invalidMetadata }
    }

    private func writeSidecar(_ segment: SessionAudioSegment, origin: Double? = nil) throws {
        let sidecar = AudioChunkSidecar(sessionID: sessionID, hostTimeOrigin: origin ?? hostTimeOrigin, segment: segment)
        try JSONEncoder().encode(sidecar).write(to: sidecarURL(for: segment), options: .atomic)
    }

    func checkpoint(_ segment: SessionAudioSegment) throws {
        try validate(segment)
        try writeSidecar(segment)
    }

    static func rebindCopy(in directory: URL, from sourceID: UUID, to destinationID: UUID) throws {
        var manifest = try SessionAudioStore(directory: directory, sessionID: sourceID).reconcile()
        manifest.sessionID = destinationID
        let destination = SessionAudioStore(directory: directory, sessionID: destinationID, hostTimeOrigin: manifest.hostTimeOrigin)
        for segment in manifest.segments { try destination.checkpoint(segment) }
        try destination.save(manifest)
    }

    private func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let bytes = try handle.read(upToCount: 64 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

actor SessionAudioCommitter {
    let store: SessionAudioStore
    init(store: SessionAudioStore) { self.store = store }
    func publish(_ segment: SessionAudioSegment) throws { try store.publish(segment) }
}

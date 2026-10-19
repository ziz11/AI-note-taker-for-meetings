import CryptoKit
import Foundation

struct InferenceWindowSettings: Codable, Equatable {
    var ownershipSeconds: Int64 = 50
    var contextSeconds: Int64 = 5
    var implementationVersion = "segmented-inference-v2.1"
    var resultVersion = 1
    var diarizationSettingsIdentity = "backend-default-v2;fluidaudio:0.17.7;embedding:wespeaker-256-l2;alignment-overlap:0.25;session-voice-v1"
}

struct InferenceWindow: Codable, Equatable {
    var track: TrackKind
    var ownershipStartFrame: Int64
    var ownershipEndFrame: Int64
    var inputStartFrame: Int64
    var inputEndFrame: Int64
    var id: String { "\(track.rawValue)-\(ownershipStartFrame)" }
    var frameCount: Int64 { inputEndFrame - inputStartFrame }
    var offsetMs: Int { Int(inputStartFrame / 48) }
    var ownershipStartMs: Int { Int(ownershipStartFrame / 48) }
    var ownershipEndMs: Int { Int(ownershipEndFrame / 48) }
}

struct InferenceWindowPlanner {
    var settings = InferenceWindowSettings()

    func windows(track: TrackKind, durationFrames: Int64) throws -> [InferenceWindow] {
        guard durationFrames >= 0, settings.ownershipSeconds > 0, settings.contextSeconds >= 0,
              settings.ownershipSeconds <= 60, settings.contextSeconds <= 30,
              settings.ownershipSeconds + 2 * settings.contextSeconds <= 60 else {
            throw SessionAudioError.invalidMetadata
        }
        let step = settings.ownershipSeconds * 48_000
        let context = settings.contextSeconds * 48_000
        // Bound metadata too: reject impossible/corrupt durations instead of allocating
        // billions of windows. This still permits more than a month of continuous audio.
        guard durationFrames / step < 100_000 else { throw SessionAudioError.invalidMetadata }
        var result: [InferenceWindow] = []
        var start: Int64 = 0
        while start < durationFrames {
            let end = min(durationFrames, start + step)
            result.append(InferenceWindow(track: track, ownershipStartFrame: start, ownershipEndFrame: end,
                inputStartFrame: max(0, start - context), inputEndFrame: min(durationFrames, end + context)))
            start = end
        }
        return result
    }
}

struct WindowAudioFingerprint: Codable, Equatable {
    var id: UUID
    var contentHash: String?
    var track: TrackKind
    var startFrame: Int64
    var frameCount: Int64
    var state: AudioSegmentState
    var sampleRate: Int
    var codec: String
    var gaps: [AudioTimelineGap]
}

struct WindowInferenceProvenance: Codable, Equatable {
    var sessionID: UUID
    var timelineVersion: Int
    var sampleRate: Int
    var hostTimeOrigin: Double
    var window: InferenceWindow
    var audio: [WindowAudioFingerprint]
    var asrBackend: String
    var asrArtifactFingerprint: String
    var asrEngineFingerprint: String
    var diarizationBackend: String
    var diarizationArtifactFingerprint: String?
    var settings: InferenceWindowSettings

    var fingerprint: String { get throws { try InferenceFingerprint.encode(self) } }

    init(manifest: SessionAudioManifest, window: InferenceWindow, profile: InferenceRuntimeProfile,
         asrArtifactFingerprint: String, asrEngineFingerprint: String, diarizationArtifactFingerprint: String?,
         settings: InferenceWindowSettings) {
        sessionID = manifest.sessionID
        timelineVersion = manifest.version
        sampleRate = manifest.timelineSampleRate
        hostTimeOrigin = manifest.hostTimeOrigin
        self.window = window
        audio = manifest.segments.filter {
            $0.track == window.track && $0.startFrame < window.inputEndFrame && $0.endFrame > window.inputStartFrame
        }.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            WindowAudioFingerprint(id: $0.id, contentHash: $0.contentHash, track: $0.track, startFrame: $0.startFrame,
                frameCount: $0.frameCount, state: $0.state, sampleRate: $0.sampleRate, codec: $0.codec, gaps: $0.gaps)
        }
        asrBackend = profile.stageSelection.backend(for: .asr).rawValue
        self.asrArtifactFingerprint = asrArtifactFingerprint
        self.asrEngineFingerprint = asrEngineFingerprint
        self.settings = settings
        diarizationBackend = window.track == .system ? profile.stageSelection.backend(for: .diarization).rawValue : InferenceBackend.disabled.rawValue
        self.diarizationArtifactFingerprint = window.track == .system ? diarizationArtifactFingerprint : nil
        if window.track == .microphone { self.settings.diarizationSettingsIdentity = "not-applicable" }
    }
}

enum InferenceFingerprint {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return digest(try encoder.encode(value))
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Hash actual supplied artifacts, never discover a model or load it into RAM.
    /// This catches same-path replacements that path-only runtime fingerprints miss.
    static func artifact(at url: URL) throws -> String {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            let files = ((enumerator?.allObjects as? [URL]) ?? []).filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }.sorted { $0.path < $1.path }
            var entries: [String] = []
            for file in files {
                try Task.checkCancellation()
                entries.append("\(file.path.dropFirst(url.path.count)):\(try fileHash(file))")
            }
            return digest(Data("\(url.standardizedFileURL.path)\n\(entries.joined(separator: "\n"))".utf8))
        }
        return digest(Data("\(url.standardizedFileURL.path):\(try fileHash(url))".utf8))
    }

    private static func fileHash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 64 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

func propagateInferenceCancellation(_ error: Error) throws {
    if error is CancellationError || Task.isCancelled { throw CancellationError() }
    if let error = error as? ASREngineRuntimeError, error == .cancelled { throw CancellationError() }
    if let error = error as? DiarizationRuntimeError, error == .cancelled { throw CancellationError() }
    if let error = error as? TranscriptionPipelineError, case .cancelled = error { throw CancellationError() }
}

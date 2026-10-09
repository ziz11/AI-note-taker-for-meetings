import Foundation

enum InferenceTemporaryAudio {
    static func removeStale(in directory: URL) throws -> Int {
        var removed = 0
        for url in try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
            try Task.checkCancellation()
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-", maxSplits: 2)
            guard url.pathExtension == "caf", parts.count == 3,
                  [TrackKind.microphone.rawValue, TrackKind.system.rawValue].contains(String(parts[0])),
                  let frame = Int64(parts[1]), frame >= 0, UUID(uuidString: String(parts[2])) != nil else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try FileManager.default.removeItem(at: url)
            removed += 1
        }
        return removed
    }
}

struct PersistedInferenceWindow: Codable {
    var version = 1
    var provenance: WindowInferenceProvenance
    var asr: ASRDocument?
    var diarization: DiarizationDocument?
    var diarizationRunID: UUID?
    var asrFailure: String?
    var diarizationFailure: String?
}

struct WindowInferenceCache {
    let directory: URL

    func load(matching provenance: WindowInferenceProvenance) -> PersistedInferenceWindow? {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url(for: provenance.window)),
              let cached = try? decoder.decode(PersistedInferenceWindow.self, from: data),
              cached.version == provenance.settings.resultVersion, cached.provenance == provenance,
              cached.asr?.sessionID == nil || cached.asr?.sessionID == provenance.sessionID,
              cached.diarization?.sessionID == nil || cached.diarization?.sessionID == provenance.sessionID else { return nil }
        return cached
    }

    func save(_ value: PersistedInferenceWindow) throws { try writeInferenceJSON(value, to: url(for: value.provenance.window)) }

    private func url(for window: InferenceWindow) -> URL {
        directory.appendingPathComponent("inference/windows/\(window.id).json")
    }
}

enum SessionSpeakerContinuity: String, Codable {
    case microphoneOnly
    case windowLocalOnly
    case unresolvedAcrossWindows
}

struct SessionSpeakerIdentity: Codable, Equatable {
    var id: String
    var defaultLabel: String
    var displayName: String?
    // The identity describes a local group, never a proven global person.
    var continuity = SessionSpeakerContinuity.windowLocalOnly
}

struct SessionSpeakerIdentityDocument: Codable {
    var version = 1
    var sessionID: UUID
    // Copies keep this namespace only for matching unchanged local evidence.
    // The owning session ID always identifies the current recording.
    var identityScopeSessionID: UUID?
    var identities: [String: SessionSpeakerIdentity] = [:]
    var aliases: [String: String] = [:]
}

/// Raw labels are scoped to actual inference runs. Only an exact local turn
/// signature with identical audio and diarization configuration can recover a
/// prior local identity, independently of subsequent ASR model changes.
/// We never infer cross-window identity from the backend's speaker_0 label.
struct SessionSpeakerIdentityStore {
    let directory: URL
    let sessionID: UUID
    var url: URL { directory.appendingPathComponent("speaker-identities.json") }

    func load() throws -> SessionSpeakerIdentityDocument {
        guard FileManager.default.fileExists(atPath: url.path) else { return SessionSpeakerIdentityDocument(sessionID: sessionID) }
        let value = try JSONDecoder().decode(SessionSpeakerIdentityDocument.self, from: Data(contentsOf: url))
        guard value.version == 1, value.sessionID == sessionID else { throw SessionAudioError.invalidMetadata }
        return value
    }

    func save(_ document: SessionSpeakerIdentityDocument) throws { try writeInferenceJSON(document, to: url) }

    static func rebindCopy(in directory: URL, from sourceID: UUID, to destinationID: UUID) throws {
        let source = SessionSpeakerIdentityStore(directory: directory, sessionID: sourceID)
        guard FileManager.default.fileExists(atPath: source.url.path) else { return }
        var document = try source.load()
        document.identityScopeSessionID = document.identityScopeSessionID ?? sourceID
        document.sessionID = destinationID
        // Copied aliases describe old inference runs. A new run must establish
        // the same turn partition before a saved local name can be applied.
        document.aliases = [:]
        try SessionSpeakerIdentityStore(directory: directory, sessionID: destinationID).save(document)
    }

    func rename(speakerID: String, to name: String) throws {
        var value = try load()
        guard value.identities[speakerID] != nil else { throw SessionAudioError.invalidMetadata }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.identities[speakerID]?.displayName = trimmed.isEmpty ? nil : trimmed
        try save(value)
    }

    func identity(rawLabel: String, diarization: DiarizationDocument, runID: UUID,
                  provenance: WindowInferenceProvenance, document: inout SessionSpeakerIdentityDocument) throws -> SessionSpeakerIdentity {
        let scope = try InferenceFingerprint.encode(LocalSpeakerScope(provenance: provenance,
            scopeSessionID: document.identityScopeSessionID ?? document.sessionID))
        let aliasKey = "\(provenance.window.id)|\(runID.uuidString)|\(rawLabel)"
        if let id = document.aliases[aliasKey], let identity = document.identities[id] { return identity }
        // This deliberately excludes the raw label, so a label permutation on the
        // same exact local turn partition does not lose the user's rename.
        let turns = diarization.segments.filter { $0.speaker == rawLabel }
            .sorted { ($0.startMs, $0.endMs) < ($1.startMs, $1.endMs) }
            .map { "\($0.startMs):\($0.endMs)" }.joined(separator: ",")
        let otherLabels = Set(diarization.segments.map(\.speaker)).subtracting([rawLabel])
        let ambiguous = otherLabels.contains { label in
            diarization.segments.filter { $0.speaker == label }
                .sorted { ($0.startMs, $0.endMs) < ($1.startMs, $1.endMs) }
                .map { "\($0.startMs):\($0.endMs)" }.joined(separator: ",") == turns
        }
        // Coincident turn partitions cannot prove identity under label permutations.
        // Keep these local groups distinct and decline cross-run rename matching.
        let signature = ambiguous ? "\(turns)|\(runID)|\(rawLabel)" : turns
        let id = "remote_local_" + String(InferenceFingerprint.digest(Data("\(scope)|\(signature)".utf8)).prefix(20))
        let identity = document.identities[id] ?? SessionSpeakerIdentity(id: id,
            defaultLabel: "Remote (window \(provenance.window.ownershipStartMs / 50_000 + 1), group \(diarization.segments.map(\.speaker).filter { $0 < rawLabel }.uniqueCount + 1))")
        document.identities[id] = identity
        document.aliases[aliasKey] = id
        return identity
    }
}

private struct LocalSpeakerScope: Encodable {
    let version = "window-local-speakers-v1"
    let sessionID: UUID
    let timelineVersion: Int
    let sampleRate: Int
    let hostTimeOrigin: Double
    let window: InferenceWindow
    let audio: [WindowAudioFingerprint]
    let diarizationBackend: String
    let diarizationArtifactFingerprint: String?
    let diarizationSettingsIdentity: String

    init(provenance: WindowInferenceProvenance, scopeSessionID: UUID) {
        sessionID = scopeSessionID
        timelineVersion = provenance.timelineVersion
        sampleRate = provenance.sampleRate
        hostTimeOrigin = provenance.hostTimeOrigin
        window = provenance.window
        audio = provenance.audio
        diarizationBackend = provenance.diarizationBackend
        diarizationArtifactFingerprint = provenance.diarizationArtifactFingerprint
        diarizationSettingsIdentity = provenance.settings.diarizationSettingsIdentity
    }
}

private extension Array where Element == String {
    var uniqueCount: Int { Set(self).count }
}

struct InferenceWindowFailure: Codable, Equatable {
    var windowID: String
    var track: TrackKind
    var startFrame: Int64
    var endFrame: Int64
    var stage: String
    var message: String
}

struct TranscriptEventProvenance: Codable {
    var eventID: String
    var windowID: String
    var windowFingerprint: String
}

struct SegmentedInferenceReport: Codable {
    var version = 1
    var sessionID: UUID
    var status = "processing"
    var speakerContinuity: SessionSpeakerContinuity
    var windowFailures: [InferenceWindowFailure] = []
    var audioDiagnostics: [String]
    var materializedWindowCount = 0
    var maximumMaterializedFrames: Int64 = 0
    var reusedASRWindows = 0
    var reusedDiarizationWindows = 0
    var completedWindows: [String] = []
    var events: [TranscriptEventProvenance] = []
    var diagnostics: [String] = []
}

func writeInferenceJSON<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(value).write(to: url, options: .atomic)
}

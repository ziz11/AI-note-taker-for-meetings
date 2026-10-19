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
    case sessionMatched
    case partiallyMatched
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
    var voiceProfiles: [String: SessionVoiceProfile]? = nil
}

struct SessionVoiceSample: Codable, Equatable {
    var evidenceKey: String
    var embedding: [Float]
}

struct SessionVoiceProfile: Codable, Equatable {
    var space: String
    var samples: [SessionVoiceSample]
    var anchors: [SessionVoiceSample]
}

struct SessionWindowSpeakerResolution {
    var identities: [String: SessionSpeakerIdentity]
    var voicedGroups: Int
    var unresolvedGroups: Int
}

/// Only voice evidence in the same model space may match across windows. Raw
/// labels remain run-local; the legacy exact-turn fallback preserves old names.
struct SessionSpeakerIdentityStore {
    static let matchingContract = "session-voice-v1;cosine:0.80;margin:0.08;exclusive-ms:3000;anchors:8;profiles:128"
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

    /// Pipeline updates are serialized with UI renames on the main actor. Names
    /// are user-owned; inference can replace mappings/evidence but never names.
    @MainActor
    func savePreservingDisplayNames(_ document: SessionSpeakerIdentityDocument) throws -> SessionSpeakerIdentityDocument {
        let latest = try load()
        var merged = document
        for (id, identity) in latest.identities where merged.identities[id] != nil {
            merged.identities[id]?.displayName = identity.displayName
        }
        try save(merged)
        return merged
    }

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

    /// Rebuild current contributions, retaining only named anchors whose exact
    /// source evidence still exists. Removed/replaced audio never seeds a profile.
    func beginRebuild(provenances: [WindowInferenceProvenance], document: inout SessionSpeakerIdentityDocument) throws {
        let valid = Set(try provenances.map { try evidenceKey($0, document: document) })
        var retained: [String: SessionVoiceProfile] = [:]
        for (id, profile) in document.voiceProfiles ?? [:] where document.identities[id]?.displayName != nil {
            let anchors = (profile.anchors + profile.samples).filter { valid.contains($0.evidenceKey) }
            if !anchors.isEmpty {
                var unique: [SessionVoiceSample] = []
                for sample in anchors where !unique.contains(sample) {
                    unique.append(sample)
                    if unique.count == 8 { break }
                }
                retained[id] = SessionVoiceProfile(space: profile.space, samples: [], anchors: unique)
            }
        }
        document.voiceProfiles = retained
        // Every alias is a decision against the previous profile set. Recompute
        // cached local decisions too; exact-turn IDs still recover local names.
        document.aliases = [:]
    }

    func identity(rawLabel: String, diarization: DiarizationDocument, runID: UUID,
                  provenance: WindowInferenceProvenance, document: inout SessionSpeakerIdentityDocument) throws -> SessionSpeakerIdentity {
        let result = try resolveWindow(diarization: diarization, runID: runID, provenance: provenance, document: &document)
        if let identity = result.identities[rawLabel] { return identity }
        return try localIdentity(rawLabel: rawLabel, diarization: diarization, runID: runID, provenance: provenance, document: &document)
    }

    func resolveWindow(diarization: DiarizationDocument, runID: UUID,
                       provenance: WindowInferenceProvenance, document: inout SessionSpeakerIdentityDocument) throws -> SessionWindowSpeakerResolution {
        let labels = Set(diarization.segments.map(\.speaker)).sorted()
        let ownedStart = provenance.window.ownershipStartMs - provenance.window.offsetMs
        let ownedEnd = provenance.window.ownershipEndMs - provenance.window.offsetMs
        let ownedLabels = Set(diarization.segments.filter {
            $0.startMs < $0.endMs && $0.startMs < ownedEnd && $0.endMs > ownedStart
        }.map(\.speaker))
        func resolution(_ identities: [String: SessionSpeakerIdentity]) -> SessionWindowSpeakerResolution {
            let owned = identities.filter { ownedLabels.contains($0.key) }
            let voiced = owned.values.filter { $0.continuity == .sessionMatched }.count
            return .init(identities: identities, voicedGroups: voiced, unresolvedGroups: owned.count - voiced)
        }
        let aliasPrefix = "\(provenance.window.id)|\(runID.uuidString)|"
        // A run is resolved once as a batch. Subsequent consumers only read it.
        if labels.allSatisfy({ document.aliases[aliasPrefix + $0] != nil }) {
            let identities = Dictionary(uniqueKeysWithValues: labels.compactMap { label -> (String, SessionSpeakerIdentity)? in
                guard let id = document.aliases[aliasPrefix + label], let identity = document.identities[id] else { return nil }
                return (label, identity)
            })
            if identities.count == labels.count {
                return resolution(identities)
            }
        }
        let key = try evidenceKey(provenance, document: document)
        let artifact = provenance.diarizationArtifactFingerprint
        let validArtifact = artifact != nil && diarization.embeddingArtifactFingerprint == artifact
        let space = validArtifact ? diarization.embeddingSpace.map {
            "\(provenance.diarizationBackend)|\(artifact!)|\($0)|\(provenance.settings.diarizationSettingsIdentity)|\(Self.matchingContract)"
        } : nil
        var voices: [String: [Float]] = [:]
        if space != nil {
            for label in labels {
                if let embedding = representative(label: label, diarization: diarization, window: provenance.window) { voices[label] = embedding }
            }
        }
        let profiles = document.voiceProfiles ?? [:]
        var proposals: [String: String] = [:]
        var uncertain = Set<String>()
        var newLabels = Set<String>()
        for label in labels {
            guard let voice = voices[label], let space else { continue }
            let ranked = profiles.filter { $0.value.space == space }.compactMap { id, profile -> (String, Float)? in
                let similarities = (profile.anchors + profile.samples).compactMap { sample -> Float? in
                    guard let normalized = DiarizationVoiceObservation.normalized(sample.embedding) else { return nil }
                    return Self.cosine(voice, normalized)
                }
                guard let score = similarities.max() else { return nil }
                return (id, score)
            }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
            if let best = ranked.first, best.1 >= 0.80 {
                let runnerUp = ranked.dropFirst().first?.1 ?? -1
                if best.1 - runnerUp >= 0.08 { proposals[label] = best.0 }
                else { uncertain.insert(label) }
            } else if let best = ranked.first, best.1 >= 0.72 {
                // Near an existing profile but below the match threshold: don't
                // create a competing profile from weak/ambiguous evidence.
                uncertain.insert(label)
            } else { newLabels.insert(label) }
        }
        // All local groups are distinct constraints. Conflicting matches are
        // declined together, rather than depending on enumeration order.
        for (_, group) in Dictionary(grouping: proposals.keys, by: { proposals[$0]! }) where group.count > 1 {
            for label in group { proposals[label] = nil; uncertain.insert(label) }
        }
        for label in newLabels {
            if labels.contains(where: { other in
                other != label && voices[other].map { Self.cosine(voices[label]!, $0) >= 0.80 } == true
            }) { uncertain.insert(label) }
        }
        var resolved: [String: SessionSpeakerIdentity] = [:]
        var mutableProfiles = profiles
        for label in labels {
            if let space, let voice = voices[label], !uncertain.contains(label),
               proposals[label] != nil || (newLabels.contains(label) && mutableProfiles.count < 128) {
                let id: String
                if let existing = proposals[label] { id = existing }
                else {
                    let local = try localIdentity(rawLabel: label, diarization: diarization, runID: runID, provenance: provenance, document: &document)
                    id = "remote_voice_" + String(InferenceFingerprint.digest(Data("\(local.id)|\(space)".utf8)).prefix(20))
                    if document.identities[local.id]?.displayName == nil { document.identities[local.id] = nil }
                }
                let identity = document.identities[id] ?? SessionSpeakerIdentity(id: id,
                    defaultLabel: "Speaker \(mutableProfiles.count + 1)", continuity: .sessionMatched)
                document.identities[id] = identity
                document.aliases[aliasPrefix + label] = id
                var profile = mutableProfiles[id] ?? SessionVoiceProfile(space: space, samples: [], anchors: [])
                // One contribution per source window/group. A cache-warm run
                // cannot add the same sample repeatedly or drift a centroid.
                let sample = SessionVoiceSample(evidenceKey: key, embedding: voice)
                if !profile.samples.contains(sample), profile.samples.count < 8 { profile.samples.append(sample) }
                mutableProfiles[id] = profile
                resolved[label] = identity
            } else {
                resolved[label] = try localIdentity(rawLabel: label, diarization: diarization, runID: runID,
                    provenance: provenance, document: &document)
            }
        }
        document.voiceProfiles = mutableProfiles
        return resolution(resolved)
    }

    /// Adjacent padded windows sometimes give a short boundary turn a noisy
    /// embedding. They still observe the same physical speech. Link only mutual,
    /// unambiguous temporal matches on verified identical audio/model evidence.
    /// Short turns never seed or modify a voice profile through this path.
    func linkSharedTurns(in windows: [PersistedInferenceWindow], document: inout SessionSpeakerIdentityDocument) throws -> [String: String] {
        func duration(_ ranges: [(Int, Int)]) -> Int {
            var count = 0, cursor = Int.min
            for (a, b) in ranges.sorted(by: { $0.0 < $1.0 }) where a < b {
                count += max(0, b - max(a, cursor)); cursor = max(cursor, b)
            }
            return count
        }
        func alias(_ window: PersistedInferenceWindow, _ label: String) -> String {
            "\(window.provenance.window.id)|\(window.diarizationRunID!.uuidString)|\(label)"
        }
        func ownedLabels(_ window: PersistedInferenceWindow) -> Set<String> {
            let w = window.provenance.window
            return Set((window.diarization?.segments ?? []).filter {
                $0.startMs + w.offsetMs < w.ownershipEndMs && $0.endMs + w.offsetMs > w.ownershipStartMs
            }.map(\.speaker))
        }
        let ordered = windows.filter { $0.diarization != nil && $0.diarizationRunID != nil }
            .sorted { $0.provenance.window.inputStartFrame < $1.provenance.window.inputStartFrame }
        var proposals: [String: Set<String>] = [:]
        for (left, right) in zip(ordered, ordered.dropFirst()) {
            try Task.checkCancellation()
            let p = left.provenance, q = right.provenance
            let lower = max(p.window.inputStartFrame, q.window.inputStartFrame)
            let upper = min(p.window.inputEndFrame, q.window.inputEndFrame)
            guard lower < upper, p.sessionID == q.sessionID, p.timelineVersion == q.timelineVersion,
                  p.hostTimeOrigin == q.hostTimeOrigin, p.sampleRate == q.sampleRate,
                  p.window.track == .system, q.window.track == .system,
                  p.diarizationBackend == q.diarizationBackend,
                  let artifact = p.diarizationArtifactFingerprint, artifact == q.diarizationArtifactFingerprint,
                  p.settings.diarizationSettingsIdentity == q.settings.diarizationSettingsIdentity,
                  left.diarization?.embeddingArtifactFingerprint == artifact,
                  right.diarization?.embeddingArtifactFingerprint == artifact,
                  let space = left.diarization?.embeddingSpace, space == right.diarization?.embeddingSpace else { continue }
            let audio = p.audio.filter { $0.startFrame < upper && $0.startFrame + $0.frameCount > lower }
            let otherAudio = q.audio.filter { $0.startFrame < upper && $0.startFrame + $0.frameCount > lower }
            guard !audio.isEmpty, audio == otherAudio,
                  audio.allSatisfy({ $0.contentHash != nil && $0.state == .committed }) else { continue }
            func ranges(_ window: PersistedInferenceWindow) -> [String: [(Int, Int)]] {
                var result: [String: [(Int, Int)]] = [:]
                for turn in window.diarization!.segments {
                    let a = max(Int(lower / 48), turn.startMs + window.provenance.window.offsetMs)
                    let b = min(Int(upper / 48), turn.endMs + window.provenance.window.offsetMs)
                    if a < b { result[turn.speaker, default: []].append((a, b)) }
                }
                return result
            }
            let l = ranges(left), r = ranges(right)
            for (label, intervals) in l {
                let matches = r.filter { _, other in
                    let common = duration(intervals.flatMap { a, b in other.map { (max(a, $0.0), min(b, $0.1)) } })
                    return common >= 750 && Double(common) / Double(max(duration(intervals), duration(other))) >= 0.80
                }
                guard matches.count == 1, let (otherLabel, otherIntervals) = matches.first else { continue }
                let reverse = l.filter { _, candidate in
                    let common = duration(candidate.flatMap { a, b in otherIntervals.map { (max(a, $0.0), min(b, $0.1)) } })
                    return common >= 750 && Double(common) / Double(max(duration(candidate), duration(otherIntervals))) >= 0.80
                }
                guard reverse.count == 1,
                      let leftID = document.aliases[alias(left, label)], let rightID = document.aliases[alias(right, otherLabel)] else { continue }
                for (local, voice, window, localLabel) in [(leftID, rightID, left, label), (rightID, leftID, right, otherLabel)] {
                    guard document.identities[local]?.continuity == .windowLocalOnly,
                          document.identities[voice]?.continuity == .sessionMatched,
                          ownedLabels(window).contains(localLabel) else { continue }
                    proposals[local, default: []].insert(voice)
                }
            }
        }
        var links = proposals.compactMapValues { $0.count == 1 ? $0.first : nil }
        // Distinct owned groups in one window must stay distinct, including
        // conflicting proposals discovered from opposite padding boundaries.
        for window in ordered {
            let owned = ownedLabels(window).compactMap { label -> String? in document.aliases[alias(window, label)] }
            for (_, group) in Dictionary(grouping: owned, by: { links[$0] ?? $0 }) where Set(group).count > 1 {
                for id in group { links[id] = nil }
            }
        }
        for (voice, locals) in Dictionary(grouping: links.keys, by: { links[$0]! }) {
            let names = Set(([voice] + locals).compactMap { document.identities[$0]?.displayName })
            if names.count > 1 { for local in locals { links[local] = nil } }
            else if let name = names.first { document.identities[voice]?.displayName = name }
        }
        for (local, voice) in links where document.identities[local]?.displayName == document.identities[voice]?.displayName {
            // The user now edits the shared identity. Do not retain a stale
            // local name that could resurrect a cleared name on the next rebuild.
            document.identities[local]?.displayName = nil
        }
        for (key, id) in document.aliases { if let voice = links[id] { document.aliases[key] = voice } }
        return links
    }

    func evidenceKey(_ provenance: WindowInferenceProvenance, document: SessionSpeakerIdentityDocument) throws -> String {
        try InferenceFingerprint.encode(LocalSpeakerScope(provenance: provenance,
            scopeSessionID: document.identityScopeSessionID ?? document.sessionID))
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private func representative(label: String, diarization: DiarizationDocument, window: InferenceWindow) -> [Float]? {
        let lower = window.ownershipStartMs - window.offsetMs
        let upper = window.ownershipEndMs - window.offsetMs
        var exclusive: [(Int, Int)] = diarization.segments.filter { $0.speaker == label }.compactMap {
            let a = max(lower, $0.startMs), b = min(upper, $0.endMs)
            return a < b ? (a, b) : nil
        }
        for other in diarization.segments where other.speaker != label {
            exclusive = exclusive.flatMap { a, b -> [(Int, Int)] in
                if other.endMs <= a || other.startMs >= b { return [(a, b)] }
                return [(a, min(b, other.startMs)), (max(a, other.endMs), b)].filter { $0.0 < $0.1 }
            }
        }
        var weighted = [Float](repeating: 0, count: 256)
        var supported: [(Int, Int)] = []
        // The domain independently bounds and validates input from any backend.
        for observation in (diarization.voiceObservations ?? []).prefix(128) where observation.speaker == label {
            guard let vector = DiarizationVoiceObservation.normalized(observation.embedding), observation.startMs < observation.endMs else { continue }
            let ranges = exclusive.compactMap { a, b -> (Int, Int)? in
                let start = max(a, observation.startMs), end = min(b, observation.endMs)
                return start < end ? (start, end) : nil
            }
            let weight = ranges.reduce(0) { $0 + $1.1 - $1.0 }
            guard weight > 0 else { continue }
            supported += ranges
            for i in weighted.indices { weighted[i] += vector[i] * Float(weight) }
        }
        // Union durations so repeated/overlapping chunk observations cannot turn
        // a short utterance into apparently sufficient evidence.
        var duration = 0, cursor = Int.min
        for (a, b) in supported.sorted(by: { $0.0 < $1.0 }) {
            duration += max(0, b - max(a, cursor)); cursor = max(cursor, b)
        }
        guard duration >= 3_000 else { return nil }
        return DiarizationVoiceObservation.normalized(weighted)
    }

    private func localIdentity(rawLabel: String, diarization: DiarizationDocument, runID: UUID,
                  provenance: WindowInferenceProvenance, document: inout SessionSpeakerIdentityDocument) throws -> SessionSpeakerIdentity {
        let scope = try InferenceFingerprint.encode(LocalSpeakerScope(provenance: provenance,
            scopeSessionID: document.identityScopeSessionID ?? document.sessionID))
        let aliasKey = "\(provenance.window.id)|\(runID.uuidString)|\(rawLabel)"
        if let id = document.aliases[aliasKey], let identity = document.identities[id], identity.continuity == .windowLocalOnly { return identity }
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

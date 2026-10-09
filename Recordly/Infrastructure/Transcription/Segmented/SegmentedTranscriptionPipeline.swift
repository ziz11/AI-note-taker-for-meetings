import Foundation

private struct WindowTranscriptCandidate {
    var segment: TranscriptSegment
    var provenance: WindowInferenceProvenance
    var sourceStartMs: Int
    var sourceEndMs: Int
    var hasWordTiming: Bool
}

/// Session orchestration over short semantic windows. Physical AAC chunks remain
/// canonical; this path never creates or decodes a whole-session PCM/mixed file.
struct SegmentedTranscriptionPipeline {
    var settings = InferenceWindowSettings()
    var mergeService = TranscriptMergeService()
    var renderService = TranscriptRenderService()

    func process(recording: RecordingSession, in directory: URL, runtimeProfile: InferenceRuntimeProfile,
                 engineFactory: any InferenceEngineFactory,
                 onStateChange: (@MainActor (TranscriptPipelineState) -> Void)?,
                 onProgress: (@MainActor (TranscriptProcessingProgress) -> Void)? = nil) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        guard recording.assets.audioManifestFile == "audio-manifest.json" else { throw TranscriptionPipelineError.unsupportedFormat }
        let temporaryDirectory = directory.appendingPathComponent("inference/temporary")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let reclaimedTemporaryFiles = try InferenceTemporaryAudio.removeStale(in: temporaryDirectory)
        let store = SessionAudioStore(directory: directory, sessionID: recording.id)
        let manifest = try store.reconcile()
        guard manifest.segments.contains(where: { $0.state == .committed && $0.frameCount > 0 }) else {
            throw TranscriptionPipelineError.missingInputAudio
        }
        guard let modelURL = runtimeProfile.modelArtifacts.asrModelURL,
              FileManager.default.fileExists(atPath: modelURL.path) else { throw TranscriptionPipelineError.modelMissing }
        let asr = try engineFactory.makeASREngine(for: runtimeProfile)
        let asrConfiguration = ASREngineConfiguration(modelURL: modelURL)
        let asrArtifact = try InferenceFingerprint.artifact(at: modelURL)
        var diarizationArtifact: String?
        var diarizationArtifactFailure: String?
        if manifest.segments.contains(where: { $0.track == .system }),
           let diarizationURL = runtimeProfile.modelArtifacts.diarizationModelURL {
            do { diarizationArtifact = try InferenceFingerprint.artifact(at: diarizationURL) }
            catch {
                try propagateInferenceCancellation(error)
                diarizationArtifactFailure = "Diarization artifact unavailable: \(error.localizedDescription)"
            }
        }
        let diarizationConfiguration = DiarizationEngineConfiguration(modelURL: runtimeProfile.modelArtifacts.diarizationModelURL)
        let reader = SessionAudioRangeReader(manifest: manifest, directory: directory)
        let cache = WindowInferenceCache(directory: directory)
        let identityStore = SessionSpeakerIdentityStore(directory: directory, sessionID: recording.id)
        var identities = try identityStore.load()
        let planner = InferenceWindowPlanner(settings: settings)
        let tracks = [TrackKind.microphone, .system].filter { track in manifest.segments.contains { $0.track == track } }
        var windows: [InferenceWindow] = []
        for track in tracks {
            windows += try planner.windows(track: track, durationFrames: manifest.segments.filter { $0.track == track }.map(\.endFrame).max() ?? 0)
        }
        let systemWindowCount = windows.filter { $0.track == .system }.count
        var progress = TranscriptProcessingProgress(
            asr: TranscriptStageProgress(total: windows.count),
            diarization: TranscriptStageProgress(total: systemWindowCount))
        let publisher = await TranscriptProgressPublisher(callback: onProgress)
        await publisher.publish(progress, force: true)
        var report = SegmentedInferenceReport(sessionID: recording.id,
            speakerContinuity: systemWindowCount > 1 ? .unresolvedAcrossWindows : (systemWindowCount == 1 ? .windowLocalOnly : .microphoneOnly),
            audioDiagnostics: manifest.diagnostics)
        if systemWindowCount > 1 {
            report.diagnostics.append("Remote speaker continuity across inference windows is unresolved. Local backend labels are not global identities.")
        }
        if systemWindowCount > 0 && diarizationArtifact == nil && diarizationArtifactFailure == nil {
            report.diagnostics.append("Diarization artifact identity unavailable; successful diarization is rerun rather than reusing an unverifiable model cache.")
        }
        if let diarizationArtifactFailure { report.diagnostics.append(diarizationArtifactFailure) }
        if reclaimedTemporaryFiles > 0 { report.diagnostics.append("Removed \(reclaimedTemporaryFiles) stale owned inference audio exports from a prior interrupted run.") }
        let reportURL = directory.appendingPathComponent("inference/report.json")
        var candidates: [WindowTranscriptCandidate] = []
        var completedASR: [TrackKind: Int] = [:]
        var diarizationSegments: [DiarizationSegment] = []
        var degraded: [PipelineDegradationReason] = manifest.diagnostics.isEmpty ? [] : [.captureDiagnostics]
        var diarization: (any DiarizationEngine)?
        var diarizationUnavailable = diarizationArtifactFailure
        var requiresDiarizationRestart = false
        do {
            if systemWindowCount > 0 && diarizationArtifactFailure == nil {
                do { diarization = try await MainActor.run { try engineFactory.makeDiarizationEngine(for: runtimeProfile) } }
                catch { try propagateInferenceCancellation(error); diarizationUnavailable = error.localizedDescription }
            }
            try writeInferenceJSON(report, to: reportURL)
            do {
                for (windowIndex, window) in windows.enumerated() {
                    progress.activeWindow = windowIndex + 1
                    try Task.checkCancellation()
                    let provenance = WindowInferenceProvenance(manifest: manifest, window: window, profile: runtimeProfile,
                        asrArtifactFingerprint: asrArtifact, asrEngineFingerprint: asr.cacheFingerprint(configuration: asrConfiguration),
                        diarizationArtifactFingerprint: window.track == .system ? diarizationArtifact : nil, settings: settings)
                    var result = cache.load(matching: provenance) ?? PersistedInferenceWindow(provenance: provenance)
                    let hadASR = result.asr != nil
                    let hadDiarization = result.diarization != nil && result.diarizationRunID != nil && diarizationArtifact != nil
                    if hadASR { report.reusedASRWindows += 1 }
                    if hadDiarization { report.reusedDiarizationWindows += 1 }
                    if window.track == .system && !hadDiarization { result.diarization = nil; result.diarizationRunID = nil }
                    let ownsAudio = hasUsableAudio(manifest: manifest, track: window.track, startFrame: window.ownershipStartFrame, endFrame: window.ownershipEndFrame)
                    if !ownsAudio {
                        report.windowFailures.append(failure(window, stage: "audio", message: "No committed audio in owned range; gap preserved as silence."))
                        report.completedWindows.append(window.id)
                        try writeInferenceJSON(report, to: reportURL)
                        progress.asr.handled += 1
                        progress.asr.skipped += 1
                        if window.track == .system {
                            progress.diarization.handled += 1
                            progress.diarization.skipped += 1
                        }
                        await publisher.publish(progress)
                        continue
                    }
                    let unavailable = provenance.audio.filter { $0.state != .committed }
                    for chunk in unavailable {
                        report.windowFailures.append(failure(window, stage: "audio", message: "Chunk \(chunk.id) is \(chunk.state.rawValue); its timeline range remains silent."))
                    }
                    let inputURL = temporaryDirectory.appendingPathComponent("\(window.id)-\(UUID().uuidString).caf")
                    defer { try? FileManager.default.removeItem(at: inputURL) }
                    let needsDiarization = window.track == .system && !hadDiarization && diarization != nil
                    var diarizationInputAvailable = true
                    if !hadASR || needsDiarization {
                        do {
                            try reader.materialize(track: window.track, startFrame: window.inputStartFrame, frameCount: window.frameCount, to: inputURL)
                            report.materializedWindowCount += 1
                            report.maximumMaterializedFrames = max(report.maximumMaterializedFrames, window.frameCount)
                        } catch {
                            try propagateInferenceCancellation(error)
                            report.windowFailures.append(failure(window, stage: "audio", message: error.localizedDescription))
                            if hadASR {
                                // Only optional diarization needed this export. The
                                // validated ASR cache still represents the audio and
                                // must survive with an explicit unknown remote speaker.
                                diarizationInputAvailable = false
                                result.diarizationFailure = "Diarization audio materialization failed: \(error.localizedDescription)"
                            } else {
                                report.completedWindows.append(window.id)
                                try writeInferenceJSON(report, to: reportURL)
                                progress.asr.handled += 1
                                progress.asr.failed += 1
                                if window.track == .system {
                                    progress.diarization.handled += 1
                                    progress.diarization.skipped += 1
                                }
                                await publisher.publish(progress)
                                continue
                            }
                        }
                    }
                    if !hadASR {
                        progress.state = window.track == .microphone ? .transcribingMic : .transcribingSystem
                        await onStateChange?(progress.state)
                        await publisher.publish(progress)
                        do {
                            result.asr = try await asr.transcribe(audioURL: inputURL, channel: window.track.transcriptChannel,
                                sessionID: recording.id, configuration: asrConfiguration)
                            try Task.checkCancellation()
                            result.asrFailure = nil
                        } catch {
                            try propagateInferenceCancellation(error)
                            result.asr = nil
                            result.asrFailure = error.localizedDescription
                        }
                        // A completed ASR window is durable even if cancellation happens
                        // during its optional diarization step.
                        try cache.save(result)
                    }
                    progress.asr.handled += 1
                    if hadASR { progress.asr.reused += 1 }
                    else if result.asr == nil { progress.asr.failed += 1 }
                    await publisher.publish(progress)
                    let attemptedDiarization = window.track == .system && !hadDiarization && diarizationInputAvailable && diarization != nil
                    if window.track == .system && !hadDiarization && diarizationInputAvailable {
                        if let activeDiarization = diarization {
                            progress.state = .diarizingSystem
                            await onStateChange?(progress.state)
                            await publisher.publish(progress)
                            do {
                                result.diarization = try await activeDiarization.diarize(window: PreparedDiarizationWindow(
                                    audioURL: inputURL, track: window.track, startFrame: window.inputStartFrame, frameCount: window.frameCount),
                                    sessionID: recording.id, configuration: diarizationConfiguration)
                                try Task.checkCancellation()
                                result.diarizationRunID = UUID()
                                result.diarizationFailure = nil
                            } catch {
                                try propagateInferenceCancellation(error)
                                result.diarization = nil
                                result.diarizationRunID = nil
                                result.diarizationFailure = error.localizedDescription
                                if let runtimeError = error as? DiarizationRuntimeError,
                                   [.timedOut, .runtimeBusy, .runtimeQuarantined].contains(runtimeError) {
                                    diarization = nil
                                    var diagnostic = "Further diarization skipped after runtime timeout or unavailable manager. \(error.localizedDescription)"
                                    if runtimeProfile.stageSelection.backend(for: .diarization) == .fluidAudio && runtimeError != .runtimeBusy {
                                        requiresDiarizationRestart = true
                                        diagnostic += " A timed out or cancelled SDK manager requires an app restart."
                                    }
                                    diarizationUnavailable = diagnostic
                                    report.diagnostics.append(diagnostic)
                                }
                            }
                        } else {
                            result.diarizationFailure = diarizationUnavailable ?? "Diarization is disabled or unavailable."
                        }
                    }
                    if window.track == .system {
                        progress.diarization.handled += 1
                        if hadDiarization { progress.diarization.reused += 1 }
                        else if result.diarization == nil {
                            if attemptedDiarization || !diarizationInputAvailable { progress.diarization.failed += 1 }
                            else { progress.diarization.skipped += 1 }
                        }
                    }
                    await publisher.publish(progress)
                    try cache.save(result)
                    if let error = result.asrFailure { report.windowFailures.append(failure(window, stage: "asr", message: error)) }
                    if let error = result.diarizationFailure { report.windowFailures.append(failure(window, stage: "diarization", message: error)) }
                    if let document = result.asr {
                        completedASR[window.track, default: 0] += 1
                        candidates += try makeCandidates(asr: document, diarization: result.diarization, diarizationRunID: result.diarizationRunID,
                            provenance: provenance, manifest: manifest, identityStore: identityStore, identities: &identities)
                        if document.segments.isEmpty { appendDegradation(window.track == .microphone ? .emptyMicASR : .emptySystemASR, to: &degraded) }
                    }
                    if let document = result.diarization, let runID = result.diarizationRunID {
                        for local in document.segments {
                            let start = max(window.ownershipStartMs, local.startMs + window.offsetMs)
                            let end = min(window.ownershipEndMs, local.endMs + window.offsetMs)
                            guard start < end else { continue }
                            let identity = try identityStore.identity(rawLabel: local.speaker, diarization: document,
                                runID: runID, provenance: provenance, document: &identities)
                            diarizationSegments.append(DiarizationSegment(id: "\(window.id)-\(local.id)", speaker: identity.id,
                                startMs: start, endMs: end, confidence: local.confidence))
                        }
                    }
                    try identityStore.save(identities)
                    report.completedWindows.append(window.id)
                    try writeInferenceJSON(report, to: reportURL)
                }
            }
            if report.windowFailures.contains(where: { $0.stage == "diarization" }) { appendDegradation(.diarizationDegraded, to: &degraded) }
            if report.windowFailures.contains(where: { $0.stage == "asr" && $0.track == .microphone }) { appendDegradation(.micASRFailedFallbackUsed, to: &degraded) }
            if report.windowFailures.contains(where: { $0.stage == "asr" && $0.track == .system }) { appendDegradation(.systemASRFailedFallbackUsed, to: &degraded) }
            if report.windowFailures.contains(where: { $0.stage == "audio" || $0.stage == "asr" }) { appendDegradation(.windowInferenceFailed, to: &degraded) }
            if systemWindowCount > 1 { appendDegradation(.speakerContinuityUnresolved, to: &degraded) }
            guard completedASR.values.reduce(0, +) > 0 else {
                report.status = "failed"; try writeInferenceJSON(report, to: reportURL)
                throw TranscriptionPipelineError.inferenceFailed(report.windowFailures.first?.message ?? "No inference windows completed.")
            }
            try Task.checkCancellation()
            let reconciled = try reconcile(candidates)
            report.events = try reconciled.map { TranscriptEventProvenance(eventID: $0.segment.id, windowID: $0.provenance.window.id, windowFingerprint: try $0.provenance.fingerprint) }
            let segments = mergeService.merge(micSegments: reconciled.filter { $0.segment.channel == .mic }.map(\.segment),
                systemSegments: reconciled.filter { $0.segment.channel == .system }.map(\.segment))
            progress.state = .merging
            progress.activeWindow = nil
            await onStateChange?(.merging)
            await publisher.publish(progress, force: true)
            try Task.checkCancellation()
            let channels = [TranscriptChannel.mic, .system].filter { completedASR[$0 == .mic ? .microphone : .system] != nil }
            let transcript = TranscriptDocument(version: 1, sessionID: recording.id, createdAt: Date(), channelsPresent: channels,
                diarizationApplied: !diarizationSegments.isEmpty, mergePolicy: .deterministicStartEndChannelID, segments: segments)
            try writeInferenceJSON(transcript, to: directory.appendingPathComponent("transcript.json"))
            progress.completedOutputSteps = 1
            progress.state = .renderingOutputs
            progress.activeWindow = nil
            await onStateChange?(.renderingOutputs)
            await publisher.publish(progress, force: true)
            try Task.checkCancellation()
            let rendered = renderService.render(document: transcript)
            try rendered.transcriptText.write(to: directory.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
            try rendered.srtText.write(to: directory.appendingPathComponent("transcript.srt"), atomically: true, encoding: .utf8)
            for channel in channels {
                let document = ASRDocument(version: 1, sessionID: recording.id, channel: channel, createdAt: Date(),
                    segments: segments.filter { $0.channel == channel }.map { ASRSegment(id: $0.id, startMs: $0.startMs, endMs: $0.endMs,
                        text: $0.text, confidence: $0.confidence, language: $0.language, words: $0.words) })
                try writeInferenceJSON(document, to: directory.appendingPathComponent(channel == .mic ? "mic.asr.json" : "system.asr.json"))
            }
            if !diarizationSegments.isEmpty {
                try writeInferenceJSON(DiarizationDocument(version: 1, sessionID: recording.id, createdAt: Date(), segments: diarizationSegments),
                    to: directory.appendingPathComponent("system.diarization.json"))
            }
            try Task.checkCancellation()
            report.status = "ready"; try writeInferenceJSON(report, to: reportURL)
            progress.state = .ready
            progress.activeWindow = nil
            await onStateChange?(.ready)
            await publisher.publish(progress, force: true)
            let diarizationFailure = report.windowFailures.filter { $0.stage == "diarization" }.map(\.message).first
            let continuityNote = systemWindowCount > 1 ? " Remote speaker continuity across windows remains unresolved." : ""
            let failureNote = report.windowFailures.isEmpty ? "" : " \(report.windowFailures.count) inference/audio range issues; see inference/report.json."
            let restartNote = requiresDiarizationRestart ? " Restart the app before retrying diarization; ASR remains available with unknown remote speakers." : ""
            return TranscriptionResult(transcriptFile: "transcript.txt", srtFile: "transcript.srt", transcriptJSONFile: "transcript.json",
                structuredTranscriptJSONFile: nil, structuredTranscriptTextFile: nil,
                micASRJSONFile: completedASR[.microphone] != nil ? "mic.asr.json" : nil,
                systemASRJSONFile: completedASR[.system] != nil ? "system.asr.json" : nil,
                systemDiarizationJSONFile: diarizationSegments.isEmpty ? nil : "system.diarization.json", diarizationApplied: !diarizationSegments.isEmpty,
                diarizationDegradedReason: diarizationFailure, diarizationModelUsed: systemWindowCount == 0 ? nil : (runtimeProfile.modelArtifacts.diarizationModelURL?.lastPathComponent ?? "sdk-managed; cache identity unverified"),
                degradedReasons: degraded, state: .ready, summary: "Transcript ready." + failureNote + continuityNote + restartNote, audioProvenance: .m4aRecovery)
        } catch {
            progress.isCancelled = error is CancellationError
            progress.state = progress.isCancelled ? .idle : .failed
            progress.activeWindow = nil
            await publisher.publish(progress, force: true)
            report.status = progress.isCancelled ? "cancelled" : "failed"
            try? writeInferenceJSON(report, to: reportURL)
            throw error
        }
    }

    private func makeCandidates(asr: ASRDocument, diarization: DiarizationDocument?, diarizationRunID: UUID?,
                                provenance: WindowInferenceProvenance, manifest: SessionAudioManifest,
                                identityStore: SessionSpeakerIdentityStore, identities: inout SessionSpeakerIdentityDocument) throws -> [WindowTranscriptCandidate] {
        let window = provenance.window
        let localLimitMs = Int(window.frameCount / 48)
        var output: [WindowTranscriptCandidate] = []
        for local in asr.segments {
            let sourceStart = window.offsetMs + max(0, local.startMs)
            let sourceEnd = window.offsetMs + min(localLimitMs, local.endMs)
            guard sourceStart < sourceEnd else { continue }
            var start: Int
            var end: Int
            var text: String
            var words: [ASRWord]?
            let hasWords = !(local.words ?? []).isEmpty
            if hasWords {
                var seen = Set<String>()
                let owned = (local.words ?? []).compactMap { word -> ASRWord? in
                    let start = word.startMs + window.offsetMs
                    let end = word.endMs + window.offsetMs
                    let midpoint = start + (end - start) / 2
                    // Keep ownership-overlapping alternatives until reconciliation:
                    // opposite timing jitter can put each prediction's midpoint
                    // outside its own window and would otherwise drop both.
                    guard start < end, overlap(start, end, window.ownershipStartMs, window.ownershipEndMs) > 0,
                          hasUsableAudio(manifest: manifest, track: window.track, startFrame: Int64(midpoint) * 48, endFrame: Int64(midpoint) * 48 + 1),
                          seen.insert("\(start):\(end):\(word.word)").inserted else { return nil }
                    return ASRWord(word: word.word, startMs: start, endMs: end, confidence: word.confidence)
                }
                guard !owned.isEmpty else { continue }
                words = owned
                start = owned.map(\.startMs).min()!
                end = owned.map(\.endMs).max()!
                text = owned.map { $0.word.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
            } else {
                let midpoint = sourceStart + (sourceEnd - sourceStart) / 2
                guard overlap(sourceStart, sourceEnd, window.ownershipStartMs, window.ownershipEndMs) > 0,
                      hasUsableAudio(manifest: manifest, track: window.track, startFrame: Int64(midpoint) * 48, endFrame: Int64(midpoint) * 48 + 1) else { continue }
                start = sourceStart
                end = sourceEnd
                text = local.text.trimmingCharacters(in: .whitespacesAndNewlines)
                words = nil
            }
            guard start < end, !text.isEmpty else { continue }
            var speaker = window.track == .microphone ? "You" : "Remote"
            var speakerID = window.track == .microphone ? "me" : "remote_unknown"
            var role: SpeakerRole = window.track == .microphone ? .me : .unknown
            var speakerConfidence: Double?
            if window.track == .system, let diarization, let runID = diarizationRunID {
                let localStart = start - window.offsetMs
                let localEnd = end - window.offsetMs
                if let best = diarization.segments.max(by: { overlap($0.startMs, $0.endMs, localStart, localEnd) < overlap($1.startMs, $1.endMs, localStart, localEnd) }),
                   Double(overlap(best.startMs, best.endMs, localStart, localEnd)) / Double(max(localEnd - localStart, 1)) >= 0.25 {
                    let identity = try identityStore.identity(rawLabel: best.speaker, diarization: diarization,
                        runID: runID, provenance: provenance, document: &identities)
                    speaker = identity.displayName ?? identity.defaultLabel
                    speakerID = identity.id
                    role = .remote
                    speakerConfidence = best.confidence
                }
            }
            let eventID = "event_" + InferenceFingerprint.digest(Data("\(try provenance.fingerprint)|\(start):\(end)|\(text)".utf8))
            let segment = TranscriptSegment(id: eventID, channel: window.track.transcriptChannel, speaker: speaker, speakerRole: role, speakerId: speakerID,
                startMs: start, endMs: end, text: text, confidence: local.confidence, language: local.language, speakerConfidence: speakerConfidence, words: words)
            output.append(WindowTranscriptCandidate(segment: segment, provenance: provenance, sourceStartMs: sourceStart, sourceEndMs: sourceEnd, hasWordTiming: hasWords))
        }
        return output
    }

    /// Ownership coverage resolves overlapping timed word alternatives. Without word timing, resolve only
    /// temporally overlapping alternatives from distinct windows of the same track.
    /// Repeated text at different times and simultaneous mic/system speech survive.
    private func reconcile(_ input: [WindowTranscriptCandidate]) throws -> [WindowTranscriptCandidate] {
        let candidates = try reconcileTimedWords(input)
        var accepted: [WindowTranscriptCandidate] = []
        var eventIDs = Set<String>()
        let ordered = candidates.sorted {
            if $0.segment.startMs != $1.segment.startMs { return $0.segment.startMs < $1.segment.startMs }
            return $0.segment.id < $1.segment.id
        }
        for candidate in ordered {
            guard eventIDs.insert(candidate.segment.id).inserted else { continue }
            if !candidate.hasWordTiming, let index = accepted.indices.last(where: { index in
                let prior = accepted[index]
                guard !prior.hasWordTiming, prior.segment.channel == candidate.segment.channel,
                      prior.provenance.window.id != candidate.provenance.window.id else { return false }
                let common = overlap(prior.sourceStartMs, prior.sourceEndMs, candidate.sourceStartMs, candidate.sourceEndMs)
                let shorter = min(prior.sourceEndMs - prior.sourceStartMs, candidate.sourceEndMs - candidate.sourceStartMs)
                return Double(common) / Double(max(shorter, 1)) >= 0.65
            }) {
                let prior = accepted[index]
                func ownershipRatio(_ value: WindowTranscriptCandidate) -> Double {
                    Double(overlap(value.sourceStartMs, value.sourceEndMs, value.provenance.window.ownershipStartMs,
                        value.provenance.window.ownershipEndMs)) / Double(max(value.sourceEndMs - value.sourceStartMs, 1))
                }
                if ownershipRatio(candidate) > ownershipRatio(prior) { accepted[index] = candidate }
            } else { accepted.append(candidate) }
        }
        return accepted
    }

    private func reconcileTimedWords(_ input: [WindowTranscriptCandidate]) throws -> [WindowTranscriptCandidate] {
        struct WordCandidate {
            var candidateIndex: Int
            var wordIndex: Int
            var word: ASRWord
            var window: InferenceWindow
            var channel: TranscriptChannel
            var key: String { "\(candidateIndex):\(wordIndex)" }
        }
        var words: [WordCandidate] = []
        for (candidateIndex, candidate) in input.enumerated() where candidate.hasWordTiming {
            for (wordIndex, word) in (candidate.segment.words ?? []).enumerated() {
                words.append(WordCandidate(candidateIndex: candidateIndex, wordIndex: wordIndex, word: word,
                    window: candidate.provenance.window, channel: candidate.segment.channel))
            }
        }
        words.sort {
            if $0.word.startMs != $1.word.startMs { return $0.word.startMs < $1.word.startMs }
            return $0.key < $1.key
        }
        var selected: [WordCandidate] = []
        var removed = Set<String>()
        func normalized(_ word: String) -> String {
            word.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        }
        func ownedRatio(_ word: WordCandidate) -> Double {
            Double(overlap(word.word.startMs, word.word.endMs, word.window.ownershipStartMs, word.window.ownershipEndMs))
                / Double(max(word.word.endMs - word.word.startMs, 1))
        }
        for word in words {
            let duplicate = selected.indices.last { index in
                let prior = selected[index]
                guard prior.channel == word.channel, prior.window.id != word.window.id,
                      normalized(prior.word.word) == normalized(word.word.word) else { return false }
                let common = overlap(prior.word.startMs, prior.word.endMs, word.word.startMs, word.word.endMs)
                let shorter = min(prior.word.endMs - prior.word.startMs, word.word.endMs - word.word.startMs)
                return common > 0 && Double(common) / Double(max(shorter, 1)) >= 0.5
            }
            if let duplicate {
                let prior = selected[duplicate]
                if ownedRatio(word) > ownedRatio(prior) {
                    removed.insert(prior.key)
                    selected[duplicate] = word
                } else { removed.insert(word.key) }
            } else { selected.append(word) }
        }
        var output: [WindowTranscriptCandidate] = []
        for (index, var candidate) in input.enumerated() {
            if candidate.hasWordTiming {
                let kept = (candidate.segment.words ?? []).enumerated().filter { !removed.contains("\(index):\($0.offset)") }.map(\.element)
                guard !kept.isEmpty else { continue }
                candidate.segment.words = kept
                candidate.segment.startMs = kept.map(\.startMs).min()!
                candidate.segment.endMs = kept.map(\.endMs).max()!
                candidate.segment.text = kept.map { $0.word.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
                candidate.segment.id = "event_" + InferenceFingerprint.digest(Data("\(try candidate.provenance.fingerprint)|\(candidate.segment.startMs):\(candidate.segment.endMs)|\(candidate.segment.text)".utf8))
            }
            output.append(candidate)
        }
        return output
    }

    private func failure(_ window: InferenceWindow, stage: String, message: String) -> InferenceWindowFailure {
        InferenceWindowFailure(windowID: window.id, track: window.track, startFrame: window.ownershipStartFrame, endFrame: window.ownershipEndFrame, stage: stage, message: message)
    }
    private func overlap(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> Int { max(0, min(b, d) - max(a, c)) }
    private func appendDegradation(_ reason: PipelineDegradationReason, to values: inout [PipelineDegradationReason]) {
        if !values.contains(reason) { values.append(reason) }
    }

    private func hasUsableAudio(manifest: SessionAudioManifest, track: TrackKind, startFrame: Int64, endFrame: Int64) -> Bool {
        for chunk in manifest.segments where chunk.track == track && chunk.state == .committed {
            let lower = max(startFrame, chunk.startFrame)
            let upper = min(endFrame, chunk.endFrame)
            guard lower < upper else { continue }
            var cursor = lower
            for gap in chunk.gaps.sorted(by: { $0.startFrame < $1.startFrame }) {
                let gapStart = max(lower, gap.startFrame)
                let gapEnd = min(upper, gap.startFrame + gap.frameCount)
                guard gapStart < gapEnd else { continue }
                if cursor < gapStart { return true }
                cursor = max(cursor, gapEnd)
            }
            if cursor < upper { return true }
        }
        return false
    }
}

private extension TrackKind {
    var transcriptChannel: TranscriptChannel { self == .microphone ? .mic : .system }
}

/// Coalesces fast cache/stage changes, with a trailing update so a long backend
/// call cannot leave the UI stuck on the previous phase. Boundaries always flush.
@MainActor
final class TranscriptProgressPublisher {
    private let callback: (@MainActor (TranscriptProcessingProgress) -> Void)?
    private var lastPublication: TimeInterval = -.infinity
    private var pendingSnapshot: TranscriptProcessingProgress?
    private var pendingPublication: Task<Void, Never>?

    init(callback: (@MainActor (TranscriptProcessingProgress) -> Void)?) {
        self.callback = callback
    }

    deinit { pendingPublication?.cancel() }

    func publish(_ snapshot: TranscriptProcessingProgress, force: Bool = false) {
        guard callback != nil else { return }
        pendingSnapshot = snapshot
        let remaining = 0.1 - (ProcessInfo.processInfo.systemUptime - lastPublication)
        if force || remaining <= 0 {
            pendingPublication?.cancel()
            pendingPublication = nil
            deliverPending()
        } else if pendingPublication == nil {
            pendingPublication = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                catch { return }
                guard !Task.isCancelled, let self else { return }
                self.pendingPublication = nil
                self.deliverPending()
            }
        }
    }

    private func deliverPending() {
        guard let snapshot = pendingSnapshot else { return }
        pendingSnapshot = nil
        lastPublication = ProcessInfo.processInfo.systemUptime
        callback?(snapshot)
    }
}

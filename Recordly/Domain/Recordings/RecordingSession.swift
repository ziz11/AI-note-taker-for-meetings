import Foundation

enum RecordingLifecycleState: String, Codable, CaseIterable {
    case idle
    case recording
    case processing
    case ready
    case failed

    var label: String {
        switch self {
        case .idle:
            return "Idle"
        case .recording:
            return "Recording"
        case .processing:
            return "Processing"
        case .ready:
            return "Ready"
        case .failed:
            return "Failed"
        }
    }
}

enum RecordingSource: String, Codable, CaseIterable {
    case liveCapture
    case importedAudio

    var label: String {
        switch self {
        case .liveCapture:
            return "Live"
        case .importedAudio:
            return "Imported"
        }
    }
}

enum TranscriptPipelineState: String, Codable, CaseIterable {
    case idle
    case queued
    case transcribingMic
    case transcribingSystem
    case diarizingSystem
    case merging
    case renderingOutputs
    case ready
    case failed

    var label: String {
        switch self {
        case .idle:
            return "Idle"
        case .queued:
            return "Queued"
        case .transcribingMic:
            return "Transcribing mic"
        case .transcribingSystem:
            return "Transcribing system"
        case .diarizingSystem:
            return "Diarizing system"
        case .merging:
            return "Merging transcript"
        case .renderingOutputs:
            return "Rendering outputs"
        case .ready:
            return "Transcript ready"
        case .failed:
            return "Transcript failed"
        }
    }
}

extension TranscriptPipelineState {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if let state = TranscriptPipelineState(rawValue: value) {
            self = state
            return
        }

        switch value {
        case "notConfigured":
            self = .idle
        case "placeholderReady":
            self = .ready
        default:
            self = .idle
        }
    }
}

enum RecordingSourceState: Equatable {
    case live
    case recorded
    case stub
    case missing

    var label: String {
        switch self {
        case .live:
            return "Listening"
        case .recorded:
            return "Captured"
        case .stub:
            return "Stub"
        case .missing:
            return "No signal"
        }
    }

    var systemImage: String {
        switch self {
        case .live:
            return "waveform"
        case .recorded:
            return "checkmark.circle.fill"
        case .stub:
            return "exclamationmark.triangle.fill"
        case .missing:
            return "slash.circle.fill"
        }
    }
}

enum PlaybackAudioSource: String, CaseIterable, Equatable {
    case microphone
    case system
    case mixed

    var label: String {
        switch self {
        case .microphone:
            return "MIC"
        case .system:
            return "SYSTEM"
        case .mixed:
            return "MIXED"
        }
    }
}

struct RecordingAssets: Codable, Hashable {
    var microphoneFile: String? = nil
    var systemAudioFile: String? = nil
    var mergedCallFile: String? = nil
    var importedAudioFile: String? = nil
    var transcriptFile: String? = nil
    var srtFile: String? = nil
    var transcriptJSONFile: String? = nil
    var micASRJSONFile: String? = nil
    var systemASRJSONFile: String? = nil
    var systemDiarizationJSONFile: String? = nil
    var summaryFile: String? = nil
    var connectorNotesFile: String? = nil
    var degradedReasons: [String]? = nil
}

struct RecordingSession: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    var isFavorite: Bool
    var lifecycleState: RecordingLifecycleState
    var transcriptState: TranscriptPipelineState
    var source: RecordingSource
    var notes: String
    var assets: RecordingAssets

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt
        case duration
        case isFavorite
        case lifecycleState
        case transcriptState
        case source
        case notes
        case assets
    }

    init(
        id: UUID,
        title: String,
        createdAt: Date,
        duration: TimeInterval,
        isFavorite: Bool = false,
        lifecycleState: RecordingLifecycleState,
        transcriptState: TranscriptPipelineState,
        source: RecordingSource,
        notes: String,
        assets: RecordingAssets
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.isFavorite = isFavorite
        self.lifecycleState = lifecycleState
        self.transcriptState = transcriptState
        self.source = source
        self.notes = notes
        self.assets = assets
    }

    static func draft(index: Int) -> RecordingSession {
        RecordingSession(
            id: UUID(),
            title: "New Recording \(index)",
            createdAt: Date(),
            duration: 0,
            lifecycleState: .recording,
            transcriptState: .idle,
            source: .liveCapture,
            notes: "Recording in progress.",
            assets: RecordingAssets()
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        lifecycleState = try container.decode(RecordingLifecycleState.self, forKey: .lifecycleState)
        transcriptState = try container.decodeIfPresent(TranscriptPipelineState.self, forKey: .transcriptState) ?? .idle
        source = try container.decodeIfPresent(RecordingSource.self, forKey: .source) ?? .liveCapture
        notes = try container.decode(String.self, forKey: .notes)
        assets = try container.decodeIfPresent(RecordingAssets.self, forKey: .assets) ?? RecordingAssets()
    }
}

extension RecordingSession {
    var hasSummarizationSource: Bool {
        assets.transcriptFile != nil || assets.srtFile != nil
    }

    var transcriptProgress: Double? {
        switch transcriptState {
        case .idle, .failed:
            return nil
        case .queued:
            return 0.08
        case .transcribingMic:
            return 0.24
        case .transcribingSystem:
            return 0.46
        case .diarizingSystem:
            return 0.64
        case .merging:
            return 0.82
        case .renderingOutputs:
            return 0.94
        case .ready:
            return 1
        }
    }

    var statusBadgeText: String {
        lifecycleState == .recording ? "Live" : transcriptState.label
    }

    var systemAudioSubtitle: String {
        if systemAudioState == .stub {
            return "Remote audio is stubbed in this build"
        }

        if assets.mergedCallFile != nil {
            return "System track captured and mixed into playback"
        }

        return "Remote party / system audio"
    }

    var transcriptPreviewFallback: String {
        "No transcript yet. The placeholder ASR connector writes a stub transcript after recording stops."
    }

    var summaryPreviewFallback: String {
        "No summary yet. Run the summarizer to generate structured notes for this recording."
    }

    var createdDayLabel: String {
        createdAt.formatted(date: .abbreviated, time: .omitted)
    }

    var createdTimeLabel: String {
        createdAt.formatted(date: .omitted, time: .shortened)
    }

    var durationLabel: String {
        let totalSeconds = max(Int(duration.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }

    var statusSummary: String {
        "\(lifecycleState.label) • \(transcriptState.label)"
    }

    var captureModeLabel: String {
        switch source {
        case .liveCapture:
            return "Mic + System"
        case .importedAudio:
            return "Imported Audio"
        }
    }

    var transcriptSourceLabel: String {
        switch source {
        case .liveCapture:
            if assets.systemAudioFile != nil {
                return "System + Mic"
            }
            return "Mic"
        case .importedAudio:
            return "Imported File"
        }
    }

    var primaryAudioFileName: String? {
        switch source {
        case .liveCapture:
            return assets.mergedCallFile ?? assets.microphoneFile ?? assets.systemAudioFile
        case .importedAudio:
            return assets.importedAudioFile
        }
    }

    var playableAudioFileName: String? {
        assets.importedAudioFile
            ?? assets.mergedCallFile
            ?? assets.microphoneFile
            ?? assets.systemAudioFile
    }

    func playbackFileName(for source: PlaybackAudioSource) -> String? {
        switch self.source {
        case .importedAudio:
            return source == .mixed ? assets.importedAudioFile : nil
        case .liveCapture:
            switch source {
            case .microphone:
                return assets.microphoneFile
            case .system:
                return assets.systemAudioFile
            case .mixed:
                return assets.mergedCallFile
            }
        }
    }

    var isMixedTrackProcessing: Bool {
        guard source == .liveCapture else { return false }
        guard assets.mergedCallFile == nil else { return false }
        guard assets.microphoneFile != nil || assets.systemAudioFile != nil else { return false }
        return notes.localizedCaseInsensitiveContains("merge is running in background")
            || notes.localizedCaseInsensitiveContains("offline merge")
    }

    var microphoneState: RecordingSourceState {
        if source == .importedAudio {
            return .missing
        }

        if lifecycleState == .recording {
            return .live
        }

        if assets.microphoneFile != nil {
            return .recorded
        }

        return .missing
    }

    var systemAudioState: RecordingSourceState {
        if source == .importedAudio {
            return .missing
        }

        if lifecycleState == .recording, assets.systemAudioFile != nil {
            return .live
        }

        if assets.systemAudioFile != nil {
            return .recorded
        }

        if assets.connectorNotesFile != nil {
            return .stub
        }

        return .missing
    }
}

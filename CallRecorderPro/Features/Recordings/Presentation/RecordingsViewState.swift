import Foundation

struct RecordingsAlertState: Equatable {
    var message: String
}

struct RecordingMeterLevels: Equatable {
    var microphoneLevel: Double = 0
    var systemAudioLevel: Double = 0
    var systemAudioLabel: String = "Stub"
}

struct RecordingRuntimeState: Equatable {
    var isRecording = false
    var activeRecordingID: UUID?
    var activeDuration: TimeInterval = 0
    var recordingStartedAt: Date?
    var sidebarStatus = "Ready"
    var activityStatus = "Ready"
    var meterLevels = RecordingMeterLevels()
    var transcriptionProgress: Double?
    var transcriptionStageLabel: String?
    var summarizationProgress: Double?
    var summarizationStageLabel: String?

    var recordingDurationLabel: String {
        let totalSeconds = max(Int(activeDuration.rounded()), 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct RecordingsViewState: Equatable {
    var autoTranscribeEnabled = true
    var autoSummarizeEnabled = false
    var searchQuery = ""
    var selectedModelProfile: ModelProfile = .balanced
    var activeEngineName: String
    var storageLocationPath = ""
    var runtime = RecordingRuntimeState()
    var alert: RecordingsAlertState?
}

struct PlaybackState: Equatable {
    struct SourceAvailability: Equatable, Identifiable {
        var source: PlaybackAudioSource
        var isAvailable: Bool
        var isProcessing: Bool

        var id: PlaybackAudioSource { source }
    }

    var recordingID: UUID?
    var fileName: String?
    var isAvailable = false
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var playbackRate: Float = 1
    var selectedSource: PlaybackAudioSource = .mixed
    var sourceAvailability: [SourceAvailability] = []

    static let supportedPlaybackRates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    var currentTimeLabel: String {
        Self.format(currentTime)
    }

    var remainingTimeLabel: String {
        let remaining = max(duration - currentTime, 0)
        return "-\(Self.format(remaining))"
    }

    var playbackRateLabel: String {
        if playbackRate == floor(playbackRate) {
            return String(format: "%.0fx", playbackRate)
        }

        return String(format: "%.2gx", playbackRate)
    }

    private static func format(_ time: TimeInterval) -> String {
        let totalSeconds = max(Int(time.rounded(.down)), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }
}

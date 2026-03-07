import AVFoundation
import Foundation

@MainActor
final class PlaybackController: NSObject, @preconcurrency AVAudioPlayerDelegate {
    private let repository: RecordingsPersistence
    private let previewMode: Bool
    private var player: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var preferredSourceByRecordingID: [UUID: PlaybackAudioSource] = [:]
    private var playbackRate: Float = 1

    private(set) var state = PlaybackState() {
        didSet {
            onStateChange?(state)
        }
    }

    var onStateChange: ((PlaybackState) -> Void)?

    init(repository: RecordingsPersistence, previewMode: Bool) {
        self.repository = repository
        self.previewMode = previewMode
        super.init()
    }

    func syncSelection(_ recording: RecordingSession?) {
        guard let recording else {
            stop(resetPosition: true)
            state = PlaybackState()
            return
        }

        let sourceAvailability = buildSourceAvailability(for: recording)
        let selectedSource = resolveSelectedSource(for: recording, availability: sourceAvailability)
        let selectedFileName = recording.playbackFileName(for: selectedSource)

        if state.recordingID == recording.id,
           state.fileName == selectedFileName,
           state.selectedSource == selectedSource,
           state.sourceAvailability == sourceAvailability {
            syncStateFromPlayer()
            return
        }

        stop(resetPosition: true)
        state = PlaybackState(
            recordingID: recording.id,
            fileName: selectedFileName,
            isAvailable: selectedFileName != nil,
            duration: recording.duration,
            playbackRate: playbackRate,
            selectedSource: selectedSource,
            sourceAvailability: sourceAvailability
        )
    }

    func selectSource(_ source: PlaybackAudioSource, for recording: RecordingSession) {
        preferredSourceByRecordingID[recording.id] = source
        syncSelection(recording)
    }

    func togglePlayback(for recording: RecordingSession) throws {
        try preparePlayer(for: recording)
        guard let player, state.isAvailable else {
            return
        }

        if player.isPlaying {
            player.pause()
            state.isPlaying = false
            stopTimer()
        } else {
            player.play()
            state.isPlaying = true
            startTimer()
        }
    }

    func seek(for recording: RecordingSession, to progress: Double) throws {
        try preparePlayer(for: recording)
        guard let player, state.isAvailable else {
            return
        }

        let targetTime = max(0, min(progress, 1)) * max(player.duration, 0)
        player.currentTime = targetTime
        syncStateFromPlayer()
    }

    func skip(for recording: RecordingSession, by offset: TimeInterval) throws {
        try preparePlayer(for: recording)
        guard let player, state.isAvailable else {
            return
        }

        let targetTime = min(max(player.currentTime + offset, 0), player.duration)
        player.currentTime = targetTime
        syncStateFromPlayer()
    }

    func setPlaybackRate(_ rate: Float, for recording: RecordingSession) {
        let normalizedRate = PlaybackState.supportedPlaybackRates.contains(rate) ? rate : 1
        playbackRate = normalizedRate
        state.playbackRate = normalizedRate
        if state.recordingID != recording.id {
            syncSelection(recording)
        }
        player?.enableRate = true
        player?.rate = normalizedRate
    }

    func stop(resetPosition: Bool) {
        if let player {
            player.stop()
            if resetPosition {
                player.currentTime = 0
            }
        }

        stopTimer()
        player = nil
        state.isPlaying = false
        state.currentTime = resetPosition ? 0 : state.currentTime
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stopTimer()
        state.isPlaying = false
        state.currentTime = flag ? player.duration : player.currentTime
    }

    deinit {
        playbackTimer?.invalidate()
    }

    private func preparePlayer(for recording: RecordingSession) throws {
        let sourceAvailability = buildSourceAvailability(for: recording)
        let selectedSource = resolveSelectedSource(for: recording, availability: sourceAvailability)
        let selectedFileName = recording.playbackFileName(for: selectedSource)

        guard state.recordingID == recording.id,
              state.fileName == selectedFileName,
              state.selectedSource == selectedSource,
              state.sourceAvailability == sourceAvailability,
              player != nil else {
            try loadPlayer(for: recording)
            return
        }

        syncStateFromPlayer()
    }

    private func loadPlayer(for recording: RecordingSession) throws {
        stop(resetPosition: true)

        let sourceAvailability = buildSourceAvailability(for: recording)
        let selectedSource = resolveSelectedSource(for: recording, availability: sourceAvailability)

        guard let fileName = recording.playbackFileName(for: selectedSource) else {
            state = PlaybackState(
                recordingID: recording.id,
                duration: recording.duration,
                playbackRate: playbackRate,
                selectedSource: selectedSource,
                sourceAvailability: sourceAvailability
            )
            return
        }

        if previewMode {
            state = PlaybackState(
                recordingID: recording.id,
                fileName: fileName,
                isAvailable: true,
                duration: recording.duration,
                playbackRate: playbackRate,
                selectedSource: selectedSource,
                sourceAvailability: sourceAvailability
            )
            return
        }

        let sessionDirectory = try repository.sessionDirectory(for: recording.id)
        let audioURL = sessionDirectory.appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            state = PlaybackState(
                recordingID: recording.id,
                fileName: fileName,
                duration: recording.duration,
                playbackRate: playbackRate,
                selectedSource: selectedSource,
                sourceAvailability: sourceAvailability
            )
            return
        }

        let player = try AVAudioPlayer(contentsOf: audioURL)
        player.delegate = self
        player.enableRate = true
        player.rate = playbackRate
        player.prepareToPlay()
        self.player = player
        state = PlaybackState(
            recordingID: recording.id,
            fileName: fileName,
            isAvailable: true,
            duration: player.duration,
            playbackRate: playbackRate,
            selectedSource: selectedSource,
            sourceAvailability: sourceAvailability
        )
    }

    private func resolveSelectedSource(
        for recording: RecordingSession,
        availability: [PlaybackState.SourceAvailability]
    ) -> PlaybackAudioSource {
        if let preferred = preferredSourceByRecordingID[recording.id],
           availability.contains(where: { $0.source == preferred && $0.isAvailable }) {
            return preferred
        }

        let priority: [PlaybackAudioSource] = [.mixed, .microphone, .system]
        if let best = priority.first(where: { source in
            availability.contains(where: { $0.source == source && $0.isAvailable })
        }) {
            return best
        }

        return .mixed
    }

    private func buildSourceAvailability(for recording: RecordingSession) -> [PlaybackState.SourceAvailability] {
        let sources: [PlaybackAudioSource] = [.microphone, .system, .mixed]
        let existingFiles = existingFilesByName(for: recording)

        return sources.map { source in
            let fileName = recording.playbackFileName(for: source)
            let isAvailable: Bool
            if let fileName {
                isAvailable = previewMode || existingFiles.contains(fileName)
            } else {
                isAvailable = false
            }

            return PlaybackState.SourceAvailability(
                source: source,
                isAvailable: isAvailable,
                isProcessing: source == .mixed && recording.isMixedTrackProcessing
            )
        }
    }

    private func existingFilesByName(for recording: RecordingSession) -> Set<String> {
        guard !previewMode else { return [] }
        guard let sessionDirectory = try? repository.sessionDirectory(for: recording.id),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: sessionDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return Set(urls.map(\.lastPathComponent))
    }

    private func syncStateFromPlayer() {
        guard let player else { return }
        state.currentTime = player.currentTime
        state.duration = player.duration
        state.isPlaying = player.isPlaying
        state.playbackRate = playbackRate
    }

    private func startTimer() {
        stopTimer()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncStateFromPlayer()
            }
        }
    }

    private func stopTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
}

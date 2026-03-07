# Recordly Agent Notes

## Current In-App Modules

- App shell: startup, window lifecycle, and app commands in `Recordly/RecordlyApp.swift`.
- Recordings store: central state, recording flow, playback, import, delete, rename, and transcription queueing in `Recordly/Features/Recordings/Application/RecordingsStore.swift`.
- Capture module: microphone capture, system-audio capture, and mixed-track generation in `Recordly/Infrastructure/Capture/AudioCaptureService.swift`.
- Persistence module: session folders, metadata save/load, transcript caching, and imported-audio copying in `Recordly/Infrastructure/Persistence/RecordingsRepository.swift` and `Recordly/Infrastructure/Persistence/AppPaths.swift`.
- Transcription module: CLI-backed transcription pipeline and engines in `Recordly/Infrastructure/Transcription/TranscriptionPipeline.swift`, `WhisperCppEngine`, and `CliSystemDiarizationService`.
- Session model module: recording states, asset references, and playback source selection in `Recordly/Domain/Recordings/RecordingSession.swift`.
- Sidebar UI: recording list, start/stop, import, meters, and global status in `Recordly/Views/RecordingSidebarView.swift`.
- Detail UI: built-in player, status cards, asset list, and transcript preview in `Recordly/Views/RecordingDetailView.swift`.
- Supporting UI components: recording row, record button, and empty state in `Recordly/Views/RecordingRowView.swift`, `Recordly/Views/RecordButton.swift`, and `Recordly/Views/EmptyRecordingView.swift`.

## Current User-Facing Features

- Live recording.
- Audio import.
- Dual-track capture under the hood: microphone plus system audio.
- Mixed playback track generation.
- Local session storage.
- Built-in playback.
- CLI transcript generation and fallback summary composition.
- Session management: rename, delete, open folder, and copy transcript.

## Recording Asset Contract

For live capture, each session may contain:

- `mic.raw.caf`: normalized microphone raw track.
- `system.raw.caf`: normalized system audio raw track.
- `merged-call.caf`: intermediate merged working artifact.
- `merged-call.m4a`: mixed playback track used by the in-app player when available.

Playback should prefer the mixed track for live recordings. Imported recordings continue to use the imported file directly.

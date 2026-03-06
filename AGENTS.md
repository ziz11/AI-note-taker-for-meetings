# CallRecorderPro Agent Notes

## Current In-App Modules

- App shell: startup, window lifecycle, and app commands in `CallRecorderPro/CallRecorderProApp.swift`.
- Recordings store: central state, recording flow, playback, import, delete, rename, and transcription queueing in `CallRecorderPro/Services/RecordingsStore.swift`.
- Capture module: microphone capture, system-audio capture, and mixed-track generation in `CallRecorderPro/Services/AudioCaptureService.swift`.
- Persistence module: session folders, metadata save/load, transcript caching, and imported-audio copying in `CallRecorderPro/Services/RecordingsRepository.swift` and `CallRecorderPro/Services/AppPaths.swift`.
- Transcription module: placeholder transcription pipeline and engine in `CallRecorderPro/Services/TranscriptionPipeline.swift`.
- Session model module: recording states, asset references, and playback source selection in `CallRecorderPro/Models/RecordingSession.swift`.
- Sidebar UI: recording list, start/stop, import, meters, and global status in `CallRecorderPro/Views/RecordingSidebarView.swift`.
- Detail UI: built-in player, status cards, asset list, and transcript preview in `CallRecorderPro/Views/RecordingDetailView.swift`.
- Supporting UI components: recording row, record button, and empty state in `CallRecorderPro/Views/RecordingRowView.swift`, `CallRecorderPro/Views/RecordButton.swift`, and `CallRecorderPro/Views/EmptyRecordingView.swift`.

## Current User-Facing Features

- Live recording.
- Audio import.
- Dual-track capture under the hood: microphone plus system audio.
- Mixed playback track generation.
- Local session storage.
- Built-in playback.
- Placeholder transcript generation.
- Session management: rename, delete, open folder, and copy transcript.

## Recording Asset Contract

For live capture, each session may contain:

- `microphone.m4a`: local microphone track.
- `system-audio.caf`: captured system/remote track.
- `merged-call.m4a`: mixed playback track used by the in-app player when available.

Playback should prefer the mixed track for live recordings. Imported recordings continue to use the imported file directly.

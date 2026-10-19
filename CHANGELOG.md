# Changelog

User-visible changes since `12bf95286e8d485469de7779510db2e8e6c33b6f` (2026-05-25), consolidated on 2026-10-20. This combines 47 commits covering capture reliability, native inference, UI and packaging. It does not introduce a new application version.

## Unreleased — consolidated Recordly update

### Capture reliability and local development foundations

- Added a bounded ScreenCaptureKit recovery coordinator for stopped or stalled audio streams, with automatic restart attempts, persistent capture-health alerts and a single notification for terminal failures.
- Hardened recovery deadlines, failed-resource cleanup and pending stream-stop handling. Capture is considered healthy after audio is successfully written, rather than merely receiving a restart callback.
- Moved audio-buffer fan-in to a dedicated capture pipeline, reduced main-actor work, throttled meter publication and minimized the ScreenCaptureKit video workload. Added signposts and a separate energy-baseline script; these tools are not evidence of measured battery savings.
- Optimized legacy CAF merging and transient-file cleanup; memoized share/playback availability to reduce repeated UI filesystem work.
- Replaced the app icon with a minimal cube and added a reproducible icon generator.
- Added persistent local Debug signing setup, including login-keychain, certificate export and system LibreSSL compatibility fixes. Rebuilds retain the same signing identity instead of using changing ad-hoc identities.

### Added

- **Audio Pipeline V2:** independent microphone/system AAC chunks, a versioned session manifest, recovery sidecars and a shared capture timeline. Processing uses resumable 50-second ownership windows with context; temporary PCM inputs are limited to 60 seconds.
- Native playback of the segmented timeline and an explicit combined-audio export. Ordinary capture and processing no longer require a full-session PCM/mixed audio copy.
- Separate handled/total transcription and diarization counters, overall progress, and explicit cache reuse, skipped work and failed ranges. Successful windows survive failures elsewhere in a recording.
- **Parakeet Ultra** as the default transcription model, with **Parakeet TDT 0.6B v3** available as a saved alternative. Download, selection, retry and removal are separate guarded actions; a running job keeps its original model.
- Model-scoped voice evidence and conservative session speaker matching across windows, with persistent speaker IDs and names when the evidence supports a match.
- A small compute/performance toolbar icon and compact popover: model-loading time, ASR/job speed, process CPU and resident memory, main-queue delay, system thermal state and Low Power Mode. Background sampling runs every two seconds while active and stops when idle; bounded logs stay local.
- A locally signed standalone build script, versioned ZIP archives, checksums and release records. The app runs without Xcode at runtime on this Mac.

### Changed

- Upgraded **FluidAudio 0.14.0 → 0.17.7**, pinned to revision `503b4bd1bbf7220882de39fe8ae6716aae4132da`; added upstream change notes and required third-party notices.
- ASR and speaker-separation models use their SDK-managed provisioning and caches. Missing selected models produce a download prompt rather than silently selecting a different ASR model.
- Reduced Models settings to a minimal **400×230-point** panel with two transcription choices and a separate speaker-status row. Download progress identifies the current asset, with retry on failure.
- **Disabled summarization:** Summary controls are placeholders, no llama.cpp/MLX summary runtime is invoked, and recording detail opens Transcript by default. Existing saved artifacts are preserved.
- Coalesced inference progress updates to 10 Hz and assigned queued transcription utility priority. Diagnostics have independent observation instead of republishing the recordings list for each sample.
- Made the ASR Core ML `cpuAndNeuralEngine` policy explicit. Speaker separation retains its automatic device policy, which permits GPU use.

### Fixed

- Excess filesystem allocation in closed AAC chunks: verified copying reclaims unused allocation without re-encoding or changing the audio bytes. This does not bulk-rewrite older recordings.
- Progress switching between vague stage labels without clear completed/total counts, and overall progress regressing or reaching 100% before output completion.
- Extra spaces between timed subword tokens during transcript assembly and display: reconstruction preserves the decoded text's word boundaries within processing windows and avoids line breaks inside aligned words.
- Speaker attribution that assigned an entire ASR phrase to one diarization turn. Timed phrases now split at speaker changes; fragmented voice evidence and shared window boundaries improve conservative cross-window matching.
- **Slow opening of long transcripts:** replaced one large selectable SwiftUI Text with native TextKit layout. Selection and unchanged text storage survive playback/progress updates.

### Compatibility and known issues

- Legacy single-file recordings remain readable. Previously assembled transcripts are not automatically rebuilt; spacing corrections require explicit reprocessing from compatible raw window caches.
- **Word fragments can still be split across processing-window boundaries**, such as “артефак” / “тов” at 50 seconds. The subword-spacing correction does not fully resolve that remaining boundary bug.
- Session speaker matching remains partial. Short, overlapping or ambiguous voice evidence can remain window-local or unknown; stable IDs do not establish speaker-recognition accuracy.
- CPU + Neural Engine is an allowed-device policy, not measured ANE utilization. Diarization may use GPU. No per-app watts, battery savings or speedup against a GPU implementation has been established.
- Archived standalone **0.1.0 (4)** contains compute diagnostics but predates the final long-transcript layout fix. Build from the current checkout to include that fix. Historical build records retain their original source hashes. Binary archives and obsolete standalone tags were removed from Git on 2026-10-20.
- The persistent local signing identity supports this Mac; these archives are not a notarized Developer ID distribution.

### Repository housekeeping — 2026-10-20

- Consolidated all 47 commits after `12bf952` into one delivery commit in `develop` and `main`; preserved the baseline and a local history backup. Application code is unchanged by this rewrite.

- Removed seven standalone ZIP archives (about 150 MB) from source and downloadable branch history. Historical reports/checksums remain as text.
- Added ignore rules for archives, application bundles and packaged build output. Local builds stay in ignored `build/`; distributable binaries belong in release assets or separate storage.
- Removed obsolete standalone tags that would otherwise bring the binaries back in a fresh clone. Application, inference and test code are unchanged.

### Verification and release references

- The consolidated application code passed **395 tests, zero failures, eight optional skips** on 2026-10-20. Adding this changelog does not change application or test code.
- [Current project status](docs/project-status.md)
- [FluidAudio upstream upgrade notes](docs/fluidaudio-upgrade-changelog.md)
- [Speaker-alignment evidence and limits](docs/recording-7C943EA0-verification.md)
- [Compute measurements and evidence limits](docs/performance-diagnostics-2026-10-16.md)
- [Long-transcript layout fix](docs/recording-open-lag-fix-2026-10-16.md)
- [Archived standalone build 4](releases/standalone-2026-10-16-performance-diagnostics/README.md)

# Barkenson: capabilities and release limits

Public name: **Barkenson** (confirmed by the author on 20 October 2026). Description: **Meeting recorder for Mac.** The intended distribution is a free standalone app bundle in GitHub Releases, with a GitHub Pages website. These are release decisions, not evidence that a public release or website already exists.

## Evidence boundary

This audit inspected source at `327e976460b363d621a150d4c0d4b085e2cafabe` on 20 October 2026, the current documentation and the locally available `origin/docs/readme-uk-english:README.md` for PR #22. It did **not** build, launch or exercise the app, download models, process recordings, inspect a newly produced bundle, or validate Gatekeeper on another Mac. No fresh runtime or release acceptance is claimed here.

The source tree still uses the internal name Recordly. Links below deliberately follow those existing source paths. Reports in [project status](../project-status.md) describe earlier tests and local builds; their test counts, timings, signatures and checksums do not certify a later Barkenson build.

## Implemented behaviour found in source

| Area | Source-supported behaviour | Limits to communicate |
| --- | --- | --- |
| Live recording | Records microphone and Mac system audio through native capture services. New sessions retain separate mono AAC tracks, a versioned manifest and recovery sidecars. | Requires Microphone and Screen Recording permission. System capture sets up a display stream and requires an active display. It captures system audio, rather than selecting one meeting app. Do not promise per-app isolation or video recording. |
| Import | The import panel accepts MPEG-4 audio, MP3, WAV, AIFF, CAF and the general audio type; imported audio can be transcribed. | A file appearing in the picker does not guarantee that its codec can be decoded. Import is unavailable during recording. Imported audio is routed through the microphone/imported transcription path; do not promise multi-speaker separation of arbitrary imported files. |
| Transcription | Local FluidAudio 0.17.7, pinned to revision `503b4bd1bbf7220882de39fe8ae6716aae4132da`. Parakeet Ultra is the default; Parakeet TDT 0.6B v3 is selectable. A job retains its resolved model. | Models must be downloaded first. Download and active selection are separate actions. Transcription is post-recording processing; there is no live streaming transcript. No meeting-wide accuracy, faster-than-real-time or battery-life guarantee follows from this inspection. |
| Languages | Model descriptions in the app call Ultra and v3 multilingual. | The app has no source-defined supported-language list or language selector. The native result mapper sets `language` to `nil`; do not describe this as app-provided language detection. The historical SDK changelog mentions 25 languages, but this audit has not verified a model-specific language list or quality for each language. Avoid a numbered language claim or inferred list in public copy until checked against the exact model documentation. |
| Speaker labels | System-track diarisation uses the separately provisioned FluidAudio speaker package. Source includes session voice identities, timed speaker changes, partial matching and persistent speaker names. | Microphone speech is a local channel, not general microphone diarisation. Speaker assignment can remain unknown or split one person across identities. Overlap, brief turns and ambiguous voices need real meeting acceptance; stable IDs do not prove identity accuracy. Diarisation failure degrades labels rather than failing otherwise usable transcription. |
| Playback | Native session-timeline playback and explicit combined audio export; legacy single-file recordings remain readable. | Timeline gaps are meaningful. Routine V2 processing does not create a whole-session PCM or mixed source file. Combined export is generated on request. |
| Transcript artefacts | The pipeline writes `transcript.txt`, `transcript.srt` and `transcript.json`, including speaker information available to rendering. The recording folder is accessible through **Open Folder**. | **Export Transcript** currently copies the session's `transcriptFile`, normally TXT. There is no visible TXT/SRT/JSON export format selector. Describe SRT and JSON as files in the recording folder, rather than three button export options. |
| Recovery | Durable session metadata, completed chunks and matching inference-window caches support restarting work. Independent successful tracks/windows are retained when others fail; degraded ranges are recorded. | Cache reuse depends on provenance, audio, model and settings. An unfinished active chunk can be lost on termination; power-loss durability remains best effort. Recovery cannot restore audio never durably written. Missing all usable ASR is still failure; cancellation propagates. |
| Processing bounds | V2 inference owns 50-second intervals with up to 5 seconds of context on each side, for at most 60 seconds of PCM input per window. Jobs are queued with concurrency one. | These are per-window bounds, not a measured whole-app RAM ceiling or maximum supported meeting duration. Legacy/imported single-file preparation follows another path. Long capture, whole-app memory, energy and GUI latency remain acceptance work. |
| Diagnostics | Local process CPU/RAM, stage timings, thermal state and Low Power Mode diagnostics are implemented. ASR requests CPU plus Neural Engine compute. | It does not measure live ANE utilisation, watts or energy saved. Diarisation may use GPU. Compute configuration is not proof of realised utilisation. |
| Summaries | App composition disables summarisation. Store summary invocation is empty; workflow summary invocation returns the recording without inference or writes. The UI marks generation unavailable. | Automatic summaries are not a delivered feature. Retained backends, preferences and readable old summary artefacts must not be described as enabled generation. Do not enable them for this release. |

Primary source references:

- Capture and permissions: [AudioCaptureService.swift](../../Recordly/Infrastructure/Capture/AudioCaptureService.swift), [SessionAudioManifest.swift](../../Recordly/Infrastructure/Capture/SessionAudioManifest.swift).
- Import, export and recovery scheduling: [RecordingsStore.swift](../../Recordly/Features/Recordings/Application/RecordingsStore.swift); visible actions: [RecordingDetailView.swift](../../Recordly/Features/Recordings/Views/RecordingDetailView.swift).
- Models and architecture guards: [FluidAudioASREngine.swift](../../Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioASREngine.swift), [ASR provider](../../Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioASRModelProvider.swift), [transcription service](../../Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioTranscriptionService.swift), [diarisation engine](../../Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioDiarizationEngine.swift).
- Transcript artefacts and degradation: [TranscriptionPipeline.swift](../../Recordly/Infrastructure/Transcription/TranscriptionPipeline.swift); V2 bounds and provenance: [InferenceWindowPlan.swift](../../Recordly/Infrastructure/Transcription/Segmented/InferenceWindowPlan.swift), [segmented pipeline](../../Recordly/Infrastructure/Transcription/Segmented/SegmentedTranscriptionPipeline.swift).
- Disabled summaries: [DefaultInferenceComposition.swift](../../Recordly/Infrastructure/Inference/Composition/DefaultInferenceComposition.swift), [RecordingWorkflowController.swift](../../Recordly/Features/Recordings/Application/RecordingWorkflowController.swift).

## Platform, storage and distribution limits

- The Xcode project sets a minimum of macOS 15.0. **Apple Silicon is required for the active FluidAudio speech processing paths:** actual SDK execution and downloads are guarded by `arch(arm64) && canImport(FluidAudio)`; unsupported architectures throw unavailable errors. A universal executable does not provide Intel speech inference. Earlier runtime evidence was on an M3 Pro, not every Apple Silicon Mac.
- Model downloads require internet access; the inspected inference path loads local models and processes local audio. This is source evidence for local inference, not a network-traffic audit or a guarantee that setup works offline with missing models.
- Existing recordings remain under `~/Library/Application Support/Recordly/recordings/<session-id>/`. SDK models remain under `~/Library/Application Support/FluidAudio/Models/`. Local/legacy model paths and settings also remain compatibility contracts. A public name change must not silently move these paths or reset preferences.
- Existing build reports describe a locally signed app, not a notarised public release. Xcode is a build dependency, not a runtime requirement of a correctly packaged standalone bundle. Launch and model provisioning on a friend's Mac remain unverified until exercised on the final artefact.
- The Models panel estimates approximately 630 MB for Ultra and 500 MB for v3. These are UI estimates, not measured download, installed-disk or peak-memory requirements. The separate speaker package needs additional storage. No verified minimum RAM or free-disk requirement is established here.

See [AppPaths.swift](../../Recordly/Infrastructure/Persistence/AppPaths.swift), [Xcode project settings](../../Recordly.xcodeproj/project.pbxproj), [model integration](../model-integration.md) and [project status](../project-status.md). Preserve the persistence and ownership rules in [AGENTS.md](../../AGENTS.md).

## README PR #22 reconciliation

Use the existing README work as the baseline; do not create a competing rewrite.

1. Replace the public Recordly branding with the confirmed Barkenson name during integration, while retaining intentional internal names, compatibility paths, bundle identity and signing commands as appropriate.
2. Tighten “work with transcripts in TXT, SRT and JSON formats”: all three files are generated, but the UI export action copies TXT; SRT/JSON are available in the recording folder.
3. Tighten the Intel statement: the active SDK execution is architecture-gated, rather than merely lacking an Intel test result.
4. Keep the README's caveats about partial speaker matching, inactive summaries, model download versus selection, local signing and historical evidence. Avoid adding unsupported language, hardware performance or notarisation claims.
5. The README reports that summaries were removed because results were inadequate. The inspected code confirms disabled generation, but does not by itself establish that historical rationale; retain that explanation only with the author's confirmation or existing decision evidence.

## Release acceptance still required

The coordinator must attach fresh evidence for the integrated commit and final bundle: build and relevant tests; bundle/version/architecture inspection; signing and Gatekeeper assessment; standalone launch on the author's Mac and another intended recipient's Mac; microphone/system permissions; a short recording, playback and TXT/SRT/JSON inspection; model download/selection and offline transcription; graceful speaker-package absence/failure; interrupted-work recovery; and preservation of existing recordings, models, settings and permissions after rebranding. Annotated meeting-wide speaker and language quality remain limitations unless separately tested.

No code, persistence, model provisioning, inference routing or product functionality is changed by this audit.

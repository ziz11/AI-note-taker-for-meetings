# Audio Pipeline V2 delivery and verification

Feature branch: `feature/audio_pipeline_v2`.
Base develop: `59a0b28856b222638d0ed0aada6e63df615b9aec` (matched origin/develop when prepared).
The final branch SHA is available with `git rev-parse HEAD` and in the delivery message; develop is not merged or rewritten.

## Milestone status

- A: implemented and independently reviewed. Actual AAC storage, playback/export, recovery and fault tests pass. Hardware capture and extended meeting memory/CPU measurements remain separate acceptance work.
- B: implemented and independently reviewed; 85 focused checks passed (one existing skip), followed by the full suite. Bounded inference and persistent local speaker names work; validated remote continuity across windows remains explicitly unresolved.
- C: implemented configured external runtime, exact artifact resolution and accurate diagnostics. Standalone packaging and launch evidence are recorded below. No compatible real GGUF/MLX model was supplied or found, so real model loading/generation acceptance remains pending.

## Storage, timeline and recovery

ScreenCaptureKit buffers and AVAudioEngine fallback use one monotonic host-clock origin. All persisted positions are integer frames at 48,000 Hz. A missing capture interval remains elapsed time, with silence in encoded chunks/range reads and an explicit gap diagnostic. Recorded quiet audio is distinct from missing capture samples. Late track starts and trailing missing ranges do not collapse the timeline.

New recordings store AAC in M4A, 48 kHz mono, 96 kbps per semantic track. Chunk target is 180 seconds, configurable internally; rotation occurs at buffer boundaries. Each file name contains an index and stable UUID under `audio/microphone/` or `audio/system/`. The v2 manifest records session ID, host-clock origin, rate, segment UUID/track/index/start/valid frames, first/last capture PTS, codec, state, SHA256 and gaps. Capture-end frames preserve a trailing missing interval. Recovery sidecars carry session/timeline association independently of the manifest.

Commit sequence: prepare sidecar, write active pending container, checkpoint timing, install next writer, bounded background close, validate decodable valid frame count, persist finalized sidecar/hash, rename to final file, atomically replace manifest. Publication is serialized across tracks. At most two finalizations are pending by default, plus the active writer; capture ingress is bounded to 64 buffers per track. Accepted writer buffers are at most one second. Backlog exhaustion is explicit; it does not create an unlimited queue. Metadata/storage failures still stop sources, drain pipelines and attempt every writer close. One failed source does not silently disable the other source's health monitoring.

Reconciliation validates manifest identity/schema/paths, reads trustworthy sidecars, inspects final or pending containers and checks frames/hash. Recoverable closed orphans are republished and added to the manifest; missing/corrupt entries retain their timeline range. Unplaced files without trustworthy timing remain on disk with a diagnostic. Reconciliation is idempotent; no valid prefix is deleted because of a bad tail. Duplicate recordings get newly bound session metadata.

Process termination guarantee: committed prefixes remain usable, and finalized containers before manifest commit can be recovered. An incomplete active chunk may be lost. Power loss is best effort under filesystem/container semantics; atomic replacement is not a claim of fsync-backed power-loss durability.

Native AVFoundation compositions insert each valid chunk at its session frame offset. They avoid automatic session render, sequence decoder-trimmed valid frames, preserve gaps and reload when the manifest changes. AVFoundation drops trailing empty edits, so a bounded 0.1-second silent AAC asset anchors the final time. Full-session combined M4A is generated only by explicit export.

## Measurements and bounds

Synthetic two-track AAC fixture: 181 seconds per track, using real default codecs and 180-second rotation, occupied **3,943,616 bytes**, extrapolated **78.44 decimal MB/hour**. This is synthetic audio/container evidence, not a real meeting benchmark. Observed append p95 was approximately 1.46–2.96 ms across targeted/integration runs. Maximum observed rotation call was **2.35 ms** across those runs; final runs are noted in verification evidence. Background encode wall time for this accelerated fixture was roughly 1.1 seconds; real-time recording latency differs.

Pending finalization count is hard bounded to two in production (a slow-publication fixture used a bound of one and verified explicit overflow). Capture ingress queues have 64-buffer capacity per track. A whole-session manifest and inference plan scale with the number of chunks/windows; raw PCM does not scale with session length in the V2 path.

A 60-second mono Float32 reader buffer occupies 11.52 MB. The reader may temporarily hold another bounded decoded intersecting slice; SDK/model allocations, resampling buffers and inference output are additional. These are arithmetic allocation bounds, not whole-app peak RSS guarantees. A resident-memory regression read 575 sixty-second windows from a sparse eight-hour timeline, decoding real AAC in every window: sampled short-run peak 164,118,528 bytes, long-run peak 172,179,456 bytes (about 8.06 MB growth, below the 32 MiB acceptance margin). This isolates the reader in the test-host app; models and capture queues are excluded. Full-call peak RSS, real model inference RSS/latency and hardware capture CPU remain unmeasured. A single cancellation-resistant diarization task may remain alive until app exit; quarantining its manager prevents repeated accumulation. It is not an eight-hour recorded-call test.

Frame-count tests validate 48 kHz input, 44.1 kHz conversion including fractional callback durations, late offsets, gaps, export length and AAC boundary trimming. Tested output length differs by at most one frame. Segmented AAC decoded against a continuous AAC waveform reference has RMS error below 0.01 in the fixture; this does not establish real speech recognition quality.

## Inference and speakers

Physical 180-second chunks and inference windows are independent. Windows own 50-second intervals with up to five seconds of context on either side; each temporary CAF is at most 60 seconds / 2,880,000 mono 48 kHz frames. Windows cross storage boundaries. Processing is sequential with bounded PCM materialization and cleanup, without full-session mixed or PCM input.

Word timing is reconciled temporally across overlapping candidates with deterministic ownership. Identical text at distinct times survives; untimed alternatives use overlap/ownership coverage. Capture offsets are added to backend-local timestamps. Event IDs derive from stable session-relative evidence rather than backend raw labels. Boundary jitter tests cover both duplicate and disappearing-token cases.

`inference/windows/` records successful stage output and provenance: session/timeline origin and format, owned/input ranges, intersecting chunk IDs/content hashes/state/timeline/gaps, backend and actual model bytes, ASR engine/settings identity, diarization settings and implementation/result versions. Reuse requires matching evidence; changed inputs invalidate affected windows. Failed stages retry; completed ASR survives cancellation during optional diarization. Microphone provenance ignores unrelated diarization configuration. SDK-managed diarization has no verified artifact path in the wrapper, so its results rerun conservatively while ASR remains cached.

Mic events retain local `me` identity. Remote labels are scoped to the actual inference run and window. `speaker-identities.json` keeps local identity evidence and display names separately from raw aliases. Same exact local turn partition and audio/diarization evidence preserves names through raw-label permutation and ASR changes. Indistinguishable partitions stay separate. Cross-window remote identity is **unresolvedAcrossWindows**, never inferred merely from `speaker_0`. The current FluidAudio wrapper has no validated embedding/state matching implementation. Duplication preserves display names against original local evidence while rebinding the owning session and invalidating old-session inference caches.

Independent microphone/system/window failures preserve successful transcript output and record failed ranges. Missing/failed diarization preserves system ASR with unknown remote labels. Cached ASR also survives optional diarization materialization failure. Cancellation propagates separately from degradation. A timed-out or cancelled FluidAudio manager is quarantined for the app lifetime; restart is required before attempting diarization again with it, because SDK child-task draining cannot be proven. The run stops scheduling later diarization and preserves subsequent ASR as unknown remote output. This deliberately prevents repeated retained PCM tasks after timeout. Owned stale inference-window CAFs are cleaned on retry and excluded from duplication. Prepared window track/range metadata, rather than a CAF basename, establishes bounded system input. `inference/report.json` records status, capture diagnostics, failures/ranges, continuity, event provenance, reuse and maximum materialization counts.

## Legacy compatibility

Old CAF/M4A recordings and imported single-file audio retain legacy inference/playback/recovery adapters. Optional manifest/track asset fields decode absent fields from older metadata. V2 never fabricates legacy source file names. Transcript, text, SRT and summary artifact locations remain compatible. Export supports V2 compositions and legacy copies. Speaker names remain local evidence, not a new global person registry.

## Local LLM diagnosis and runtime

The old failure label hid several distinct causes: missing selection, missing artifact, wrong artifact type and unavailable runner. Existing project Whisper/GGML `.bin` data could be advertised as summarization models; that is not a usable GGUF LLM. CLI discovery also depended on an environment Finder need not inherit. Selection by discovery basename could redirect an explicit picked URL. These are code-confirmed failure paths; a real-model loading failure has not been reproduced without weights.

Selection now retains the exact persisted artifact URL. Header validation accepts GGUF bytes (including legacy `.bin` only with an actual GGUF header) and excludes ASR artifacts. Missing selected files remain distinguishable from no installed models/no selection. Registry lookup supports bundled subdirectories. CLI readiness and model readiness remain separate, with visible actionable reasons. A template summary preserves the exact failure reason, and cancellation is not converted into template success.

Chosen packaging: **configured external executable**, as confirmed by the user. The saved absolute path is `/opt/homebrew/bin/llama-cli`, preference `model.summarization.llamaExecutablePath`; no production PATH search is required. It runs with a single turn and EOF input, bounded captured output, deadline and cancellation. Cancellation also terminates owned process-group descendants without killing the app's process group. Environment-free CLI check (`env -i PATH=/usr/bin:/bin ... --version`) reports build 10470, commit 34af94cd9.

`scripts/build-standalone-local.sh` builds a signed Release app and ZIP using the existing persistent local certificate. Xcode tools are needed to build, but Xcode is not needed to launch the resulting app. This certificate is for this Mac; Developer ID distribution/notarization remains a separate workflow. Model weights and runtime remain external dependencies.

Existing MLX code is reachable through selector/factory when an MLX model is selected. Its validator supports config/tokenizer plus a monolithic `model.safetensors`; sharded weights are not supported. It launches external Python/`mlx_lm.generate`, assumes that environment is installed, and lacks explicit standalone Python packaging and bounded prompt/context handling. No duplicate MLX implementation was added. Runtime/model memory and Finder generation for MLX were not exercised.

## Verification evidence

- A independent review approved the final storage/capture/playback integration.
- 20 capture/storage tests plus a bounded reader memory regression passed: actual five-point SIGKILL subprocess tests, readable prefixes/orphans, recovery idempotence, corrupt/missing files, timeline gaps/late starts, 44.1 kHz conversion, real AAC continuity, composition export, manifest reload, slow publication/backlog and read-only directory failure.
- C focused tests covered artifact/CLI readiness, exact selection, cancellation/timeout, descendant pipe handling, visible fallback reason and summary isolation; no simulated runner result is claimed as real model generation.
- B focused tests and independent review fixes cover bounded cross-chunk input, eight-hour planning, cache invalidation, local names, symmetric partial failure, cancellation, missing diarization artifacts, reversed boundary jitter, optional-stage failure and duplication.
- Milestone A was built independently without B and passed 38 capture/storage/compatibility tests; the new reader memory test also passed in that independent snapshot.
- Final full suite: **322 tests, zero failures, one existing skip**, xcodebuild exit 0. The same run observed 2.347 ms maximum rotation and 118,145,024 sampled resident bytes in both short/long reader phases. Isolated reader runs sampled up to 172,179,456 bytes with 8.06 MB growth; these are separate test-host observations, not interchangeable full-call/model RSS.
- Standalone Release build and LaunchServices results are recorded below after the corresponding checks complete.

## Files and follow-up

Primary additions: `SessionAudioManifest`, `SegmentedTrackWriter`, `SessionAudioRangeReader`, `SessionAudioComposition`, `SegmentedMicrophoneCapture`, `CaptureFinalizationCoordinator`, debug `AudioPipelineCrashHarness`, `InferenceWindowPlan`, `WindowInferencePersistence`, `SegmentedTranscriptionPipeline`, segmented audio/inference tests and standalone build script. Changed integrations: capture service/pipeline, session assets, workflow/store/player/repository, inference routing, model preferences/resolution, Models settings, LlamaCpp runtime/runner and existing tests. Exact reviewable file list: `git diff --name-status 59a0b28..HEAD`.

Remaining acceptance work: provide/select a real compatible GGUF, launch the Release app through Finder and verify actual model load + generated summary; hardware permission/system-only/mic-only/full-call capture matrix; extended real-call CPU/peak RSS/storage observations; speech-quality boundary evaluation and validated cross-window remote speaker matching. No merge into develop is performed.

## Changed file inventory

Paths are repository-relative. Added:

```text
Recordly/Infrastructure/Capture/AudioPipelineCrashHarness.swift
Recordly/Infrastructure/Capture/CaptureFinalizationCoordinator.swift
Recordly/Infrastructure/Capture/SegmentedMicrophoneCapture.swift
Recordly/Infrastructure/Capture/SegmentedTrackWriter.swift
Recordly/Infrastructure/Capture/SessionAudioManifest.swift
Recordly/Infrastructure/Inference/Audio/SessionAudioComposition.swift
Recordly/Infrastructure/Inference/Audio/SessionAudioRangeReader.swift
Recordly/Infrastructure/Transcription/Segmented/InferenceWindowPlan.swift
Recordly/Infrastructure/Transcription/Segmented/SegmentedTranscriptionPipeline.swift
Recordly/Infrastructure/Transcription/Segmented/WindowInferencePersistence.swift
RecordlyTests/SegmentedAudioTests.swift
RecordlyTests/SegmentedInferenceTests.swift
docs/audio-pipeline-v2-report.md
docs/plans/2026-10-09-audio-pipeline-v2-design.md
docs/plans/2026-10-09-audio-pipeline-v2-implementation.md
docs/plans/2026-10-09-audio-pipeline-v2-request.md
scripts/build-standalone-local.sh
```

Changed:

```text
AGENTS.md
ARCHITECTURE.md
README.md
Recordly.xcodeproj/project.pbxproj
Recordly/App/RecordlyApp.swift
Recordly/Domain/Recordings/RecordingSession.swift
Recordly/Features/Recordings/Application/PlaybackController.swift
Recordly/Features/Recordings/Application/RecordingWorkflowController.swift
Recordly/Features/Recordings/Application/RecordingsStore.swift
Recordly/Features/Settings/Models/ModelSettingsView.swift
Recordly/Features/Settings/Models/ModelSettingsViewModel.swift
Recordly/Infrastructure/Capture/AudioCaptureService.swift
Recordly/Infrastructure/Capture/CaptureSamplePipeline.swift
Recordly/Infrastructure/Inference/Backends/CliDiarization/CliDiarizationEngine.swift
Recordly/Infrastructure/Inference/Backends/FluidAudio/FluidAudioDiarizationEngine.swift
Recordly/Infrastructure/Inference/Backends/LlamaCpp/LlamaCppRunner.swift
Recordly/Infrastructure/Inference/Backends/LlamaCpp/LlamaCppSummarizationEngine.swift
Recordly/Infrastructure/Inference/Contracts/InferenceStageContracts.swift
Recordly/Infrastructure/Inference/Factory/DefaultInferenceEngineFactory.swift
Recordly/Infrastructure/Inference/Runtime/DefaultInferenceRuntimeProfileSelector.swift
Recordly/Infrastructure/Inference/Runtime/InferenceRuntimeProfile.swift
Recordly/Infrastructure/Models/ModelManager.swift
Recordly/Infrastructure/Models/ModelPreferencesStore.swift
Recordly/Infrastructure/Models/ModelRegistry.swift
Recordly/Infrastructure/Models/ModelTypes.swift
Recordly/Infrastructure/Persistence/RecordingsRepository.swift
Recordly/Infrastructure/Summarization/SummaryEngine.swift
Recordly/Infrastructure/Transcription/TranscriptionPipeline.swift
RecordlyTests/CaptureSamplePipelineTests.swift
RecordlyTests/DefaultInferenceRuntimeProfileSelectorTests.swift
RecordlyTests/ModelDiscoveryTests.swift
RecordlyTests/ModelSettingsViewModelTests.swift
RecordlyTests/RecordingSessionCompatibilityTests.swift
RecordlyTests/SummarizationTests.swift
docs/README.md
docs/inference-context.md
docs/model-integration.md
```

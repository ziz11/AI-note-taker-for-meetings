# Audio Pipeline V2 design

Approved requirements: `2026-10-09-audio-pipeline-v2-request.md`. Base develop: 59a0b28856b222638d0ed0aada6e63df615b9aec.

## Existing flow

ScreenCaptureKit emits timestamped microphone/system CMSampleBuffers. Bounded single-consumer CaptureSamplePipeline instances feed mirrored 48 kHz mono PCMTrackWriters (Int16 CAF and 96 kbit/s AAC M4A). Writer PTS gaps become silence. Capture health advances after writes commit. Stop drains callbacks and closes writers; workflow schedules an offline mix. Inference already prefers per-source M4A; microphone is mapped to `me`, system is diarized then transcribed by diarization ranges. TranscriptMergeService sorts without removing overlap. Playback uses one AVAudioPlayer. Recovery and cleanup assume legacy filenames. LLM selection resolves through ModelManager and runtime profiles; generation belongs to backends. MLX already exists. README/ARCHITECTURE contain outdated ASR details; code is the baseline.

## A: storage and recovery

Separate 48 kHz mono AAC M4A tracks; target 180 seconds at buffer boundaries. Shared host-clock origin maps PTS onto integer 48 kHz session frames. Chunk IDs are UUIDs, not indices. Per-chunk sidecars persist timing before opening a writer, and finalized frame counts before final publication. Atomic manifest commits are serialized across tracks. Recovery reconciles sidecars, final files and readable pending containers, preserves invalid entries as gaps, and never deletes audio. Source frames, encoder padding, decoded frames and intended timeline duration remain distinct.

Writer rotation installs a new active writer before previous close/validation/metadata tasks. Existing capture queues remain bounded (64 buffers per track); limit pending finalizations and fail capture explicitly on exhaustion. No session-wide CAF or automatic playback merge for V2. Legacy paths remain version-aware. Playback schedules bounded PCM ranges on synchronized nodes, preserving gaps and selected source, with seek/rate support.

## B: inference

A storage reader assembles bounded semantic track/time ranges, including silence for missing intervals. Backend-specific PCM adaptation stays at the consumer boundary. Fixed windows are distinct from chunks, may overlap, and have non-overlapping ownership ranges for deterministic transcript reconciliation. Persist each window outcome with content/timeline/config fingerprint and stable provenance; only affected windows rerun. Cancellation propagates. Independent track/window failures yield a degraded partial transcript. Per-run diarization labels map to session identities; where no validated evidence proves continuity, retain distinct unresolved identities instead of inventing a match. User display names are stored separately and survive reruns.

## C: local summarization

User choice: configured external llama-cli. Store its explicit URL in model/runtime preferences; show executable readiness separately from model selection. Preserve the selected artifact URL and actual profile-resolution error. Reject ASR artifacts from summarization discovery and validate supported LLM formats at the boundary. Do not introduce a combined discovery/generation provider. Test standalone LaunchServices Release invocation with a selected real supported model when available; absence of a real supported model is a documented acceptance limitation, never a synthetic success.

## Durability and validation

Application kill: previously closed and published chunks are recoverable even without manifest commit. Power loss: best effort filesystem durability; no stronger promise without flush evidence. Faults must be injected before/after close, publish and manifest commit; actual subprocess termination covers abandoned containers. Validate gap preservation, late sources, independent failure, cache inputs, speaker renames and legacy sessions. Measure AAC frame trimming, real bytes per hour, rotation latency and bounded working set. No final milestone claim without corresponding fresh checks.

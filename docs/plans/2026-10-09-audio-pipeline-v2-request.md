# Recordly Audio Pipeline V2

Repository:

`ziz11/AI-note-taker-for-meetings`

The current reviewed code baseline is commit:

`59a0b28`

Your task is to evolve Recordly toward compact segmented audio storage, crash-safe recovery, bounded inference, stable speaker identities, resumable processing, and reliable standalone local summarization.

Do not modify `develop` directly.

Do not merge into `develop`.

The work must be implemented as independently reviewable changes rather than one large rewrite.

# 0. Branch and repository preparation

Before modifying any code:

1. Run:

```bash
git status
git branch
git remote -v
git fetch origin
```

2. Switch to:

```bash
git checkout develop
```

3. Determine:

```bash
git rev-parse develop
git rev-parse origin/develop
```

4. Verify that local `develop` is current.

If local `develop` is behind `origin/develop`, update using fast-forward only:

```bash
git pull --ff-only origin develop
```

Do not:

- force push
- rewrite shared history
- discard local modifications
- reset user work
- rebase shared `develop`

If the working tree contains uncommitted work that prevents safe branch preparation, stop before destructive changes and report exactly what is present.

Once `develop` is confirmed current, create:

```bash
feature/audio_pipeline_v2
```

The feature branch must be created from the latest `develop`, not from commit `59a0b28` unless that commit is still the current `develop`.

Before implementation report:

- local `develop` SHA
- `origin/develop` SHA
- whether they match
- feature branch name
- working tree status

# 1. Delivery structure

Do not implement this as one monolithic change.

Split the work into three independently reviewable milestones.

## Milestone A

Segmented storage, crash recovery, playback, timeline semantics, and legacy compatibility.

## Milestone B

Bounded inference, segmented transcription inputs, speaker continuity, resumable results, and cache invalidation.

## Milestone C

Local LLM diagnostics, model resolution, and standalone runtime packaging.

Each milestone should leave the application in a coherent and testable state.

Prefer separate commits for major architectural boundaries.

Do not begin Milestone B by rewriting existing channel-aware transcript behavior that already works.

# 2. First inspect the existing implementation

Before editing code, inspect at minimum:

```text
README.md
ARCHITECTURE.md
AGENTS.md

Recordly/Infrastructure/Capture/AudioCaptureService.swift

Recordly/Infrastructure/Transcription/TranscriptionPipeline.swift
Recordly/Infrastructure/Transcription/TranscriptMergeService.swift
Recordly/Infrastructure/Transcription/SystemSpeakerMappingService.swift

Recordly/Infrastructure/Inference/Backends/FluidAudio/

Recordly/Infrastructure/Inference/Backends/LlamaCpp/

Recordly/Infrastructure/Inference/

Recordly/Infrastructure/Models/

Recordly/Features/Recordings/Application/RecordingWorkflowController.swift

Recordly/Features/Settings/Models/
```

Also inspect all relevant tests.

Document the current data flow:

```text
ScreenCaptureKit
→ timestamp normalization
→ track writers
→ durable audio
→ transcription
→ diarization
→ transcript merge
→ summarization
```

Confirm the existing behavior before changing it.

In particular, verify that the current system already:

- records microphone and system audio separately
- prefers durable M4A where available
- assigns microphone transcript events to local speaker identity such as `me`
- diarizes system audio
- merges events by timestamp
- preserves overlapping events
- has an MLX backend or MLX-related implementation already present
- passes a resolved model URL into the llama.cpp summarization backend

Treat these as behavior to preserve unless testing proves otherwise.

# 3. Core architecture contract

The main architectural contract must become:

```text
capture time
→ committed durable audio
→ inference windows
→ inference results
→ stable transcript events
→ stable speaker identities
```

These layers must not be conflated.

Explicitly distinguish:

## Capture buffers

Short-lived audio buffers received from ScreenCaptureKit.

## Storage chunks

Durable compact files created for crash safety.

## Inference windows

Logical audio ranges consumed by ASR or diarization.

An inference window may:

- equal one storage chunk
- span multiple storage chunks
- overlap a neighboring inference window
- include context around a storage boundary

## Transcript events

Stable session-relative events produced from inference.

## Speaker identities

Stable identities at the session level, not backend-local speaker labels.

# 4. Audio storage format

For the first implementation use separate compact M4A files for microphone and system audio.

Do not use one stereo or multichannel M4A container in this version.

Preferred layout:

```text
session/
  capture-session.json
  audio-manifest.json

  audio/
    microphone/
      000000.m4a
      000001.m4a
      000002.m4a

    system/
      000000.m4a
      000001.m4a
      000002.m4a
```

This intentionally preserves semantic track independence.

The multichannel-container approach can remain a future optimization.

Use AAC in M4A unless investigation demonstrates a concrete correctness problem.

Long-lived session-wide PCM CAF files must no longer be required for new recordings.

PCM may still be used transiently in memory or in short internal transformations when required by AVFoundation, FluidAudio, Accelerate, ASR, diarization, or audio conversion.

# 5. Storage chunk duration

Use a target chunk duration of approximately:

```text
180 seconds
```

Do not assume an exact frame boundary at exactly 180.000 seconds.

The implementation must rotate cleanly at an appropriate audio buffer boundary.

The chunk duration must be configurable internally rather than scattered as a magic number.

Tests should use much smaller durations.

# 6. Session timeline model

Define precise time semantics before implementation.

All audio and inference output must refer to one monotonic session-relative timeline.

Do not build the transcript timeline by concatenating decoded file durations.

Each semantic track may:

- begin later than another track
- temporarily lose buffers
- restart
- contain discontinuities
- receive format changes
- recover from capture interruptions

Each storage chunk must include or be associated with sufficient timing metadata to reconstruct the original session timeline.

At minimum preserve:

```text
track kind
chunk index
session-relative start timestamp
session-relative end timestamp
first capture PTS
last capture PTS
valid frame count
sample rate
codec
finalized state
known gaps or discontinuities
```

Clearly define units.

Prefer integer frame counts or another representation that avoids cumulative floating point timeline drift.

# 7. Gap semantics

The current writer deliberately uses presentation timestamps to detect missing capture intervals and inserts silence.

Preserve this behavior intentionally rather than accidentally removing it.

Define two concepts separately:

```text
capture gap
```

and:

```text
recorded silence
```

When an input buffer arrives later than expected and the missing interval represents elapsed session time, the timeline must not collapse.

The implementation may encode the missing interval as silence if that is required to maintain deterministic media timing.

Do not allow:

```text
real session:
00:00
speech
00:10 gap
00:15 speech
```

to become:

```text
stored audio:
00:00
speech
00:10 speech
```

The second speech must remain aligned near session time 00:15.

# 8. AAC chunk boundary correctness

AAC encoder priming and trailing padding must be treated explicitly.

Investigate AVFoundation and Apple container behavior for:

- encoder delay
- priming frames
- trailing padding
- decoder trimming
- concatenated independently encoded AAC files

Add a test that decodes consecutive chunks and verifies that session-level timing does not accumulate audible or inference-relevant gaps at every boundary.

Do not assume:

```text
decodedDuration == intendedTimelineDuration
```

without validation.

Persist the timeline based on capture timing, not solely on decoder-reported duration.

# 9. Crash-safe chunk commit protocol

Atomic manifest writes alone are insufficient.

Implement an explicit commit protocol.

The normal rotation should conceptually be:

```text
capture continues
      ↓
new incoming buffers routed to next active writer
      ↓
previous writer stops receiving new data
      ↓
previous chunk finalized
      ↓
chunk validated
      ↓
final filename published
      ↓
manifest entry atomically committed
```

The next writer must begin accepting audio before expensive finalization, validation, or manifest persistence of the previous writer blocks capture.

Use a bounded queue or another bounded handoff mechanism.

Do not permit unbounded buffering.

# 10. Crash guarantees

Define guarantees separately.

## Application process crash

After a process crash:

- all fully finalized chunks should remain recoverable
- a finalized chunk must be discoverable even if its manifest entry was never committed
- an incomplete active chunk may be lost if it cannot be safely recovered
- previously committed chunks must remain usable

## Power loss or OS-level interruption

Do not claim stronger durability than the filesystem and container implementation can provide.

Document the practical guarantee.

At minimum:

- previously closed chunks should normally survive
- current open chunk may be incomplete
- recovery must tolerate metadata and filesystem state being out of sync

# 11. Recovery reconciliation

Recovery must reconcile the manifest and filesystem.

Handle at minimum:

## Manifest entry exists and file exists

Validate and keep it.

## Manifest entry exists but file is missing

Mark the entry invalid and report diagnostics.

Do not silently shift the timeline.

## Finalized file exists but manifest entry is missing

Treat this as an orphan candidate.

Inspect its naming, metadata, and media timing.

Recover it if it can be safely associated with the session.

Commit a repaired manifest entry.

## Corrupt or unreadable final file

Preserve diagnostics.

Do not destroy other valid chunks.

## Incomplete trailing file

Attempt recovery only if the container can be safely opened and validated.

Otherwise quarantine or ignore it.

Do not allow one bad trailing chunk to invalidate an entire meeting.

# 12. Manifest persistence

Manifest updates must use atomic replacement.

The manifest must include a schema version.

Example conceptual structure:

```text
sessionVersion
sessionId
timelineOrigin
tracks
segments
recoveryState
```

Each segment should have a stable identifier independent of its filename.

Do not use array position alone as identity.

# 13. Playback model

Do not require generation of one large merged session file after every recording.

The canonical representation for new sessions may remain:

```text
manifest
+
ordered compact chunks
```

Playback should support this logically continuous timeline.

If the current audio player only accepts one file, add an abstraction that can sequence chunks.

Do not automatically transcode all chunks into a new full-session M4A merely for playback.

A combined export file may be generated explicitly when required.

# 14. Preserve existing channel-aware behavior

Do not treat channel-aware transcription as greenfield work.

The current implementation already contains important parts of the desired behavior.

Preserve:

```text
microphone
→ ASR
→ local speaker identity
```

and:

```text
system
→ ASR
→ diarization
→ remote speaker identities
```

and:

```text
microphone events + system events
→ timestamp sort / merge
```

The main change is that these paths must consume segmented session audio rather than assume one fixed session file.

# 15. Remove hardcoded filename assumptions

Search for assumptions involving names such as:

```text
system.m4a
mic.m4a
mic.raw.caf
system.raw.caf
merged-call.m4a
merged-call.caf
```

Known areas include:

```text
TranscriptionPipeline
FluidAudioDiarizationEngine
```

Replace fixed filename requirements in inference code with semantic audio input abstractions.

Inference backends should request something equivalent to:

```text
session
track
timeline range
```

not:

```text
file named system.m4a
```

Legacy adapters may still recognize old filenames for old sessions.

# 16. Partial failure semantics

Preserve cancellation behavior separately from degradation.

Cancellation must still cancel the workflow.

Do not convert user cancellation into a successful partial transcript.

For non-cancellation failures implement symmetric partial success.

Examples:

## Microphone ASR fails, system ASR succeeds

Return the system transcript and explicit degraded status.

## System ASR fails, microphone ASR succeeds

Return the microphone transcript and explicit degraded status.

## Diarization fails

Keep system ASR events using a stable unknown remote speaker identity.

## One inference window fails

Preserve successful windows and expose the failed range.

Do not discard the whole meeting unless the failure makes the output unusable.

# 17. Storage chunks are not inference windows

Do not feed each 180 second storage file independently to ASR merely because that is how it is stored.

Create an inference window abstraction.

Conceptually:

```text
InferenceWindow

track
start time
end time
input segment IDs
context overlap
processing configuration
```

ASR windows may cross storage boundaries.

They may include overlap to preserve linguistic context.

For example:

```text
window 1:
0:00 to 5:10

window 2:
5:00 to 10:10
```

The exact window and overlap policy should be based on backend behavior and tested.

# 18. Duplicate suppression across inference windows

If ASR windows overlap, transcript events may be duplicated.

Implement deterministic reconciliation.

Do not deduplicate purely by exact transcript string.

Use appropriate combination of:

- timestamps
- token timing if available
- text similarity
- window ownership
- confidence if available

Ensure the resulting final transcript is stable across reruns.

# 19. Resumable inference

Inference must be resumable after application restart.

Do not require every recovered session to re-run all transcription and diarization from zero.

Every persisted inference result must identify its inputs.

At minimum include:

```text
input segment IDs
input timeline range
track
backend
model identifier
model version if known
processing configuration
processing implementation version
result version
```

A cached result is valid only if all relevant inputs and configuration still match.

# 20. Cache invalidation

Do not reuse inference output merely because a JSON result file exists.

Invalidate when:

- input chunks change
- an orphan chunk is recovered into the timeline
- an existing chunk is replaced
- timeline metadata changes
- selected model changes
- backend changes
- diarization configuration changes
- relevant processing code version changes

A recovered chunk that was absent during the previous inference run must invalidate all affected windows.

# 21. Stable transcript event identity

Transcript events should have stable identifiers where practical.

Rerunning one affected inference window should not unnecessarily regenerate unrelated event identities.

This will matter for:

- editing
- speaker renaming
- summaries
- search indexing
- annotations
- incremental processing

Define event provenance.

Example:

```text
eventId
track
input window ID
source segment IDs
start time
end time
speaker identity
text
backend metadata
```

# 22. Diarization and speaker continuity

Do not assume:

```text
speaker_0 in chunk A
```

equals:

```text
speaker_0 in chunk B
```

Backend diarization labels are local inference labels, not session speaker identities.

Implement or design a bounded session-level reconciliation strategy.

Investigate the capabilities of the current FluidAudio diarization stack.

Choose the simplest reliable approach supported by the backend.

Possible approaches:

```text
retained diarization session state
```

or:

```text
speaker embedding reconciliation
```

or another bounded session-level mechanism.

Do not invent identity continuity without evidence.

# 23. Persist session speaker mappings

Persist a session-level speaker identity layer separately from raw diarization labels.

Conceptually:

```text
SessionSpeaker

id
displayName
kind
knownLocalUser
embedding reference if available
aliases
```

and:

```text
DiarizationSpeakerMapping

inferenceRun
backendSpeakerLabel
sessionSpeakerId
confidence
```

Speaker renaming must operate on stable session speaker identities.

Reprocessing one chunk must not erase a user's speaker rename.

# 24. Speaker continuity test

Add at least one multi-window test where:

- Speaker A appears early
- Speaker B appears
- Speaker A disappears for multiple chunks
- Speaker A returns later

Verify that the chosen strategy either:

- correctly maps the returning speaker to the same session identity

or:

- explicitly leaves the identity unresolved rather than incorrectly asserting continuity

# 25. FluidAudio input abstraction

Review:

```text
FluidAudioSessionAudioLoader
AudioInput
AudioInputAdapter
FluidAudioDiarizationEngine
FluidAudioASREngine
```

Refactor the boundary so FluidAudio can request decoded PCM for:

```text
semantic track
session-relative time range
```

The loader must assemble that range from one or more storage chunks.

The inference backend should not care whether the audio originated from:

- one legacy M4A
- one CAF
- three M4A chunks
- five M4A chunks with a gap

The adapter owns storage decoding.

# 26. Memory bounds

Do not decode entire long meetings into memory.

Define measurable limits.

For example:

- maximum encoded audio queued during rotation
- maximum decoded PCM window held in memory
- maximum number of chunks open simultaneously
- maximum inference overlap

Choose appropriate values after measurement.

Document them.

Tests must verify memory does not grow proportionally to full meeting duration.

# 27. Rotation stall target

Replace vague requirements such as:

```text
minimal interruption
```

with measurable acceptance criteria.

Measure:

- maximum time capture delivery is blocked during rotation
- dropped frames at rotation
- timeline error around rotation
- queue depth
- encoder finalization latency

The capture path should not synchronously wait for the previous M4A file to finalize before accepting new buffers.

# 28. Disk-full behavior

Add explicit handling for storage exhaustion.

Test failures during:

- writing current chunk
- starting next chunk
- finalizing a chunk
- atomic manifest replacement

The application must:

- stop pretending capture is healthy
- retain already committed chunks
- preserve useful diagnostics
- avoid corrupting existing manifest state

# 29. Local LLM investigation

Treat local summarization as a separate milestone.

Do not immediately introduce a large `LocalLLMProvider` that owns discovery, selection, validation, and generation.

The repository already separates these concerns.

Preserve that separation.

Expected responsibility boundaries:

## Model layer

Own:

- model discovery
- installed artifacts
- model selection
- persistent preferences

## Runtime/profile layer

Own:

- selected model resolution
- runtime readiness
- backend configuration

## Backend layer

Own:

- model loading
- generation
- backend-specific failures

# 30. Diagnose the actual llama.cpp failure

Before changing architecture, reproduce the current failure.

Inspect:

```text
LlamaCppSummarizationEngine
LlamaCppRunner
ModelManager
ModelRegistry
ModelStorage
ModelPreferencesStore
InferenceRuntimeProfile
DefaultInferenceRuntimeProfileSelector
DefaultInferenceEngineFactory
RecordingWorkflowController
model settings UI
```

Determine exactly where the selected installed model becomes unavailable.

Known area to investigate:

profile resolution errors may currently be swallowed and later presented as:

```text
model-not-selected
```

Do not assume the root cause until reproduced.

Document:

```text
user selects model
→ persisted selection
→ model registry resolution
→ runtime profile resolution
→ model URL
→ summarization backend
→ llama runtime invocation
```

Identify the precise failing transition.

# 31. Local model error states

Expose distinct diagnostics for:

```text
no models installed
model installed but no model selected
selected model missing
selected model artifact invalid
selected model incompatible
runtime executable missing
runtime not executable
runtime failed to launch
model failed to load
generation failed
generation succeeded
```

Do not collapse these into one generic:

```text
model-not-selected
```

Do not silently hide the underlying failure when falling back to template summarization.

# 32. Standalone Release application requirement

The application must work outside Xcode.

Explicitly decide the llama.cpp runtime packaging model.

Choose one of:

## Bundled runtime

The application ships the required executable or library.

or:

## Configured external runtime

The user explicitly configures the executable location.

Do not rely on:

```text
PATH
Homebrew environment
developer shell environment
Xcode launch environment
```

without explicit configuration.

# 33. Finder launch acceptance test

Build a Release application.

Launch it from Finder or equivalent LaunchServices behavior.

Do not launch from Xcode.

Use an environment with no developer shell PATH assumptions.

Verify:

- selected model resolves
- runtime resolves
- model loads
- summary generates

This is a required acceptance test for Milestone C.

# 34. MLX review

Before suggesting a new MLX implementation, inspect the MLX backend already present in the repository.

Document:

- what already exists
- whether it is currently reachable from runtime composition
- supported model format
- packaging requirements
- standalone Release behavior
- memory behavior
- missing integration pieces

Then compare existing MLX and llama.cpp options.

Do not replace llama.cpp unless there is a concrete reason.

Do not implement a second redundant MLX path.

# 35. Legacy compatibility

Existing recordings must remain readable.

Support old sessions containing any of:

```text
mic.raw.caf
system.raw.caf
mic.m4a
system.m4a
merged-call.caf
merged-call.m4a
```

Use version-aware adapters.

Do not automatically migrate old recordings on disk.

New sessions should use the segmented format.

Old sessions should continue to support:

- playback
- transcription
- diarization
- summarization where previously supported

# 36. Fault-injection tests

Add tests for failures around every important commit boundary.

At minimum:

## Capture

- rotation while receiving audio
- slow finalization
- capture restart
- missing buffers
- track starts late
- track ends early
- microphone only
- system only

## Commit

- crash before chunk close
- crash after chunk close
- crash after validation
- crash after file publication
- crash before manifest write
- crash during manifest replacement
- crash immediately after manifest commit

## Recovery

- missing manifest
- corrupt manifest
- valid manifest with missing file
- orphan finalized file
- corrupt trailing chunk
- multiple orphan chunks
- partially recovered session

## Storage

- disk full during write
- disk full during rotation
- disk full during manifest commit

## Timeline

- gaps
- overlap
- restart discontinuity
- input sample rate change
- speech spanning storage chunk boundaries
- AAC boundary timing

## Inference

- inference window spanning multiple chunks
- overlapping ASR windows
- duplicate suppression
- partial microphone failure
- partial system failure
- diarization failure
- cancellation

## Cache

- same inputs and same config reuse
- model changed
- backend changed
- recovered chunk added
- chunk removed
- timeline changed

## Speakers

- returning speaker after several chunks
- speaker rename survives reprocessing

## Local LLM

- selected model resolves
- selected model missing
- runtime missing
- runtime launch failure
- model load failure
- successful generation
- Release app launched outside Xcode

# 37. Real crash tests

Do not test all recovery paths only by throwing Swift errors.

Create an integration test or test helper that launches a child recording process or writer process and forcibly terminates it at controlled commit points.

Use actual process termination where practical to validate interrupted M4A container behavior.

The goal is to test what survives when destructors and graceful shutdown code do not run.

# 38. Performance measurements

Record before and after measurements.

At minimum measure:

```text
disk usage per hour
recording CPU
memory after 10 minutes
memory after extended recording
rotation finalization latency
maximum capture queue depth
dropped or missing frames
timeline error across chunk boundaries
```

Also compare inference output quality on representative fixtures.

Storage reduction alone is not sufficient if segmentation meaningfully damages transcription or diarization.

# 39. Explicit initial performance targets

Use these as engineering targets, not unverifiable product promises.

## Storage

New steady-state disk usage should be substantially below the legacy raw CAF representation.

Report actual measured bytes per hour per track.

## Memory

Recording memory usage should remain approximately bounded with meeting duration.

Do not retain the entire decoded session in memory.

## Rotation

Rotation should not synchronously block incoming capture for the full encoder finalization duration.

## Timeline

Chunk boundaries should not accumulate measurable timeline drift over long recordings.

Any remaining measurable offset must be documented.

# 40. Documentation

Update:

```text
README.md
ARCHITECTURE.md
```

Add a focused architecture document, for example:

```text
docs/AUDIO_PIPELINE_V2.md
```

Document:

- storage layout
- manifest schema
- session timeline definition
- gap semantics
- chunk commit protocol
- crash guarantees
- recovery reconciliation
- AAC timing behavior
- playback behavior
- legacy compatibility
- storage chunk versus inference window distinction
- inference cache keys
- transcript provenance
- speaker identity model
- local LLM runtime packaging
- known limitations

# 41. Ownership rules

Preserve the repository's architectural separation.

Do not put:

- inference orchestration into low-level audio writers
- model discovery inside `LlamaCppSummarizationEngine`
- capture policy into `RecordingsStore`
- filesystem search logic across multiple inference backends
- backend-specific logic inside generic transcript models

Prefer existing contracts where possible.

Extend them only where current abstractions cannot represent segmented inputs or timeline ranges correctly.

# 42. Suggested commit sequence

A reasonable sequence is:

```text
1. Define segmented audio manifest and session timeline contracts

2. Implement separate mic/system M4A segment writers

3. Implement non-blocking segment rotation and commit protocol

4. Implement filesystem and manifest recovery reconciliation

5. Add segmented playback and legacy adapter

6. Add semantic track and time-range audio loading

7. Adapt existing mic/system transcription to segmented inputs

8. Add inference windows and overlap reconciliation

9. Add resumable inference provenance and cache invalidation

10. Add session speaker identity persistence and continuity strategy

11. Diagnose and fix local LLM model resolution

12. Make local runtime work in standalone Release application

13. Expand fault injection and forced-crash tests

14. Documentation and performance report
```

Do not combine unrelated milestones into one commit simply to reduce commit count.

# 43. Milestone A definition of done

Milestone A is complete when:

- new sessions use segmented compact M4A
- microphone and system use independent files
- long-lived raw CAF is not required for new sessions
- approximately 3 minute chunks are finalized during recording
- incoming capture continues while previous chunk finalizes
- completed orphan chunks can be recovered
- missing manifest files are reconciled
- corrupt trailing chunks do not destroy the session
- timeline gaps remain represented correctly
- AAC chunk timing behavior is tested
- playback works across multiple chunks
- old sessions remain readable
- storage and performance measurements are documented

# 44. Milestone B definition of done

Milestone B is complete when:

- existing microphone and system transcript semantics are preserved
- hardcoded `system.m4a` and equivalent active-session inference assumptions are removed
- ASR consumes semantic tracks and timeline ranges
- storage chunks and inference windows are separate abstractions
- inference windows may cross storage boundaries
- overlapping windows do not duplicate transcript content
- microphone and system failures degrade independently
- cancellation remains cancellation
- diarization works with segmented system audio
- speaker identity continuity has an explicit validated strategy
- speaker mappings persist
- renamed speakers survive reprocessing
- inference results include provenance
- cache reuse validates its actual inputs and configuration
- recovered audio invalidates affected inference windows only

# 45. Milestone C definition of done

Milestone C is complete when:

- the actual current local summarization failure is reproduced and documented
- selected model resolution is deterministic
- profile-resolution errors are no longer hidden as incorrect generic states
- backend diagnostics distinguish model and runtime failures
- llama.cpp packaging strategy is explicit
- a Release app launched outside Xcode successfully resolves its runtime
- a Release app launched outside Xcode successfully loads a selected supported model
- local summarization succeeds or reports an accurate actionable failure
- existing MLX integration has been reviewed
- no duplicate local-model discovery layer has been introduced

# 46. Final report

At the end provide:

```text
Feature branch
Base develop SHA
Final branch SHA

Milestone A status
Milestone B status
Milestone C status

Files added
Files changed

Storage architecture
Manifest architecture
Timeline semantics
Gap behavior
Chunk commit protocol
Crash guarantees
Recovery algorithm

Storage format
Target chunk duration
Measured disk usage per hour

Maximum observed rotation stall
Maximum queue depth
Memory behavior
Timeline accuracy

How inference windows differ from storage chunks
ASR overlap strategy
Duplicate suppression strategy
Inference cache key and invalidation rules

Speaker continuity strategy
Speaker persistence model

Legacy compatibility behavior

Local LLM root cause
Model resolution fix
Runtime packaging strategy
Finder / standalone Release test result
MLX assessment

Tests run
Fault-injection results
Forced-process-termination results

Known limitations
Follow-up work
```

Do not merge into `develop`.

Leave the branch ready for review.

If a technically important assumption in this task proves false during implementation, do not silently work around it. Document the evidence, choose the safest compatible design, and include the deviation in the final report.
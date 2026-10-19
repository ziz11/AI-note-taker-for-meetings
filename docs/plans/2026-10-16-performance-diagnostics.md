# Performance diagnostics implementation plan

**Goal:** Add one tiny compute-status icon with an on-demand performance popover and start collecting trustworthy local measurements without inflating the Models panel or repeatedly invalidating the recordings UI.

**Architecture:** A serial utility-queue telemetry service collects bounded spans, process CPU/resident memory, main-queue response delay, system thermal state and Low Power Mode. A separate observed UI model receives at most periodic samples plus completion updates. Sampling runs only while recording, processing or viewing diagnostics; idle with the panel closed has no timer. Backend adapters measure model setup and ASR/diarization work; Store measures whole jobs including cache reuse, excluding queue wait. No transcript/audio content or paths in diagnostic records. Keep inference and persistence contracts unchanged.

**Design:** A 20-point chip button beside Models/Import, with a roughly 300-point popover. Show CPU+Neural Engine as configured ASR policy, automatic diarization policy (GPU allowed), measured ASR input/runtime ratio, pipeline/cache ratio, CPU, resident RAM, main-queue delay, thermal and Low Power Mode. Explicitly state that ANE percent and per-app battery watts are unavailable here. Copy a bounded JSON report via an explicit user action. Avoid polling power sensors or using privileged/private APIs in the app.

**Alternatives:** A permanent dashboard would contradict the user's minimalist direction. A static ANE badge alone would not establish actual utilization or efficiency. Use the tiny icon plus actual low-frequency metrics and a separate Core ML/device-plan or Instruments verification.

## Tasks

1. Tests first for CPU deltas/baseline reset, weighted ASR speed excluding setup/failures, pipeline cancelled/failed semantics, bounded retention and sampling lifecycle. Implement telemetry and scoped spans with monotonic time. Resource collection/log I/O stays off MainActor; at most one outstanding main-queue probe.
2. Wire scoped ASR/model-load/diarization events in backend adapters; make the existing CPU+ANE ASR configuration explicit. Give queued transcription tasks utility priority. Wire job/capture lifecycle without expanding stage contracts or altering speaker identities.
3. Add the small independently observed icon/popover, background local bounded JSONL diagnostics and copy report. Render real SwiftUI states; confirm idle stops sampling. Review implementation.
4. Run appropriate suite and bounded native Ultra/v3 acceptance with live process/UI responsiveness metrics. Inspect actual encoder compute plan or target-specific Instruments traces when supported. Record hardware/OS, cold/warm timings and the limits of energy/utilization evidence. Never infer ANE utilization from CPU%, and never label thermal/Low Power Mode as watts.
5. Build signed standalone0.1.0(4), record source/checksums and current documentation; integrate develop/master. Preserve any active recording during installation/relaunch.

Apple references: Core ML compute units, MLComputePlan/deviceUsage and Instruments model profiling; ProcessInfo thermalState/isLowPowerModeEnabled. Trace-derived device activity and measured energy must remain separate from allowed-device policy and wall-clock speed.

## Delivery evidence

Implemented with bounded native Ultra measurements, compute-plan inspection and native SwiftUI rendering. Managed v3 was absent, so no replacement/download or current v3 comparison was performed. No power trace or watts measurement was obtained. See [measurement report](../performance-diagnostics-2026-10-16.md) and [current delivery status](../project-status.md).

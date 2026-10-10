# FluidAudio 0.14.0 → 0.17.7

> Reviewed 2026-10-10. Current reference. Evidence and open acceptance limits are tracked centrally. See [current project status](project-status.md).

Checked against the official GitHub releases on **2026-10-10**. Recordly pins **0.17.7**, commit `503b4bd1bbf7220882de39fe8ae6716aae4132da`; it previously pinned 0.14.0.

Sources: [full source comparison](https://github.com/FluidInference/FluidAudio/compare/v0.14.0...v0.17.7), [latest pinned release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.7), and the individual release notes linked below. Dates in this table are publication dates in UTC. This is a Recordly-focused summary, not a copy of every upstream change.

## What Recordly enables

- **Parakeet v3** remains the transcription engine. The new SDK's v3 loader expects `Encoder.mlmodelc` and `JointDecisionv3.mlmodelc`; an old model directory needs provisioning through the updated SDK before it is Ready. The canonical SDK cache folder is `parakeet-tdt-0.6b-v3`, not the Hugging Face repository slug ending in `-coreml`. Inference uses the validated local package.
- **Offline diarization** remains the speaker engine. Its required segmentation, filter-bank, embedding and PLDA assets in `speaker-diarization` are checked; unrelated files and unfinished `.partial` weights cannot make it Ready.
- **Per-chunk voice embeddings** supply evidence for matching returning speakers within a recording. The application must match and persist identities itself; upgrading the SDK alone does not make independent windows share identities.
- SDK version participates in inference cache identity. Cached results produced by the old runtime are recomputed; canonical recording audio stays compatible.
- NeMo text normalization remains enabled. With Swift 6.2, upstream includes a Rust static binary dependency and its resources; standalone packaging must include the required resources.
- Summarization remains a placeholder. New SDK models are not automatically downloaded or selected just because they are available.

## Published releases since the previous pin

| Tag / UTC date | Relevant upstream changes | Effect on Recordly |
| --- | --- | --- |
| [0.14.1](https://github.com/FluidInference/FluidAudio/releases/tag/v0.14.1) · Apr 24 | Speaker-manager concurrency fix; short Latin utterances incorrectly decoded as Cyrillic fixed. | Included runtime fixes. |
| [0.14.2](https://github.com/FluidInference/FluidAudio/releases/tag/v0.14.2) · Apr 28 | Streaming finish confidence warning corrected; mostly TTS updates. | Limited relevance to saved meetings. |
| [0.14.3](https://github.com/FluidInference/FluidAudio/releases/tag/v0.14.3) · Apr 29 | Module-map build fix. | Build compatibility. |
| [0.14.4](https://github.com/FluidInference/FluidAudio/releases/tag/v0.14.4) · May 4 | Optional int4 Parakeet v3 encoder; short-segment diarization timeline filtering fixed. | Offline fix included; int4 is not selected. |
| [0.14.5](https://github.com/FluidInference/FluidAudio/releases/tag/v0.14.5) · May 9 | Primarily TTS updates. | No new Recordly feature. |
| [0.14.6](https://github.com/FluidInference/FluidAudio/releases/tag/v0.14.6) · May 17 | Speaker manager becomes a struct; diarizer APIs lose unnecessary async calls; LS-EEND memory leak fix; TDT configuration and diarization progress exposed. | API compatibility checked; LS-EEND remains unselected. |
| [0.14.7](https://github.com/FluidInference/FluidAudio/releases/tag/v0.14.7) · May 19 | Opt-in v3 no-mel decode arbitration. | Later releases change long-form defaults. |
| [0.14.8](https://github.com/FluidInference/FluidAudio/releases/tag/v0.14.8) · May 31 | Public per-chunk diarization embeddings; downloader honors requested models; French drift and end-of-utterance fixes. | Embeddings enable session matching; download fixes included. |
| [0.15.0](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.0) · Jun 4 | Nemotron 3.5 multilingual streaming ASR, SenseVoice Small and Paraformer Large. | Additional engines available, not selected. |
| [0.15.1](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.1) · Jun 5 | Optional GPU encoder placement for v3; Nemotron English latency tier. | Existing compute policy retained. |
| [0.15.2](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.2) · Jun 7 | Primarily TTS updates. | No new Recordly feature. |
| [0.15.3](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.3) · Jun 13 | Experimental Qwen3 ASR/CTC zh-CN removed; transient download retry; timing, final-window and long-form word-boundary improvements; unified Parakeet streaming/offline backend. | ASR fixes included; removed engines were not used by Recordly. |
| [0.15.4](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.4) · Jun 16 | Unified streaming token timings; Japanese TTS additions. | Limited relevance to the offline path. |
| [0.15.5](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.5) · Jul 7 | DownloadUtils replaced by ModelHub: resumable downloads, byte progress, cache validation, retry and cancellation; native Parakeet mel frontend; Sortformer timestamp/precision fixes; offline compute-unit configuration honored. | Provisioning/API changes checked; offline fixes included. |
| [0.15.6](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.6) · Aug 19 | Offline diarization split into `prepare()` / `cluster()` for reusing segmentation and embeddings; ASR seam/alignment fixes; downloader interruption/cache/stall fixes; Sortformer frame fixes; CAM++, FSMN VAD and Canary additions. | Existing offline process path retained; preparation/cache improvements available; new engines not activated. |
| [0.15.7](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.7) · Sep 10 | v3 long-form no-mel arbitration becomes default; optional int8 `Encoder_v2`; offline cancellation and speaker-cap fixes; Intel build fix; NeMo normalization becomes a Swift 6.2 package trait. | Updated v3 behavior included; existing int8 encoder retained; cancellation checked; normalization retained. |
| [0.15.8](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.8) · Sep 20 | Fresh decode state per window, blank-window recovery, seam/text and vocabulary punctuation fixes; diarization artifacts pinned to an immutable revision; CUA-S1-FORM scoring introduced. | Window/runtime and artifact fixes included; scoring model not activated. The official release title says **0.16.0**, but its actual tag is **0.15.8**. |
| [0.16.1](https://github.com/FluidInference/FluidAudio/releases/tag/v0.16.1) · Sep 21 | NeMo dependency updated for Mac Catalyst. | Dependency/build update. |
| [0.17.0](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.0) · Sep 23 | Nemotron 3 streaming diarization for up to eight speakers; ASR tensor-fill optimization. | Optimization included; new streaming diarizer not selected. |
| [0.17.1](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.1) · Sep 23 | CocoaPods version metadata fix. | No functional change for Recordly's Swift Package Manager integration. |
| [0.17.2](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.2) · Sep 24 | Nemotron output-buffer precision mismatch/crash fixed. | Relevant only if that backend is later enabled. |
| [0.17.3](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.3) · Sep 24 | **Parakeet Ultra** and **Redux** added. Ultra is a post-trained v3 derivative supporting the same 25 languages; Redux trades model size for a different performance profile. | Options for a later measured ASR comparison. Existing v3 remains selected. |
| [0.17.4](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.4) · Sep 25 | Nemotron M3 Neural Engine compilation fixed with a revised Core ML export; configurable minimum log level and console mirroring. | M3 fix concerns the new Nemotron backend; logging controls are available. |
| [0.17.5](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.5) · Oct 1 | Phonon-2 English ASR; LocalVQE echo/noise/reverb processing beta; word alignment/vocabulary fixes; TTS roman-numeral list-marker normalization fixed. | ASR fixes included; the numeral fix concerns TTS. English-only engine and beta audio processing not selected. |
| [0.17.7](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.7) · Oct 8 | Paradee-8M beta TTS and Kokoro pronunciation fixes. | Latest pinned maintenance release; no TTS feature added to Recordly. |

There is no separate 0.17.6 entry in the published releases returned by GitHub at the check date. The full comparison includes intervening commits.

## Apple Silicon and model choices

Parakeet is a model family; FluidAudio is the Swift runtime that can execute its Core ML exports on Apple Silicon. MLX is another possible runtime, not a requirement of the Parakeet architecture. Recordly continues to use FluidAudio/Core ML on this Mac.

Ultra is approximately **630 MB** as a complete model directory and supports macOS 14+. Redux is approximately **220 MB** and requires macOS 15+. The upstream benchmarks favor Ultra's accuracy over v3, but they are not a measurement of Recordly's M3 meetings. Changing ASR does not replace the separate diarization embedding model or supply persistent speaker identities. See the pinned [Ultra documentation](https://github.com/FluidInference/FluidAudio/blob/v0.17.7/Documentation/ASR/ParakeetUltra.md).

The eight-speaker limit belongs to the new **streaming Nemotron diarizer**, not an application-wide limit imposed on Recordly's existing offline engine. Overlapping voices, very short turns and noisy audio can still produce uncertain evidence. Those cases must remain visible instead of being forced into a confident identity.

## Acceptance and delivery

Recordly's verification report records the exact test counts, native model run, measured standalone size and source revision. Upstream benchmark numbers are not local acceptance results. The previous standalone archive remains available for rollback; models and recordings live outside the application bundle.

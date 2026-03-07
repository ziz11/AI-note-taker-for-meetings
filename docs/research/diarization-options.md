# Native Open-Source Speaker Diarization Options for a macOS App Without Python

## Executive Summary

This report compares modern speaker-diarization options for integration into a macOS application that should stay local-first and avoid a Python runtime in production.

Best matches as of March 7, 2026:

- **Best fit for Swift/macOS integration:** `FluidAudio`
- **Best fit for C++ or cross-language integration:** `sherpa-onnx`

Useful but weaker fits:

- `qwen3-asr-swift`: strong native Swift option, but more demanding on platform and toolchain requirements
- `Picovoice Falcon`: convenient SDK surface, but not fully offline because it depends on an access key and license validation
- `ALIZE / LIA_RAL / LIA_SpkSeg`: legacy C++ stack, but not a modern DL diarization choice

## Requirements and Assumptions

Target requirement set used in this comparison:

- native macOS integration preferred
- no Python runtime in the production pipeline
- local or offline-first execution preferred
- practical API or CLI for retrieving speaker segments with timestamps
- reasonable integration effort for an app team, not just a research environment

Important assumptions:

- minimum macOS version was not fixed in the source request
- App Store vs direct distribution was not fixed
- real-time vs offline post-processing was not fixed
- overlap handling and cross-session speaker identity were treated as open requirements

## Evaluation Criteria

Each option was evaluated against:

- integration language and runtime shape
- code and model licensing constraints
- current project activity
- macOS build and packaging story
- runtime dependencies
- model format and whether user-side conversion is needed
- API or CLI quality for timecodes and speaker labels
- available performance or quality metrics
- practical product constraints

## Candidate Comparison

| Candidate | Integration shape | Strengths | Main constraints | Overall fit |
|---|---|---|---|---|
| `FluidAudio` | Swift SDK + CLI, CoreML-oriented | Best Apple-platform fit, strong Swift integration story, direct segment output with `speakerId` and timestamps, published benchmark claims | Model licensing must be reviewed separately from SDK licensing; typical input preparation expects 16 kHz mono; remote model registry behavior may need mirroring | Best option for a Swift-first macOS app |
| `sherpa-onnx` | C/C++ API + CLI, ONNX Runtime | Strong C/C++ surface, documented macOS builds, practical CLI and C API, can be packaged for Xcode as an XCFramework | Heavier build/runtime footprint than pure Swift/CoreML; input expectations are stricter; some model choices carry separate usage constraints | Best option for C++ core or cross-language embedding |
| `qwen3-asr-swift` | Swift package + CLI, MLX with optional CoreML embeddings | Native Apple stack, direct diarization API, local model flow, promising modern toolkit | Requires modern Apple Silicon setup, higher toolchain friction, fewer published full-pipeline diarization metrics | Good exploratory option, but not the lowest-risk integration |
| `Picovoice Falcon` | C API and SDKs | Simple API surface and straightforward segment output | Requires access key and online license validation, which conflicts with strict offline expectations | Product-risky for a local-first app |
| `ALIZE / LIA_RAL / LIA_SpkSeg` | Legacy C++ toolchain | Native code and classical offline workflows | Older stack, weaker fit for modern diarization quality expectations, licensing complexity, more setup friction | Only a legacy fallback path |

## Detailed Notes

## `FluidAudio`

Why it stands out:

- It is the cleanest fit for a Swift-first macOS product.
- It is oriented around Apple platforms and CoreML.
- It exposes direct diarization flows that already produce speaker segments and timestamps.

Operational notes:

- Treat code license and model license as separate review items.
- Expect normal audio preparation requirements such as 16 kHz mono input.
- If the default model registry is remote, plan for mirror or override support in enterprise or offline deployments.

Recordly relevance:

- This is the most natural future backend if the app stays Swift-heavy.
- It fits the current stage-driven architecture well because it can live behind a backend module without changing workflow ownership.

## `sherpa-onnx`

Why it stands out:

- It offers a solid C/C++ integration path and documented macOS builds.
- It has both CLI and C API entry points, which makes it usable for fast prototyping and tighter embedding.
- It is a practical candidate when Swift is not the only consumer of the inference layer.

Operational notes:

- Plan for ONNX Runtime packaging and build complexity.
- Expect file-format preparation such as 16 kHz, 16-bit, mono WAV in common examples.
- Review the exact license terms of the chosen diarization models, not just the codebase.

Recordly relevance:

- This is the strongest option if the diarization backend needs to stay C++-friendly or cross-language.
- It matches the current boundary-adaptation rule: convert at the backend boundary, not in session storage.

## `qwen3-asr-swift`

Why it is interesting:

- It is a modern Swift-native toolkit with diarization support.
- It can return structured segments through API or CLI flows.
- It keeps the stack close to Apple tooling.

Why it is not the default recommendation:

- It assumes newer macOS and Apple Silicon requirements.
- It introduces MLX and Metal toolchain expectations that raise integration cost.
- Public full-pipeline diarization metrics are less complete than the strongest alternatives.

Recordly relevance:

- Good for a spike or future experiment.
- Higher risk than `FluidAudio` for a fast production integration path.

## `Picovoice Falcon`

Why it is easy to like:

- It exposes a convenient SDK and C API surface.
- Segment output is easy to consume.

Why it is a poor fit here:

- It depends on access-key validation and periodic online checks.
- That conflicts with strict local-first and air-gapped expectations.

Recordly relevance:

- Technically integrable, but weak on product constraints.

## `ALIZE / LIA_RAL / LIA_SpkSeg`

Why it is still worth noting:

- It is native C++ and historically useful in classic speaker-segmentation stacks.

Why it is not a strong modern choice:

- It is older, less aligned with current diarization expectations, and harder to package cleanly.
- Licensing and setup are more awkward than the modern alternatives.

Recordly relevance:

- Only worth considering as a niche legacy path, not a default recommendation.

## Recommendation for Recordly

Recommended order of exploration:

1. `FluidAudio` if the goal is the fastest clean integration into the current Swift/macOS architecture
2. `sherpa-onnx` if the team wants a stronger C/C++ core or easier cross-language reuse
3. `qwen3-asr-swift` only as an exploratory alternative when Apple-Silicon-only constraints are acceptable

Do not make `Picovoice Falcon` the default choice for Recordly if offline-first behavior is a hard requirement.

Do not choose `ALIZE / LIA_RAL / LIA_SpkSeg` unless there is a very specific legacy reason.

## Integration Guidance for the Current Architecture

Any selected diarization backend should be integrated by:

1. adding a backend module under `Recordly/Infrastructure/Inference/Backends/`
2. implementing `DiarizationEngine`
3. routing it through `DefaultInferenceEngineFactory`
4. switching stage mapping in `DefaultInferenceComposition`

It should not require:

- rewriting `TranscriptionPipeline`
- moving fallback policy out of orchestration
- changing session storage contracts
- changing canonical capture artifacts

## Minimal C API Sketch for a Native Backend Path

```c
#include "sherpa-onnx/c-api/c-api.h"

// Sketch only: build config, create diarizer, run on prepared audio,
// then read segments[i].start / end / speaker.
```

## Final Recommendation

For Recordly's current architecture and product direction:

- choose `FluidAudio` first for a Swift-first diarization spike
- choose `sherpa-onnx` first for a C/C++-centric or cross-language spike
- keep all backend-specific format adaptation at the backend boundary
- preserve the stage-driven, backend-agnostic orchestration model

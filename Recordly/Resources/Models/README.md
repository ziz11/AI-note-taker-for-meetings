# Bundled model resources

> Reviewed 2026-10-10. Current reference. Evidence and open acceptance limits are tracked centrally. See [current project status](../../../docs/project-status.md).

This folder is reserved for explicitly bundled model artifacts. The current standalone does not load speech models from here.

Active models are separately provisioned by FluidAudio 0.17.7 under:

- `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3/` — Parakeet v3 ASR, including JointDecisionv3.
- `~/Library/Application Support/FluidAudio/Models/speaker-diarization/` — offline segmentation/embedding/PLDA package.

The ASR and diarization providers validate required files and prepare the SDK runtime. A Whisper/GGML `.bin` is neither the active speech model nor a usable summary model.

Legacy discovery in `Recordly/Models`, `~/models`, project model folders and `/Users/Shared/RecordlyModels` is compatibility code. Summary controls are disabled; placing GGUF/MLX data here or elsewhere does not enable generation.

See [model integration](../../../docs/model-integration.md) and [latest standalone](../../../releases/standalone-2026-10-10-fluid-speakers/README.md). The FluidAudio resource bundle and license notices are packaged separately; they are not the downloaded model weights.

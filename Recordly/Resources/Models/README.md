Place local model artifacts here only if you intentionally want to bundle them with the app.

Examples:
- summarization-compact-v1.bin
- summarization-compact-v1.gguf
- diarization-enhanced-v1/

Current development flow for Recordly does not read models from this folder.

Development source files are staged outside the app bundle:

- FluidAudio ASR models are SDK-managed and not staged here as local `.bin` files
- `/Users/Shared/RecordlyModels/diarization/diarization-enhanced-v1/`
- `/Users/Shared/RecordlyModels/summarization/summarization-compact-v1.bin`

Installed copies are managed under:

- `~/Library/Application Support/Recordly/Models/diarization/<model-id>/`
- `~/Library/Application Support/Recordly/Models/summarization/<model-id>/`

FluidAudio ASR models are managed separately under:

- `~/Library/Application Support/FluidAudio/Models/<version>/`

For the integration contract, see:
- [Model Integration](../../../docs/model-integration.md)

Place local model artifacts here only if you intentionally want to bundle them with the app.

Examples:
- ggml-medium.bin
- ggml-large-v3-turbo-q5_0.bin

Current development flow for Recordly does not read models from this folder.

Development source files are staged outside the app bundle:

- `/Users/Shared/RecordlyModels/asr/asr-compact-v1.bin`
- `/Users/Shared/RecordlyModels/asr/asr-balanced-v1.bin`
- `/Users/Shared/RecordlyModels/diarization/diarization-enhanced-v1.bin`
- `/Users/Shared/RecordlyModels/summarization/summarization-compact-v1.bin`

Installed copies are managed under:

- `~/Library/Application Support/Recordly/Models/asr/<model-id>/`
- `~/Library/Application Support/Recordly/Models/diarization/<model-id>/`
- `~/Library/Application Support/Recordly/Models/summarization/<model-id>/`

For the integration contract, see:
- [Model Integration](../../../docs/model-integration.md)

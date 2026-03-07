Place local model artifacts here only if you intentionally want to bundle them with the app.

Examples:
- ggml-medium.bin
- ggml-large-v3-turbo-q5_0.bin

Current development flow for Recordly does not read models from this folder.

Development source files are staged outside the app bundle:

- `/Users/Shared/CallRecorderProModels/asr/asr-compact-v1.bin`
- `/Users/Shared/CallRecorderProModels/asr/asr-balanced-v1.bin`
- `/Users/Shared/CallRecorderProModels/diarization/diarization-enhanced-v1.bin`
- `/Users/Shared/CallRecorderProModels/summarization/summarization-compact-v1.bin`

Installed copies are managed under:

Recordly intentionally keeps the legacy `CallRecorderPro` storage folder names for compatibility with existing local installs.

- `~/Library/Application Support/CallRecorderPro/Models/asr/<model-id>/`
- `~/Library/Application Support/CallRecorderPro/Models/diarization/<model-id>/`
- `~/Library/Application Support/CallRecorderPro/Models/summarization/<model-id>/`

For the integration contract, see:
- [MODEL_INTEGRATION.md](/Users/nacnac/Documents/Other_Interner/CallRecorderPro/MODEL_INTEGRATION.md)

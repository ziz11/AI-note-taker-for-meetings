Place bundled native binaries here only if Recordly intentionally starts shipping them inside the app bundle.

Current state:
- the app does not bundle `llama.cpp` here
- summarization expects `main` or `llama-cli` on `PATH`
- backend/runtime selection does not depend on this folder

Add files here only with an explicit packaging change.

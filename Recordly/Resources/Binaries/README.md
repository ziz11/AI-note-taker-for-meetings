# Bundled native binaries

> Reviewed 2026-10-10. Current reference. Evidence and open acceptance limits are tracked centrally. See [current project status](../../../docs/project-status.md).

The current app does not invoke or bundle llama.cpp/llama-cli here. Summarization is disabled by composition and workflow; no PATH lookup or executable setup is required to use Recordly.

Speech inference runs through the linked FluidAudio/Core ML SDK. The standalone has system dynamic dependencies and includes the SDK resource bundle and static NeMo text-normalization runtime.

Retained legacy CLI/backend types are compatibility/test surfaces. Add executable resources only through an explicit packaging/runtime change. See [current model integration](../../../docs/model-integration.md).

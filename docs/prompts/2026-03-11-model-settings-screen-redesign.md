# Model Settings Screen Redesign Prompt

Use this prompt when redesigning the Recordly Models settings screen.

```text
Redesign the Recordly “Models” settings screen.

Goals:
- Make it obvious that users can both download models and select active models.
- Group the UI by provider/runtime.
- Support multiple providers cleanly, even if only some are available today.
- Keep the screen practical and product-like, not a generic AI dashboard.

Core jobs the screen must support:
1. Show providers/runtime groups clearly.
2. For each provider, list available models.
3. Let the user download/install a model.
4. Let the user remove a downloaded model when allowed.
5. Let the user select the active model for each task/stage.
6. Show current status for each model:
   - not downloaded
   - downloading
   - installed
   - selected
   - failed/problem state
7. Show enough metadata to make a choice:
   - model name
   - intended task
   - quality/speed profile
   - size
   - local/SDK-managed/provider-managed source
8. Make it clear which provider owns which models.

Information architecture:
- Top level grouped by provider/runtime, for example:
  - FluidAudio
  - Local models
  - Legacy / compatibility
- Inside each provider section, group by task/stage:
  - ASR
  - diarization
  - summarization
- Within each task group:
  - show currently selected model prominently
  - show other available models below
  - each model row/card must support download/select actions

Behavior requirements:
- Download and selection must feel separate:
  - first acquire/install
  - then select active model
- If a provider manages models via SDK, reflect that clearly.
- If only one model can be selected for a task, use a strong single-select pattern.
- Disabled states must explain why selection is unavailable.
- Failed download/provisioning states must be visible and actionable.
- Preserve room for future providers without redesigning the screen.

Design direction:
- macOS settings feel, polished and dense but readable
- confident hierarchy, minimal clutter
- clear section headers and status badges
- avoid toy-like cards and avoid “AI slop”
- prioritize scanability and operational clarity over decoration

Output:
- produce a detailed screen spec
- include layout structure
- include component list
- include interaction states
- include copy examples for buttons, labels, and status text
- include one desktop layout
- include notes for empty, downloading, installed, selected, and error states

Important:
Design the screen around this product truth:
users need to manage models per provider and per task, with two main actions:
1. download/install
2. select active model
```

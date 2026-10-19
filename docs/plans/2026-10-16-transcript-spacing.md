# Transcript spacing fix

Goal: preserve decoded word boundaries in segmented transcription, rendering and cached reprocessing without changing token timings or storage contracts.

Design: align timed token characters to the original decoded text. Use the matching text pieces when selecting tokens for window ownership, speaker groups, reconciliation and display. Preserve the existing word/punctuation fallback when text and timings cannot be aligned. Do not split display lines inside an aligned word.

Alternatives considered: removing spaces would merge real words; discarding timings would harm window ownership and speaker alignment. Neither is needed.

1. Add regression tests using the reported Russian phrase, cached processing, display boundaries and punctuation. Run them against unchanged production code and verify failure.
2. Add a shared text alignment helper beside ASRWord; use it at every reconstruction boundary. Keep raw timed tokens and cache schema unchanged.
3. Run focused tests and the complete suite; verify a copy of the affected recording using cached inference.
4. Apply verified changes to the actual project and build a signed standalone application.

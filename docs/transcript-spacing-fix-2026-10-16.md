# Transcript spacing fix — 2026-10-16

## Problem and correction

FluidAudio returns both decoded text and timed subword tokens. Segmented transcript assembly treated those tokens as whole words and inserted spaces at ownership filtering, speaker grouping and boundary reconciliation. Rendering could then accept the damaged text as word-level input.

`ASRTimedText` aligns the timed token characters with the decoded text and preserves its whitespace for ordered token selections. Skipped token ranges carry a word boundary forward when necessary. The renderer uses the same reconstruction and waits for a word boundary before splitting a line. Unalignable text retains the existing conservative word/punctuation fallback.

No ASR or diarization model, inference cache schema, token value, confidence, timestamp, audio layout or speaker-matching policy changed. Already assembled historical transcripts need reprocessing from their raw window cache to recover word boundaries.

## Validation

- Regression tests failed on the prior implementation for the reported Russian text and display-line splitting. A review-discovered omitted-prefix case also failed before correction.
- Full suite: 372 tests, 4 optional skips, 0 failures; xcodebuild exit 0.
- Additional opt-in native copy acceptance: 1 test, 0 failures. All 6 ASR windows reused; all 88 timed tokens retained, cached ASR documents unchanged, repeat output stable, audio hashes and session metadata unchanged.
- Independent artifact audit confirmed native acceptance results.
- Signed universal Release built successfully; strict deep signature verification passed. Installed at `/Applications/Recordly.app` with the same designated signing requirement. The running app was not interrupted; restart to load the new executable. GUI validation was unavailable because Computer Use access to Recordly was not approved.
- Installed executable SHA-256: `8ce986f2f16ad53b81a6bc28d5d36c6eb3270c144700d8d974425d7fc42d8921`.
- `git diff --check` passed before the local commit.

## Existing recording and rollback

The affected recording's TXT/SRT/JSON and microphone ASR document were rebuilt from the verified cache output. Every other original file, including audio, raw inference cache, identities and session metadata, remained byte-identical. ASR recognition errors beyond spacing were left as decoded.

A full recording backup, previous signed app, before/after hash audits and verification logs are under `build/spacing-fix-backup-2026-10-16/`. These local ignored files include private recording data and must not be committed. Restoring the saved recording files and app provides rollback.

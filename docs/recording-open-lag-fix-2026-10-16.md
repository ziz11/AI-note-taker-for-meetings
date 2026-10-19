# Recording detail opening performance

Opening a long recording could freeze the UI on every selection because the entire selectable transcript was a single SwiftUI Text. Reading recording 439's transcript took under 1 ms, while laying out that text took about 3.16 s in an isolated reproduction. The UI may request multiple layouts.

The notes panel now uses a read-only, selectable NSTextView with TextKit layout inside the same outer scroll view. It retains complete text, paragraph-spanning selection, native text accessibility, font, dynamic primary/secondary colors, padding and the existing full-transcript Copy action. Width changes recalculate the document height. Playback/progress updates do not replace unchanged text storage or reset selection. Recording files, ASR and diarization are unchanged.

Validation:

- Before the fix, the synthetic 138,000-character detail-view regression failed for all three switches: 2.505 / 2.502 / 2.554 s, exceeding its 1.5 s budget.
- After the fix, the same full detail-view transitions took 0.143 / 0.054 / 0.053 s in the full suite.
- A standalone harness compiled from the exact production component displayed recordings 439, 437, then 439 in 0.132 / 0.157 / 0.050 s. It checked that the native text exactly matched the files and remained selectable and non-editable. Original files were read only.
- Tests cover paragraph-spanning selection, preserving selection on unchanged text, updating text and fallback colors, and reflow after narrowing the window.
- Original fix branch full suite: 387 tests, 6 optional skips, 0 failures. After integration onto updated `develop`: 395 tests, 8 optional skips, 0 failures; long-detail transitions 0.175 / 0.060 / 0.059 s. `git diff --check` passed. Independent code review found no actionable issues.

Limit: installed-app physical mouse selection, autoscroll and VoiceOver were not exercised because computer-use access to Recordly was not approved. Measurements use isolated AppKit/SwiftUI hosts, including the complete detail view in the regression test.

The original implementation was committed on `codex/fix-recording-open-lag`, based on `develop` at `d60d8e8`. At the user's request, the fix is applied as one commit on top of the updated `develop` branch, retaining its later diagnostics changes. The original signed standalone app was built from the fix branch with `scripts/build-standalone-local.sh`; installation retains the previous app and verification logs under the main checkout's ignored build directory. The running app is not stopped automatically, so it needs a relaunch to load the new executable.

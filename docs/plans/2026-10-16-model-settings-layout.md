# Spokenly-style Model Settings Implementation Plan

**Goal:** Replace the oversized, mixed-style Models sheet with the compact catalog requested by the user, using their Spokenly screenshot as the approved visual reference.

**Architecture:** Presentation changes to ModelSettingsView and a narrow view-model fix for immediate diarization download busy state. Preserve the existing view model, provider grouping, download/selection separation, workflow deletion guard, per-asset progress, retry, diarization focus and disabled summaries. No inference or persistence changes.

**Tech Stack:** SwiftUI, AppKit, existing macOS XCTest rendering harness.

## Design

Use one header (Dictation Models, a short local-processing subtitle, close). Follow with a single ruled table: Model, Runtime, Features; compact radio, 36-point icon, 14-point semibold model title, short two-line description and text actions. Keep Ultra's recommended badge small, and selected state as a subdued blue row with radio rather than a second large status. Use 12–13-point metadata and 20-point outer margins, neutral dark surfaces, 10-point corners and restrained separators.

Speaker Separation has one small section label and one table row with the same columns and geometry. Show Ready once, download or retry when needed, and an explicit downloading/error state. Summarization is one muted footer line. Discovered custom ASR remains a separate labeled, read-only compact list. Do not invent ratings, cloud tabs, unsupported models, or a nonfunctional Test action.

Alternative considered: adding a sidebar like the whole Spokenly app would create navigation to two short sections inside an existing sheet. Keeping the current large cards would preserve the visual inconsistency rejected by the user. A compact catalog best matches the supplied reference and existing product navigation.

## Tasks

1. Replace ModelSettingsView layout and remove obsolete card/chip/wrap helpers. Keep actions and accessibility labels; pin the header outside scrolling content. Use explicit fonts so system text styles cannot inflate hierarchy.
2. Add and run a failing regression test for diarization download busy state and repeated clicks; make the view model publish busy before awaiting preparation. Reuse and extend the opt-in NSHostingView visual harness to render the normal 1040×680 sheet, a 900×620 sheet, and a light appearance. Include ready, missing/downloading/failed ASR fixtures and missing/failed diarization fixtures. Do not add tests that mirror static layout code.
3. Run ModelSettingsViewModelTests and FluidAudioASREngineTests against pinned packages. Inspect rendered images at actual output size and correct clipping/overflow. Obtain read-only code review.
4. Increment the app build to 2. Build signed standalone, verify extracted bundle and runtime binary. Record the new artifact/checksums and update the delivery/status documentation. Integrate changes while preserving unrelated work. Check active recording before replacing/relaunching any running app; preserve capture.

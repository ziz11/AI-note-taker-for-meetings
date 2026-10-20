# Barkenson app implementation plan

**Goal:** Prepare the existing macOS app for the approved Barkenson presentation while preserving existing data and runtime behaviour.

**Approved design (2026-10-20):** Barkenson public name, native macOS typography and surfaces, a warm orange accent, no inactive summary controls. Final icon is explicitly deferred until the designer provides the selected artwork.

**Architecture:** Presentation and bundle metadata own this change. Keep Recordly product/module/target names, com.local.Recordly, existing signing settings, storage paths, model providers, preference keys and inference algorithms unchanged. A public app name does not require a persistence migration.

**Tech stack:** SwiftUI/AppKit, Xcode 26.3, macOS 15+, existing FluidAudio 0.17.7 pin.

## Steps

1. Add a hosted compatibility check for the built bundle public name and retained identifier/executable; run it against the current metadata to confirm the missing brand.
2. Set CFBundleName/CFBundleDisplayName, permission explanations and build number. Keep executable/product names and signing identity stable. Use native About/menu and Models settings access.
3. Remove inactive Summary tabs, actions and search claims from views; keep summary persistence and disabled entry points intact. Keep transcript copy/export and audio controls.
4. Replace the unused legacy onboarding presentation with a concise branded welcome and explicit route to existing SDK model settings. Explain permissions, local processing and model downloads; retain skip/reopen paths. Use semantic text colours in light/dark appearance.
5. Stage Barkenson.app from the unchanged Recordly.app build product for standalone packaging, and retain executable/signing identifiers. Document upgrade procedure, links and release limits in a focused guide; avoid duplicating README PR #22.
6. Run the existing suite, packaging checks and metadata checks. Render welcome/models/recording views in light/dark appearance for inspection where supported. Request review; fix material findings; create a PR targeting develop.

## Baseline evidence

Source: 327e976460b363d621a150d4c0d4b085e2cafabe. Worktree: .worktrees/barkenson-app; branch: codex/barkenson-app.

Xcode Debug test run succeeded on macOS: 395 tests, eight opt-in skips, zero failures. Disabled unsigned/distribution script checks and local-signing script check each passed. Baseline is a build/test result, not GUI or recording hardware acceptance.

## Open acceptance limits

Final icon/brand artwork awaits the designer. No other-Mac installation, long recording/sleep, permission renewal, Developer ID or notarisation claims are implied by local tests. Integration/publication and repository rename belong to the coordinator.

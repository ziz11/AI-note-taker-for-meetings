# Barkenson Distribution Preparation Plan

> Execution owner: the technical coordinator. Agents work in separate branches; only the coordinator integrates. This plan covers preparation and verification, not new product features.

**Goal:** Prepare a free standalone macOS meeting recorder for the author and friends, distributed through GitHub Releases with a GitHub Pages website.

**Architecture:** Change public branding at the presentation and packaging boundaries. Preserve the existing inference, workflow, persistence and model contracts. Automatic summaries remain disabled.

**Tech stack:** Swift/SwiftUI, Xcode, FluidAudio 0.17.7, local AAC session storage, GitHub Releases and GitHub Pages.

> Current execution status: see [application/icon integration](../distribution/2026-10-20-app-icon-integration.md). The repository has since been renamed to `ziz11/Barkenson-Meeting-recorder-for-Mac`. Initial baseline and PR inventories below are dated snapshots.

## Final naming decision

The owner confirmed **Barkenson** as the final public application name on 20 October 2026 in this chat. The exact short description is **Meeting recorder for Mac.** The app is free. Public text uses British English: diarisation, summarisation, behaviour, artefacts, licences and notarisation.

Keep `Recordly` as the internal project, target, executable, bundle identity and storage namespace for the first branded release. A marketing rename does not require renaming those identifiers. The repository slug proposed for the final cutover is `Barkenson`; its availability and the Pages destination must be checked before the rename. Name confirmation alone does not prove those checks passed.

## Baseline and evidence policy

Initial checkout: clean `develop`, commit `327e976460b363d621a150d4c0d4b085e2cafabe`. Local `main`, `origin/main` and `origin/develop` match. A fresh remote heads query confirmed `main` and `develop` at that commit, `docs/readme-uk-english` at `bae5e9f39189b9461f8cc185b7c7e85041ed69d9`, and `site/barkenson-paper` at the baseline. The default remote branch is `main`.

Existing documentation is useful for locating implementation and historical acceptance, but its 16 October build and test counts do not certify the current source. Classify every claim as source inspection, fresh automated verification, manual acceptance, historical evidence or unverified. Native speech accuracy, permissions and a quarantined download require their own acceptance; a successful unit suite is insufficient.

## Ownership and file allocation

| Owner / branch | Exclusive files in this preparation round | Responsibility |
| --- | --- | --- |
| Coordinator / `codex/barkenson-coordination` | `README.md`, `docs/README.md`, `docs/project-status.md`, this plan, `docs/distribution/integration-result.md` | Review PRs, final name, integration order, baseline build/tests, public claims and final evidence |
| Identity agent / `codex/barkenson-identity-audit` | `docs/distribution/identity-preservation.md` | Inventory settings, paths, signing and permission dependencies; safe upgrade and rollback plan |
| Release agent / `codex/barkenson-release-audit` | `docs/distribution/release-readiness.md` | Audit packaging, licences, signing, Gatekeeper, Pages and release gates |
| Capabilities agent / `codex/barkenson-capabilities-audit` | `docs/distribution/capabilities.md` | Compare implementation with advertised capabilities and limits |

All branches start at the same baseline in separate ignored `.worktrees/` checkouts. Agents commit their owned files and report the SHA; they do not merge, push, publish, edit installed apps or touch personal recording data. The coordinator reviews each diff and integrates the commits. This round deliberately produces an integrated preparation dossier and corrected README; it does not claim to produce a branded distributable binary or a deployed website.

## Existing work and duplication control

[PR #22](https://github.com/ziz11/AI-note-taker-for-meetings/pull/22), “Describe Recordly as a local call recorder in British English”, is open, non-draft, mergeable and based on current `main`. Its head is `bae5e9f`; the one-commit diff changes only `README.md`. The GitHub query returned no other open PRs; comments and reviews were empty at inspection. The coordinator reuses this commit before making narrow naming and accuracy corrections. Do not commission another README rewrite. Local inclusion does not close or merge the remote PR; preserve its attribution and avoid later applying the README patch twice.

The remote `site/barkenson-paper` branch has no changes relative to the baseline at inspection. A branch name is not proof of a completed or deployed site. Before a site agent starts, re-query its head and open PRs to avoid racing work outside this chat.

## Integration sequence

1. Lock the public name and baseline. **Done:** name confirmed; branch/remote/PR inspection recorded above.
2. Reuse PR #22 in the coordinator branch. Correct platform and export claims; introduce Barkenson while explaining the retained internal name.
3. Review and integrate the three independent audit documents. Resolve inconsistent terminology and distinguish implemented behaviour from demonstrated acceptance.
4. Run a fresh macOS test build, retain the exact command, source commit, Xcode version, result bundle, failures and skips. Run packaging guard checks. Record failed attempts as well as successful ones.
5. Review the integrated diff against AGENTS.md: no inference, workflow, persistence, cache or summary-enablement changes. Check Markdown links and ensure no binaries or personal data enter Git.
6. Only then allocate the implementation round below. All release gates remain open until demonstrated on the actual release artefact.

## Implementation round after preparation

| Owner | Files allowed | Required output |
| --- | --- | --- |
| Brand agent | `Recordly/Info.plist`; visible name strings in `Recordly/App/RecordlyApp.swift` and recording/onboarding views only where needed | Display name and permission prose say Barkenson; internal IDs, paths, runtime and workflow unchanged. Do not globally replace Recordly. |
| Packaging agent | `scripts/build-standalone-local.sh`, dedicated new release packaging/verification scripts and script tests; project signing settings only by coordinator-approved signing decision | Versioned ZIP, notices, checksum and documented signing policy; compatible installed-app upgrade, without exporting signing keys |
| Website agent | New `website/` and a narrowly scoped Pages workflow under `.github/workflows/` | Static British English page; final name/description/free price, accurate capabilities and limits, requirements, setup/privacy/storage information, release link; no fake download |
| Coordinator | README/status/index/release notes and repo settings | Review brand/package/site PRs in that order, run acceptance, update links, then rename repository and publish |

Do not change source folder names, Xcode target/scheme/executable, bundle identifier, session artefacts, model resolution, UserDefaults keys or signing certificate merely for brand consistency. If the implementation needs broader changes, return to the identity plan before editing.

## Readiness criteria and blockers

Preparation is ready when the four documents and reused README are integrated, source findings are reconciled, fresh verification is recorded and open release gates are explicit.

Distribution is ready only when all of the following are demonstrated:

- A freshly built, versioned standalone bundle runs without Xcode on the author's Mac and a separate supported Apple Silicon Mac running macOS 15 or later.
- A signed artefact has a documented trust path. Local self-signing is not notarised public distribution. Choose and verify Developer ID/notarisation, or explicitly accept a limited friends-only, non-notarised distribution with tested Gatekeeper instructions; never instruct recipients to disable Gatekeeper globally.
- Existing sessions, names, transcript artefacts, model caches, selected model, settings and legacy sessions survive an upgrade and rollback. Verify on a backed-up test account/copy; do not run destructive acceptance on the author's only recordings.
- Compare old/new designated requirements; demonstrate Microphone and Screen Recording consent behaviour. If the signing identity changes, record any legitimate re-consent instead of promising preservation.
- Capture microphone/system audio, play back, import audio, transcribe, export TXT and combined audio, reopen after restart and recover interrupted work. Confirm summary calls remain no-ops. Record unresolved speaker labels and failure behaviour honestly.
- Validate the archive after extraction, embedded notices, minimum OS, actual architecture, version/build, bundle ID, checksum, no models/private recordings, and final source SHA.
- Confirm permission to distribute the project's own code and every bundled dependency/model artefact. Free pricing is not a licence grant; no root project licence was found in the baseline.
- Review all app/README/site/release text in British English. Do not advertise Intel inference, meeting-wide speaker accuracy, live transcripts or summaries.
- Test the actual Pages deployment at its repository subpath, including all assets, navigation and release links. No deployed Pages site has been verified in this round.
- Re-query open PRs and branches, check target slug availability and all external URLs, then rename the repository. Update remotes, clone instructions, badges, GitHub Pages base path, workflows, releases links and website metadata in one coordinator-owned cutover. Test old redirects and new direct URLs; do not assume Pages redirects follow repository redirects.

Current release blockers: an actual branded bundle and upgrade/permissions acceptance; chosen signing/trust policy; friends' clean-Mac smoke test; missing root licence decision; Pages implementation/deployment and link verification; repository cutover. None is waived by historical reports or by a green test suite.

See [capabilities](../distribution/capabilities.md), [identity preservation](../distribution/identity-preservation.md), [release readiness](../distribution/release-readiness.md) and the [integration result](../distribution/integration-result.md) for details and fresh evidence.

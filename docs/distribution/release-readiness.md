# Barkenson release readiness

Audit date: 20 October 2026. Final public name: **Barkenson**, confirmed by the owner. Description: **Meeting recorder for Mac.** Free standalone application, delivered as a GitHub Release asset; website on GitHub Pages. Public copy uses British English.

## Scope and evidence

This audit inspected source at `327e976460b363d621a150d4c0d4b085e2cafabe` in `codex/barkenson-release-audit`. It changes documentation only. It does not certify a current app build, signing identity, installed application, release asset, Pages deployment or remote repository settings. No Keychain, TCC, recordings or model-cache changes were made.

The [project status](../project-status.md), [distribution plan](../plans/2026-03-12-distribution-packaging-design.md) and [historical release records](../../releases/README.md) were read as context. Their binary hashes, installation claims and test totals are historical evidence. They cannot qualify the integrated Barkenson source or a future release ZIP.

| Check performed in this audit | Result | What it establishes |
| --- | --- | --- |
| `zsh scripts/test-build-distribution-app.sh` | PASS | Disabled distribution script rejects execution and creates no build artefacts. |
| `zsh scripts/test-build-unsigned-app.sh` | PASS | Disabled unsigned script rejects execution and creates no build artefacts. |
| `zsh scripts/test-local-signing.sh` | PASS | Mocked Keychain flow is idempotent; certificate packaging supports tested OpenSSL variants; expected Debug identity settings exist. It does not inspect a real identity or sign an application. |
| `zsh scripts/build-standalone-local.sh --help` | Exit 0 | Help path works; no build executed. |
| `plutil -lint Recordly/Info.plist scripts/export-options-developer-id.plist Recordly.xcodeproj/project.pbxproj` | All three OK | Files parse; no claim about build or export success. |
| PNG signature/dimension check against `AppIcon.appiconset/Contents.json` using Python standard library | PASS, 10 PNG files | Checked-in icon sizes match catalogue declarations; no visual brand approval or compiled icon check. |

## Packaging and signing findings

- [`build-standalone-local.sh`](../../scripts/build-standalone-local.sh) builds Release with a persistent `Recordly Local Development` certificate, copies third-party notices into the bundle, signs again, verifies the signature and creates a ZIP using `ditto`. Outputs and project/scheme names currently use Recordly. Its explicit build destination is arm64; no architecture claim is accepted without inspecting the resulting executable and dependencies.
- This script is a local development route. It does not implement Developer ID export, notarisation or stapling. `--preserve-metadata=...runtime` preserves existing metadata; it does not demonstrate that hardened runtime was enabled.
- [`build-distribution-app.sh`](../../scripts/build-distribution-app.sh) and [`build-unsigned-app.sh`](../../scripts/build-unsigned-app.sh) are disabled. [`export-options-developer-id.plist`](../../scripts/export-options-developer-id.plist) retains `TEAMID_PLACEHOLDER`; it is not a working export configuration.
- Baseline Release settings have automatic signing and an empty team; Debug has the local certificate. No explicit hardened-runtime build setting or app entitlements file was found. The app sandbox is disabled. The public shipping signature and any required entitlements remain unverified.
- The project declares macOS 15.0 minimum, app version 0.1.0/build 4, bundle identifier `com.local.Recordly`, and FluidAudio 0.17.7 pinned to `503b4bd1bbf7220882de39fe8ae6716aae4132da`. These are source settings, not a fresh binary inspection.
- Public branding can change without renaming the project, scheme, Swift module or compatibility identity. Packaging must resolve the actual resulting app name; do not replace every occurrence of Recordly globally. Keep storage, preferences and signing continuity under the identity plan.

## Notices, models and assets

[`THIRD_PARTY_LICENSES.md`](../../THIRD_PARTY_LICENSES.md) includes FluidAudio/NeMo attribution and Apache text. [`third-party/FluidAudio-0.17.7/`](../../third-party/FluidAudio-0.17.7/) contains fastcluster, VBx, NeMo attribution, licence, NOTICE and dependency notices. The local standalone script copies them before the final signature. A direct Xcode build has no equivalent explicit copy step for these root-level files; inspect the final public bundle rather than assuming every build route includes them.

No root-level project `LICENSE` was found. The owner must state the intended terms for Barkenson's own code/binary before the release presents licensing claims; being free does not itself define those terms. This is an unresolved distribution decision, not a legal finding about third-party compliance.

SDK-managed models are downloaded separately and are not supplied by the packaging script. Record the exact model repositories/revisions, download terms and required notices for Ultra, v3 and speaker separation before claiming model redistribution permission. Do not bundle model weights as part of rebranding. The presence of SDK attribution does not establish terms for every downloaded weight.

The current AppIcon catalogue has all ten declared PNG sizes. Visual Barkenson approval, compiled `.icns` inclusion, Finder/Dock rendering, permission-prompt copy and website/social assets still need review. Screenshots must come from the integrated app and use British English; do not advertise summaries, guaranteed speaker accuracy, Intel inference support or quantified performance improvements without matching evidence.

## Blocking gates and owners

| Gate | Owner | Evidence needed to close |
| --- | --- | --- |
| Integrated source builds and tests | Coordinator | Exact integrated commit, Xcode/macOS versions, fresh command logs and result bundle; required tests passing with every skip explained. |
| Upgrade identity and data continuity | Identity/app agent, coordinator accepts | Disposable copy of existing recordings/settings/models; old/new bundle identity and designated requirements; recordings, names, cached work, selected models and permissions checked across replacement and restart. Do not reset existing grants as routine release preparation. |
| Distribution signing route | Coordinator/owner | Decide supported release route. For the normal signed release, a usable Developer ID identity/team and repeatable signing/export process, hardened runtime/entitlement review, notarisation result and final artefact assessment. If an explicitly agreed limited pilot uses another route, label its trust limitations and test the exact downloaded bundle on another Mac; do not call a local certificate notarised. |
| Exact downloadable ZIP | Coordinator | New version/build, exact source SHA, architecture inspection, included runtime dependencies/notices/icon, successful final signature verification, ZIP SHA-256 and size, extract-and-run acceptance. No Xcode or repository checkout at runtime. |
| Real user acceptance | Coordinator + owner/tester | Quarantined download on a separate macOS user/Mac, first launch, microphone/system-audio grant/denial/retry, model download then offline processing, record/stop/restart/reopen/import/playback/export, degraded diarisation and disabled summaries. Use disposable recordings; preserve originals. |
| Own and third-party terms | Owner, coordinator inventories | Own-code/binary licence decision; inventory of actual linked/embedded components and model terms; final bundle notices verified after packaging. |
| Site and release links | Website agent, coordinator accepts | Deployed Pages URL and base path, valid download/version/checksum links, repository/support/source links and mobile/desktop checks after final repository name. No download button to a nonexistent asset. |

Lack of current build/acceptance evidence blocks a release-ready claim. Meeting-wide speaker accuracy, Intel speech-runtime support, long-capture energy/memory behaviour and complete GUI responsiveness remain unverified product limits; release copy must state the support actually tested. These are not invitations to change inference during this work.

## Repository and Pages sequence

1. Coordinator confirms the latest remote PR/branch inventory, including README PR #22 and the reported `site/barkenson-paper` work. Reuse existing work; this audit does not recreate the README or website. That site branch was not present in this worktree's local remote refs, so its contents and deployment are unverified here.
2. Integrate and review the name/identity, British English README and site changes on the coordinator branch. Keep the source-repository URL currently configured as `https://github.com/ziz11/AI-note-taker-for-meetings` until the remote is actually renamed. The owner has confirmed Barkenson; final repository slug/availability and Pages settings still need checking.
3. Search all public documents, site files, metadata, release templates and scripts for the old repository URL/name. Classify compatibility names separately from public links. Check GitHub project-site base paths and relative assets, not only absolute URLs. Baseline has no tracked Pages site or `.github` workflow in this checkout; remote deployment settings need a live inspection.
4. Only the coordinator renames the repository, after the link change set is concrete and reviewed. Record the new URL, update remotes/metadata and links, then verify old redirect behaviour rather than relying on it. Pages serving and project base paths must be tested at the new address.
5. Build and verify the exact integrated source, prepare the release artefact and checksum, then publish GitHub Releases and Pages in an order that never advertises an absent download. If the site is published first, present an honest preparation state without an active download claim. Verify live final links and downloaded checksum after publication.

## Required release record

For each candidate retain: source commit/tag; version/build; toolchain and OS; build/test commands and logs; expected/observed architectures; old/new identity comparison; signature and notarisation assessment; final ZIP filename, bytes and SHA-256; notices inventory; disposable upgrade and separate-Mac acceptance outcomes; known limitations; final repository, Pages and release URLs. A passing helper-script test or old installed app is never a substitute for this record.

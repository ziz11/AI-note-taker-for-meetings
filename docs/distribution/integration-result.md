# Barkenson preparation: integrated result

Date: 20 October 2026. **Historical preparation baseline:** superseded for current integration status by [the application and icon integration record](2026-10-20-app-icon-integration.md). Coordinator branch: `codex/barkenson-coordination`.

**Preparation status:** the final name, ownership plan, capability inventory, identity-preservation strategy and release gates are integrated. **Distribution status:** not release-ready. This round does not rename the application bundle or repository, deploy Pages, publish an asset, install an app or certify upgrade permissions.

## Included work

The owner confirmed **Barkenson**, **Meeting recorder for Mac.**, free standalone distribution through GitHub Releases and a GitHub Pages site. Public documents use British English. Internal Recordly identifiers remain intentional compatibility boundaries.

| Input | Integrated result |
| --- | --- |
| Existing README PR [#22](https://github.com/ziz11/AI-note-taker-for-meetings/pull/22), original commit `bae5e9f` | Reused as `e2ca50e`, preserving authorship; then corrected public branding, platform/export statements, permission wording and historical-build claims. No parallel README rewrite. |
| Release agent `242925a` | Integrated as `89b14c4`: [release-readiness.md](release-readiness.md). |
| Capability agent `e1bcdb1` | Integrated as `ea1aa9d`: [capabilities.md](capabilities.md). |
| Identity agent `57f058e` | Integrated as `a7b14d5`: [identity-preservation.md](identity-preservation.md). |
| Coordinator | [Final plan and file allocation](../plans/2026-10-20-barkenson-distribution.md), README/index corrections and this evidence record. |

All agents worked in separate branches/worktrees. Only the coordinator integrated commits. The release agent independently reviewed the combined documents and README read-only; the coordinator resolved its three findings about notarisation wording, summary rationale and stale rollback claims. No app, test, project or packaging source changes are part of this preparation branch.

GitHub inspection found one open PR (#22), mergeable and non-draft, based on `main` at `327e976`; no reviews/comments were returned. It remains open remotely. The remote `site/barkenson-paper` branch pointed at the baseline, with no site changes demonstrated. Remote inspection is a snapshot; re-query before integration or publication. Remote PR merge, branch synchronisation and repository rename have not been performed.

## Fresh verification

Machine: arm64, macOS **26.7.1 (25G241)**, Xcode **26.3 (17C529)**. Tests target macOS arm64. Application/test/project/script source matches baseline `327e976460b363d621a150d4c0d4b085e2cafabe`; subsequent integrated changes are documentation only. The reused FluidAudio checkout was inspected at pinned revision `503b4bd1bbf7220882de39fe8ae6716aae4132da` (0.17.7), matching `Package.resolved`.

The first sandboxed test attempt failed during package resolution because Xcode could not write its Swift/Clang caches. This was an environment failure before tests, not a passing build. A subsequent run with the required Xcode access completed with exit 0 and `TEST SUCCEEDED`:

```sh
xcodebuild test -project Recordly.xcodeproj -scheme Recordly \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /Users/nacnac/Documents/dev/vibecode/Recordly/build/barkenson-readiness \
  -clonedSourcePackagesDirPath /Users/nacnac/Documents/dev/vibecode/Recordly/build/standalone/SourcePackages \
  -disableAutomaticPackageResolution \
  -resultBundlePath /Users/nacnac/Documents/dev/vibecode/Recordly/build/barkenson-readiness-tests.xcresult
```

Result: **395 tests, 0 failures, 8 skips**. Local evidence: `build/barkenson-readiness-tests.log` and `build/barkenson-readiness-tests.xcresult` at the repository root, not committed. The failed initial attempt is `build/barkenson-readiness-baseline.log`.

The eight skips were: one non-FluidAudio runtime branch inapplicable on this build; one opt-in Ultra/v3 native excerpt; one model-picker visual render; two private-recording acceptance probes requiring isolated paths; one native performance excerpt; one performance-panel render; and one native voice-evidence fixture. No opt-in recording/model environment variables were supplied. These skips leave native model quality, GUI rendering/performance and recorded-meeting acceptance open.

Coordinator repeats of `scripts/test-build-distribution-app.sh`, `scripts/test-build-unsigned-app.sh` and `scripts/test-local-signing.sh` passed. The first two verify that disabled scripts remain disabled, not that distribution works. The signing test uses a fake Keychain boundary, not the user's real signing identity. `plutil -lint` passed for the app plist, export-options plist and Xcode project. The release agent additionally checked ten declared icon PNG dimensions and the standalone help path.

## Fresh local Release package

The existing `scripts/build-standalone-local.sh` completed with exit 0 and `BUILD SUCCEEDED` using the existing local identity. Command, run from the coordinator worktree:

```sh
RECORDLY_BUILD_DIR=/Users/nacnac/Documents/dev/vibecode/Recordly/build/barkenson-readiness-release \
RECORDLY_PACKAGE_CACHE=/Users/nacnac/Documents/dev/vibecode/Recordly/build/standalone/SourcePackages \
./scripts/build-standalone-local.sh
```

The source revision recorded by packaging is **`2c391f4`** (the preparation commit); application, project, scripts and tests remain identical to baseline `327e976`. Subsequent evidence-only commits do not alter the binary source. Log: `build/barkenson-readiness-release.log`.

| Inspected output | Fresh result |
| --- | --- |
| Local archive | `build/barkenson-readiness-release/Recordly-2c391f4-local.zip`, **24,154,946 bytes** |
| ZIP SHA-256 | `1a1fcbcfea7b75d2b67ceeb3227009e8b6b8de24f6ef7ae07db45e0879aad638` |
| Executable SHA-256, built and extracted | `fe824b69e2b62838a6c25899ead819e37887c05f1c180da699eb96b129d300b0` |
| Bundle metadata | `Recordly.app`, executable/name `Recordly`, identifier `com.local.Recordly`, version **0.1.0 (4)**, minimum macOS **15.0** |
| Executable architecture | Universal **arm64 + x86_64**, inspected with `file`; this does not add Intel inference |
| Signature | Built and extracted apps pass `codesign --verify --deep --strict --verbose=2` with Keychain access: valid on disk and satisfy their designated requirement |
| Signing identity | `Recordly Local Development`, no TeamIdentifier, flags `0x0`; no hardened runtime or notarisation claim |
| Designated requirement | Identifier `com.local.Recordly` and certificate root hash `b5b4e764405e28dd9d5a814d5241c77b5c591e8e` |
| ZIP inspection | CRC integrity check passed; 123 entries; root third-party notices and FluidAudio licence directory present; no recording/audio/model-weight entries found in the targeted scan |

An initial additional `codesign` check inside the restricted sandbox returned `CSSMERR_TP_NOT_TRUSTED` and could not display the authority. Repeating with the required Keychain access verified both the original and extracted app and displayed the authority above. The initial failure is not silently treated as a success.

This is a **local verification package**, retaining the original app name and version. It was not installed, launched, notarised, tested as a quarantined download, or published. It is not the final Barkenson release asset. No signature comparison with the author's installed old app or TCC upgrade test was performed. A successful local package does not close the remaining release gates.

## Reconciled product claims

- Active speech recognition and diarisation require Apple Silicon; a universal executable does not provide Intel inference.
- Live capture records microphone/system audio; no live streaming transcript or meeting-app isolation is promised.
- TXT export is visible in the UI. SRT and JSON are saved session artefacts, accessible through the recording folder.
- System-track speaker matching is partial. Arbitrary imported audio does not establish general multi-speaker diarisation support.
- Models download separately, and selection is distinct from installation. No unverified language-count or hardware-performance promise is added.
- Summaries remain disabled. No inference pipeline, stage selection, workflow, cache, settings key or canonical recording format changed.

## Remaining release blockers

1. Implement and inspect presentation-only branding and the final outer `Barkenson.app` package while retaining `com.local.Recordly`, executable/module/scheme, data/model paths and preference keys.
2. Choose a tested signing/trust route. Verify actual old/new designated requirements and both capture permissions; a move to Developer ID may require legitimate renewed consent.
3. Run upgrade/rollback and clean-recipient acceptance on disposable backed-up data and a separate supported Mac, including model download/offline processing, capture, playback, import/export and recovery.
4. Resolve own-code/binary licence terms and verify notices for actual bundled dependencies and separately downloaded models. No new model redistribution is proposed.
5. Implement/review/deploy Pages, verify the proposed repository slug and complete link cutover. Do not present a download button until its release asset exists.

The detailed owner/file matrix and closure evidence are in the [coordination plan](../plans/2026-10-20-barkenson-distribution.md). These are pending checks and decisions, not inferred failures of the existing application. Preparation is reviewable; publication waits on demonstrated release gates.

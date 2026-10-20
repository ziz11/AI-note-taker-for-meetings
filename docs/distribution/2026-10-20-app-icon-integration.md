# Barkenson application and icon integration

20 October 2026. This record supersedes the [initial preparation snapshot](integration-result.md) for current integration state. It separates source integration from public distribution acceptance.

## Integrated decisions and PRs

- The final name is **Barkenson**, description **Meeting recorder for Mac.**, free standalone distribution through GitHub Releases. Public copy uses British English.
- The owner renamed the existing repository to [ziz11/Barkenson-Meeting-recorder-for-Mac](https://github.com/ziz11/Barkenson-Meeting-recorder-for-Mac). The coordinator updated `origin` and the current README/build guide. Historical evidence retains its original URLs and dates where appropriate.
- [PR #24](https://github.com/ziz11/Barkenson-Meeting-recorder-for-Mac/pull/24) was independently reviewed and merged into `develop` as `d82c43d`. It contains approved native typography, warm orange accent, Barkenson display/menu/About/permission text, build 5, removal of inactive summary UI and local package naming. Inference, models, canonical data paths, existing settings and signing identity remain unchanged. The additional Store state is presentation readiness after recovery discovery, with regression coverage.
- [PR #22](https://github.com/ziz11/Barkenson-Meeting-recorder-for-Mac/pull/22) was retargeted to `develop` and merged as `d628b3e`. The coordinator preserved its authorship, corrected platform/export/identity claims and updated the final name and repository links. The integration branch reconciles both remote merge histories.
- The owner explicitly selected only the **The Imprint icon**: orange quotation marks on cream. Designer commit `18b6f40393a95263dc2bf84bb90fdda52be16088` supplies editable SVG, ten PNG representations and ICNS. The coordinator copied the exact ten verified PNGs into the existing `AppIcon.appiconset`; catalogue filenames and build identity are unchanged. See [icon source and reproduction](../brand/icon-handoff.md).
- [PR #23](https://github.com/ziz11/Barkenson-Meeting-recorder-for-Mac/pull/23) remains a draft. The site agent is updating links, Pages subpath and factual copy for the new repository/name. The existing website design is not treated as approved by the icon choice. A combined local review branch preserves the earlier draft; the publishable application integration excludes the website/workflow.

## Fresh coordinator checks

Independent read-only review of `327e976..f7b3a46` found no actionable correctness findings. It checked recovery/welcome ordering, the single modal presentation, summary UI removal, bundle/executable identity, packaging and tests. Whitespace, shell syntax and plist checks passed. This is code review, not live interaction acceptance.

The coordinator ran the integrated application suite on arm64 macOS with Xcode 26.3 using the persistent local signing configuration:

```sh
xcodebuild test -project Recordly.xcodeproj -scheme Recordly \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /Users/nacnac/Documents/dev/vibecode/Recordly/build/barkenson-readiness \
  -clonedSourcePackagesDirPath /Users/nacnac/Documents/dev/vibecode/Recordly/build/standalone/SourcePackages \
  -disableAutomaticPackageResolution \
  -resultBundlePath /Users/nacnac/Documents/dev/vibecode/Recordly/build/barkenson-integrated-app-tests.xcresult
```

Result: **397 tests, 0 failures, 8 skips**, `TEST SUCCEEDED`, exit 0. Local log: `build/barkenson-integrated-app-tests.log`. This run preceded the PNG-only icon replacement. The eight skips are the same opt-in native/model/private-recording/render probes and inapplicable non-FluidAudio path explained in the initial report; they do not establish model quality or installed GUI acceptance.

The coordinator separately repeated all three existing packaging/signing guard scripts: PASS. The disabled distribution/unsigned guards do not implement Developer ID distribution. The icon source/export checksums were all verified; every copied representation matches its declared pixel size and the designer's source bytes. The scale study was visually inspected. No icon image was regenerated or inferred from a mock-up.

Application inference, transcription, persistence, model provisioning and workflow source has no changes relative to the pre-branding baseline. Summary generation remains disabled; only its inactive UI was removed. The bundle identifier remains `com.local.Recordly`; the executable/module/scheme remain Recordly; SDK and Recordly data roots remain intact.

## Verified integrated local package

Source/package commit: **`15be35a`**, including the selected icon. The working tree was clean when the existing local standalone script built the Release package. The script completed with exit 0 and `BUILD SUCCEEDED`. It used `RECORDLY_BUILD_DIR` at repository-root `build/barkenson-readiness-release` and the existing pinned `build/standalone/SourcePackages` checkout. Local log: `build/barkenson-final-icon-package.log`.

| Check | Fresh result |
| --- | --- |
| Archive | `build/barkenson-readiness-release/Barkenson-15be35a-local.zip`, **24,078,882 bytes** |
| ZIP SHA-256 | `1ee36de64e35f7750bfd621ae338347b75d6cb2582f60e03e04e76eaf71c5124` |
| Extracted executable SHA-256 | `ed31d8b96280e3dbef5eb192036983a0350b8f15f08abd70c78446b3aa45e128` |
| Metadata | Name/display name Barkenson, executable Recordly, identifier `com.local.Recordly`, **0.1.0 (5)**, minimum macOS 15.0, universal arm64/x86_64 |
| Extracted signature | `codesign --verify --deep --strict --verbose=2` passes; authority `Recordly Local Development`, no team, flags `0x0` |
| Designated requirement | `identifier "com.local.Recordly" and certificate root = H"b5b4e764405e28dd9d5a814d5241c77b5c591e8e"` |
| Icon | `CFBundleIconFile`/`CFBundleIconName` resolve AppIcon. Compiled ICNS decodes; its 256 px representation was visually inspected and contains the selected cream tile/orange quotation marks. `assetutil --info Assets.car` confirms all ten named AppIcon renditions, from 16 to 1024 px |
| Archive contents | 128 entries, Barkenson.app root, notices present, CRC check passes; targeted scan found no recordings, audio, transcript/summary artefacts or model weights |

The extracted app is at repository-root `build/barkenson-final-icon-extracted/Barkenson.app`; this path is ignored and was not installed or launched. The existing installed Recordly app was not replaced. Live Finder/Dock inspection was attempted through the supported computer-use tool, which returned **Computer Use permissions are not granted**. No OS permission was changed, and no live Finder/Dock success is claimed. Actual upgrade/privacy consent, live recording and another-Mac launch remain pending.

This package is a local integration candidate, not a notarised public release. Subsequent report-only commits do not alter its application source or icon.

## Remaining acceptance and publication

Source readiness and a valid local package do not establish a public release. Before publishing, record actual upgrade/rollback with preserved recordings/settings/models; real microphone/system permission behaviour; capture, playback/import/export, interrupted work and sleep/long-recording checks; downloaded Gatekeeper behaviour and another supported Mac. The [identity matrix](identity-preservation.md) remains the acceptance procedure. A matching designated requirement is evidence for compatibility, not a completed TCC upgrade test.

The selected icon does not approve the full designer concept, site or a new app redesign. Keep the agreed native app styling. Live Finder/Dock inspection requires the built app; no private recordings or model caches should be changed merely to inspect an icon. The author's installed application is not replaced by source integration.

Developer ID/notarisation, own-code/binary licence terms, model-notice inventory and the final GitHub Release asset remain open. No automatic global security bypass or privacy reset is part of integration. Pages remains unpublished by this work until the website is approved and its final links are verified.

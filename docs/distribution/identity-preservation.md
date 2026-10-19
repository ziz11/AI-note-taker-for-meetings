# Barkenson identity preservation and rename plan

Reviewed on 20 October 2026 against source commit `327e976460b363d621a150d4c0d4b085e2cafabe`.

Barkenson is the confirmed public name. The description is **Meeting recorder for Mac.** Public naming and technical identity are separate: retain the existing Recordly identifiers and storage paths for this distribution preparation. No storage migration, inference changes or summary generation are required.

## Evidence boundary

This is a source inspection and an implementation/acceptance plan. The application was not built, launched, installed, renamed or used to access private recordings during this audit. No installed signature, keychain identity, model cache or privacy database was examined or changed. Historical build reports in [project status](../project-status.md) are context, not current-build evidence. Every upgrade, rollback and permission check below remains **pending** until the coordinator records a fresh result against the integrated commit and final archive hash.

Apple sources were checked online on 20 October 2026. Their code-identity rules support the plan; they do not establish the identity or permission behaviour of an uninspected binary.

## Identity inventory and decisions

Paths below are relative to the repository unless they begin with `/` or `~`.

| Concern | Inspected source | Required decision |
|---|---|---|
| Application bundle identifier | `Recordly.xcodeproj/project.pbxproj`: Debug and Release use `com.local.Recordly`; `Recordly/Info.plist` expands `PRODUCT_BUNDLE_IDENTIFIER` | Keep exactly `com.local.Recordly`, including case. Do not invent `com.local.Barkenson`. |
| Displayed name | `Recordly/Info.plist`: `CFBundleName` currently expands `PRODUCT_NAME`; no `CFBundleDisplayName` | Use explicit `Barkenson` display/name values and update owned UI/permission text in British English. Verify Finder, Dock, menus and About in the final app. |
| Bundle/executable/build names | Product and Swift module are `Recordly`; executable expands `EXECUTABLE_NAME`; project, target and scheme are Recordly | Preserve project, scheme, target, module and executable. A packaged outer folder may be `Barkenson.app` while its executable remains `Contents/MacOS/Recordly`; validate the packaged plist/signature and Finder behaviour. |
| Persistent preferences | `ModelPreferencesStore` and `FluidAudioASRModelProvider` default to `UserDefaults.standard` | Keep the bundle domain and every key/value. Do not copy to a new preferences domain or edit its plist directly. |
| Recording root | `Infrastructure/Persistence/AppPaths.swift` constructs `~/Library/Application Support/Recordly/recordings/<UUID>/session.json` | Keep the root and UUID/session layout. Existing recordings need no rename or copy. |
| Local/legacy models | `AppPaths` uses `~/Library/Application Support/Recordly/Models/<kind>/`, `installed-models.json`, `/Users/Shared/RecordlyModels/<kind>/`, `~/models/<kind>/`, and repository `Models/`/`models/` discovery | Preserve all locations, custom model paths and metadata. Source-tree model discovery does not establish availability in a standalone installation. |
| Active SDK models | `AppPaths.fluidAudioSDKModelsDirectory()` resolves `~/Library/Application Support/FluidAudio/Models`; ASR uses SDK repo folder names; diarization can fall back to `OfflineDiarizerModels.defaultModelsDirectory()` | Preserve SDK ownership and resolved folders. Do not move these assets under Barkenson or change the pinned SDK during the rename. Record actual runtime paths in acceptance evidence. |
| Local signing | Debug selects manual `Recordly Local Development`, empty team. `scripts/setup-local-signing.sh` reuses an identity with this name or creates/trusts a self-signed certificate | Retain the existing certificate and private key. A newly generated certificate with the same name is not evidence of the same code identity. Never package or publish the private key. |
| Local standalone signing | `scripts/build-standalone-local.sh` overrides Release to manual local signing, adds notices, re-signs preserving identifier/requirements/entitlements/flags/runtime, verifies then archives | Preserve this reproducible local route; it explicitly is not Developer ID distribution. Changing the archive/outer app label must leave internals consistent. |
| Project Release signing | Release has automatic signing, an empty development team, no explicit Developer ID identity in this configuration | A Developer ID release route is unconfirmed. Do not equate the local script's success with notarised distribution readiness. |
| Sandbox and deployment | Debug/Release have `ENABLE_APP_SANDBOX = NO`; minimum macOS 15.0 | Preserve sandbox/deployment policy. Enabling sandboxing would be a separate migration and entitlement task. |
| Permission callers | `Infrastructure/Capture/AudioCaptureService.swift` calls `AVCaptureDevice.requestAccess(for: .audio)` and uses a screen-capture permission coordinator with `CGPreflightScreenCaptureAccess`/`CGRequestScreenCaptureAccess` | Retain the capture flow. Test microphone and system recording independently from the installed candidate. |

Preferences include `model.selectedProfile`, `model.pendingProfile`, `model.onboardingSeen`, retained `model.selectedASRLanguage`/`model.selectedASRBackend`, `model.selectedDiarizationModelID`, `model.selectedSummarizationModelID`, `model.summarization.llamaExecutablePath`, `model.summarization.contextSize`, `.temperature`, `.topP`, and `fluidAudio.asr.selectedModel`. The existing legacy ASR preference normalisation may update backend/language values on launch; compare against equivalent old-build behaviour, rather than calling this a new rebranding migration. Retained summary preferences must not activate summary inference.

The canonical audio contract remains `audio-manifest.json`, AAC chunks in `audio/microphone/` and `audio/system/`, recovery sidecars, and integer 48 kHz frame offsets. Keep existing transcript/SRT/JSON/summary asset references and legacy CAF/M4A reading intact. `RecordingsRepository` loads asset filenames from session metadata. A blanket Recordly-to-Barkenson replacement risks changing persistence, test imports, script paths, signing identity and diagnostic labels together; do not use one.

## macOS permission and signing constraints

Apple explains that macOS records an application's designated requirement (DR) when authorising microphone access and checks later versions against it. Unsigned code has no DR; ad hoc identity is tied to a particular build. Developer identity and signing identifier matter. Consequently, changing the visible app name while retaining a compatible signature is a reasonable preservation strategy, but **permission retention is a testable expectation, not a completed guarantee**. [Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)

Apple also documents that distribution variants can have different DRs, and that compatible requirements are needed to share access to privacy-protected resources. Keep the bundle/signing identifier and signer continuity; compare the actual old/new DRs. Do not weaken a DR or invent a custom requirement solely to suppress prompts. A move from the existing local certificate to Developer ID may require fresh user consent and must be treated as a separate signing transition. [Apple distribution signing guidance](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)

Microphone identity compatibility does not establish every Screen Recording behaviour on every macOS release. Test both permissions before and after a relaunch on each supported version used for acceptance. The capture source already warns that multiple registered copies with one bundle ID can make the system's quit-and-reopen flow relaunch another copy. Use one active installed copy during upgrade tests and record the launched process path. Do not reset TCC as part of a preservation test, edit its database, grant permissions programmatically or remove quarantine to manufacture a passing result.

Apple distinguishes human-readable bundle names from identifiers; Finder can fall back to the on-disk name when display and bundle names do not match. Package the public release as `Barkenson.app`, with matching display strings, and verify rather than relying on a display-name-only change. [Apple property-list reference](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html)

Apple documents that standard application preferences belong to a bundle-identifier domain. Keeping `com.local.Recordly` avoids a new preference namespace; direct plist editing is not the migration mechanism. [Apple defaults domains](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UserDefaults/AboutPreferenceDomains/AboutPreferenceDomains.html)

For normal external distribution, evaluate Developer ID signing, hardened runtime and notarisation as an explicit release route. A free application and a GitHub Releases ZIP do not demonstrate Gatekeeper acceptance. The local build route remains a separate option whose friction must be stated honestly. [Apple notarisation guidance](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## Safe implementation order

1. Freeze the identity inventory above and record the old installed app's actual version, executable hash, signing identifier, certificate chain, entitlements and DR. Do not infer its signer from the current project settings.
2. Integrate only public naming changes: owned strings, Info.plist display/name and permission descriptions, release labels and website/docs. The coordinator owns integration. Keep app identity, persistence, SDK/provider wiring and inference contracts unchanged.
3. Adapt packaging paths explicitly if the final outer bundle is `Barkenson.app`. Preserve `CFBundleExecutable = Recordly`, Swift module and project/scheme references. Copy licence notices and complete all bundle mutations before final signing; verify and archive the exact signed app.
4. Run isolated fixture tests and a fresh build at the integrated commit. Existing tests such as `AppPathsCompatibilityTests`, model-provider/preferences coverage, capture and recovery tests are useful, but passing unit tests do not demonstrate TCC or installed-data continuity.
5. Perform the controlled upgrade and rollback matrix below before publishing a preservation claim. Use a disposable macOS user or separately backed-up acceptance environment with the real old signed build; do not silently replace the author's active installation.
6. Publish the archive hash, source commit, architecture/minimum macOS, signing/notarisation status and verification limits. Rename the GitHub repository only after the coordinator has checked release, Pages, clone, documentation and automation links against the final repository name. Repository naming does not require changing the local app identity.

## Fresh acceptance matrix

Every row is currently **pending**. Record date, machine/architecture, macOS version, old/new commit or provenance, binary hashes, signing mode, result and evidence location. Use copies of recordings for destructive recovery/reprocessing fixtures. Do not include private audio or signing secrets in public evidence.

| Check | Procedure and acceptance |
|---|---|
| Baseline backup | Quit the old app normally. Preserve the old bundle, export the `com.local.Recordly` preferences domain using supported defaults tools, and back up Recordly application support plus resolved SDK/custom model folders. Inventory recordings by UUID, model selections/paths and file hashes. Keep protected originals outside the test's writable data. |
| Final artefact identity | Inspect the old and final candidate `Info.plist` (`plutil -p`), `codesign --display --verbose=4`, `codesign --display --requirements -`, and `codesign --display --entitlements :-`. Bundle/signing identifier remains `com.local.Recordly`; executable resolves; intended signer/DR/entitlements are recorded. Verify the exact candidate using `codesign --verify --deep --strict`. |
| DR compatibility | Extract each actual DR as a requirement expression using the TN3127 procedure; check the candidate against the old DR and the old bundle against the candidate DR with `codesign --verify -R <requirement-file>`. Both pass for a claimed two-way identity-compatible upgrade/rollback. A failure blocks the permission-preservation claim and requires an explicit signing-transition decision. |
| Packaging | Extract the final ZIP into an empty test folder and repeat signature and executable-hash checks. It contains `Barkenson.app`, notices and required runtime resources. It launches without Xcode or source-tree models. Check Gatekeeper assessment with the intended signing route, and notarisation/stapling evidence if that route is claimed. A successful local launch is not equivalent to a browser-downloaded clean-Mac test. |
| Preferences/models | Replace the old bundle in the controlled installation, retaining one active copy. Launch by its explicit path. Selected Ultra/v3, installed model state, retained custom model paths and existing settings remain available without a new download. Compare the preferences domain, allowing only known old-build normalisation and explicit user actions. |
| Recordings | Session count, UUIDs, titles, notes, favourites, audio/transcript references and speaker names remain readable. Compare original audio/manifest hashes after read-only browsing; loading must not convert/move source audio. Check V2 and legacy fixtures, playback and export. |
| Existing granted permissions | Grant microphone and system recording to the old installed build in the acceptance environment, then quit it and upgrade. Verify both permissions and actual captured tracks before/after candidate relaunch. Record any prompts or OS reminders verbatim. Existing grants must remain usable for a preservation claim; a renewed consent request must be disclosed, not hidden. |
| Denied/new permissions | On separate denied and clean profiles, check that denied access is explained and the existing settings/consent flow works; test mic-only degradation and authorised system capture. Do not treat expected first-run consent as an upgrade regression. |
| Recovery | With disposable V2 and legacy fixtures, verify reopening completed and interrupted sessions after restart; use a controlled termination only in the disposable environment. Existing bounded-window/cached transcript recovery still works. Document the known possible loss of an unfinished active chunk. |
| Disabled summaries | Open old summary artefacts if supported without altering them; attempt the existing summary entry points on a disposable session. No runtime resolution, llama.cpp/MLX invocation, generated template or new summary artefact occurs. |
| Rollback | Quit the candidate, preserve newly created test data separately, and restore the prior bundle without resetting preferences or moving recordings/models. Confirm old and newly created compatible sessions, model selection, playback and permissions. Compare protected pre-upgrade hashes. If candidate writes are incompatible, restore the backed-up test data only after preserving the candidate data; do not claim seamless rollback. |

## Open blockers and limits

- No fresh signed Barkenson artefact or inspected installed baseline is supplied by this audit. Source configuration does not prove which certificate signed a previously distributed bundle.
- Signer choice for friends, Developer ID availability, notarisation and clean-machine Gatekeeper behaviour require a release decision and fresh evidence. Stable local signing is not notarisation.
- Permission preservation across local-to-Developer-ID signing is unproven and may be unavailable without renewed consent. A matching bundle ID alone does not close this blocker.
- Finder/menu branding, launch-copy ambiguity, SDK cache reuse, preference/session continuity and rollback require the controlled acceptance matrix; old reports do not satisfy it.
- No pipeline changes, new features, model moves or storage migration are authorised by this plan. Summary generation stays disabled.

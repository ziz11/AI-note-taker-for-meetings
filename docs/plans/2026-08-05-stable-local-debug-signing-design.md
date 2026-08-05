# Stable Local Debug Signing Design

**Date:** 2026-08-05

## Problem

Recordly Debug builds launched with Xcode Run are currently ad-hoc signed. Their
designated requirement is tied to the build's code-directory hash, so rebuilding
changes the identity macOS records in Transparency, Consent, and Control (TCC).
Microphone and Screen Recording permissions therefore appear to belong to an old
build and have to be removed and granted again.

The development workflow must keep working without a paid Apple Developer account.

## Chosen Approach

Use one persistent, locally trusted, self-signed code-signing certificate for every
Recordly Debug build:

- certificate name: `Recordly Local Development`;
- keychain: the current user's login keychain;
- app bundle identifier: `com.local.Recordly`;
- Xcode Debug signing style: manual;
- Apple development team and provisioning profile: unset;
- Release signing: unchanged.

The certificate and its private key are local machine state and must never be
committed. A repository script creates them once and is safe to run repeatedly.
Subsequent Xcode Run builds use the same certificate-backed designated requirement,
so macOS can associate them with the same TCC identity even though their CDHash
changes.

## Setup Workflow

`scripts/setup-local-signing.sh` will:

1. Locate the user's login keychain.
2. Return successfully when a valid code-signing identity named
   `Recordly Local Development` already exists.
3. Generate a self-signed code-signing certificate and private key in a temporary
   directory when the identity is absent.
4. Import the PKCS#12 identity into the login keychain with `/usr/bin/codesign`
   access and add a user-level Code Signing trust rule.
5. Verify that `security find-identity -p codesigning` sees the identity.
6. Delete all temporary key, certificate, password, and PKCS#12 files.

The script must not reset TCC automatically. Permission resets are destructive to
the current grants and are needed only once during migration, so the README will
provide explicit commands for the developer to run intentionally.

## Xcode Configuration

Only the Recordly application target's Debug configuration changes:

- `CODE_SIGN_STYLE = Manual`
- `CODE_SIGN_IDENTITY = Recordly Local Development`
- `DEVELOPMENT_TEAM = ""`
- `PROVISIONING_PROFILE_SPECIFIER = ""`
- `PRODUCT_BUNDLE_IDENTIFIER = com.local.Recordly`

The test bundle may keep Xcode's local ad-hoc signature. The host app is signed last,
so the final Debug `.app` retains the persistent application identity.

If the certificate has not been installed, Xcode should fail clearly with a missing
signing-certificate message rather than silently falling back to ad-hoc signing.

## One-Time Permission Migration

After installing the certificate and rebuilding, the developer quits all Recordly
instances and resets the old ad-hoc records once:

```bash
tccutil reset Microphone com.local.Recordly
tccutil reset ScreenCapture com.local.Recordly
```

The next Xcode Run requests Microphone access through the existing app flow. Screen
Recording is requested through Recordly's explicit **Grant Access** action, after
which macOS may require one application restart. Later rebuilds must not require
removing the app from System Settings or granting either permission again.

## Verification

Repository tests will cover the setup script's idempotent decision-making without
touching the real login keychain, and a static configuration test will prevent the
Debug target from reverting to automatic/ad-hoc signing.

Manual verification on the developer machine:

1. Run the setup script and confirm the identity is listed by `security`.
2. Build through Xcode Run.
3. Inspect the built app with `codesign -dvvv -r-` and confirm the authority is
   `Recordly Local Development` and the designated requirement is not CDHash-only.
4. Grant Microphone and Screen Recording once.
5. Change a Swift source file, rebuild with Xcode Run, and confirm both grants remain.

## Security and Scope

The certificate is trusted only on the local Mac and is intended only for Debug
builds. It is not suitable for distribution, Gatekeeper, notarization, or the Mac
App Store. The change does not alter capture behavior, sandboxing, persisted audio,
or release packaging.

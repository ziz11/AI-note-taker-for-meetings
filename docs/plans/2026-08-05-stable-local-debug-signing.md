# Stable Local Debug Signing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make Xcode Run sign Recordly Debug builds with one persistent local self-signed identity so macOS permission grants survive rebuilds without a paid Apple Developer account.

**Architecture:** A one-time shell setup script creates and trusts `Recordly Local Development` in the login keychain, while the Recordly application target's Debug configuration requires that identity explicitly. Shell regression tests use a fake `security` executable and parsed Xcode project data so they never modify the developer's real keychain.

**Tech Stack:** zsh, OpenSSL, macOS `security`/`codesign`, Xcode project build settings, `plutil`, Ruby JSON parsing.

---

### Task 1: Add failing local-signing regression tests

**Files:**
- Create: `scripts/test-local-signing.sh`

**Step 1: Write the failing test**

Create an executable zsh test that:

- converts `Recordly.xcodeproj/project.pbxproj` to JSON with `plutil`;
- locates the `Recordly` native target and its Debug configuration;
- asserts `CODE_SIGN_STYLE=Manual`, `CODE_SIGN_IDENTITY=Recordly Local Development`, an empty team/profile, and `com.local.Recordly`;
- creates a temporary fake `security` executable whose state lives under a temporary directory;
- runs `scripts/setup-local-signing.sh` twice with `RECORDLY_SECURITY_BIN` and `RECORDLY_KEYCHAIN_PATH` overrides;
- asserts that the first run imports/trusts one identity and the second run performs no additional import;
- verifies the setup output reports creation first and an existing identity second;
- cleans temporary files on exit.

**Step 2: Run the test to verify it fails**

Run:

```bash
chmod +x scripts/test-local-signing.sh
./scripts/test-local-signing.sh
```

Expected: FAIL because `scripts/setup-local-signing.sh` does not exist and the Debug target still uses automatic signing.

**Step 3: Commit the RED test**

```bash
git add scripts/test-local-signing.sh
git commit -m "test: specify stable local debug signing"
```

### Task 2: Create the idempotent certificate setup script

**Files:**
- Create: `scripts/setup-local-signing.sh`

**Step 1: Implement the minimal setup workflow**

Implement a zsh script with these externally visible contracts:

```zsh
IDENTITY_NAME="Recordly Local Development"
SECURITY_BIN="${RECORDLY_SECURITY_BIN:-/usr/bin/security}"
OPENSSL_BIN="${RECORDLY_OPENSSL_BIN:-$(command -v openssl)}"
```

The script must:

1. use `RECORDLY_KEYCHAIN_PATH` when supplied, otherwise parse
   `security default-keychain -d user`;
2. exit successfully without mutation if `find-identity -v -p codesigning`
   already contains the quoted identity name;
3. create a temporary OpenSSL config with `digitalSignature` key usage and
   `codeSigning` extended key usage;
4. generate an RSA-2048 self-signed certificate valid for ten years;
5. export a password-protected PKCS#12;
6. import it with access for `/usr/bin/codesign` and `/usr/bin/security`;
7. add a user Code Signing trust rule with `security add-trusted-cert`;
8. verify the identity is now valid or fail with an actionable message;
9. remove the temporary private key and PKCS#12 via `trap`.

**Step 2: Run the focused test to verify GREEN**

Run:

```bash
chmod +x scripts/setup-local-signing.sh
./scripts/test-local-signing.sh
```

Expected: the setup-script checks pass; the test still fails only on the Xcode Debug configuration assertions.

**Step 3: Commit the setup script**

```bash
git add scripts/setup-local-signing.sh
git commit -m "build: add local signing identity setup"
```

### Task 3: Require the persistent identity for Xcode Debug builds

**Files:**
- Modify: `Recordly.xcodeproj/project.pbxproj`

**Step 1: Update only the Recordly target Debug configuration**

Change its build settings to:

```text
CODE_SIGN_IDENTITY = "Recordly Local Development";
CODE_SIGN_STYLE = Manual;
DEVELOPMENT_TEAM = "";
PROVISIONING_PROFILE_SPECIFIER = "";
PRODUCT_BUNDLE_IDENTIFIER = com.local.Recordly;
```

Do not change the Release configuration or the tests target.

**Step 2: Run the focused test to verify GREEN**

Run:

```bash
./scripts/test-local-signing.sh
```

Expected: `PASS`.

**Step 3: Commit the Xcode configuration**

```bash
git add Recordly.xcodeproj/project.pbxproj
git commit -m "build: use persistent identity for debug"
```

### Task 4: Document setup, migration, and verification

**Files:**
- Modify: `README.md`

**Step 1: Add the developer workflow**

Document these commands:

```bash
./scripts/setup-local-signing.sh
security find-identity -v -p codesigning | grep "Recordly Local Development"
tccutil reset Microphone com.local.Recordly
tccutil reset ScreenCapture com.local.Recordly
```

Explain that the two `tccutil` commands are a one-time migration from previous
ad-hoc builds, Screen Recording may require one app restart after the first grant,
and the self-signed identity is local-development-only.

Add built-app verification:

```bash
codesign -dvvv -r- "/path/from/Xcode/Recordly.app"
```

**Step 2: Run the focused regression test**

Run:

```bash
./scripts/test-local-signing.sh
```

Expected: `PASS`.

**Step 3: Commit the documentation**

```bash
git add README.md
git commit -m "docs: explain persistent local signing"
```

### Task 5: Verify the complete change

**Files:**
- Test: `scripts/test-local-signing.sh`
- Test: `RecordlyTests/`

**Step 1: Run shell regression tests**

```bash
./scripts/test-local-signing.sh
./scripts/test-build-unsigned-app.sh
./scripts/test-build-distribution-app.sh
```

Expected: all print `PASS`.

**Step 2: Run the full Xcode suite**

Before installing the real certificate, verify compilation with an explicit ad-hoc
override so repository CI does not depend on machine-local keychain state:

```bash
xcodebuild test -project Recordly.xcodeproj -scheme Recordly -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual
```

Expected: 243 tests execute, 1 is skipped, 0 fail, and `** TEST SUCCEEDED **` appears.

**Step 3: Inspect the diff and status**

```bash
git diff develop...HEAD --check
git status --short --branch
```

Expected: no whitespace errors and a clean feature branch.

**Step 4: Install and manually verify on the developer Mac**

Run `./scripts/setup-local-signing.sh`, then build twice with Xcode Run and inspect
both built apps with `codesign -dvvv -r-`. Confirm the authority and designated
requirement remain certificate-backed and the previously granted permissions remain
enabled after the second build.

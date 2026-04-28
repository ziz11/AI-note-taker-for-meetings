# Distribution Packaging Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a repeatable script that archives, signs, and packages `Recordly.app` for outside-App-Store distribution.

**Architecture:** Keep distribution logic in repo-local tooling only. The app target and persistence behavior remain unchanged; packaging is handled by a shell script plus an export-options plist, with lightweight shell-based validation coverage and README usage docs.

**Tech Stack:** Xcode, `xcodebuild`, `codesign`, `security`, POSIX shell

---

### Task 1: Add packaging script validation coverage

**Files:**
- Create: `scripts/test-build-distribution-app.sh`

**Step 1: Write the failing test**

Create a shell test that:

- runs `scripts/build-distribution-app.sh` without `TEAM_ID`
- expects a non-zero exit code
- expects stderr to mention `TEAM_ID`

Add a second case that omits `SIGNING_IDENTITY` and expects the same pattern.

**Step 2: Run test to verify it fails**

Run: `zsh scripts/test-build-distribution-app.sh`
Expected: FAIL because the packaging script does not exist yet.

**Step 3: Commit**

```bash
git add scripts/test-build-distribution-app.sh
git commit -m "test: add packaging script validation coverage"
```

### Task 2: Implement the distribution packaging script

**Files:**
- Create: `scripts/build-distribution-app.sh`
- Create: `scripts/export-options-developer-id.plist`

**Step 1: Write minimal implementation**

Implement a shell script that:

- requires `TEAM_ID` and `SIGNING_IDENTITY`
- accepts optional `PROJECT_PATH`, `SCHEME`, `CONFIGURATION`, `ARCHIVE_PATH`, `EXPORT_PATH`, and `OUTPUT_DIR`
- verifies the signing identity exists via `security find-identity`
- archives the app with `xcodebuild archive`
- exports the archive using the checked-in export options plist
- zips the exported `Recordly.app` into `OUTPUT_DIR/Recordly.zip`

The export options plist should target Developer ID distribution.

**Step 2: Run test to verify it passes**

Run: `zsh scripts/test-build-distribution-app.sh`
Expected: PASS

**Step 3: Commit**

```bash
git add scripts/build-distribution-app.sh scripts/export-options-developer-id.plist
git commit -m "feat: add distribution packaging script"
```

### Task 3: Document the packaging flow

**Files:**
- Modify: `README.md`

**Step 1: Add usage docs**

Add a short `Distribution build` section with:

- required Apple certificate: `Developer ID Application`
- required env vars: `TEAM_ID`, `SIGNING_IDENTITY`
- example command invoking `./scripts/build-distribution-app.sh`
- expected outputs: signed `.app` and `.zip`

**Step 2: Verify docs reference the actual script paths**

Run: `rg -n "build-distribution-app|Developer ID Application|TEAM_ID|SIGNING_IDENTITY" README.md`
Expected: matches in the new section.

**Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add distribution packaging instructions"
```

### Task 4: Final verification

**Files:**
- Verify: `scripts/build-distribution-app.sh`
- Verify: `scripts/test-build-distribution-app.sh`
- Verify: `scripts/export-options-developer-id.plist`
- Verify: `README.md`

**Step 1: Run validation tests**

Run: `zsh scripts/test-build-distribution-app.sh`
Expected: PASS

**Step 2: Run script help/validation path**

Run: `zsh scripts/build-distribution-app.sh`
Expected: non-zero exit with a clear missing-`TEAM_ID` message.

**Step 3: Review diff**

Run:

```bash
git diff -- docs/plans/2026-03-12-distribution-packaging-design.md scripts/build-distribution-app.sh scripts/test-build-distribution-app.sh scripts/export-options-developer-id.plist README.md
```

Expected: only packaging tooling and docs changes.

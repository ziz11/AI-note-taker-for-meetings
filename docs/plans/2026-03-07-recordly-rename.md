# Recordly Rename Implementation Plan

> **Status:** Completed. The app was renamed from CallRecorderPro to Recordly. File paths below reflect the current project structure. Note: `PRODUCT_CONTEXT.md` was consolidated into `README.md`, and `MODEL_INTEGRATION.md` was moved to `docs/model-integration.md`.

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rename the shipped macOS app to `Recordly` while keeping all existing recordings and model storage under the legacy `Recordly` filesystem locations (originally named `CallRecorderPro`, now updated to `Recordly`).

**Architecture:** Treat the rename as a branding and build-configuration change, not a persistence migration. Keep the Swift module and storage constants stable unless the code proves they must change, and update only the Xcode product metadata, scheme wiring, permission strings, and documentation that users see. Add a compatibility test first so future edits cannot silently rename the storage roots.

**Tech Stack:** Swift, SwiftUI, Xcode project configuration, XCTest, `xcodebuild`, `rg`

---

### Task 1: Lock legacy storage compatibility

**Files:**
- Create: `RecordlyTests/AppPathsCompatibilityTests.swift`
- Verify only: `Recordly/Infrastructure/Persistence/AppPaths.swift`

**Step 1: Write the compatibility test**

Create an XCTest case that asserts:

```swift
XCTAssertEqual(AppPaths.appSupportFolderName, "Recordly")
XCTAssertEqual(AppPaths.sharedModelsFolder, "/Users/Shared/RecordlyModels")
```

Import the production module with:

```swift
@testable import Recordly
```

**Step 2: Run the targeted test to establish the baseline**

Run:

```bash
xcodebuild test -scheme Recordly -destination 'platform=macOS' -only-testing:RecordlyTests/AppPathsCompatibilityTests
```

Expected: `PASS`

**Step 3: Commit**

```bash
git add RecordlyTests/AppPathsCompatibilityTests.swift
git commit -m "test: lock legacy Recordly storage paths"
```

### Task 2: Rename the built product and bundle wiring to Recordly

**Files:**
- Modify: `Recordly.xcodeproj/project.pbxproj`
- Modify or rename: `Recordly.xcodeproj/xcshareddata/xcschemes/Recordly.xcscheme`
- Modify: `Recordly/Info.plist`

**Step 1: Snapshot the current branded wiring**

Run:

```bash
rg -n 'PRODUCT_NAME =|PRODUCT_BUNDLE_IDENTIFIER =|TEST_HOST =|BuildableName =|BlueprintName =|Recordly.app|Recordly captures|Recordly records' \
  Recordly.xcodeproj/project.pbxproj \
  Recordly.xcodeproj/xcshareddata/xcschemes \
  Recordly/Info.plist
```

Expected: matches showing the current `Recordly` product metadata.

**Step 2: Update the app product metadata**

Make these edits:

- Set the app target `PRODUCT_NAME` to `Recordly`.
- Change the app bundle identifier to `com.local.Recordly`.
- Update `TEST_HOST` and any executable path references to `Recordly.app/Contents/MacOS/Recordly`.
- Update shared scheme buildable names to `Recordly.app`.
- Update `NSAudioCaptureUsageDescription` and `NSMicrophoneUsageDescription` to say `Recordly`.

Do not change:

- `AppPaths.appSupportFolderName`
- `AppPaths.sharedModelsFolder`

**Step 3: Verify the wiring is consistent**

Run:

```bash
rg -n 'CallRecorderPro.app|CallRecorderPro captures|CallRecorderPro records|com.local.CallRecorderPro' \
  Recordly.xcodeproj/project.pbxproj \
  Recordly.xcodeproj/xcshareddata/xcschemes \
  Recordly/Info.plist
```

Expected: no matches.

**Step 4: Build the renamed app**

```bash
xcodebuild build -scheme Recordly -destination 'platform=macOS'
```

Expected: `BUILD SUCCEEDED`

**Step 5: Commit**

```bash
git add Recordly.xcodeproj/project.pbxproj Recordly.xcodeproj/xcshareddata/xcschemes Recordly/Info.plist
git commit -m "feat: rename app product to Recordly"
```

### Task 3: Update user-facing docs and copy without renaming storage paths

**Files:**
- Modify: `README.md`
- Modify: `PRODUCT_CONTEXT.md`
- Modify: `ARCHITECTURE.md`
- Modify: `MODEL_INTEGRATION.md`
- Modify: `Recordly/Resources/Models/README.md`

**Step 1: Update branding references**

Replace user-facing product references from `CallRecorderPro` to `Recordly` in narrative text, headings, and setup guidance.

Keep storage path literals as they are now (already updated to `Recordly`):

- `~/Library/Application Support/Recordly/...`
- `/Users/Shared/RecordlyModels/...`

**Step 2: Verify only allowed references remain**

Run:

```bash
rg -n 'CallRecorderPro' README.md PRODUCT_CONTEXT.md ARCHITECTURE.md MODEL_INTEGRATION.md Recordly/Resources/Models/README.md
```

Expected: no matches.

**Step 3: Commit**

```bash
git add README.md PRODUCT_CONTEXT.md ARCHITECTURE.md MODEL_INTEGRATION.md Recordly/Resources/Models/README.md
git commit -m "docs: rename product references to Recordly"
```

### Task 4: Run final verification before completion

**Files:**
- Verify: `Recordly.xcodeproj/project.pbxproj`
- Verify: `Recordly/Info.plist`
- Verify: `Recordly/Infrastructure/Persistence/AppPaths.swift`
- Verify: `RecordlyTests/AppPathsCompatibilityTests.swift`

**Step 1: Run the compatibility test suite**

```bash
xcodebuild test -scheme Recordly -destination 'platform=macOS' -only-testing:RecordlyTests/AppPathsCompatibilityTests
```

Expected: `PASS`

**Step 2: Run the full test target**

```bash
xcodebuild test -scheme Recordly -destination 'platform=macOS'
```

Expected: `TEST SUCCEEDED`

**Step 3: Confirm final rename boundaries**

Run:

```bash
rg -n 'CallRecorderPro' \
  Recordly/Infrastructure/Persistence/AppPaths.swift \
  Recordly/Resources/model-registry.json \
  README.md \
  PRODUCT_CONTEXT.md \
  MODEL_INTEGRATION.md \
  Recordly/Resources/Models/README.md \
  Recordly.xcodeproj/project.pbxproj \
  Recordly.xcodeproj/xcshareddata/xcschemes
```

Expected:

- No stale `CallRecorderPro` references remain.

**Step 4: Review the diff**

Run:

```bash
git status --short
git diff -- Recordly.xcodeproj/project.pbxproj Recordly/Info.plist Recordly/Infrastructure/Persistence/AppPaths.swift RecordlyTests/AppPathsCompatibilityTests.swift README.md PRODUCT_CONTEXT.md ARCHITECTURE.md MODEL_INTEGRATION.md Recordly/Resources/Models/README.md Recordly.xcodeproj/xcshareddata/xcschemes
```

Expected: only the planned rename and compatibility-lock changes are present.

**Step 5: Final commit**

```bash
git add Recordly.xcodeproj/project.pbxproj Recordly/Info.plist Recordly/Infrastructure/Persistence/AppPaths.swift RecordlyTests/AppPathsCompatibilityTests.swift README.md PRODUCT_CONTEXT.md ARCHITECTURE.md MODEL_INTEGRATION.md Recordly/Resources/Models/README.md Recordly.xcodeproj/xcshareddata/xcschemes
git commit -m "feat: ship Recordly branding with legacy storage compatibility"
```

**Step 6: Final verification note**

Before declaring success, use `@verification-before-completion` and record the exact build/test commands that passed.

# Recordly Rename Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rename the shipped macOS app to `Recordly` while keeping all existing recordings and model storage under the legacy `CallRecorderPro` filesystem locations.

**Architecture:** Treat the rename as a branding and build-configuration change, not a persistence migration. Keep the Swift module and storage constants stable unless the code proves they must change, and update only the Xcode product metadata, scheme wiring, permission strings, and documentation that users see. Add a compatibility test first so future edits cannot silently rename the storage roots.

**Tech Stack:** Swift, SwiftUI, Xcode project configuration, XCTest, `xcodebuild`, `rg`

---

### Task 1: Lock legacy storage compatibility

**Files:**
- Create: `CallRecorderProTests/AppPathsCompatibilityTests.swift`
- Verify only: `CallRecorderPro/Infrastructure/Persistence/AppPaths.swift`

**Step 1: Write the compatibility test**

Create an XCTest case that asserts:

```swift
XCTAssertEqual(AppPaths.appSupportFolderName, "CallRecorderPro")
XCTAssertEqual(AppPaths.sharedModelsFolder, "/Users/Shared/CallRecorderProModels")
```

Import the production module with:

```swift
@testable import CallRecorderPro
```

**Step 2: Run the targeted test to establish the baseline**

Run:

```bash
xcodebuild test -scheme CallRecorderPro -destination 'platform=macOS' -only-testing:CallRecorderProTests/AppPathsCompatibilityTests
```

Expected: `PASS`

**Step 3: Commit**

```bash
git add CallRecorderProTests/AppPathsCompatibilityTests.swift
git commit -m "test: lock legacy Recordly storage paths"
```

### Task 2: Rename the built product and bundle wiring to Recordly

**Files:**
- Modify: `CallRecorderPro.xcodeproj/project.pbxproj`
- Modify or rename: `CallRecorderPro.xcodeproj/xcshareddata/xcschemes/CallRecorderPro.xcscheme`
- Inspect and align if still used: `CallRecorderPro.xcodeproj/xcshareddata/xcschemes/xcshareddata/xcschemes/CallRecorderPro.xcscheme`
- Modify: `CallRecorderPro/Info.plist`

**Step 1: Snapshot the current branded wiring**

Run:

```bash
rg -n 'PRODUCT_NAME =|PRODUCT_BUNDLE_IDENTIFIER =|TEST_HOST =|BuildableName =|BlueprintName =|CallRecorderPro.app|CallRecorderPro captures|CallRecorderPro records' \
  CallRecorderPro.xcodeproj/project.pbxproj \
  CallRecorderPro.xcodeproj/xcshareddata/xcschemes \
  CallRecorderPro/Info.plist
```

Expected: matches showing the current `CallRecorderPro` product metadata.

**Step 2: Update the app product metadata**

Make these edits:

- Set the app target `PRODUCT_NAME` to `Recordly`.
- Change the app bundle identifier from `com.local.CallRecorderPro` to `com.local.Recordly`.
- Update the test target bundle identifier only if you are renaming the test bundle branding as part of the same pass.
- Update `TEST_HOST` and any executable path references from `CallRecorderPro.app/Contents/MacOS/CallRecorderPro` to `Recordly.app/Contents/MacOS/Recordly`.
- Update shared scheme buildable names from `CallRecorderPro.app` to `Recordly.app`.
- Rename the shared scheme file to `Recordly.xcscheme` if Xcode still resolves it cleanly; keep `BlueprintName` on `CallRecorderPro` if preserving the Swift module/target name avoids churn.
- Update `NSAudioCaptureUsageDescription` and `NSMicrophoneUsageDescription` to say `Recordly`.

Do not change:

- `@testable import CallRecorderPro`
- `AppPaths.appSupportFolderName`
- `AppPaths.sharedModelsFolder`

**Step 3: Verify the wiring is consistent**

Run:

```bash
rg -n 'CallRecorderPro.app|CallRecorderPro captures|CallRecorderPro records|com.local.CallRecorderPro' \
  CallRecorderPro.xcodeproj/project.pbxproj \
  CallRecorderPro.xcodeproj/xcshareddata/xcschemes \
  CallRecorderPro/Info.plist
```

Expected: no matches, unless a deliberate legacy compatibility reference is documented inline.

**Step 4: Build the renamed app**

If the shared scheme was renamed, run:

```bash
xcodebuild build -scheme Recordly -destination 'platform=macOS'
```

If the scheme name was intentionally left alone, run:

```bash
xcodebuild build -scheme CallRecorderPro -destination 'platform=macOS'
```

Expected: `BUILD SUCCEEDED`

**Step 5: Commit**

```bash
git add CallRecorderPro.xcodeproj/project.pbxproj CallRecorderPro.xcodeproj/xcshareddata/xcschemes CallRecorderPro/Info.plist
git commit -m "feat: rename app product to Recordly"
```

### Task 3: Update user-facing docs and copy without renaming storage paths

**Files:**
- Modify: `README.md`
- Modify: `PRODUCT_CONTEXT.md`
- Modify: `ARCHITECTURE.md`
- Modify: `MODEL_INTEGRATION.md`
- Modify: `CallRecorderPro/Resources/Models/README.md`

**Step 1: Update branding references**

Replace user-facing product references from `CallRecorderPro` to `Recordly` in narrative text, headings, and setup guidance.

Keep legacy path literals unchanged:

- `~/Library/Application Support/CallRecorderPro/...`
- `/Users/Shared/CallRecorderProModels/...`

Where helpful, add a short note that `Recordly` still uses the legacy storage folder names for compatibility.

**Step 2: Verify only allowed legacy references remain**

Run:

```bash
rg -n 'CallRecorderPro' README.md PRODUCT_CONTEXT.md ARCHITECTURE.md MODEL_INTEGRATION.md CallRecorderPro/Resources/Models/README.md
```

Expected: matches only inside filesystem paths, compatibility notes, or code/module identifiers that were intentionally preserved.

**Step 3: Commit**

```bash
git add README.md PRODUCT_CONTEXT.md ARCHITECTURE.md MODEL_INTEGRATION.md CallRecorderPro/Resources/Models/README.md
git commit -m "docs: rename product references to Recordly"
```

### Task 4: Run final verification before completion

**Files:**
- Verify: `CallRecorderPro.xcodeproj/project.pbxproj`
- Verify: `CallRecorderPro/Info.plist`
- Verify: `CallRecorderPro/Infrastructure/Persistence/AppPaths.swift`
- Verify: `CallRecorderProTests/AppPathsCompatibilityTests.swift`

**Step 1: Run the compatibility test suite**

Run:

```bash
xcodebuild test -scheme CallRecorderPro -destination 'platform=macOS' -only-testing:CallRecorderProTests/AppPathsCompatibilityTests
```

If the scheme name was renamed, use:

```bash
xcodebuild test -scheme Recordly -destination 'platform=macOS' -only-testing:CallRecorderProTests/AppPathsCompatibilityTests
```

Expected: `PASS`

**Step 2: Run the full test target**

Run:

```bash
xcodebuild test -scheme CallRecorderPro -destination 'platform=macOS'
```

If the scheme name was renamed, use:

```bash
xcodebuild test -scheme Recordly -destination 'platform=macOS'
```

Expected: `TEST SUCCEEDED`

**Step 3: Confirm final rename boundaries**

Run:

```bash
rg -n 'CallRecorderPro' \
  CallRecorderPro/Infrastructure/Persistence/AppPaths.swift \
  CallRecorderPro/Resources/model-registry.json \
  README.md \
  PRODUCT_CONTEXT.md \
  MODEL_INTEGRATION.md \
  CallRecorderPro/Resources/Models/README.md \
  CallRecorderPro.xcodeproj/project.pbxproj \
  CallRecorderPro.xcodeproj/xcshareddata/xcschemes
```

Expected:

- Legacy path references remain in `AppPaths` and storage documentation.
- No stale `CallRecorderPro.app` product-name references remain in build wiring.

**Step 4: Review the diff**

Run:

```bash
git status --short
git diff -- CallRecorderPro.xcodeproj/project.pbxproj CallRecorderPro/Info.plist CallRecorderPro/Infrastructure/Persistence/AppPaths.swift CallRecorderProTests/AppPathsCompatibilityTests.swift README.md PRODUCT_CONTEXT.md ARCHITECTURE.md MODEL_INTEGRATION.md CallRecorderPro/Resources/Models/README.md CallRecorderPro.xcodeproj/xcshareddata/xcschemes
```

Expected: only the planned rename and compatibility-lock changes are present.

**Step 5: Final commit**

```bash
git add CallRecorderPro.xcodeproj/project.pbxproj CallRecorderPro/Info.plist CallRecorderPro/Infrastructure/Persistence/AppPaths.swift CallRecorderProTests/AppPathsCompatibilityTests.swift README.md PRODUCT_CONTEXT.md ARCHITECTURE.md MODEL_INTEGRATION.md CallRecorderPro/Resources/Models/README.md CallRecorderPro.xcodeproj/xcshareddata/xcschemes
git commit -m "feat: ship Recordly branding with legacy storage compatibility"
```

**Step 6: Final verification note**

Before declaring success, use `@verification-before-completion` and record the exact build/test commands that passed.

# Recordly App Icon Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace Recordly's current app icon with the approved minimal graphite-and-gold cube and produce a verified Release bundle.

**Architecture:** Add a deterministic Swift/AppKit icon generator that draws one 1024 px master from flat vector geometry, then derives every existing macOS asset size with high-quality resizing. Keep the current asset filenames and catalog mapping so no Xcode project changes are required.

**Tech Stack:** Swift, AppKit, `sips`, Xcode asset catalogs, `xcodebuild`

---

### Task 1: Add a reproducible cube-icon generator

**Files:**

- Create: `scripts/generate-app-icon.swift`
- Create: `scripts/test-app-icon-generator.sh`

**Step 1: Write the failing generator smoke test**

Create a shell test that:

- creates a temporary directory;
- runs `swift scripts/generate-app-icon.swift <temporary-directory>`;
- asserts that `icon_512x512@2x.png` exists;
- uses `sips -g pixelWidth -g pixelHeight` to assert `1024 × 1024`;
- asserts all ten filenames from the existing `Contents.json` exist.

**Step 2: Run the test and verify failure**

Run:

```bash
zsh scripts/test-app-icon-generator.sh
```

Expected: FAIL because `scripts/generate-app-icon.swift` does not exist.

**Step 3: Implement the generator**

Use `NSBitmapImageRep` and `NSBezierPath` to render:

- an opaque `#202424` canvas;
- a centered isometric cube occupying approximately 43% of the canvas width;
- top face `#E1BD8D`;
- left face `#D4AB78`;
- right face `#C69662`;
- thin `#202424` seams between faces;
- no text, gradient, shadow, glow, border, or recording indicator.

Render a 1024 px master first. Generate the remaining files from that master with
`sips --resampleHeightWidth`, preserving these existing names and dimensions:

```text
icon_16x16.png          16
icon_16x16@2x.png       32
icon_32x32.png          32
icon_32x32@2x.png       64
icon_128x128.png       128
icon_128x128@2x.png    256
icon_256x256.png       256
icon_256x256@2x.png    512
icon_512x512.png       512
icon_512x512@2x.png   1024
```

The generator must accept the destination `AppIcon.appiconset` directory as its
only argument and overwrite icon PNGs only inside that explicit directory.

**Step 4: Run the smoke test**

Run:

```bash
zsh scripts/test-app-icon-generator.sh
```

Expected: PASS with all ten PNG dimensions validated.

**Step 5: Commit**

```bash
git add scripts/generate-app-icon.swift scripts/test-app-icon-generator.sh
git commit -m "build: add reproducible app icon generator"
```

### Task 2: Replace and visually verify the AppIcon assets

**Files:**

- Modify: `Recordly/Resources/Assets.xcassets/AppIcon.appiconset/icon_16x16.png`
- Modify: `Recordly/Resources/Assets.xcassets/AppIcon.appiconset/icon_16x16@2x.png`
- Modify: `Recordly/Resources/Assets.xcassets/AppIcon.appiconset/icon_32x32.png`
- Modify: `Recordly/Resources/Assets.xcassets/AppIcon.appiconset/icon_32x32@2x.png`
- Modify: `Recordly/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128.png`
- Modify: `Recordly/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png`
- Modify: `Recordly/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png`
- Modify: `Recordly/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png`
- Modify: `Recordly/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512.png`
- Modify: `Recordly/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png`

**Step 1: Generate the approved assets**

Run:

```bash
swift scripts/generate-app-icon.swift \
  Recordly/Resources/Assets.xcassets/AppIcon.appiconset
```

Expected: ten PNG files are regenerated without changing `Contents.json`.

**Step 2: Validate dimensions**

Run:

```bash
zsh scripts/test-app-icon-generator.sh
sips -g pixelWidth -g pixelHeight \
  Recordly/Resources/Assets.xcassets/AppIcon.appiconset/*.png
```

Expected: all dimensions match the catalog declarations.

**Step 3: Inspect representative sizes**

Inspect:

- `icon_512x512@2x.png`
- `icon_128x128.png`
- `icon_32x32.png`
- `icon_16x16.png`

Expected: centered cube, even negative space, distinct faces, no artifacts or
unexpected white background.

**Step 4: Commit**

```bash
git add Recordly/Resources/Assets.xcassets/AppIcon.appiconset
git commit -m "feat: replace app icon with minimal cube"
```

### Task 3: Build and stage the test application

**Files:**

- Generated, ignored output: `build/DerivedData/Build/Products/Release/Recordly.app`

**Step 1: Build Release**

Run:

```bash
xcodebuild build \
  -project Recordly.xcodeproj \
  -scheme Recordly \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData
```

Expected: `** BUILD SUCCEEDED **` with no missing AppIcon asset warnings.

**Step 2: Verify the bundle**

Run:

```bash
codesign --verify --deep --strict --verbose=2 \
  build/DerivedData/Build/Products/Release/Recordly.app
```

Expected: bundle is valid on disk and satisfies its designated requirement.

**Step 3: Copy to the normal project build directory**

Copy the verified bundle to:

```text
/Users/nacnac/Documents/dev/vibecode/Recordly/build/Recordly.app
```

Use `ditto` only after confirming the exact source and destination paths.

**Step 4: Inspect in Finder and Dock**

Reveal the copied app in Finder and launch it once.

Expected: the graphite cube icon appears correctly in Finder, the Dock, and the
application switcher.

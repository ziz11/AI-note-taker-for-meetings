# Recordly Rename Design

> **Status:** Completed. The rename from CallRecorderPro to Recordly has been fully applied, including storage paths.

**Date:** 2026-03-07

**Goal:** Rename the shipped app from `CallRecorderPro` to `Recordly`, updating all branding, project wiring, and storage paths.

## Scope

This design followed a full rename strategy:

- Renamed user-facing branding to `Recordly`.
- Updated project wiring that depends on the built app product name.
- Updated persistence paths to `Recordly`:
  - `~/Library/Application Support/Recordly`
  - `/Users/Shared/RecordlyModels`

## Approaches Considered

### 1. Branding and project wiring rename with legacy storage retained

Rename the app product, bundle-facing strings, scheme/target references, and documentation branding while keeping storage constants on the old name.

**Pros**
- Meets the product rename requirement.
- Avoids data migration risk.
- Keeps the code change bounded.

**Cons**
- Leaves some internal identifiers on the legacy name.

### 2. Branding-only rename

Change only the visible app name and strings presented to users.

**Pros**
- Lowest risk.
- Smallest edit surface.

**Cons**
- Leaves project wiring inconsistent.
- Repo continues to look half-renamed.

### 3. Full internal rename with compatibility fallback

Rename branding, project wiring, storage paths, and internal module names, then add fallback logic to load old locations.

**Pros**
- Cleanest end state.

**Cons**
- Highest risk.
- Requires migration or compatibility code.
- Expands the validation surface for little user-facing benefit.

## Chosen Design

Full rename was applied. All branding, project wiring, storage paths, and module names now use `Recordly`.

## Rename Boundary

### Changed

- Xcode target and product settings that determine the built app name.
- Scheme references and test host paths tied to the app binary name.
- Bundle identifier strings (now `com.local.Recordly`).
- `Info.plist` permission strings and other user-facing copy.
- Documentation and product references that describe the app.
- Storage paths updated to `Recordly`.
- Source directory renamed from `CallRecorderPro/` to `Recordly/`.

### Current storage paths

- `AppPaths.appSupportFolderName = "Recordly"`
- `AppPaths.sharedModelsFolder = "/Users/Shared/RecordlyModels"`
- Recordings: `~/Library/Application Support/Recordly/recordings`
- Installed models: `/Users/Shared/RecordlyModels` and `~/Library/Application Support/Recordly/Models`

## Verification

- Build the app target successfully.
- Build and run the test target successfully.
- Confirm the built product is `Recordly.app`.
- Confirm permission usage strings show `Recordly`.
- Confirm the app uses `~/Library/Application Support/Recordly` and `/Users/Shared/RecordlyModels`.
- Smoke-test launch and recordings list loading.

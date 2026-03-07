# Recordly Rename Design

**Date:** 2026-03-07

**Goal:** Rename the shipped app from `CallRecorderPro` to `Recordly` while preserving compatibility with existing local recordings and model storage.

## Scope

This design follows a hybrid rename strategy:

- Rename user-facing branding to `Recordly`.
- Update project wiring that depends on the built app product name.
- Keep existing persistence paths unchanged:
  - `~/Library/Application Support/CallRecorderPro`
  - `/Users/Shared/CallRecorderProModels`

The intent is to ship `Recordly.app` without forcing a migration of recordings, model installs, or other local state.

## Approaches Considered

### 1. Branding and project wiring rename with legacy storage retained

Rename the app product, bundle-facing strings, scheme/target references, and documentation branding while keeping storage constants on `CallRecorderPro`.

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

Use approach 1.

Rename the visible product to `Recordly` and update project wiring that must stay aligned with the built app name, while preserving legacy persistence and model storage paths.

## Rename Boundary

### Change

- Xcode target and product settings that determine the built app name.
- Scheme references and test host paths tied to the app binary name.
- Bundle identifier strings if they are currently branded as `CallRecorderPro`.
- `Info.plist` permission strings and other user-facing copy.
- Documentation and product references that describe the app.

### Keep unchanged

- `AppPaths.appSupportFolderName = "CallRecorderPro"`
- `AppPaths.sharedModelsFolder = "/Users/Shared/CallRecorderProModels"`
- Model registry labels and other persistence references that point at the legacy storage locations.
- Swift module identity if it can remain stable without affecting the user-facing rename.

## Compatibility

- Existing recordings remain under `~/Library/Application Support/CallRecorderPro/recordings`.
- Existing installed models remain under `/Users/Shared/CallRecorderProModels` and `~/Library/Application Support/CallRecorderPro/Models`.
- Tests should continue to import the existing Swift module if the module name is not part of the user-facing rename.

## Risks

- Renaming the target/product incompletely can break scheme references or the test host executable path.
- Renaming storage paths accidentally would strand existing local data.
- Renaming the Swift module unnecessarily would increase code churn and test fallout without improving the shipped product.

## Verification

- Build the app target successfully.
- Build and run the test target successfully.
- Confirm the built product is `Recordly.app`.
- Confirm permission usage strings show `Recordly`.
- Confirm the app still uses `~/Library/Application Support/CallRecorderPro` and `/Users/Shared/CallRecorderProModels`.
- Smoke-test launch and recordings list loading against existing local data.

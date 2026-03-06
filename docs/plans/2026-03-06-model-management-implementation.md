# Model Management Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add managed on-device model installation for ASR and diarization with stable paths, profile-based requirements, checksum validation, and UI controls.

**Architecture:** Introduce a new `Infrastructure/Models` layer with registry+storage+downloader+manager. Wire model resolution into transcription through DI, and expose profile/install controls in settings UI state owned by `RecordingsStore`.

**Tech Stack:** Swift, Foundation, SwiftUI, URLSession, FileManager, CryptoKit.

---

### Task 1: Infrastructure model types and JSON registry loader
- Create model domain types.
- Add bundle-backed `model-registry.json` decoding with safe fallback to empty list on parse/read failures.
- Keep format compatible with future remote JSON.

### Task 2: Persistent model storage
- Add `AppPaths` support for `~/Library/Application Support/CallRecorderPro/Models`.
- Implement deterministic install directories by type/id.
- Add helpers for canonical model URL, file checks, installed metadata file, removal, and disk size.

### Task 3: Download/install pipeline
- Implement downloader with temp files, SHA-256 verification, atomic move, cleanup on failures.
- Add progress callback support.

### Task 4: High-level model manager and profile mapping
- Implement `ModelManager` API: list/state/install/remove/resolve/ensure required by profile.
- Enforce idempotency using file existence + checksum + installed metadata entry.

### Task 5: Integrate with transcription pipeline and DI
- Add model requirements resolver into workflow before transcription.
- Pass resolved ASR model URL (and optional diarization URL) into transcription engine config.

### Task 6: Add model management UI
- Add model profile selection and model install status/actions.
- Display state, installed size, and download/remove actions.

### Task 7: Verification
- Build after each stage.
- Manual checks: first install, re-install idempotency, remove/re-install, checksum mismatch/partial download handling.

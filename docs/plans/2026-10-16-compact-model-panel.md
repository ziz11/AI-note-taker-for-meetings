# Compact model panel

**Goal:** Follow the user's corrected design direction: a roughly 400×260-point macOS settings panel, with no decorative model icons or catalog table.

**Design:** One small Models heading/close action, two compact transcription rows with radio selection and download/remove actions, then one speaker-separation status row. Keep the expanded custom-file list in a bounded 100-point scroll area. Use system-sized type and small standard buttons. Keep model sizes in help, remove runtime/features columns, badges, descriptive prose and disabled-feature advertising. Additional discovered local files stay in a collapsed disclosure. Downloads and errors expand the content only as needed.

**Scope:** Presentation only. Preserve provider-backed download/use separation, unavailable-selection and deletion guards, retry/errors/progress, busy state and requested diarization focus. Audio, ASR and saved recordings unchanged.

**Steps:**
1. Replace ModelSettingsView with the small panel; change native visual harness to 400-point width and intrinsic height in all states. Increment app build to3.
2. Run existing model/ASR checks and inspect light/dark/loading/error fixtures. Obtain read-only review.
3. Build/verify standalone and update delivery records; integrate into develop/master. Install with rollback and relaunch only when no recording is active.

**References:** User's Spokenly screenshots and requested minimalism; Apple HIG Settings and Layout: https://developer.apple.com/design/human-interface-guidelines/settings and https://developer.apple.com/design/human-interface-guidelines/layout . Do not describe the visual as certified or exhaustively HIG-audited.

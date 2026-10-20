# Barkenson GitHub Pages publication — 20 October 2026

**Published website:** https://ziz11.github.io/Barkenson-Meeting-recorder-for-Mac/

The coordinator merged [PR #23](https://github.com/ziz11/Barkenson-Meeting-recorder-for-Mac/pull/23) as `e7c8e7fcef6275b7dfcd5bfb13913c3620b2492d`, containing the owner's approved concise page and real app screenshot. The prior site remains backed up on `codex/site-backup-2026-10-20` at `e0d67ba35fba00870d9eb81646059bbfff0baa3b`.

The page retains the cream/orange/book style and hero composition, presents four benefits, three steps and three FAQs, and links to the existing `v0.1.0-preview.1` ZIP. Detailed setup is on [the installation page](https://ziz11.github.io/Barkenson-Meeting-recorder-for-Mac/installation.html). ChatGPT Sites is not the public host or a runtime dependency.

## Verification

- Static two-page checker and whitespace checks passed; independent review found no integration blockers.
- Desktop at 1280 px and mobile/tablet at 320/375/768 px: no horizontal overflow. The app image preserves its aspect ratio, and links to the full-size original. FAQ disclosure, guide navigation and visible keyboard focus were checked in the browser.
- The real owner-supplied screenshot is unchanged: 2704×1756, 432,745 bytes, SHA-256 `60717e1a57900e973b79b716d4922676807860167d34eab11cc6e86309e51e99`. Its visible transcript is the harmless test phrase supplied by the owner, not a synthetic marketing mock-up.
- The first main-branch publication failed at `actions/configure-pages` because Pages was disabled. The owner enabled GitHub Actions as the Pages source; the coordinator reran failed jobs in [workflow run 39404521703](https://github.com/ziz11/Barkenson-Meeting-recorder-for-Mac/actions/runs/39404521703). Validate, build and deploy then completed successfully.
- Fresh public HTTPS GETs returned **200** for the landing page, installation guide, CSS, app PNG, quotation-mark SVG and favicon. The published app PNG's SHA-256 exactly matches the owner's source above. The live HTML contains the correct release ZIP URL and no ChatGPT Sites URL.

This closes website publication. Older dated notes saying that the website was deferred or that a screenshot was missing are historical snapshots superseded by this record. No application code, inference, models, storage, release binary or user recordings were changed during website publication. The primary checkout's separate uncommitted project-status changes were preserved.

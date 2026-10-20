# Barkenson concise website implementation plan

**Goal:** Implement the owner's approved concise landing page in the existing static GitHub Pages source.

**Architecture:** Keep buildless HTML/CSS and relative assets; reuse existing hero composition and approved quotation-mark vector. Move detailed setup to installation.html. GitHub Pages is the canonical public host; no app/runtime changes or new Sites project.

**Tech stack:** HTML, CSS, Python standard-library checks and GitHub Pages Actions.

1. Back up the exact existing site to codex/site-backup-2026-10-20 and verify its tree matches the original.
2. Edit site/index.html and site/style.css: supplied copy, four benefits, three steps, three questions, published ZIP links, approved mark. Add site/installation.html with setup and signing details; no fake screenshot or placeholder explanation. Reuse only truthful artwork.
3. Update site/check.py to validate both pages, local anchors/assets, project subpath, accessibility basics, canonical/OG URLs and exact published download URL. Run external HTTP checks and inspect desktop/mobile browser rendering if browser access is available.
4. Update site/README.md with backup, exact Pages destination and remaining screenshot requirement. Review the focused diff, update existing PR23, and show the actual HTML preview. Keep PR draft and deployment pending the real screenshot/final review; do not silently publish an incomplete page.

# Barkenson website

Buildless HTML/CSS for the repository's **GitHub Pages** site:

**https://ziz11.github.io/Barkenson-Meeting-recorder-for-Mac/**

`index.html` is the concise British English landing page. `installation.html` contains setup, signing and upgrade details. All assets are local; there is no analytics, external font request, runtime API call or third-party script. ChatGPT Sites is not the canonical host and its old preview is not updated by this work.

## Backup and approved direction

The full previous site is preserved on GitHub in branch [`codex/site-backup-2026-10-20`](https://github.com/ziz11/Barkenson-Meeting-recorder-for-Mac/tree/codex/site-backup-2026-10-20/site), at commit `e0d67ba35fba00870d9eb81646059bbfff0baa3b`. Its source tree was preserved before edits.

The owner supplied the concise structure/copy and approved retaining cream paper, orange quotation marks, ink text, book typography and the first-screen composition. The landing page has four benefits, three steps, three FAQs and two direct download buttons. Internal paths, model names and signing detail stay off the landing page. The linked installation guide includes release-specific limitations.

The approved editable quotation symbol and app icon are reused from the designer's exports, not redrawn. The original decorative waveform is retained in the hero and is not presented as an app screenshot.

## Screenshot acceptance gap

A large **real recording-and-transcript screenshot** is still required below the hero. None has been supplied to the coordinator. Existing native test renders contain synthetic fixture data and are not substituted for an installed-app screenshot. The landing page has no fake screenshot, broken image or public missing-screenshot message.

Before marking the PR ready, add a privacy-reviewed real screenshot from the owner. Store an optimised copy under `assets/`, with explicit image dimensions, useful alt text and a responsive full-width figure below the hero. Check the transcript's legibility on desktop/mobile. Do not publish private meeting content, speaker names or identifiers without the owner's approval.

## Published download

Both download buttons point to the existing `v0.1.0-preview.1` asset:

https://github.com/ziz11/Barkenson-Meeting-recorder-for-Mac/releases/download/v0.1.0-preview.1/Barkenson-0.1.0-build5-macOS.zip

ZIP: 24,078,882 bytes. SHA-256: `1ee36de64e35f7750bfd621ae338347b75d6cb2582f60e03e04e76eaf71c5124`.

It is a local-certificate preview, not notarised Developer ID distribution. That detail belongs in the installation guide and release notes. The earlier pending-download assertions were replaced because the real release exists.

## Verification

Run `python3 site/check.py` from the repository root. It checks both pages, British English metadata, landmark/heading basics, image dimensions/alt attributes, anchors, assets, no external scripts, exact release links and canonical/OG metadata.

Serve `site/` at the project subpath `/Barkenson-Meeting-recorder-for-Mac/`, rather than testing only `/`. Relative CSS, image, navigation and guide links must remain inside that subpath. The guide's canonical is the same Pages base plus `installation.html`.

## Publication

The existing PR #23 remains a draft while the real screenshot and final review are pending. The coordinator owns integration. The workflow validates PRs without deploying; build/deploy jobs run only from `main`. For the first deployment, repository Settings → Pages must use **GitHub Actions**. After approval/merge, verify the returned deployment URL and live nested assets before claiming the GitHub Pages site is published.

## Coordinator verification — 20 October 2026

- `python3 site/check.py` and `git diff --check`: PASS.
- Local HTTP at the exact project subpath: index, installation guide, CSS, quotation mark, favicon, grain and social card all returned 200.
- Browser inspected at 1280 px desktop and 320/375/768 px widths: no horizontal overflow. Desktop/mobile screenshots remain in ignored repository-root `build/barkenson-site-preview/`.
- FAQ disclosure opens its answer; the installation link navigates to the guide; keyboard focus has the intended visible 3 px outline.
- Repository, Releases, Feedback and exact ZIP links returned HTTP 200 with HEAD requests.
- Main-page text reduced from 772 to 233 whitespace-separated words, excluding markup. No inference, Swift, project or packaging files changed.
- Canonical and Open Graph point to the GitHub Pages destination above. These checks do not assert a live GitHub Pages deployment or a real installed-app screenshot.

# Barkenson website

Buildless HTML and CSS for GitHub Pages. No package installation, analytics, remote fonts, runtime API requests or third-party scripts.

## Publication

Merge the website PR into `main`. In repository Settings → Pages, select **GitHub Actions** as the build source. The `Publish website to GitHub Pages` workflow validates the site and publishes only the `site/` directory. PR runs validate without publishing. Manual publication is restricted to `main`.

Expected project URL: https://ziz11.github.io/AI-note-taker-for-meetings/

The workflow supplies an artifact directly, so no Jekyll build is needed. All local links use relative paths and work under the repository subpath. If the repository or domain changes, update the canonical, Open Graph URL and absolute social image URL in `index.html`.

## Local check

Run `python3 site/check.py` from the repository root. Serve the repository locally and visit `/site/` to check nested paths. Use any standard static HTTP server. There is no build step.

## Release handoff

GitHub Releases returned no published releases on 20 October 2026. Historical records under `releases/` are not download assets. The download button is deliberately disabled and the hero links to the preparation status.

Before enabling downloads:

1. Obtain the final name and visual identity from the coordinator and designer. Barkenson is a working brand, not final approval. Neither collaborator was available in this task context.
2. Publish and verify the actual standalone asset, architecture, minimum macOS version, signing/notarisation state and installation instructions. Update the pending copy and FAQ, then replace the disabled button with an anchor to that exact existing asset. Update the download assertion in `check.py` to validate the selected URL.
3. Confirm model download size, disk space and any memory requirements from that release. Avoid speculative figures.
4. Capture real screenshots from the approved build, remove private meeting content, add descriptive alt text and dimensions, then replace the screenshot note. The waveform is decorative artwork, not a screenshot. Do not use model-picker design mock-ups as release screenshots.
5. Recheck links, keyboard focus, disclosure controls and layouts at narrow and wide widths.

Current capability copy is grounded in `README.md`, `AGENTS.md`, the Xcode deployment target and the recording/export implementation. macOS 15+, Apple Silicon inference verified on M3 Pro, Intel inference unconfirmed. Summary generation is disabled. No claim of perfect speaker matching or validated minimum RAM.

The application remains named Recordly in permission prompts and storage. Keep that distinction in installation copy until the actual bundle is renamed.

`assets/social.png` is a locally drawn typographic social card. `grain.svg` and `favicon.svg` are local decorative assets. No external asset requests are made.

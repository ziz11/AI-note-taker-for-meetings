# Barkenson icon handoff — The Imprint

20 October 2026. Branch: `codex/barkenson-brand`.

## Decision and scope

The owner wrote “У второго варианта мне иконка понравилась” in the Barkenson chat. This package develops that preference: burnt-orange closing quotation marks on a cream tile, taken from concept 02, The Imprint. It does not approve the full concept 02 website or app. The coordinator's distribution plan confirms **Barkenson** and **Meeting recorder for Mac.**

The icon is redrawn as editable vector geometry, rather than cropped from the generated concept board. It retains two slanted-top quotation marks and a cream rounded tile. Grain and baked shadows are omitted to keep the small icon clear and let macOS composite the asset. A 96-unit transparent inset on the 1024-unit canvas provides optical space around the tile. The two tails stay separate at small sizes.

## Files

All artwork is under [`assets/barkenson-imprint/`](assets/barkenson-imprint/):

- `barkenson-icon.svg` — editable full app icon, no font dependencies.
- `barkenson-mark.svg` — editable transparent quotation symbol for site use.
- `barkenson-icon-1024.png` — full-resolution transparent PNG.
- `Barkenson.iconset/` — ten named macOS representations: 16, 32, 128, 256 and 512 points at 1× and 2×. Pixel sizes cover 16, 32, 64, 128, 256, 512 and 1024.
- `Barkenson.icns` — compiled with macOS `iconutil`.
- `icon-scale-study.png` — actual-size 16, 24, 32, 48, 64, 128 and 256 px previews on illustrative light/dark surfaces; not a Dock screenshot.
- `SHA256SUMS` — source and deliverable checksums.

Icon colours: quotation marks `#C94C25`; cream tile from `#FFF5E5` to `#FFF0D8`. These are icon-specific values, not an approved global UI token set. Keep original geometry and aspect ratio; do not substitute font quotation glyphs, stretch, add outlines, grain or extra shadows. For the standalone mark, leave at least one stem-width of clear space. Review at 16 CSS px or larger; use the supplied icon rather than a busy wordmark at tiny sizes.

## Reproduction

Requires Node.js, `sharp` and macOS `iconutil`. With `sharp` installed in Node's module search path:

```sh
node docs/brand/tools/export-imprint.cjs
```

In this desktop environment, the bundled runtime was used:

```sh
NODE_PATH=/Users/nacnac/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules /Users/nacnac/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node docs/brand/tools/export-imprint.cjs
```

The sandbox's `iconutil` rejected the valid iconset; the same command outside the sandbox succeeded. `--skip-icns` regenerates PNGs and the scale study while retaining an already compiled ICNS. It still requires that ICNS to exist for checksum generation. No network service or image-generation model is needed to reproduce these vectors and exports.

## Checks and integration

- Checked all ten PNG dimensions, RGBA format and transparent outer inset.
- Compiled ICNS and decoded it back to an iconset; compared decoded PNG pixels with the original exports.
- Inspected the scale study on light and dark surfaces. At 16 px the separated quotation marks remain visible; detail is stronger at 32 px and above. A real Finder/Dock check on the integrated bundle is still required; this package does not install or launch an app.
- No Swift, AppIcon catalogue, Xcode, signing, release or Pages configuration changes.

The macOS agent should map these representations into the app's existing AppIcon catalogue in its own branch, then inspect the compiled bundle in Finder/Dock and permission contexts. The website agent should reuse the SVG symbol or icon on the existing website foundation (draft PR #23); this package does not create another site. Website/app direction, global tokens, typography and mobile layouts remain open. Only the coordinator integrates these materials.

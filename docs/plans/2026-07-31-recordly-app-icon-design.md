# Recordly App Icon Design

## Goal

Replace the current glassy recording-button icon with a quiet, minimal macOS app
icon based on the user's cube reference.

## Visual direction

- Use a matte graphite background.
- Center one small geometric cube with generous surrounding space.
- Render the cube as three flat warm beige/gold faces.
- Separate the faces with thin dark seams.
- Keep the composition and cube-to-canvas proportion close to the supplied
  reference.
- Do not add text, initials, a recording dot, a waveform, gradients, glass,
  glow, highlights, or cast shadows.

## Asset construction

Create one square 1024 × 1024 master image. Use it as the source for every
required macOS `AppIcon.appiconset` size:

- 16 × 16 and 32 × 32
- 32 × 32 and 64 × 64 Retina
- 128 × 128 and 256 × 256 Retina
- 256 × 256 and 512 × 512 Retina
- 512 × 512 and 1024 × 1024 Retina

Downsample from the approved master with high-quality resampling so the cube
stays centered and its seams remain legible at small sizes. Keep the existing
asset filenames and `Contents.json` mapping.

## Validation

- Inspect the 1024 px master and representative 16, 32, 128, and 512 px outputs.
- Build the Release app and verify the icon appears in Finder and the Dock.
- Confirm all required asset slots compile without warnings about missing icon
  files.

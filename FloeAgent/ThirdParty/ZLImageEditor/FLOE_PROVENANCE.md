# ZLImageEditor in Floe

- Upstream: https://github.com/longitachi/ZLImageEditor
- Version: 3.0.0
- Commit: 6a0f56fb631a8b3f3e70c08895a3e71d921fd4cd
- License: MIT, retained in LICENSE and the app resources.
- Vendored Package.swift and Sources; no network or external package dependencies.
- upstream-sha256.json records files before Floe patches.

## Local patches

Raise the vendored package deployment target to iOS 26, matching Floe. The host
minimum does not override a Swift package target; keeping upstream iOS 10 caused
modern system colors and SF Symbols in Floe chrome to fail SDK compatibility builds.

Remove automatic JPEG recompression after editing. Floe writes and verifies PNG
copies, preserving alpha and avoiding an undocumented lossy encode before export.
The original crop, drawing, text, mosaic, filter and adjustment renderers are retained.

Add accessible tool names (English and Simplified/Traditional Chinese, English fallback
for other languages) and stable tool identifiers.

Replace stock editor chrome with Floe's adaptive native surfaces, SF Symbols,
labelled six-tool strip, 44-point actions and persistent controls outside the
image viewport. Add original comparison and host-owned save/dismissal so saving
returns directly to the canvas, with errors retained for retry.

## Integration boundaries

The host supplies a validated local image and explicitly saves a new asset. Image
stickers are disabled until a host sticker picker exists. Edit state can be reused
while the editor presentation remains open; exported PNG files are flattened.
Layered edit-state restoration across app restarts is not claimed.

# Floe image workbench — interaction and visual contract

This surface inherits Floe's native iOS visual system. It is an editing task,
not a separate library demo or a settings form. The user rejected the initial
stock UI and intermediate preview/save page.

## Flow

Canvas image → editor → Done (save a copy) → canvas with a derived asset.
Cancellation returns without creating an asset. Save failure keeps the editor
and current work available, with an explicit retry. The original file is retained.

## Composition

- Native adaptive system surfaces and SF Symbols; blue identifies actions/selection.
- One compact top row: close, undo/redo, original comparison, Done. Done is a normal-sized text action, without a large filled block. Original comparison fits the full source separately and leaves edit geometry untouched.
- Image viewport remains above the tool and parameter areas; controls do not cover its fitted bounds.
- Six labelled, visible tools: drawing, crop, text, mosaic, filters, adjustment.
- Tool parameters occupy the area immediately above those tools. Crop and text
  entry remain focused native editing steps, returning to the same image.
- Minimum 44-point primary controls. Selected tools have both color and a visible
  selection background. Labels have real accessibility names and stable identifiers.
- Existing small-image or portrait content is not artificially enlarged to fill
  unrelated screen space. Test screenshots are labelled synthetic fixtures.

## Evidence boundary

The first backend checks passed (real crop/Chinese pixels, orientation, PNG and
invalid input). The original UI round passed cancellation but failed tool lookup.
The redesigned surface requires fresh interaction tests and light/dark screenshots.
Full App canvas navigation, large-device layout and real-device memory acceptance
remain separate gates.

Validation is paused at the user's request until the next feature batch. The latest toolbar revision is unverified.

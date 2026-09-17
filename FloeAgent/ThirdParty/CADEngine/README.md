# Local CAD editing engine (qualification in progress)

Floe-owned MPL-2.0 WebAssembly binding for `acadrust` **0.5.5** (MPL-2.0),
upstream https://github.com/hakanaktt/acadrust. Crates.io archive SHA-256:
`6298485f7afd00af7880f285f01ab387143a1fbb20c42f9048830c95b19dda5d`.

The native document is retained through editing. DWG is written by the native
DWG writer; a DXF projection is used only for rendering. Initial edits cover
lines, circles and text, numeric moves, delete, atomic pencil strokes
(`addStroke`, see below), and eight undo/redo snapshots.
Locked layers are respected. Read diagnostics block editing. Saving reparses
the actual same-format output and checks the version, entities, references and
layers; errors return no replacement bytes. This is a compatibility guard,
not proof that arbitrary third-party DWG content is preserved.

## Atomic pencil strokes (`addStroke`)

`CadSession::edit` accepts one additional typed operation:

```json
{"operation":"addStroke","points":[[0,0,0],[10,0,0],[10,10,0]],
 "color":1,"lineWeight":25}
```

- **Atomic**: all points, the ACI color and the line weight are validated
  before any entity is created. A failure (out-of-bounds point, too few/many
  points, locked layer, unsupported color/width, entity cap) leaves the
  document and the undo/redo history untouched. A successful stroke is applied
  in one document mutation and commits exactly one undo snapshot for the whole
  stroke; `undo`/`redo` move every segment together. There is no batch/nested
  operation, so one request cannot amplify work.
- **Bounds**: `2..=256` points, each coordinate finite with `abs(value) <= 1e12`;
  `points - 1` LINE entities are created and the `MAX_ENTITIES` cap is checked
  up front. Stroke points are unitless drawing/world coordinates `[x, y, z]`
  (Z preserved).
- **Layer**: segments go on `FLOE_ANNOTATION` (created on demand). If that
  layer already exists and is locked, the whole stroke is rejected. Annotation
  geometry is separate from drawing entities so it can be hidden/removed
  without touching the original content.
- **Color/width**: only values that are actually saved are accepted. `color` is
  an ACI index `1..=255`; omit it to inherit the layer color. `lineWeight` is
  in 1/100 mm and restricted to the canonical widths that acadrust round-trips
  through the DWG 5-bit table index; unsupported widths are rejected rather
  than silently rewritten. No free-form width or RGB true color is advertised.
- **Metadata**: `inspect()` returns a versioned `capabilities.addStroke` object
  (`FloeAgent/ThirdParty/CADEngine/src/lib.rs`, `capabilities()`); the CAD UI
  must gate its controls on those exact fields rather than assume more.

## Round-trip gate: narrow DXF reference normalization

`verify()` compares the entities and auxiliary data represented by this
engine. Two reference fields are compared by resolved table name instead of
raw handle because the pinned
acadrust 0.5.5 writer provably cannot round-trip the in-memory value
(`src/lib.rs`, `normalize_auxiliary`):

- `MultiLeaderStyle.line_type_handle`: the constructor default is `None`, and
  the DXF writer substitutes the ByLayer linetype handle (code 340), so a
  re-read document legitimately holds `Some(ByLayer)`. `None` therefore
  compares as the resolved name "ByLayer".
- `TableStyle` row `text_style_handle`: the writer persists only the text
  style name (code 7) and the reader never restores a handle, while the
  synthesized standard style stores `Some(Standard)`. The handle therefore
  compares as the row's persisted `text_style_name`.

Both sides resolve handles through their own document's tables, so a custom
linetype/text style is still compared by exact name, and an unresolvable
handle stays verbatim so a dangling reference still fails the gate. This is
what allows no-op saves of drawings that omit an `OBJECTS` section (they keep
`initialize_defaults()`-synthesized standard objects) without blanket-stripping
objects. Regression tests cover the no-OBJECTS no-op save, annotation strokes
on such drawings, preservation of non-default custom styles/objects/layouts,
and rejection of genuinely missing objects.

Run `cargo test --locked` for native qualification. The dedicated Linux workflow
also compiles WASM with a 384 MiB linear-memory maximum and emits web bindings.
The initial workflow preserves its resolved lock for review and commit before
shipping assets. No runtime code or font may be loaded from a CDN. Bindings
must run inside a disposable, timed Web Worker. Native saving must use the
original file SHA and preserve a recoverable draft on conflicts.

This crate is connected through the bundled worker and scoped native save/review bridge; full-App qualification is pending. Neither successful compilation
nor same-library round-trip tests establish AutoCAD compatibility. External
fixtures, browser interactions, binary conflict protection and full-App checks
are required before documenting editable formats or uploading a release.

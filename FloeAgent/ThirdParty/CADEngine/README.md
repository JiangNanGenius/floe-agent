# Local CAD editing engine (qualification in progress)

Floe-owned MPL-2.0 WebAssembly binding for `acadrust` **0.5.5** (MPL-2.0),
upstream https://github.com/hakanaktt/acadrust. Crates.io archive SHA-256:
`6298485f7afd00af7880f285f01ab387143a1fbb20c42f9048830c95b19dda5d`.

The native document is retained through editing. DWG is written by the native
DWG writer; a DXF projection is used only for rendering. Initial edits cover
lines, circles and text, numeric moves, delete, and eight undo/redo snapshots.
Locked layers are respected. Read diagnostics block editing. Saving reparses
the actual same-format output and checks the version, entities, references and
layers; errors return no replacement bytes. This is a compatibility guard,
not proof that arbitrary third-party DWG content is preserved.

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

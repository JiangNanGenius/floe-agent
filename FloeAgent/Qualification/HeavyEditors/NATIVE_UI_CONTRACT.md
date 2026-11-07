# Native editor presentation

The native UI direction follows the user's 2026-11-08 request. SwiftUI owns
tool menus, parameter forms, lists, inspectors, result tables, file actions,
playback controls and feature navigation. WebKit retains fixed computation and
format libraries plus map/terrain and score engraving canvases. Font outlines
and spacing interactions preferentially use SwiftUI Canvas/Path; actual browser
FontFace proofing may remain a rendering surface.

`HeavyEditorView` composes the native `outline`, `canvasToolbar`, `inspector`,
optional `canvasContent` and `bottomBar` slots supplied by each public domain
EditorView. Wide layouts expose side panels; compact layouts use native sheets.
Production hosts must compose the domain EditorView rather than relying on the
generic drawing surface alone. The qualification App does this explicitly.

Product grouping follows the user's latest decision: score is a workspace inside
the existing music editor; font design belongs under Settings → Font manager.
Neither becomes a separate Space create card. GIS retains its spatial workspace.
The independent host demonstrates Music editor → Score and Settings → Font
manager → Font editing, preserving the parent route on close. It does not
implement or qualify the production DAW or global font store.

Production controllers bind the actual parent `music(UUID)` or
`fontLibrary(UUID)` owner and its existing service hooks. Rich MusicXML remains
an original; an explicit MIDI transfer must not silently discard notation.
Font drafts retain their imported source. Compiled font installation returns
through DeviceFontStore; a matching PostScript name alone is not proof of a
same-name replacement. Mainline owns those App service connections.

The controller publishes `presentation` and a small `commandCatalog`. A domain
sets `engine.configuration.nativeSnapshot` to a bounded JSON projection of its
current selection, list page and inspector data. It excludes original binary
files, full history, raster bands and complete font glyph libraries. Native
selection/mode commands are hidden, typed, read/sideEffecting `*.ui.*` entries;
document mutations retain existing edit/import commands and commit paths.

`runCommand` starts service-owned execution. `showCommand` resolves the selected
command's dynamic schema into a native Form, using `formDescription(id,args)`
for dependent options. Forms retain the original revision; stale writes reject.
`requestImport` uses the native security-scoped picker. Results and exports use
native views and the existing managed-file hook. No additional edit approval,
model-authored script, environment selector or arbitrary host-file reader is
introduced.

Every completed execution refreshes the presentation. Canvas selection and
render events send coalesced `presentationChanged` notifications; additional
domain UI changes can call `notifyPresentation()`. Read/UI/export commands no
longer copy the full project state into their response. Mutation responses still
carry the payload needed for revisioned durable commits. Binary exports remain
in the canonical artifact channel and return managed receipts to callers.

The native host enables `nativeChrome` before loading the original. The common
HTML chrome is hidden and each domain removes its duplicate HTML controls;
browser-only qualification retains its original fallback interface. HTML
`showAction`/`showResult` requests are redirected to native presentation while
in this mode. Fixed bundled WASM bytes, strict CSP, original license choices,
JSON-value transport and ownership hooks remain authoritative.

Per-domain DTO and control details are documented under each module's
`Integration` directory. Initial WebKit workbench evidence remains historical.
The [native qualification record](Evidence/20261108-native/results.json) captures
macOS and generic iOS Simulator object compilation, real native editing and
parent-route return checks. The production music session and font-management
connections remain a separate App integration batch under the mainline owner.

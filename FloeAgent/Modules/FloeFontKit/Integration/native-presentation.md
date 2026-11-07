# Native font workbench contract

The App presents this workbench only from Settings' existing `FontManagementView`
and returns there on close. It must not create a standalone font-editor route in
Space, Notes or Creative. The host owns a persistent `.fontLibrary(...)` scope,
the editable project, an immutable input copy and the association to
`DeviceFontStore` records. Saving/exporting a project does not install a font.
Installation or replacement returns through the same font manager; concrete
store API limits and the required replacement boundary are in [README.md](README.md).

`FontEditorView(controller:onClose:)` supplies all five optional
`HeavyEditorView` slots. `FontNativePanels.swift` owns SwiftUI controls and the
character, outline, spacing, feature-source and variation surfaces. The retained
WebKit surface is visible only in `proof`, where the actual compiled FontFace
performs OpenType shaping. A host must keep the engine WebView alive when covered.

`engine.configuration.nativeSnapshot(e)` returns a value DTO through
`controller.presentation`; no original font bytes, history or ownership metadata
are included. Paths are in font units with positive Y upwards. SwiftUI flips Y
only when projecting onto the screen. Coordinates have already passed the same
finite-number model validation used by document editing.

| Field | Shape / bound |
| --- | --- |
| `kind`, `revision` | `font`, acknowledged document revision |
| `ui` | mode, search, page, tool, curveType, snap, text, size, direction, language, vertical, multisize, previewLocation, previewFeatures |
| `info` | Current master's whitelisted font information and horizontal / vertical metrics |
| `masterID`, `masters`, `masterTotal` | Current ID; default plus at most 127 source summaries, retaining the active master; total |
| `axes`, `axisTotal` | At most 32 `{tag,name,min,default,max,mapping}` summaries; total |
| `instances`, `instanceTotal` | At most 128 `{id,name,location}` summaries; total |
| `glyphList` | `{items,total,filtered,page,pageSize:48}`. Search matches glyph name, character and U+ hexadecimal value. `items` have id/name/unicodes/advance and optional thumbnail commands/bounds. Thumbnails have a shared 14,000 source-point budget and a 2,000-point per-item ceiling. |
| `glyph` | Current id/name/unicodes, advance/advanceHeight/verticalOrigin, bounds, commands, componentCommands, direct contours, anchors, components, guidelines. `null` for an incomplete empty master. |
| `selectedPoints` | Direct editable point IDs only |
| `spacing` | At most 40 characters in metrics mode: `{name,previous,x,kern,advance,commands,bounds}`. Includes class-kerning fallback from the active master. |
| `features` | Editable OpenType feature source |
| `kerning` | First 240 pairs and 100 group summaries, with full totals. Complete pair/group editing remains available through the native parameter forms. |
| `compatibility` | Count and first 100 issues; full `variation.validate` remains available |
| `preview` | FontFace readiness and presence of an exportable imported original, without bytes |

`commands` / `componentCommands` are arrays of `{op,...}`:

* `M`, `L`: `x,y`.
* `Q`: `x1,y1,x,y`.
* `C`: `x1,y1,x2,y2,x,y`.
* `Z`: close the current subpath.

Components are recursively transformed and flattened. Quadratic implied nodes,
including all-off-curve closed contours, are expanded by the same point-pen
segment algorithm as the existing editor. Direct node IDs remain unchanged.
Native live dragging carries adjacent handles and preserves smooth tangents;
the final complete set of changed coordinates is submitted once with
`point.move(...,follow:false)`. Native pen input, rectangles and ellipses use
`outline.addContour` and `outline.shape`. Spacing origin-line dragging uses the
existing active-master `kerning.pair`. Undo/save remain the shared controller's.

All temporary UI commands have `access:read`, `sideEffecting:true`, `hidden:true`:

| Command | Arguments |
| --- | --- |
| `font.ui.mode` | `mode`: overview / outline / metrics / features / variations / proof |
| `font.ui.search` | `query` string, at most 256 UTF-16 units; resets page |
| `font.ui.page` | Nonnegative integer `page` |
| `font.ui.glyph` | `glyph` name, optional `outline:false` |
| `font.ui.points` | `glyph` name and direct point-ID `points` array |
| `font.ui.master` | `master` ID or `default`; resets point selection |
| `font.ui.tool` | Optional `tool` (select / marquee / pan / pen / rectangle / ellipse), `curveType` (line / qcurve / curve), `snap` (0...100) |
| `font.ui.proof` | Optional text (max 20,000 UTF-16 units), size (12...200), language, direction, vertical/multisize booleans, location object or axis=value string, and features object (kern / liga / calt / mark / locl / smcp booleans) |

These commands change no document state or durable revision. All original
editing / compilation / import / export commands remain registered and can be
opened through the shared native command menu and dynamic parameter Form. Large
metadata lists are summarized; existing commands still address omitted axes,
masters, instances and kerning records by tag, ID or name.

`nativeChrome` may be enabled before `load` or before `FontView` construction.
Swift's initial empty document normalizes to `.notdef`; no validator is relaxed.
Native chrome emits no in-canvas HTML buttons, selectors or text inputs. Proof
text uses `textContent`; its preview is not content-editable. The JSON string /
JSON.parse value bridge, Paper Core and the fixed WOFF2 CSP adaptation stay in use.

Validation for this UI batch: the focused Web behavior runner includes native
path/component/pagination, typed transient-state, and empty-document/native-chrome
checks. Swift object compilation and actual native interaction acceptance are
performed by the unified host owner; a Web test is not native UI acceptance.

# FloeCanvasExchange — Format Support Matrix

Scope: `Sources/FloeCanvasExchange`. The module now compiles under Swift 6
(object builds of the library and test targets) and its fixture-driven
tests run against the real codecs; see "Verification status" below for the
exact state and remaining lane boundaries.

The native **`.floecanvaslab`** archive is the recovery authority. Every
open format below is an *editable projection*: importing it never grants
execution permissions, never schedules flow runs, and never reads the
filesystem or network unless a host explicitly passes a trusted root and
opts in.

## Consumed Core surface

Consumed through `CoreCompatibility.swift` only — a signature drift is a
one-file fix:

- `CanvasPageSnapshot.flowGraphs: [FlowGraph]` (decodes absent as `[]`).
- `CanvasPageSnapshot.pencilDrawingData: Data?` (decodes absent as `nil`).
- `CanvasContent.richText(document: CanvasRichTextDocument)` with
  `CanvasRichTextRun(text, bold, italic, underline, strikethrough, link,
  foregroundColor)`.
- `CanvasContent.shape(kind: CanvasShapeKind, text: String)` with
  `rectangle / roundedRectangle / ellipse / diamond / line / arrow`.
- Node metadata keys: `floeCanvas.visual.fillColor`, `floeCanvas.visual.strokeColor`,
  `floeCanvas.visual.strokeWidth`, `floeCanvas.visual.textColor` (visual style) and `floe.flow.graphID`, `floe.flow.nodeID`
  (flow card binding). The `setPencilDrawingData` edit operation is provided
  by Core for hosts; exchange only reads the field.

## Native archive `.floecanvaslab`

| Aspect | Behavior |
| --- | --- |
| Contents | `manifest.json` (versioned, sha256 per entry), `document.json` (whole `CanvasSnapshot`: pages, nodes, connections, groups, regions, scenes, strokes, flowGraphs, sourceRefs+annotations, viewports, revision), `assets/<id>`, `sources/<id>.bin` (original import bytes), `children/<projectID>@<revision>.bin`, `templates/<id>@<version>.json` (reusable flow template definitions) |
| Assets | Every modeled reference is embedded: media locators, formula rendered assets, PDF document assets, `metadata["pencilKitDataID"]`, flow-variable `FlowValue.asset` (incl. nested lists), and the same typed references inside embedded template graphs (template variables + `FlowOperand` literals in condition/`stopWhen` predicates). Same-id conflicting locators (different hash/path/mime/size/license) fail the export — never last-write-wins |
| Asset integrity | If resolved bytes hash ≠ locator `contentHash`, export **fails** (`.integrity`). Hosts refresh the asset and commit a new canvas revision first |
| Flow templates | `CanvasNativeArchive.FlowTemplateDefinition(id, version=1, name, graph: FlowGraph, exposedPorts=[FlowPort])` is the archive-owned serialization envelope for reusable templates (hosts map its exact six fields to/from their runtime `FlowSubgraphTemplate` registry). Export takes an optional host registry and embeds **only the definitions reachable** from the snapshot graphs (`subgraphTemplateID` / `group.id`, transitive through nested template graphs); a missing referenced definition **fails the export** — completeness is never claimed silently. On import every definition is digest/id/version-verified and returned in `ImportResult.flowTemplates` / `CanvasExchangeBundle.flowTemplates` as data only — recovery never executes template graphs or adopts permissions. Recursive references and unconfigured draft subgraphs are reported as `flowTemplate.recursiveReference` / `flowTemplate.unconfiguredDraft` issues (data-complete; instantiation validity is the runtime's concern). `Manifest.flowTemplates` is optional-decodable: archives written before templates existed stay valid |
| Staging budget | A running staged-bytes budget (default 512 MiB, `stagedByteBudget` override for tests) is enforced BEFORE each entry lands: a locator's declared `byteCount` pre-flights before its bytes are pulled, and an over-budget archive fails immediately — never after pulling every referenced byte into memory |
| Child projects | `.editor` references require an injected `CanvasChildProjectExportProvider`; the opaque archive bytes + revision + sha256 are embedded. Without a provider the export fails — a bare projectID is not an offline-reopenable project |
| Reopen | Import verifies: manifest/document digests, identity cross-checks (id/name/revision/schemaVersion/pageCount), duplicate ids/paths, every document-referenced asset and child present and digest-clean, and every document- or template-referenced template definition present, digest-clean, and id/version-consistent. `ImportResult.documentData` always returns the original document bytes (recovery envelope for newer schemas); `sourceDataByID` returns original import bytes so import→export preserves raw payloads byte-for-byte |
| Dates | document/manifest dates encode as the tagged native form `{"floeDate": <reference-date seconds decimal>, "floeDateBits": <IEEE-754 bit pattern hex>}` — raw 2001-reference seconds preserve any finite Date **bit-exactly** (the earlier epoch-Double spelling lost sub-microsecond precision to the 978307200-second offset shift; `Date(timeIntervalSinceReferenceDate: 123.123456789012345)` is the deterministic regression). The decoder also accepts the two legacy spellings: epoch-seconds JSON numbers and ISO8601 strings |
| Missing referenced asset | Hard `.integrity` failure with the asset id — never reported as success |
| Missing referenced template | Hard export failure (named template id) and hard `.integrity` failure on reopen when the manifest closure is incomplete — never reported as success |
| Bounds | ≤ 20 000 entries; ≤ 64 MiB per entry; ≤ 512 MiB staged/expanded total; ≤ 128 MiB compressed. Staging fails before the budget is crossed; `CanvasLabZIP.pack` keeps its own outer bounds check as defense in depth |
| ZIP safety | Absolute paths, `..`, empty segments (`//`, trailing `/`), `\`, `:`, NUL, duplicates and symlinks are rejected on read; corrupt entries and unreadable archives surface as typed `.integrity`/`.invalid` errors |
| File write | `CanvasAtomicFile.write`: O_EXCL staging, fsync, same-directory rename, directory fsync |
| Never stored | Credentials, execution permissions, code signatures |

Unknown numeric fidelity: external trees are parsed/emitted with
`JSONFidelity` (exact number literals). The native `document.json` uses the
Core JSONValue Codable tagged representation intentionally (Core decision);
unknown big literals survive through either path.

## JSON Canvas 1.0 (`jsoncanvas.org/spec/1.0/`)

| Canvas class | JSON Canvas | Notes |
| --- | --- | --- |
| text / markdown | `text` node | markdown source verbatim; preview hint loss-reported |
| web | `link` node | original url string re-emitted verbatim via sidecar |
| media w/ `relativePath` | `file` node | `subpath` preserved via sidecar |
| file reference (unresolved) | `file` node | round-trips; host importer resolves bytes (opt-in trusted root, symlink-escape safe) |
| region | `group` node | deliberate: JSON Canvas groups are labelled backdrops = collapsible regions. `CanvasGroupRecord` (move-together grouping) is **not** exported |
| connection | `edge` | sides mapped (left/right/top/bottom ↔ leading/trailing/top/bottom); `fromEnd`/`toEnd` ↔ kind (arrow/line); color preserved via sidecar |
| shape / richText / code / formula / table / pdf / editor / unknown | `text` node (editable projection) | per-class `jsoncanvas.projectedToText` loss issue |
| flow cards | visual `text` projection | `drawio.flowCard`-style issue; execution never exported |
| strokes, pencil, scenes, flowGraphs | — | loss-reported; native archive retains |

- External ids: deterministic UUIDs (`sha256(namespace:id)`), mapping
  returned in `externalIDs`; re-export recovers original ids.
- Unknown node/edge/top-level keys (e.g. the fixture's
  `floeUnknownFixture`, `fixtureExtension`) are preserved verbatim in the
  import sidecar and re-injected on export — including exact big-number
  literals.
- Multipage: single-page format. Export is explicit: `selectedPageOnly`
  (with a per-page loss issue naming every skipped page) or
  `oneFilePerPage`. Nothing is silently dropped.
- Rejection: duplicate node/edge ids (`.invalid`, actionable); non-finite
  or out-of-range positions rejected per node with issue; non-positive
  sizes clamped with issue; unknown `type` kept as `.unknown` content.

## Excalidraw (schema per v0.18.x)

| Canvas class | Excalidraw | Notes |
| --- | --- | --- |
| shape rectangle/ellipse/diamond | same types | 1:1, style metadata ↔ stroke/background/strokeWidth |
| shape line/arrow | `line`/`arrow` | frame-projected points; original point lists/bindings via sidecar re-injection |
| richText / text / markdown | `text` | run formatting loss-reported (`excalidraw.richText`) |
| stroke | `freedraw` | world points → relative, pressures re-injected from sidecar |
| region | `frame` | `frameId` ↔ `regionID` |
| group | `groupIds` | each foreign group id ↔ one deterministic group record |
| media | `image` + `files` entry | bytes from `files` on import; injected `assetBytes` on export; missing bytes → issue, never a blank placeholder |
| bound text | shape text | `containerId` folded into shape text |
| arrow bindings | semantic connection + binding metadata | a connection re-merges into its origin arrow element on export (no duplicated pair); its bound label text becomes the connection label; dangling bindings issue-reported |
| isDeleted | dropped, counted | `excalidraw.tombstones` issue; tombstones stay in the sidecar |
| unknown element types / customData | `.unknown` content + sidecar | verbatim re-injection incl. big literals (fixture `fixtureUnknownInteger` beyond Int64, high-precision decimal) |
| pencil (page PKDrawing) | — | `excalidraw.pencil.notRepresentable` loss issue; native archive retains; discrete strokes still export |
| flowGraphs / scenes / editor / pdf / web | text projection or omission with issue | explicit per-class issues |

- Output numbers (`x`, `y`, `width`, `height`, `angle`, `seed`,
  `strokeWidth`, points) are real JSON numbers; unknown literals keep
  source spelling.
- Input validation: duplicate element ids rejected; non-finite
  coordinates clamped with issue; point-count bounds enforced; embedded
  `files` size-bounded; base64 validated.
- Multipage: same explicit strategy as JSON Canvas.

## draw.io (via DiagramKit public exchange codec)

Geometry, multipage `<diagram>` pages, DTD/external-entity refusal and
import decoding reuse `DiagramExchange.importData/export(.drawio)`
unchanged. Compressed page output is applied by this module on top of the
public uncompressed export with the standard diagrams.net transform
(URI-encode → raw DEFLATE → base64, RFC 1951 bit-exact), and re-imports
through DiagramKit's own zlib inflate — so `options.compressed` produces
real, diagrams.net-readable payloads.

| Canvas class | draw.io | Notes |
| --- | --- | --- |
| page | `<diagram>` page | multipage ↔ multipage; `compressed:` standard encoded payload |
| region | group shape | container membership |
| group (CanvasGroupRecord) | group container + `floeParent` membership | distinct from regions; members keep group identity on re-import |
| shape closed kinds | rounded/rect/ellipse/diamond | |
| shape line/arrow | connection (or dropped w/ issue if textless) | |
| richText | editable label (plain text projection) | character styles/links are loss-reported (`drawio.richText.projected`) |
| text / markdown / code / formula / table | editable label carrying the source text | per-class projection issues; re-import gives editable text |
| media | labeled card with its reference | the public geometry path embeds no image bytes (`drawio.media.notEmbeddable`); bytes stay in the native archive |
| pdf / editor | labeled card | revisions kept in native archive; `drawio.pdf.projected` / `drawio.editor.projected` |
| connection | edge | ports, label, arrowheads; waypoints kept in the original payload + issue |
| strokes / pencil / scenes / rotation / flowGraphs | not representable | explicit loss issues; flow cards export as visual shapes only — binding ids are never written to open output, and nothing executable is emitted |

Unsupported original XML/styles: preserved in `originalNodes` sidecar
(style/value) and the original draw.io bytes travel as a
`.drawioOriginal` original source for the native archive.

## Native rendered export (PDF / SVG / PNG)

Renders the actual node content — Unicode text (CoreText), rich runs
(bold/italic/underline/strikethrough), tables, code blocks, formulas
(rendered asset image when resolved, source otherwise), media thumbnails
(injected bytes), real PDF page crops (`CGPDFDocument`, requested page
range), shapes, regions (with explicit collapsed-chip vs expanded
presentation), connection arrows + labels, freehand strokes, and page
PKDrawing ink via `DiagramNativeInk` at world-space bounds. Reuse:
`DiagramPalette`, `DiagramNativeExporter.rasterImagePNG`,
`DiagramNativeInk`.

| Aspect | Behavior |
| --- | --- |
| Scope | `wholePage` / `region(id)` / `scene(id)` / `selection(ids)` |
| Multipage PDF | every page (or `pageIDs`) becomes one PDF page |
| Bounds | union of rotated frame AABBs, stroke points, ink bounds, label chip rects (CJK-aware width, not a fixed guess); padded 32 pt |
| Edge labels / arrows | connection lines paint under the cards with endpoints at the exact border/port points; arrowheads and opaque label chips (sized to the measured/estimated full text) paint **above** the node groups, so a tight-gap edge keeps its whole label legible and its arrow tips visible |
| Shape text | centered inside the shape bounds (PDF/PNG via measured CoreText layout, SVG via `text-anchor="middle"`) — never top-left anchored, which spilled CJK glyphs outside a diamond |
| Raster guard | PNG scale = min(2, 8192/maxDim, √(24 MP/area)); over-limit refuses rather than allocating |
| Missing preview | opaque CAD/3D/editor children and unresolved PDF/media draw an explicit dashed placeholder card + `.unavailable` issue — never a blank rectangle sold as rich export |
| SVG safety | escaped text; links restricted to http/https/mailto; images only as injected-bytes data URIs (PNG/JPEG only, no silent re-encode); no scripts, no external network references; eraser strokes approximated with background color (issue noted) |
| PDF crop | real `CGPDFDocument` page rendering where bytes resolve; placeholder + issue otherwise |

## Host APIs (summary)

- `CanvasExchange.importData/export/save` — facade. `save` validates every
  output name (plain basename only) and stages all payloads before the
  first publish; publishing is a per-file atomic rename sequence, not a
  global transaction (failures roll back this save's own new files and
  report the rest — never deleting a pre-existing destination).
- `CanvasAssetResolver` — injected async byte channel;
  `CanvasInMemoryAssetResolver`, `CanvasTrustedFileAssetResolver` (root
  confinement, symlink escape refusal, regular-file check, bounded chunked
  reads).
- `CanvasNativeArchive.CanvasChildProjectExportProvider` — host child
  project archival.
- Every import returns `CanvasExchangeBundle` (snapshot, assets,
  originalSources, externalIDs, originalNodes/Edges, originalDocument,
  flowTemplates, issues); every export accepts the sidecar maps back for
  lossless re-export. `CanvasExportOptions.flowTemplates` carries the host
  template registry into a native archive export; only reachable
  definitions embed.
- Limits: `CanvasExchangeLimits` (input 128 MiB; archive 20 000 entries /
  64 MiB each / 512 MiB staged total; 100 000 foreign elements; 100 000
  points per stroke; raster 24 MP / 8192 px).

## Verification status

- Current Swift 6 object builds and full Exchange test suite pass: **71 tests,
  zero failures and zero skips**. Layout passes **73 tests** separately.
  Root evidence: `Local/Private/infinite-canvas-qualification-20261103/export-final-validation-01`.
  Earlier failed runs remain preserved and are not counted as passes.
- Current exact exported artifacts are in
  `Local/Artifacts/FloeCanvasKit/exchange-final-20261103-r4`.
  Native ZIP manifest/entry hashes and all formats were independently inspected;
  PNG and both PDF pages were visually reviewed after Poppler rasterization.
- Actual r4 draw.io file imported into diagrams.net through its Device file input;
  both pages rendered and shape/text editing controls opened. Both r4 JSON Canvas
  files opened in official Obsidian 1.15.0; second-page text entered its editor.
- Both unchanged r4 `.excalidraw` files opened in official Excalidraw through
  Microsoft Edge's native file picker. The first page rendered the embedded
  checkerboard PNG, bound labels, arrow, frame, freehand and Chinese/emoji; both
  pages entered the actual text editor. Excalidraw's own PNG exports are retained
  as rendering evidence. Earlier clipboard-based checks are supplementary;
  the native file-open path is now verified. No external account save/publication.
- Source contracts and component evidence do not establish main App integration,
  physical Pencil behavior, real provider execution or two-device synchronization.

Page-scoped IDs repeated by cloned/imported pages are deterministically remapped only in draw.io output, including connection and container references. The native source retains its identities. Standalone unlabeled line/arrow shape omission is explicitly reported as a loss.

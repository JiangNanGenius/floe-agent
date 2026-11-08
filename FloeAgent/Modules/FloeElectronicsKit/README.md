# FloeElectronicsKit

Native electronics document and editing services for the complete PCB/schematic
editor tracked in [the implementation ledger](../../../docs/FLOE_PCB_EDITOR_IMPLEMENTATION_PLAN.zh-CN.md).
This is an incremental implementation, not a completed full PCB editor. The
native UI and App/Files/model integration are under active qualification.

`FloeElectronicsCore` provides millimetre geometry, hierarchical schematic and
board records, symbol/footprint definitions, typed atomic edits, monotonic undo
and redo, a host-bound original store with revision/digest compare-and-swap,
and readback/history. Connectivity uses actual placed pins, wire endpoints,
explicit junctions and local/global/hierarchical labels. ERC reports actual
pin conflicts and missing references. Forward annotation previews pad/net
changes, preserves existing placement/routing and refuses unresolved routed-net
splits, missing footprints or locked-placement changes.

Eighteen focused tests passed with Xcode 27.2 (27B52) on the arm64 macOS host on
2026-11-08, including independent-writer races, external same-revision changes,
symlink refusal, read-only access, crossing/junction geometry, hierarchical
connectivity, output conflicts and routed-net migration/split handling.

`FloeElectronicsUI` supplies the native schematic/PCB/symbol/footprint workbench,
properties, checks, exports and a separate board-only 3D view. It embeds in the
host navigation and uses the injected original store and one monotonic undo
stack. Mouse and Pencil edit by default; finger drawing is an explicit toggle.
Narrow windows use panels instead of squeezing three columns onto the canvas.

Manual 45-degree routing resolves the touched pad, track or via on its actual
copper layer. It rejects different-net endpoints and violations involving the
new track in the supported DRC checks. It is not a shove/automatic router.
Native project, netlist, BOM, positions and actual board/schematic SVG exports
are available. Numeric position columns retain negative values; spreadsheet
formula-like user text is escaped. Native text rotation/mirroring is retained.

Five focused Mac session/routing/export tests and arm64 iOS 26 object
compilation passed on 2026-11-08. Those results do not validate the App wiring,
latest adaptive panel changes, actual touch input, or the whole PCB ledger.
App qualification is recorded separately. The bounded refill checkpoint below
does not close the full copper-zone feature set. Complete DRC,
advanced routing/tuning, KiCad exchange, Gerber/Excellon fabrication, component
3D models and simulation remain open implementation stages.

## PCB DRC core checkpoint

`EDADRC.check(project, boardID:)` returns revision-bound, Codable diagnostics
with rule, instance-aware objects, copper layer, location, measured/required
millimetres, severity and rule sources. Coverage and excluded checks accompany
every report; an empty error list is not a claim of complete PCB qualification.

The declared checks cover different-net copper clearance/contact, explicit
minimum track width and via diameter/drill/annular width, copper distance to the
polygonal board outline/cutouts, independent track/via/zone-fill keepouts, and
actual same-net copper connectivity. Routing results contain disconnected
copper components and a minimum spanning set of missing connections, including
required layer transitions; they are not routes or a count of nets. Missing
schematic terminals are separate diagnostics, without invented coordinates.

Geometry uses analytic track capsules, circles, transformed rectangles and oval
capsules, drilled apertures, via spans in actual copper stack order, and supplied
simple fill polygons as filled solids. Via barrels join the layers they span.
Only nonempty zone fills whose `fillRevision` matches the checked revision are
used. Missing/stale fills, missing definitions, unsupported pad shapes/layers
and ambiguous pad plating make affected coverage incomplete. No bounding box
stands in for copper, and no zone outline stands in for a fill.

`EDABoard.drcConstraints` is optional for existing schema-1 originals. Its explicit
minima are millimetres; validation rejects negative/nonfinite/oversized values.
Absent width or via minima remain unconfigured. Net-class width/via sizes remain
routing preferences; exact net-name/ID clearance assignments use the stricter
matching value, with empty-name classes as fallback and explicit global minima
as a floor. This limited resolver has no priority/pattern/custom-rule language.
These contracts follow the distinction between routing preferences and DRC
bounds in the [KiCad 10 PCB manual](https://docs.kicad.org/10.0/en/pcbnew/pcbnew.html#net-classes).

`keepout.copper` applies to filled zones; `tracks` and `vias` are independent.
The model has no pad/footprint keepout option. A via keepout uses the whole via
footprint, including its aperture. Copper clearance uses its actual annulus.
Round-rectangle corner radii, pad plating, hole clearance, pad annular minima,
custom padstacks/net ties, arcs/slots, mask/paste/silk/courtyard, differential
pairs/timing, fill generation/thermal/neck checks, and fabrication acceptance
are not supplied by this stage. See each report's coverage and excluded checks.

Work is bounded by copper/diagnostic counts and a cancellable geometry budget.
Exhaustion throws an error rather than returning a partial successful report.
The implementation remains quadratic for general geometry; large-board
performance and App integration have not been qualified.

The exact DRC candidate passed actual arm64 Swift 6 object compilation and
53 focused tests (35 DRC and the original 18 core checks) with Xcode 27.2.
The original failed test-source compilation is retained separately. This
checkpoint does not close PCB13 or the remaining editor feature ledger.

Build from the repository with Xcode selected explicitly and a dedicated
SwiftPM scratch directory on the internal SSD, for example:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --package-path FloeAgent/Modules/FloeElectronicsKit \
  --scratch-path "$FLOE_ELECTRONICS_SCRATCH" --jobs 6
```

The store receives its original directory from the trusted host. Tool arguments
must not construct an arbitrary store. The package runs no imported code and
does not provide a new execution or authorization system.


## Manufacturing output candidate

`EDAExchange.export(..., format: .gerber | .excellon, boardID:)` returns real
RS-274X copper/profile or XNC/Excellon hole/straight-slot files and a source
project/board/revision manifest with exact output hashes. These are partial
manufacturing exports, not a complete factory data set or fabrication approval.
Existing project/netlist/BOM/positions/SVG formats retain their entrypoint.

Gerber uses millimetres and 6.6 fixed coordinates (1 nm coordinate grid).
Rotated rectangles and oval pads use standard aperture macros; circles/vias
use circular flashes, tracks use circular-aperture strokes, and current actual
filled polygons use regions. Bottom footprints apply the existing mirror and
placement transform; whole bottom layers are not mirrored. Copper artwork is
before drilling. Drilled apertures are represented in the separate drill files.
Undefined layers/libraries, unassigned board/footprint graphics, missing corner
radii, non-round circle pads, and absent/stale zone fills fail with an object and
field path. Unsupported copper or hole geometry must never be deleted to turn
that failure into a success.

Excellon uses the [Ucamco XNC subset](https://www.ucamco.com/files/downloads/file_en/452/xnc-format-specification-revision-2021-11_en.pdf),
explicit decimal millimetre coordinates and finished-hole/slot diameters.
Files are split by plating and copper-layer span; straight slots use the
actual supplied endpoints with the declared circular tool width. No centreline
is guessed from a board cutout. Pad `drillPlated` and board `edgePlated` are
optional explicit metadata. Unknown pad plating blocks drill output; unknown
edge plating exports only profile geometry and is reported in the manifest.
A nonnil hole `endPosition` defines an explicit straight slot; nil retains the
legacy round-hole geometry. Missing optional fields in existing schema-1
originals remain decodable. Slots reject invalid or coincident endpoints.

The [Gerber specification](https://www.ucamco.com/files/downloads/file_en/554/gerber-layer-format-specification-revision-2026-05_en.pdf)
provides the command/attribute contracts. No mask, paste, silkscreen, assembly
artwork, process compensation, complete fabrication package or factory check
is fabricated by this writer. Only the modeled geometry and declared metadata
are emitted. Empty copper layers are listed explicitly, without blank files;
no represented holes gives an explicit no-drill result.

The independent reader qualification uses the unchanged App-bundled
`gerber-to-svg` 4.2.8, not a matching parser written for this exporter. It
honors the chosen macro/region/drill/route geometry, but ignores X2 metadata and
reports legacy NC mode hints even with explicit decimal coordinates. Those
warnings are retained; qualified geometry readback is distinct from a clean
parser/conformance result, actual App preview acceptance and fabrication.

## Bounded copper-zone refill

`EDACopperFill.plan(project, boardID:)` computes all zones on one board from the
actual geometry. `EDAEditingSession.applyCopperFill` compares the complete
source value and revision before one monotonic undo commit; its supported DRC
postconditions run before that commit. `EDWorkbenchSession.refillCopper` owns
the detached worker and uses the existing original-store CAS/publication path.
Ordinary edits clear derived fills; cancellation, close and newer revisions
fence late results. A failed original CAS retains the local proposal for review.

The core directly uses the existing pinned `Clipper2C` package, not a media or
manufacturing engine. Boolean/offset geometry uses a 1 nm integer coordinate
grid with explicit 0.0001 mm round chord error and conservative clearance
margins. Curved obstacles remain controlled polygon envelopes, not analytic
arcs. Board outline, cutouts, round holes/explicit straight slots, applicable
zone-fill keepouts, rotated/mirrored supported pads, track capsules, actual via
spans and exact-name/ID net clearance floors participate. Higher priority zones
fill first; lower different-net zones clear their actual filled copper.
Conflicting equal-priority different-net zones refuse to invent a winner.

Native holes are partitioned by vector clipping into nonoverlapping simple
solid `filledPolygons`; inner rings are never emitted as filled solids.
Isolated regions are retained and remain actual disconnected copper in DRC.
Computed `fillState` is optional (`filled`/`empty`) and revision-bound. A legacy
empty array with nil state remains missing. A successfully computed empty zone
is reported in DRC and the fabrication manifest without a fake copper file.

Optional `thermalRelief` carries explicit gap/spoke width (mm), board-axis
angle (degrees) and spoke count (currently four). Legacy `thermal=false` is
solid; `true` with nil parameters refuses refill. New-zone creation explicitly
chooses visible 0.25 mm / 0.3 mm / 45 degree / four-spoke values. A legacy zone
can select and apply those same defaults in its existing Inspector. Larger
zone/netclass/global clearance floors override smaller proposed thermal gaps;
an explicit minimum track width is also a conservative filler floor for spoke
width. Preferred netclass routing widths are not minima. A blocked spoke
refuses the whole refill; it does not stamp a partial result as complete.

Unlayered graphics, unsupported pad radius/shape/layer, unmapped preserved source,
precision/budget exhaustion or missing parameters fail explicitly. Never delete
original geometry to obtain a successful output. Minimum neck width, island
removal, hatch patterns, custom padstacks/net ties/thermal overrides and explicit
copper-to-hole clearance are outside this stage. The same original, undo and
typed model records remain authoritative. Normal `native.put` clears all derived
fill data; only the actual `eda.refillCopper` session action computes it.

The private candidate passed actual Swift 6 arm64/macOS 15 deployment object
compilation, 20 new Core tests plus the unchanged manufacturing refusal case,
and four real session/CAS/cancellation/close tests. New Gerber zone geometry was
read back by the unchanged App parser with its X2 warnings retained. These are
component results, not iOS/App UI, macOS 15 hardware or fabrication acceptance.

## Explicit graphic layers

Boards and footprint definitions optionally carry `graphicLayers`, an array
aligned with the unchanged `graphics` array. Each entry is nil (unassigned) or
an explicit `layerID` plus existing layer `kind`. A nonnil array must have the
same count as its graphics. Existing JSON and `EDAGraphic` case encoding remain
unchanged; missing metadata never becomes an inferred copper or non-copper role.

`EDAGraphicEditing` maintains both arrays for assignment, append, remove,
duplicate, reorder and geometry replacement. Inspector and footprint-canvas
edits use those helpers before the existing session transaction/CAS/undo.
Complete typed `native.put` records carry the same metadata. Explicit layer
changes remain ordinary authorized edits; a copper assignment can be saved
even when a consumer cannot yet plot or check that graphic.

`EDAGraphicLayers` resolves the explicit role consistently for DRC, refill and
Cu/profile export. Footprint front/back layer IDs swap once with a back-side
instance; board layer IDs are already absolute. Layer/kind conflicts, unknown
or unassigned layers, Cu graphics, mask/paste graphics and Edge.Cuts graphics
refuse the current output/refill subset. Unsupported graphics also make the
affected DRC coverage incomplete; a supported pad/track check cannot qualify
unhandled copper graphics.

Explicit silkscreen, fabrication and courtyard graphics remain in the original
and drawing views. Cu/profile Gerber omits those layer images and identifies
every excluded source graphic by owner, placed instance, index, declared and
resolved layer, kind and reason in the manifest. No missing layer image or
complete fabrication set is invented. Courtyard and silk fabrication checks
remain excluded from the DRC contract.

New self-authored generic 0603, 0805 and DIP rectangles explicitly choose
F.Fab/fabrication as a visible template design role. Their original geometry is
unchanged; this is not manufacturer-qualified package data. Legacy originals
keep nil metadata until a user or authorized model explicitly assigns a layer.
The existing graphics Inspector exposes that assignment and preserves unknown
entries while paired edits retain their array association.

This candidate passed Swift 6 arm64/macOS 15 deployment object compilation,
eight new Core tests plus the unchanged manufacturing-refusal case, and three
actual session/default-library/export/undo/CAS tests. A default native 0603
project generated real copper/profile before and after actual zone refill while
retaining its drawing; the unchanged App Gerber reader read four resulting
files with its X2 warnings retained. App/iOS/AI/UI and factory acceptance remain
separate. No dependencies or original-store behavior changed in this stage.

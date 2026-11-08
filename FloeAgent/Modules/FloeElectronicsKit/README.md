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
App qualification is recorded separately. Copper filling, complete DRC,
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

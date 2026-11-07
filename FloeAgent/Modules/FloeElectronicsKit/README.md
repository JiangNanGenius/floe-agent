# FloeElectronicsKit

Native electronics document and editing services for the complete PCB/schematic
editor tracked in [the implementation ledger](../../../docs/FLOE_PCB_EDITOR_IMPLEMENTATION_PLAN.zh-CN.md).
This package checkpoint is the document/core stage, not a completed App editor.

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

App creation/navigation, touch/Pencil editing, library UI, interactive routing,
complete DRC, copper filling, exchange/fabrication, 3D, simulation and model tool
bindings remain stages in the ledger. They are not satisfied by these core tests.

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

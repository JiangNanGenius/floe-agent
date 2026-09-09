# XLSX live embedded-object export

Applies only to online.mirror `27b21dc1a90ac67c90fb1addd6f9fb22eec40ccc`.
The exact original and patched sources and original archive are recorded in
`../filter-overlay.lock.json`. This patch remains under the upstream source's
MPL-2.0 license; it is distributed as source alongside Floe's other engine patches.

The pinned `XclObjOle` has a binary exporter but inherits an empty XML exporter.
Both actual Calc save controls therefore produced no embedded data in XLSX.
This patch exports objects from the live engine's storage, using the existing
`oox::GetOLEObjectStream` conversion for embedded documents that were edited.
It does not repair the ZIP after saving or copy stale objects from the input.

Each worksheet receives an OLE relationship, original ProgID/view aspect, a
preview image, a VML picture-frame object, and cell anchors. A shared record binds
the worksheet `shapeId` to the VML shape. This is required by the pinned Calc
importer (`WorksheetFragment::importOleObject` registers with `VmlDrawing`).
Modern `objectPr` records additionally retain EMU anchors and cell-movement flags.
The tag is emitted with escaped attribute values because adding it to the sorted
token table would change token IDs throughout the already compiled engine.

References:

- [Microsoft OLE object definition](https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.spreadsheet.oleobject?view=openxml-3.0.1)
- [Microsoft embedded-object properties](https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.spreadsheet.embeddedobjectproperties?view=openxml-3.0.1)
- [Pinned Calc exporter](https://github.com/CollaboraOnline/online.mirror/blob/27b21dc1a90ac67c90fb1addd6f9fb22eec40ccc/engine/sc/source/filter/xcl97/xcl97rec.cxx)
- [Pinned worksheet importer](https://github.com/CollaboraOnline/online.mirror/blob/27b21dc1a90ac67c90fb1addd6f9fb22eec40ccc/engine/sc/source/filter/oox/worksheetfragment.cxx)

Build and qualification:

1. Create a fresh sparse checkout using `build_office_filter_overlay.SPARSE_PATHS`.
2. Run `build_office_filter_overlay.py BUNDLE SOURCE OUTPUT` on macOS with Xcode.
3. Run `build_office_native_host.py BUNDLE HOST --filter-overlay OUTPUT`.
4. Install and exercise real XLSX insert, undo/redo, save, close/reopen, move/resize,
   delete, export and multiple-sheet/object cases. Compare original payload bytes.

The build regenerates headers using the exact upstream generators. It compiles
three translation units and checks that replacing `xcl97rec.o`, `xlroot.o` and
`unitconverter.o` preserves every other
archive member. No class layout, virtual method table or token table is changed.
The verified source archive is never modified; only an owned library is selected
in the host's new linker list. Copy/preview errors propagate as failed saves.

The VML identifier fix follows pinned VMLExport::StartShape, disabling X-escaping
only for shape start attributes and restoring it afterward. Normal XML escaping
remains active. Actual attachment insert, undo/redo and two saves/reopens now retain
the original payload and Package metadata. Microsoft Office validation remains pending.

Repeated saves still shrink default column widths and untouched attachment geometry.
The ReferenceDevice/ApiFontData export candidate failed real repeated-save testing
and has been removed from conversion behavior. Its measurement is retained only as
an opt-in diagnostic control, alongside actual import and original export metrics.
Set `FLOE_OFFICE_FONT_METRICS_TRACE` only in the synthetic qualification probe to
collect requested/effective/device fonts, digit widths, DPI and map scaling. The
trace excludes document contents and file names and stops at 1 MiB. Unset by default,
it does not replace export metrics or change document conversion state. No class
layout changes are involved; the added UnitConverter methods are static.

The repeated-save comparator also found VML and modern movement flags disagreed.
The exporter now follows Excel's convention used by the pinned ClientDataContext:
emit an empty MoveWithCells/SizeWithCells element to disable that behavior, omit it
to enable it. Modern objectPr anchor booleans retain their positive meaning.
This applies independently to page, cell-move and cell-resize anchors. See Microsoft's
[MoveWithCells implementation note](https://learn.microsoft.com/en-us/openspecs/office_standards/ms-oi29500/40158516-bf23-46b1-b809-063618265082)
and [SizeWithCells implementation note](https://learn.microsoft.com/en-us/openspecs/office_standards/ms-oi29500/f7349999-2b8b-434b-a3ca-650b7c61f2b5).
Actual repeated-save verification of host 34344605828 confirms fixed-page flags
now remain correct and attachment bytes survive undo/redo and two saves/reopens.
The reference-font metric candidate FAILED: an untouched column changed from
22 to 22.82 to 21.8. It is recorded as a failed candidate, not qualified as a fix.
The attachment left position
stayed fixed, but width/height still drifted by 5/1 hundredths of a millimeter.
The pinned VML importer rounds offsets to integer pixels; its handling of the
precise `objectPr` anchors needs runtime fidelity checks and potentially a follow-up
importer patch. Grouped objects, linked OLE, absent previews, repeated saves and
protected documents are not yet qualified. Do not mark Office A04 or F04 complete.

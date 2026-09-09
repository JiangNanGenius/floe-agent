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
one translation unit and checks that replacing `xcl97rec.o` preserves every other
archive member. No class layout, virtual method table or token table is changed.
The verified source archive is never modified; only an owned library is selected
in the host's new linker list. Copy/preview errors propagate as failed saves.

Current boundary: the first native host linked and preserved actual attachment
bytes, but runtime reopen found no live object because X-escaping changed VML IDs
and type references. The patch now follows pinned VMLExport::StartShape, disabling
X-escaping only for the shape start attributes and restoring it afterward. Normal
XML escaping remains active. The corrected arm64 compile and archive preservation
passed; new host linking, runtime reopen and Microsoft Office validation remain pending.
The pinned VML importer rounds offsets to integer pixels; its handling of the
precise `objectPr` anchors needs runtime fidelity checks and potentially a follow-up
importer patch. Grouped objects, linked OLE, absent previews, repeated saves and
protected documents are not yet qualified. Do not mark Office A04 or F04 complete.

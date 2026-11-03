# Audit Continuation

## Current Tracking

[Entity status matrix](entity_status_matrix.md) catalogs 71 fixture cases, every public `EntityType` variant, indirect structural records, and excluded extended/dynamic families across AC1012 through AC1032. Separate matrices cover AutoCAD 2027 and BricsCAD, each for DWG, ASCII DXF, and binary DXF. The JSON sibling contains evidence paths and hashes.

Statuses distinguish native presence, proxy fallback, changed type, missing records, audit errors, blocked drawing opens, stale evidence, unavailable fixtures, and untested cases. A successful audit alone is not marked as native compatibility. Surface subtypes are checked explicitly. BricsCAD's PDFREFERENCE/DWFREFERENCE/DGNREFERENCE are accepted native underlay aliases.

## Confirmed Fixes

- Removed two abstract base classes from fresh default registration: `AcDbAssocActionParam` and `AcDbAssocPointRefActionParam`. Each declaration independently makes AutoCAD 2027 reject an otherwise valid AC1032 LINE drawing. Other action-parameter subclasses remain registered. Imported declarations are retained.
- AutoCAD now directly opens LINE controls for all eight DWG versions with zero audit errors. AC1027 and AC1032 previously failed. BricsCAD's AC1027 control also passes.
- Embedded LINE profiles now use the same lossless verification policy as embedded REGION: if decoding and re-encoding do not reproduce the original meaningful bits, preserve the opaque profile. This avoids corrupting unrecognized native construction payloads; it is not a claim that the complete EXTRUDEDSURFACE round-trip is fixed.
- R13/R14 MTEXT no longer writes the R2000-only line-spacing fields. The reader uses the legacy defaults for these versions.
- R13/R14 VIEWPORT uses its short entity body, ACAD/MVIEW EED, and VX headers. Slot zero is reserved so the paper-space overview and floating viewport retain valid IDs. MVIEW updates preserve unrelated structured ACAD values and reject malformed view parameters.
- Legacy EED string code pages use the native big-endian byte order. Reading also accepts the byte-swapped form emitted by older acadrust versions.
- Legacy modeler SAT blocks use the native flag, printable-byte substitution excluding spaces, CRLF separators, and no standalone SAT end marker. Classic SAT 700 is normalized to SAT 400 for R13/R14/R2000, including the older edge layout. R2004 SAT-origin geometry uses version-2 SAB. Verified geometry is the seven analytic solid fixtures, REGION and BODY, not arbitrary newer ASM schemas.
- ARCALIGNEDTEXT's six D2T numeric fields are written/read as text, not binary doubles. This fixes BricsCAD's `Object improperly read: <AcDbArcAlignedText>` failure. DXF arc-text angles now convert between API radians and DXF degrees.
- The DWG reader now dispatches all mapped entity sentinels, including arc/jogged dimensions, CAMERA, SECTIONOBJECT, ARCALIGNEDTEXT, RTEXT, position markers, point clouds, MPOLYGON and proxies. The previous entity predicate stopped at LIGHT and silently omitted the later types.
- AC1024 TABLE now writes the native `true` header bit, distinct from the R2013+ integer default of zero. The false default caused AutoCAD to hang during direct open. Explicit imported R2010 values are retained independently.
- LOFTEDSURFACE, REVOLVEDSURFACE and SWEPTSURFACE no longer write an extra modeler-version short or use the incorrect R2007+ field order. Native AC1021 records contain embedded construction profiles. Native-reader and four-version write tests now retain the profiles, transformations and options.
- R2013/R2018 AcDs now writes a contiguous record table, correct geometry offsets and the dynamic aligned blob-area offset. The previous interleaved records and fixed one-record offset caused drawings with several modeler entities to fail although individual entities passed. Tests cover 1, 2, 7, 8 and 16 records, with AutoCAD integration checks for multiple solids and surfaces.
- AcDs extraction recognizes the tagged `End-of-ACIS-data` terminator and aligned blob area; native surface geometry previously disappeared during library readback despite external acceptance.
- SAB output maps surface boolean keywords back to boolean tags. Binary modeler transformations preserve typed SAB records and wireframe metadata instead of converting through SAT. Native modeler header flags greater than one are also preserved through SAT/SAB conversion.
- DXF common-field parsing retains layer, indexed color and lineweight for surfaces and lights. Those entities previously appeared missing from their atlas layers even though their bodies were present.
- Modern ShapeManager SAT exported to DXF now declares its actual record count. A zero count made BricsCAD report a nonempty surface body as `Data stream is empty`. SAB boolean decoding now restores the third face containment role and transform role names, so DXF emits `forward/reversed`, `single/double`, `in/out`, and `no_rotate/no_reflect/no_shear` instead of context-free `T`/`F` values.

## Evidence

`target/class-single/validation/ACAD2027/` contains the isolated declaration probes. Classes 56 (`ACDBASSOCACTIONPARAM`) and 59 (`ACDBASSOCPOINTREFACTIONPARAM`) failed, while the other declarations in that probe range passed. `target/class-modes/` confirms that omitting both permits the full remaining class table to open; merely changing DWG metadata or DXF names does not fix it. This replaces the earlier unconfirmed oversized-class-table hypothesis.

`target/entity-version-controls/` contains the regenerated eight-version LINE controls. The optional AutoCAD integration test also covers AC1027/AC1032 alongside the existing empty, mixed, preview and multipage AC1021 controls.

`target/entity-matrix-isolated/` holds the fresh per-entity AC1021 DWG probes. Do not infer that their results extend to other untested versions.

`target/entity-matrix-isolated-AC1012/` through `target/entity-matrix-isolated-AC1032/` contain the other version probes. The latest source regenerated every isolated corpus so obsolete hashes cannot be mistaken for fresh evidence. The live matrix is authoritative for current per-entity results.

Complete DWG atlas results after the legacy and arc-text repairs:

| DWG Version | Included Cases | AutoCAD 2027 | BricsCAD |
|---|---:|---|---|
| AC1012 | 44 | 44 present, audit 0 | 44 present, audit 0 |
| AC1014 | 49 | 49 present, audit 0; 2 proxies | 49 present, audit 0; 1 proxy |
| AC1015 | 49 | 49 present, audit 0; 2 proxies | 49 present, audit 0; 1 proxy |
| AC1018 | 52 | 52 present, audit 0; 2 proxies | 52 present, audit 0; 1 proxy |
| AC1021 | 68 | NURBSURFACE blocks combined open | 68 present, audit 0; 1 proxy |
| AC1024 | 70 | NURBSURFACE blocks combined open | 70 present, audit 0; 1 proxy |
| AC1027 | 71 | 71 present, audit 0; 3 proxies | 71 present, audit 0; 1 proxy |
| AC1032 | 71 | 71 present, audit 0; 3 proxies | 71 present, audit 0; 1 proxy |

ARCALIGNEDTEXT is now native and audit-clean in BricsCAD on every included version (AC1014 through AC1032); AutoCAD Core Console retains it as a proxy. Its repaired reader also decodes BricsCAD's native reference from `target/arc-native-reference.dwg`. The six D2T fields agree with [LibreDWG's record description](https://github.com/LibreDWG/libredwg/blob/master/src/dwg2.spec); the supplied ODA PDF covers the common DWG/EED layouts but does not list this Express Tools entity. AC1021 ELLIPSE and LWPOLYLINE pass on retry; their previous failures were engine startup failures.

AutoCAD and BricsCAD now open all eight ASCII/binary DXF pairs with zero audit errors. A separately AutoCAD-authored AC1021 DXF control established that BricsCAD accepts the same four native construction surface types; comparing its modeler stream exposed the record-count and role-name defects above. Proxy cells remain distinct from native passes, and neither audit nor type presence proves appearance or editing-history fidelity.

The atlas now contains authored construction fixtures in `examples/entity_atlas_assets/native_surfaces.dwg`, with provenance and authoring commands in the adjacent Markdown file. All four advanced surface subtypes are retained, including complete embedded profiles. The original seven-case surface catalog remains intact. Diagnostic `--exclude` corpora are only for isolating failures and are never used as the complete-atlas matrix.

The matrix has a per-version DWG summary and 3,408 detailed cells. Engine startup failures are separate from invalid drawing failures. Resume checks now compare source hashes and retry timeouts/startup failures. Isolated runners use a private generator executable so a concurrent rebuild cannot replace their running program.

When duplicate isolated corpora cover a case, the matrix prefers current hashes and then the latest result, not directory enumeration order. Full BricsCAD AC1024 and AC1027 individual batches ran during this continuation; the latest combined results supersede their older surface failures after fixture and codec repair.

Verification on 2026-09-10: the full Rust test suite passes (1,279 library tests plus integration suites). The audit regression suite has 20 tests, seven native surface tests cover geometry, construction data and both DXF encodings, and TABLE regressions cover both version defaults. The optional AutoCAD integration test opens all nine controls directly with zero audit errors. All-target checks, including the serde feature, pass.

## Remaining Work

- NURBSURFACE remains rejected by AutoCAD in AC1021/AC1024 DWG. AutoCAD itself saves an authored NURBSURFACE as generic SURFACE in those formats, while retaining NURBSURFACE in AC1032. The matrix keeps the rejected native fixture explicit; it is not silently removed or downgraded to obtain a pass.
- A freshly authored AC1032 NURBSURFACE has more complex native data than the current planar atlas fixture, and the reader's fields need investigation. An audit-clean planar fixture is not full NURBSURFACE support.
- Recheck full imported-document round-trips independently. Earlier EXTRUDEDSURFACE and REGION failures may involve metadata or multiple-body AcDs defects now repaired, but this broader workflow has not yet been revalidated.
- SAT 700-to-400 conversion is demonstrated for analytic fixtures only. Arbitrary newer ASM schemas and mixed imported VX tables require additional coverage.
- The unsynthesized OLE, point-cloud, coordination, model-documentation and dynamic families still need valid payload/ownership fixtures. Their UT cells are not completed validation.
- Proxy fallback and external asset dependencies remain visible in the matrices.

## Commands

```powershell
cargo run --example entity_atlas -- target/entity-atlas
scripts/validate_entity_atlas.ps1 -Engine ACAD2027
scripts/validate_entity_atlas.ps1 -Engine BCAD -Filter '*dxf*' -TimeoutSeconds 22
scripts/validate_entities_individually.ps1 -Version AC1021 -Engine ACAD2027 -Format dwg
scripts/validate_entities_individually.ps1 -Root target/entity-matrix-isolated-AC1032 -Version AC1032 -Engine ACAD2027 -Format dwg
scripts/entity_status_matrix.ps1
cargo test --tests
```

Tests and automation remain console-only. IntelliCAD is excluded.

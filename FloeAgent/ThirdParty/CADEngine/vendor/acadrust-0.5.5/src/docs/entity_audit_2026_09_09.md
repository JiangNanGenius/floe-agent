# Entity Audit Repairs, 2026-09-09

This is the first repair-batch snapshot. See [continuation findings](entity_audit_continuation.md) and the [current per-entity matrix](entity_status_matrix.md) for subsequent fixes and stricter native-type validation.

## Status

Console-only validation, using AutoCAD 2027.1 Core Console and BricsCAD V20.1 COM automation. IntelliCAD was not used.

The complete ASCII and binary DXF atlases open directly in AutoCAD and complete `AUDIT N` with zero errors in all eight versions: AC1012, AC1014, AC1015, AC1018, AC1021, AC1024, AC1027, AC1032. Every version-eligible numbered case is present (44, 49, 49, 52, 68, 70, 71, 71 respectively). BricsCAD's complete AC1021 ASCII and binary DXFs also open with 68/68 cases and zero audit errors.

Native-type validation is stricter: only the complete AC1012 and AC1032 DXFs pass without proxies in AutoCAD. AC1014/AC1015 contain RTEXT and ARCALIGNEDTEXT proxies; AC1018 also contains IMAGE/WIPEOUT proxies; AC1021/AC1024/AC1027 additionally contain CAMERA and LIGHT proxies. BricsCAD AC1021 contains an RTEXT proxy. These are reported as `PROXY_ENTITIES`, not full compatibility passes. Earlier runs checked only layer presence and audit counts; their `PASS` statuses must be read with that limitation.

The combined DWG atlas is **not yet clean**. Do not interpret DXF acceptance or library readback as proof of general DWG compatibility.

## Repairs By Record

| Record | Defect and correction | External evidence |
|---|---|---|
| HEADER | SOLIDHIST/SHOWHIST use byte group 280 from R2007; ACADMAINTVER uses 70 before R2018. Omit nonstandard SKTOLERANCE. | AutoCAD no longer rejects the header. |
| STYLE/SHAPE | Shape-file STYLE name must be empty in DXF; SHAPE resolves the shape name from loaded shape files. No group 7 is required on SHAPE. | Isolated AC1021 DWG and both DXFs pass AutoCAD and BricsCAD. |
| INSERT/ATTRIB | Allocate null child handles, budget them in HANDSEED, avoid collisions with existing child identities, remove duplicate INSERT XDATA; derive block has-attributes flag from ATTDEF members. | Isolated AC1021 DWG and both DXFs pass both engines. |
| DIMENSION | Omit absent DXF geometry-cache block names; retain class definitions required by arc/jogged dimensions when preparing legacy DWGs. | All nine variants pass isolated AC1021 DWG and both DXFs in both engines. |
| TABLE | Create/resolve anonymous block references and allocate record/BLOCK/ENDBLK handles. Use decimal anonymous suffixes. Retain TABLESTYLE from R2004 onward. | Isolated AC1021 DWG and both DXFs pass both engines. |
| MULTILEADER | R2007 includes the arrowhead override count/list; the old gate excluded it. Preserve MLEADERSTYLE from R2007, resolve null DWG linetype to ByLayer, omit DXF group 270 before R2010. | AC1021 DWG passes both engines; complete AC1021 DXFs retain the entity with zero audit errors. |
| MLINE | Resolve missing style handles before output. | Isolated AC1021 DWG and both DXFs pass both engines. |
| WIPEOUT | Use AcDbWipeout, not AcDbRasterImage, as the DXF subclass. | Isolated AC1021 DWG and both DXFs pass both engines. |
| REGION/BODY | Correct ASCII/binary DXF SAT ciphers and caret handling; fix SAT header strings, compact boolean tokens and placement records; encode R2007+ inline SAB and terminate the modeler payload chain. Restore REGION's legacy history handle slot. | Isolated AC1021 DWG and both DXFs pass both engines, including translated geometry. |
| 3DSOLID | Same modeler corrections; omit pre-R2007 DXF history subclass/handle. Pyramid side-plane normal components and one coedge partner were incorrect. | Box, cylinder, cone, sphere, torus, wedge and pyramid individually pass AutoCAD AC1021 DWG and both DXFs. |
| SURFACE/PLANESURFACE | Same modeler corrections; omit the extraneous AcDbPlaneSurface DXF subclass. | Both individually pass AutoCAD AC1021 DWG and both DXFs. |
| LIGHT | Register its class; write groups 70/72/73 as i16 and 91 as i32. | Binary DXF parsing is fixed; native in AC1032, proxies in older complete AutoCAD DXFs. |
| UNDERLAY | Remove invalid DXF group 91; restore definition reactor back-references and serialize them in DWG/DXF. | BricsCAD's DWF/DGN missing-reactor errors cleared in the complete AC1021 DXFs. |
| VIEWPORT | ID belongs in DXF group 69, not 68. Fixture supplies an overview viewport on layer 0 and a separate ID-2 test viewport. | Complete AC1021 DXFs pass both engines. |
| Legacy table/object records | Gate AcDbDimStyleTable and CLASS instance count fields; include the R13/R14 placeholder subclass marker. | Complete R13/R14 DXFs pass AutoCAD. |

Polyline3D, PolygonMesh and LEADER were also checked individually in AC1021 and pass all three encodings in both engines. Their atlas layer/annotation setup was corrected before this repair batch.

## Remaining DWG Work

- EXTRUDEDSURFACE, LOFTEDSURFACE, REVOLVEDSURFACE, SWEPTSURFACE and NURBSURFACE still fail isolated AutoCAD AC1021 DWG direct open. Their DXF records pass. Investigate native construction metadata/layouts without dropping the entities.
- AC1027/AC1032 can fail AutoCAD even for a single LINE, independently of modeler geometry. The CLASSES section remains a suspect, not a confirmed diagnosis or completed fix.
- The rich pre-R2007 DWGs still fail direct open. Isolate the remaining native records and modeler representation by version.
- BricsCAD's other full-version atlases need a fresh run after these repairs; older result files are not evidence for current output.

The per-record passes above refer to direct open, zero audit errors and presence; inspect actual entity types in the logs for native-versus-proxy status. No claim is made about rendered geometry, every possible entity configuration, proprietary object graphs or missing external underlay assets. Audit and entity-presence checks are necessary but do not establish those properties.

## Reproduction

```powershell
cargo run --example entity_atlas -- target/entity-atlas
cargo run --example entity_atlas -- target/entity-audit-REGION --case=REGION --version=AC1021
scripts/validate_entity_atlas.ps1 -Root target/entity-atlas -Engine ACAD2027
scripts/validate_entity_atlas.ps1 -Root target/entity-atlas -Engine BCAD -Filter '*AC1021*' -TimeoutSeconds 25
cargo test --tests
```

Per-file results/logs: `target/entity-atlas/validation/<engine>/<filename>/`. Isolated results: `target/entity-audit-<case>/validation/`. `--case=` accepts a prefix, such as `DIM_` or `3DSOLID`. `--untranslated` is only a diagnostic control, not a compatibility workaround. Validation uses drawing copies and records input hashes; reporting rejects stale copies.

All Rust tests pass, including 13 new tests in `tests/entity_audit_regressions.rs`. `cargo check --all-targets` passes. AutoCAD's optional `ac1021_compatibility` test also passed empty, mixed, preview and 5,000-line multipage DWGs without recovery and with zero audit errors. The existing AC1021 parity fix remains intact.

## References

- [ODA DWG specification](OpenDesign_Specification_for_.dwg_files.pdf): header page 82; SHAPE section 20.4.37; modeler sections 20.4.41; MLEADER sections 20.4.48 and 20.4.86; SHAPEFILE section 20.4.56.
- [ezdxf SAT cipher reference](https://github.com/mozman/ezdxf/blob/master/src/ezdxf/tools/crypt.py), checked against AutoCAD-created binary DXF.
- [ezdxf DXF header definitions](https://github.com/mozman/ezdxf/blob/master/src/ezdxf/sections/headervars.py) and [entity definitions](https://github.com/mozman/ezdxf/tree/master/src/ezdxf/entities).
- [LibreDWG surface layouts](https://github.com/LibreDWG/libredwg/blob/master/src/dwg2.spec).

# Entity Status By DWG/DXF Version

Generated from console validation results. AutoCAD 2027 and BricsCAD V20.1; IntelliCAD excluded. A cell describes the tested fixture, not every possible configuration of that entity.

`OK`: native type present, completed audit, zero errors. `PROXY`: retained only as a proxy. `TYPE`: unexpected native type. `MISSING`: case absent. `UNREAD`: absent with unreadable records. `AUDIT`: type present but drawing has audit errors, not necessarily attributable to this entity. `BLOCKED`: the entire drawing did not open, so this entity is untested in that drawing. `ENGINE`: engine startup failed before opening the drawing. `INCOMPLETE`: no completed audit. `UT`: not tested. `STALE`: source changed after validation. `NA`: excluded by the atlas version gate, not a claim about all possible down-conversions.

`i:` prefixes an isolated-drawing result used when the combined drawing cannot establish the status. BricsCAD native underlay names PDFREFERENCE/DWFREFERENCE/DGNREFERENCE are accepted aliases. Native identity and audit do not verify appearance, exact topology or external assets. Structural records are covered indirectly through their parent entities; exclusions are listed below rather than silently treated as passing.

## DWG Progress

Counts include isolated results where the combined atlas cannot open. Not verified includes blocked opens, stale evidence, engine failures and untested cases. Issue cells include proxies and non-native or incomplete results; they are not passes.

| Engine | Version | Native, Audit-Clean | Proxy | Other Issues | Not Verified | Excluded |
|---|---|---:|---:|---:|---:|---:|
| ACAD2027 | AC1012 | 44 | 0 | 0 | 0 | 27 |
| ACAD2027 | AC1014 | 47 | 2 | 0 | 0 | 22 |
| ACAD2027 | AC1015 | 47 | 2 | 0 | 0 | 22 |
| ACAD2027 | AC1018 | 50 | 2 | 0 | 0 | 19 |
| ACAD2027 | AC1021 | 64 | 3 | 0 | 1 | 3 |
| ACAD2027 | AC1024 | 66 | 3 | 0 | 1 | 1 |
| ACAD2027 | AC1027 | 68 | 3 | 0 | 0 | 0 |
| ACAD2027 | AC1032 | 68 | 3 | 0 | 0 | 0 |
| BCAD | AC1012 | 44 | 0 | 0 | 0 | 27 |
| BCAD | AC1014 | 48 | 1 | 0 | 0 | 22 |
| BCAD | AC1015 | 48 | 1 | 0 | 0 | 22 |
| BCAD | AC1018 | 51 | 1 | 0 | 0 | 19 |
| BCAD | AC1021 | 67 | 1 | 0 | 0 | 3 |
| BCAD | AC1024 | 69 | 1 | 0 | 0 | 1 |
| BCAD | AC1027 | 70 | 1 | 0 | 0 | 0 |
| BCAD | AC1032 | 70 | 1 | 0 | 0 | 0 |

## Version Availability

This is the minimum version selected for the fixture, not a guarantee that every API field is native in that version. See the engine matrices for actual results.

| Case | First Atlas Version | AC1012 | AC1014 | AC1015 | AC1018 | AC1021 | AC1024 | AC1027 | AC1032 |
|---|---|---|---|---|---|---|---|---|---|
| POINT | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| LINE | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| CIRCLE | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| ARC | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| ELLIPSE | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| LWPOLYLINE | AC1014 | NA | YES | YES | YES | YES | YES | YES | YES |
| POLYLINE | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| POLYLINE2D | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| POLYLINE3D | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| SPLINE | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| HELIX | AC1021 | NA | NA | NA | NA | YES | YES | YES | YES |
| TEXT | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| MTEXT | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| ATTDEF | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| INSERT | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| MINSERT | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| ATTRIB | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| DIM_LINEAR | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| DIM_ALIGNED | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| DIM_RADIUS | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| DIM_DIAMETER | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| DIM_ANGULAR2 | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| DIM_ANGULAR3 | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| DIM_ORDINATE | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| DIM_ARC | AC1018 | NA | NA | NA | YES | YES | YES | YES | YES |
| DIM_JOGGED | AC1018 | NA | NA | NA | YES | YES | YES | YES | YES |
| SOLID | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| 3DFACE | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| HATCH_SOLID | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| HATCH_PATTERN | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| LEADER | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| MULTILEADER | AC1021 | NA | NA | NA | NA | YES | YES | YES | YES |
| MLINE | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| TOLERANCE | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| POLYFACE | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| POLYGON_MESH | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| MESH | AC1024 | NA | NA | NA | NA | NA | YES | YES | YES |
| WIPEOUT | AC1014 | NA | YES | YES | YES | YES | YES | YES | YES |
| TABLE | AC1018 | NA | NA | NA | YES | YES | YES | YES | YES |
| 3DSOLID_BOX | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| 3DSOLID_CYLINDER | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| 3DSOLID_CONE | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| 3DSOLID_SPHERE | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| 3DSOLID_TORUS | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| 3DSOLID_WEDGE | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| 3DSOLID_PYRAMID | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| REGION | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| BODY | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| SURFACE_GENERIC | AC1021 | NA | NA | NA | NA | YES | YES | YES | YES |
| SURFACE_PLANE | AC1021 | NA | NA | NA | NA | YES | YES | YES | YES |
| SURFACE_EXTRUDED | AC1021 | NA | NA | NA | NA | YES | YES | YES | YES |
| SURFACE_LOFTED | AC1021 | NA | NA | NA | NA | YES | YES | YES | YES |
| SURFACE_REVOLVED | AC1021 | NA | NA | NA | NA | YES | YES | YES | YES |
| SURFACE_SWEPT | AC1021 | NA | NA | NA | NA | YES | YES | YES | YES |
| SURFACE_NURB | AC1021 | NA | NA | NA | NA | YES | YES | YES | YES |
| LIGHT_POINT | AC1021 | NA | NA | NA | NA | YES | YES | YES | YES |
| LIGHT_SPOT | AC1021 | NA | NA | NA | NA | YES | YES | YES | YES |
| LIGHT_DISTANT | AC1021 | NA | NA | NA | NA | YES | YES | YES | YES |
| SHAPE | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| IMAGE | AC1014 | NA | YES | YES | YES | YES | YES | YES | YES |
| PDFUNDERLAY | AC1024 | NA | NA | NA | NA | NA | YES | YES | YES |
| DWFUNDERLAY | AC1021 | NA | NA | NA | NA | YES | YES | YES | YES |
| DGNUNDERLAY | AC1021 | NA | NA | NA | NA | YES | YES | YES | YES |
| CAMERA | AC1021 | NA | NA | NA | NA | YES | YES | YES | YES |
| SECTIONOBJECT | AC1021 | NA | NA | NA | NA | YES | YES | YES | YES |
| RTEXT | AC1014 | NA | YES | YES | YES | YES | YES | YES | YES |
| POSITIONMARKER | AC1027 | NA | NA | NA | NA | NA | NA | YES | YES |
| ARCALIGNEDTEXT | AC1014 | NA | YES | YES | YES | YES | YES | YES | YES |
| VIEWPORT | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| RAY | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |
| XLINE | AC1012 | YES | YES | YES | YES | YES | YES | YES | YES |

## ACAD2027 / dwg

| Entity | AC1012 | AC1014 | AC1015 | AC1018 | AC1021 | AC1024 | AC1027 | AC1032 |
|---|---|---|---|---|---|---|---|---|
| POINT | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| LINE | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| CIRCLE | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| ARC | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| ELLIPSE | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| LWPOLYLINE | NA | OK | OK | OK | i:OK | i:OK | OK | OK |
| POLYLINE | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| POLYLINE2D | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| POLYLINE3D | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| SPLINE | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| HELIX | NA | NA | NA | NA | i:OK | i:OK | OK | OK |
| TEXT | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| MTEXT | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| ATTDEF | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| INSERT | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| MINSERT | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| ATTRIB | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| DIM_LINEAR | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| DIM_ALIGNED | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| DIM_RADIUS | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| DIM_DIAMETER | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| DIM_ANGULAR2 | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| DIM_ANGULAR3 | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| DIM_ORDINATE | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| DIM_ARC | NA | NA | NA | OK | i:OK | i:OK | OK | OK |
| DIM_JOGGED | NA | NA | NA | OK | i:OK | i:OK | OK | OK |
| SOLID | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| 3DFACE | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| HATCH_SOLID | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| HATCH_PATTERN | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| LEADER | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| MULTILEADER | NA | NA | NA | NA | i:OK | i:OK | OK | OK |
| MLINE | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| TOLERANCE | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| POLYFACE | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| POLYGON_MESH | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| MESH | NA | NA | NA | NA | NA | i:OK | OK | OK |
| WIPEOUT | NA | OK | OK | OK | i:OK | i:OK | OK | OK |
| TABLE | NA | NA | NA | OK | i:OK | i:OK | OK | OK |
| 3DSOLID_BOX | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| 3DSOLID_CYLINDER | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| 3DSOLID_CONE | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| 3DSOLID_SPHERE | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| 3DSOLID_TORUS | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| 3DSOLID_WEDGE | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| 3DSOLID_PYRAMID | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| REGION | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| BODY | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| SURFACE_GENERIC | NA | NA | NA | NA | i:OK | i:OK | OK | OK |
| SURFACE_PLANE | NA | NA | NA | NA | i:OK | i:OK | OK | OK |
| SURFACE_EXTRUDED | NA | NA | NA | NA | i:OK | i:OK | OK | OK |
| SURFACE_LOFTED | NA | NA | NA | NA | i:OK | i:OK | OK | OK |
| SURFACE_REVOLVED | NA | NA | NA | NA | i:OK | i:OK | OK | OK |
| SURFACE_SWEPT | NA | NA | NA | NA | i:OK | i:OK | OK | OK |
| SURFACE_NURB | NA | NA | NA | NA | i:BLOCKED | i:BLOCKED | OK | OK |
| LIGHT_POINT | NA | NA | NA | NA | i:OK | i:OK | OK | OK |
| LIGHT_SPOT | NA | NA | NA | NA | i:OK | i:OK | OK | OK |
| LIGHT_DISTANT | NA | NA | NA | NA | i:OK | i:OK | OK | OK |
| SHAPE | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| IMAGE | NA | OK | OK | OK | i:OK | i:OK | OK | OK |
| PDFUNDERLAY | NA | NA | NA | NA | NA | i:OK | OK | OK |
| DWFUNDERLAY | NA | NA | NA | NA | i:OK | i:OK | OK | OK |
| DGNUNDERLAY | NA | NA | NA | NA | i:OK | i:OK | OK | OK |
| CAMERA | NA | NA | NA | NA | i:PROXY | i:PROXY | PROXY | PROXY |
| SECTIONOBJECT | NA | NA | NA | NA | i:OK | i:OK | OK | OK |
| RTEXT | NA | PROXY | PROXY | PROXY | i:PROXY | i:PROXY | PROXY | PROXY |
| POSITIONMARKER | NA | NA | NA | NA | NA | NA | OK | OK |
| ARCALIGNEDTEXT | NA | PROXY | PROXY | PROXY | i:PROXY | i:PROXY | PROXY | PROXY |
| VIEWPORT | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| RAY | OK | OK | OK | OK | i:OK | i:OK | OK | OK |
| XLINE | OK | OK | OK | OK | i:OK | i:OK | OK | OK |

## ACAD2027 / dxf_ascii

| Entity | AC1012 | AC1014 | AC1015 | AC1018 | AC1021 | AC1024 | AC1027 | AC1032 |
|---|---|---|---|---|---|---|---|---|
| POINT | OK | OK | OK | OK | OK | OK | OK | OK |
| LINE | OK | OK | OK | OK | OK | OK | OK | OK |
| CIRCLE | OK | OK | OK | OK | OK | OK | OK | OK |
| ARC | OK | OK | OK | OK | OK | OK | OK | OK |
| ELLIPSE | OK | OK | OK | OK | OK | OK | OK | OK |
| LWPOLYLINE | NA | OK | OK | OK | OK | OK | OK | OK |
| POLYLINE | OK | OK | OK | OK | OK | OK | OK | OK |
| POLYLINE2D | OK | OK | OK | OK | OK | OK | OK | OK |
| POLYLINE3D | OK | OK | OK | OK | OK | OK | OK | OK |
| SPLINE | OK | OK | OK | OK | OK | OK | OK | OK |
| HELIX | NA | NA | NA | NA | OK | OK | OK | OK |
| TEXT | OK | OK | OK | OK | OK | OK | OK | OK |
| MTEXT | OK | OK | OK | OK | OK | OK | OK | OK |
| ATTDEF | OK | OK | OK | OK | OK | OK | OK | OK |
| INSERT | OK | OK | OK | OK | OK | OK | OK | OK |
| MINSERT | OK | OK | OK | OK | OK | OK | OK | OK |
| ATTRIB | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_LINEAR | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ALIGNED | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_RADIUS | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_DIAMETER | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ANGULAR2 | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ANGULAR3 | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ORDINATE | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ARC | NA | NA | NA | OK | OK | OK | OK | OK |
| DIM_JOGGED | NA | NA | NA | OK | OK | OK | OK | OK |
| SOLID | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DFACE | OK | OK | OK | OK | OK | OK | OK | OK |
| HATCH_SOLID | OK | OK | OK | OK | OK | OK | OK | OK |
| HATCH_PATTERN | OK | OK | OK | OK | OK | OK | OK | OK |
| LEADER | OK | OK | OK | OK | OK | OK | OK | OK |
| MULTILEADER | NA | NA | NA | NA | OK | OK | OK | OK |
| MLINE | OK | OK | OK | OK | OK | OK | OK | OK |
| TOLERANCE | OK | OK | OK | OK | OK | OK | OK | OK |
| POLYFACE | OK | OK | OK | OK | OK | OK | OK | OK |
| POLYGON_MESH | OK | OK | OK | OK | OK | OK | OK | OK |
| MESH | NA | NA | NA | NA | NA | OK | OK | OK |
| WIPEOUT | NA | OK | OK | PROXY | PROXY | PROXY | PROXY | OK |
| TABLE | NA | NA | NA | OK | OK | OK | OK | OK |
| 3DSOLID_BOX | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_CYLINDER | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_CONE | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_SPHERE | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_TORUS | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_WEDGE | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_PYRAMID | OK | OK | OK | OK | OK | OK | OK | OK |
| REGION | OK | OK | OK | OK | OK | OK | OK | OK |
| BODY | OK | OK | OK | OK | OK | OK | OK | OK |
| SURFACE_GENERIC | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_PLANE | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_EXTRUDED | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_LOFTED | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_REVOLVED | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_SWEPT | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_NURB | NA | NA | NA | NA | OK | OK | OK | OK |
| LIGHT_POINT | NA | NA | NA | NA | PROXY | PROXY | PROXY | OK |
| LIGHT_SPOT | NA | NA | NA | NA | PROXY | PROXY | PROXY | OK |
| LIGHT_DISTANT | NA | NA | NA | NA | PROXY | PROXY | PROXY | OK |
| SHAPE | OK | OK | OK | OK | OK | OK | OK | OK |
| IMAGE | NA | OK | OK | PROXY | PROXY | PROXY | PROXY | OK |
| PDFUNDERLAY | NA | NA | NA | NA | NA | OK | OK | OK |
| DWFUNDERLAY | NA | NA | NA | NA | OK | OK | OK | OK |
| DGNUNDERLAY | NA | NA | NA | NA | OK | OK | OK | OK |
| CAMERA | NA | NA | NA | NA | PROXY | PROXY | PROXY | OK |
| SECTIONOBJECT | NA | NA | NA | NA | OK | OK | OK | OK |
| RTEXT | NA | PROXY | PROXY | PROXY | PROXY | PROXY | PROXY | OK |
| POSITIONMARKER | NA | NA | NA | NA | NA | NA | OK | OK |
| ARCALIGNEDTEXT | NA | PROXY | PROXY | PROXY | PROXY | PROXY | PROXY | OK |
| VIEWPORT | OK | OK | OK | OK | OK | OK | OK | OK |
| RAY | OK | OK | OK | OK | OK | OK | OK | OK |
| XLINE | OK | OK | OK | OK | OK | OK | OK | OK |

## ACAD2027 / dxf_binary

| Entity | AC1012 | AC1014 | AC1015 | AC1018 | AC1021 | AC1024 | AC1027 | AC1032 |
|---|---|---|---|---|---|---|---|---|
| POINT | OK | OK | OK | OK | OK | OK | OK | OK |
| LINE | OK | OK | OK | OK | OK | OK | OK | OK |
| CIRCLE | OK | OK | OK | OK | OK | OK | OK | OK |
| ARC | OK | OK | OK | OK | OK | OK | OK | OK |
| ELLIPSE | OK | OK | OK | OK | OK | OK | OK | OK |
| LWPOLYLINE | NA | OK | OK | OK | OK | OK | OK | OK |
| POLYLINE | OK | OK | OK | OK | OK | OK | OK | OK |
| POLYLINE2D | OK | OK | OK | OK | OK | OK | OK | OK |
| POLYLINE3D | OK | OK | OK | OK | OK | OK | OK | OK |
| SPLINE | OK | OK | OK | OK | OK | OK | OK | OK |
| HELIX | NA | NA | NA | NA | OK | OK | OK | OK |
| TEXT | OK | OK | OK | OK | OK | OK | OK | OK |
| MTEXT | OK | OK | OK | OK | OK | OK | OK | OK |
| ATTDEF | OK | OK | OK | OK | OK | OK | OK | OK |
| INSERT | OK | OK | OK | OK | OK | OK | OK | OK |
| MINSERT | OK | OK | OK | OK | OK | OK | OK | OK |
| ATTRIB | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_LINEAR | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ALIGNED | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_RADIUS | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_DIAMETER | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ANGULAR2 | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ANGULAR3 | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ORDINATE | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ARC | NA | NA | NA | OK | OK | OK | OK | OK |
| DIM_JOGGED | NA | NA | NA | OK | OK | OK | OK | OK |
| SOLID | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DFACE | OK | OK | OK | OK | OK | OK | OK | OK |
| HATCH_SOLID | OK | OK | OK | OK | OK | OK | OK | OK |
| HATCH_PATTERN | OK | OK | OK | OK | OK | OK | OK | OK |
| LEADER | OK | OK | OK | OK | OK | OK | OK | OK |
| MULTILEADER | NA | NA | NA | NA | OK | OK | OK | OK |
| MLINE | OK | OK | OK | OK | OK | OK | OK | OK |
| TOLERANCE | OK | OK | OK | OK | OK | OK | OK | OK |
| POLYFACE | OK | OK | OK | OK | OK | OK | OK | OK |
| POLYGON_MESH | OK | OK | OK | OK | OK | OK | OK | OK |
| MESH | NA | NA | NA | NA | NA | OK | OK | OK |
| WIPEOUT | NA | OK | OK | PROXY | PROXY | PROXY | PROXY | OK |
| TABLE | NA | NA | NA | OK | OK | OK | OK | OK |
| 3DSOLID_BOX | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_CYLINDER | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_CONE | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_SPHERE | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_TORUS | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_WEDGE | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_PYRAMID | OK | OK | OK | OK | OK | OK | OK | OK |
| REGION | OK | OK | OK | OK | OK | OK | OK | OK |
| BODY | OK | OK | OK | OK | OK | OK | OK | OK |
| SURFACE_GENERIC | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_PLANE | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_EXTRUDED | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_LOFTED | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_REVOLVED | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_SWEPT | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_NURB | NA | NA | NA | NA | OK | OK | OK | OK |
| LIGHT_POINT | NA | NA | NA | NA | PROXY | PROXY | PROXY | OK |
| LIGHT_SPOT | NA | NA | NA | NA | PROXY | PROXY | PROXY | OK |
| LIGHT_DISTANT | NA | NA | NA | NA | PROXY | PROXY | PROXY | OK |
| SHAPE | OK | OK | OK | OK | OK | OK | OK | OK |
| IMAGE | NA | OK | OK | PROXY | PROXY | PROXY | PROXY | OK |
| PDFUNDERLAY | NA | NA | NA | NA | NA | OK | OK | OK |
| DWFUNDERLAY | NA | NA | NA | NA | OK | OK | OK | OK |
| DGNUNDERLAY | NA | NA | NA | NA | OK | OK | OK | OK |
| CAMERA | NA | NA | NA | NA | PROXY | PROXY | PROXY | OK |
| SECTIONOBJECT | NA | NA | NA | NA | OK | OK | OK | OK |
| RTEXT | NA | PROXY | PROXY | PROXY | PROXY | PROXY | PROXY | OK |
| POSITIONMARKER | NA | NA | NA | NA | NA | NA | OK | OK |
| ARCALIGNEDTEXT | NA | PROXY | PROXY | PROXY | PROXY | PROXY | PROXY | OK |
| VIEWPORT | OK | OK | OK | OK | OK | OK | OK | OK |
| RAY | OK | OK | OK | OK | OK | OK | OK | OK |
| XLINE | OK | OK | OK | OK | OK | OK | OK | OK |

## BCAD / dwg

| Entity | AC1012 | AC1014 | AC1015 | AC1018 | AC1021 | AC1024 | AC1027 | AC1032 |
|---|---|---|---|---|---|---|---|---|
| POINT | OK | OK | OK | OK | OK | OK | OK | OK |
| LINE | OK | OK | OK | OK | OK | OK | OK | OK |
| CIRCLE | OK | OK | OK | OK | OK | OK | OK | OK |
| ARC | OK | OK | OK | OK | OK | OK | OK | OK |
| ELLIPSE | OK | OK | OK | OK | OK | OK | OK | OK |
| LWPOLYLINE | NA | OK | OK | OK | OK | OK | OK | OK |
| POLYLINE | OK | OK | OK | OK | OK | OK | OK | OK |
| POLYLINE2D | OK | OK | OK | OK | OK | OK | OK | OK |
| POLYLINE3D | OK | OK | OK | OK | OK | OK | OK | OK |
| SPLINE | OK | OK | OK | OK | OK | OK | OK | OK |
| HELIX | NA | NA | NA | NA | OK | OK | OK | OK |
| TEXT | OK | OK | OK | OK | OK | OK | OK | OK |
| MTEXT | OK | OK | OK | OK | OK | OK | OK | OK |
| ATTDEF | OK | OK | OK | OK | OK | OK | OK | OK |
| INSERT | OK | OK | OK | OK | OK | OK | OK | OK |
| MINSERT | OK | OK | OK | OK | OK | OK | OK | OK |
| ATTRIB | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_LINEAR | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ALIGNED | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_RADIUS | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_DIAMETER | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ANGULAR2 | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ANGULAR3 | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ORDINATE | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ARC | NA | NA | NA | OK | OK | OK | OK | OK |
| DIM_JOGGED | NA | NA | NA | OK | OK | OK | OK | OK |
| SOLID | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DFACE | OK | OK | OK | OK | OK | OK | OK | OK |
| HATCH_SOLID | OK | OK | OK | OK | OK | OK | OK | OK |
| HATCH_PATTERN | OK | OK | OK | OK | OK | OK | OK | OK |
| LEADER | OK | OK | OK | OK | OK | OK | OK | OK |
| MULTILEADER | NA | NA | NA | NA | OK | OK | OK | OK |
| MLINE | OK | OK | OK | OK | OK | OK | OK | OK |
| TOLERANCE | OK | OK | OK | OK | OK | OK | OK | OK |
| POLYFACE | OK | OK | OK | OK | OK | OK | OK | OK |
| POLYGON_MESH | OK | OK | OK | OK | OK | OK | OK | OK |
| MESH | NA | NA | NA | NA | NA | OK | OK | OK |
| WIPEOUT | NA | OK | OK | OK | OK | OK | OK | OK |
| TABLE | NA | NA | NA | OK | OK | OK | OK | OK |
| 3DSOLID_BOX | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_CYLINDER | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_CONE | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_SPHERE | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_TORUS | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_WEDGE | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_PYRAMID | OK | OK | OK | OK | OK | OK | OK | OK |
| REGION | OK | OK | OK | OK | OK | OK | OK | OK |
| BODY | OK | OK | OK | OK | OK | OK | OK | OK |
| SURFACE_GENERIC | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_PLANE | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_EXTRUDED | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_LOFTED | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_REVOLVED | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_SWEPT | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_NURB | NA | NA | NA | NA | OK | OK | OK | OK |
| LIGHT_POINT | NA | NA | NA | NA | OK | OK | OK | OK |
| LIGHT_SPOT | NA | NA | NA | NA | OK | OK | OK | OK |
| LIGHT_DISTANT | NA | NA | NA | NA | OK | OK | OK | OK |
| SHAPE | OK | OK | OK | OK | OK | OK | OK | OK |
| IMAGE | NA | OK | OK | OK | OK | OK | OK | OK |
| PDFUNDERLAY | NA | NA | NA | NA | NA | OK | OK | OK |
| DWFUNDERLAY | NA | NA | NA | NA | OK | OK | OK | OK |
| DGNUNDERLAY | NA | NA | NA | NA | OK | OK | OK | OK |
| CAMERA | NA | NA | NA | NA | OK | OK | OK | OK |
| SECTIONOBJECT | NA | NA | NA | NA | OK | OK | OK | OK |
| RTEXT | NA | PROXY | PROXY | PROXY | PROXY | PROXY | PROXY | PROXY |
| POSITIONMARKER | NA | NA | NA | NA | NA | NA | OK | OK |
| ARCALIGNEDTEXT | NA | OK | OK | OK | OK | OK | OK | OK |
| VIEWPORT | OK | OK | OK | OK | OK | OK | OK | OK |
| RAY | OK | OK | OK | OK | OK | OK | OK | OK |
| XLINE | OK | OK | OK | OK | OK | OK | OK | OK |

## BCAD / dxf_ascii

| Entity | AC1012 | AC1014 | AC1015 | AC1018 | AC1021 | AC1024 | AC1027 | AC1032 |
|---|---|---|---|---|---|---|---|---|
| POINT | OK | OK | OK | OK | OK | OK | OK | OK |
| LINE | OK | OK | OK | OK | OK | OK | OK | OK |
| CIRCLE | OK | OK | OK | OK | OK | OK | OK | OK |
| ARC | OK | OK | OK | OK | OK | OK | OK | OK |
| ELLIPSE | OK | OK | OK | OK | OK | OK | OK | OK |
| LWPOLYLINE | NA | OK | OK | OK | OK | OK | OK | OK |
| POLYLINE | OK | OK | OK | OK | OK | OK | OK | OK |
| POLYLINE2D | OK | OK | OK | OK | OK | OK | OK | OK |
| POLYLINE3D | OK | OK | OK | OK | OK | OK | OK | OK |
| SPLINE | OK | OK | OK | OK | OK | OK | OK | OK |
| HELIX | NA | NA | NA | NA | OK | OK | OK | OK |
| TEXT | OK | OK | OK | OK | OK | OK | OK | OK |
| MTEXT | OK | OK | OK | OK | OK | OK | OK | OK |
| ATTDEF | OK | OK | OK | OK | OK | OK | OK | OK |
| INSERT | OK | OK | OK | OK | OK | OK | OK | OK |
| MINSERT | OK | OK | OK | OK | OK | OK | OK | OK |
| ATTRIB | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_LINEAR | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ALIGNED | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_RADIUS | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_DIAMETER | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ANGULAR2 | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ANGULAR3 | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ORDINATE | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ARC | NA | NA | NA | OK | OK | OK | OK | OK |
| DIM_JOGGED | NA | NA | NA | OK | OK | OK | OK | OK |
| SOLID | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DFACE | OK | OK | OK | OK | OK | OK | OK | OK |
| HATCH_SOLID | OK | OK | OK | OK | OK | OK | OK | OK |
| HATCH_PATTERN | OK | OK | OK | OK | OK | OK | OK | OK |
| LEADER | OK | OK | OK | OK | OK | OK | OK | OK |
| MULTILEADER | NA | NA | NA | NA | OK | OK | OK | OK |
| MLINE | OK | OK | OK | OK | OK | OK | OK | OK |
| TOLERANCE | OK | OK | OK | OK | OK | OK | OK | OK |
| POLYFACE | OK | OK | OK | OK | OK | OK | OK | OK |
| POLYGON_MESH | OK | OK | OK | OK | OK | OK | OK | OK |
| MESH | NA | NA | NA | NA | NA | OK | OK | OK |
| WIPEOUT | NA | OK | OK | OK | OK | OK | OK | OK |
| TABLE | NA | NA | NA | OK | OK | OK | OK | OK |
| 3DSOLID_BOX | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_CYLINDER | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_CONE | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_SPHERE | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_TORUS | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_WEDGE | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_PYRAMID | OK | OK | OK | OK | OK | OK | OK | OK |
| REGION | OK | OK | OK | OK | OK | OK | OK | OK |
| BODY | OK | OK | OK | OK | OK | OK | OK | OK |
| SURFACE_GENERIC | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_PLANE | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_EXTRUDED | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_LOFTED | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_REVOLVED | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_SWEPT | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_NURB | NA | NA | NA | NA | OK | OK | OK | OK |
| LIGHT_POINT | NA | NA | NA | NA | OK | OK | OK | OK |
| LIGHT_SPOT | NA | NA | NA | NA | OK | OK | OK | OK |
| LIGHT_DISTANT | NA | NA | NA | NA | OK | OK | OK | OK |
| SHAPE | OK | OK | OK | OK | OK | OK | OK | OK |
| IMAGE | NA | OK | OK | OK | OK | OK | OK | OK |
| PDFUNDERLAY | NA | NA | NA | NA | NA | OK | OK | OK |
| DWFUNDERLAY | NA | NA | NA | NA | OK | OK | OK | OK |
| DGNUNDERLAY | NA | NA | NA | NA | OK | OK | OK | OK |
| CAMERA | NA | NA | NA | NA | OK | OK | OK | OK |
| SECTIONOBJECT | NA | NA | NA | NA | OK | OK | OK | OK |
| RTEXT | NA | PROXY | PROXY | PROXY | PROXY | PROXY | PROXY | PROXY |
| POSITIONMARKER | NA | NA | NA | NA | NA | NA | OK | OK |
| ARCALIGNEDTEXT | NA | OK | OK | OK | OK | OK | OK | OK |
| VIEWPORT | OK | OK | OK | OK | OK | OK | OK | OK |
| RAY | OK | OK | OK | OK | OK | OK | OK | OK |
| XLINE | OK | OK | OK | OK | OK | OK | OK | OK |

## BCAD / dxf_binary

| Entity | AC1012 | AC1014 | AC1015 | AC1018 | AC1021 | AC1024 | AC1027 | AC1032 |
|---|---|---|---|---|---|---|---|---|
| POINT | OK | OK | OK | OK | OK | OK | OK | OK |
| LINE | OK | OK | OK | OK | OK | OK | OK | OK |
| CIRCLE | OK | OK | OK | OK | OK | OK | OK | OK |
| ARC | OK | OK | OK | OK | OK | OK | OK | OK |
| ELLIPSE | OK | OK | OK | OK | OK | OK | OK | OK |
| LWPOLYLINE | NA | OK | OK | OK | OK | OK | OK | OK |
| POLYLINE | OK | OK | OK | OK | OK | OK | OK | OK |
| POLYLINE2D | OK | OK | OK | OK | OK | OK | OK | OK |
| POLYLINE3D | OK | OK | OK | OK | OK | OK | OK | OK |
| SPLINE | OK | OK | OK | OK | OK | OK | OK | OK |
| HELIX | NA | NA | NA | NA | OK | OK | OK | OK |
| TEXT | OK | OK | OK | OK | OK | OK | OK | OK |
| MTEXT | OK | OK | OK | OK | OK | OK | OK | OK |
| ATTDEF | OK | OK | OK | OK | OK | OK | OK | OK |
| INSERT | OK | OK | OK | OK | OK | OK | OK | OK |
| MINSERT | OK | OK | OK | OK | OK | OK | OK | OK |
| ATTRIB | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_LINEAR | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ALIGNED | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_RADIUS | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_DIAMETER | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ANGULAR2 | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ANGULAR3 | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ORDINATE | OK | OK | OK | OK | OK | OK | OK | OK |
| DIM_ARC | NA | NA | NA | OK | OK | OK | OK | OK |
| DIM_JOGGED | NA | NA | NA | OK | OK | OK | OK | OK |
| SOLID | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DFACE | OK | OK | OK | OK | OK | OK | OK | OK |
| HATCH_SOLID | OK | OK | OK | OK | OK | OK | OK | OK |
| HATCH_PATTERN | OK | OK | OK | OK | OK | OK | OK | OK |
| LEADER | OK | OK | OK | OK | OK | OK | OK | OK |
| MULTILEADER | NA | NA | NA | NA | OK | OK | OK | OK |
| MLINE | OK | OK | OK | OK | OK | OK | OK | OK |
| TOLERANCE | OK | OK | OK | OK | OK | OK | OK | OK |
| POLYFACE | OK | OK | OK | OK | OK | OK | OK | OK |
| POLYGON_MESH | OK | OK | OK | OK | OK | OK | OK | OK |
| MESH | NA | NA | NA | NA | NA | OK | OK | OK |
| WIPEOUT | NA | OK | OK | OK | OK | OK | OK | OK |
| TABLE | NA | NA | NA | OK | OK | OK | OK | OK |
| 3DSOLID_BOX | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_CYLINDER | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_CONE | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_SPHERE | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_TORUS | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_WEDGE | OK | OK | OK | OK | OK | OK | OK | OK |
| 3DSOLID_PYRAMID | OK | OK | OK | OK | OK | OK | OK | OK |
| REGION | OK | OK | OK | OK | OK | OK | OK | OK |
| BODY | OK | OK | OK | OK | OK | OK | OK | OK |
| SURFACE_GENERIC | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_PLANE | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_EXTRUDED | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_LOFTED | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_REVOLVED | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_SWEPT | NA | NA | NA | NA | OK | OK | OK | OK |
| SURFACE_NURB | NA | NA | NA | NA | OK | OK | OK | OK |
| LIGHT_POINT | NA | NA | NA | NA | OK | OK | OK | OK |
| LIGHT_SPOT | NA | NA | NA | NA | OK | OK | OK | OK |
| LIGHT_DISTANT | NA | NA | NA | NA | OK | OK | OK | OK |
| SHAPE | OK | OK | OK | OK | OK | OK | OK | OK |
| IMAGE | NA | OK | OK | OK | OK | OK | OK | OK |
| PDFUNDERLAY | NA | NA | NA | NA | NA | OK | OK | OK |
| DWFUNDERLAY | NA | NA | NA | NA | OK | OK | OK | OK |
| DGNUNDERLAY | NA | NA | NA | NA | OK | OK | OK | OK |
| CAMERA | NA | NA | NA | NA | OK | OK | OK | OK |
| SECTIONOBJECT | NA | NA | NA | NA | OK | OK | OK | OK |
| RTEXT | NA | PROXY | PROXY | PROXY | PROXY | PROXY | PROXY | PROXY |
| POSITIONMARKER | NA | NA | NA | NA | NA | NA | OK | OK |
| ARCALIGNEDTEXT | NA | OK | OK | OK | OK | OK | OK | OK |
| VIEWPORT | OK | OK | OK | OK | OK | OK | OK | OK |
| RAY | OK | OK | OK | OK | OK | OK | OK | OK |
| XLINE | OK | OK | OK | OK | OK | OK | OK | OK |

## Structural And Unsynthesized Entities

| Entity/API Family | AC1012 | AC1014 | AC1015 | AC1018 | AC1021 | AC1024 | AC1027 | AC1032 | Coverage/Requirement |
|---|---|---|---|---|---|---|---|---|---|
| BLOCK / ENDBLK | INDIRECT | INDIRECT | INDIRECT | INDIRECT | INDIRECT | INDIRECT | INDIRECT | INDIRECT | INSERT, MINSERT, ATTRIB and TABLE ownership; not separate graphical cases |
| VERTEX / SEQEND | INDIRECT | INDIRECT | INDIRECT | INDIRECT | INDIRECT | INDIRECT | INDIRECT | INDIRECT | Polyline2D/3D, polygon/polyface meshes and INSERT attributes |
| OLE2FRAME / OLEFRAME | UT | UT | UT | UT | UT | UT | UT | UT | Embedded OLE application payload required |
| SECTIONLINE / DRAWINGVIEW | UT | UT | UT | UT | UT | UT | UT | UT | SectionSymbol/ViewBorder require a model-documentation object graph |
| ACDBPOINTCLOUD / ACDBPOINTCLOUDEX | UT | UT | UT | UT | UT | UT | UT | UT | External indexed point-cloud data required |
| COORDINATION_MODEL | UT | UT | UT | UT | UT | UT | UT | UT | External coordination-model data required |
| LAYOUTPRINTCONFIG / Format | UT | UT | UT | UT | UT | UT | UT | UT | Structured extended entity, no independent fixture |
| ACAD_PROXY_ENTITY / RegisteredClass / Unknown | UT | UT | UT | UT | UT | UT | UT | UT | Caller-supplied class/payload; cannot certify arbitrary third-party records |
| REPEAT / ENDREP / LOAD / JUMP | NA | NA | NA | NA | NA | NA | NA | NA | Legacy pre-R13 records, outside supported output versions |
| ALIGNMENTPARAMETERENTITY | UT | UT | UT | UT | UT | UT | UT | UT | Dynamic-block parameter/grip graph required |
| BASEPOINTPARAMETERENTITY | UT | UT | UT | UT | UT | UT | UT | UT | Dynamic-block parameter/grip graph required |
| BLOCKANGULARCONSTRAINTPARAMETERENTITY | UT | UT | UT | UT | UT | UT | UT | UT | Dynamic-block parameter/grip graph required |
| FLIPGRIPENTITY | UT | UT | UT | UT | UT | UT | UT | UT | Dynamic-block parameter/grip graph required |
| FLIPPARAMETERENTITY | UT | UT | UT | UT | UT | UT | UT | UT | Dynamic-block parameter/grip graph required |
| LINEARGRIPENTITY | UT | UT | UT | UT | UT | UT | UT | UT | Dynamic-block parameter/grip graph required |
| LINEARPARAMETERENTITY | UT | UT | UT | UT | UT | UT | UT | UT | Dynamic-block parameter/grip graph required |
| POINTPARAMETERENTITY | UT | UT | UT | UT | UT | UT | UT | UT | Dynamic-block parameter/grip graph required |
| POLARGRIPENTITY | UT | UT | UT | UT | UT | UT | UT | UT | Dynamic-block parameter/grip graph required |
| ROTATIONGRIPENTITY | UT | UT | UT | UT | UT | UT | UT | UT | Dynamic-block parameter/grip graph required |
| ROTATIONPARAMETERENTITY | UT | UT | UT | UT | UT | UT | UT | UT | Dynamic-block parameter/grip graph required |
| VISIBILITYGRIPENTITY | UT | UT | UT | UT | UT | UT | UT | UT | Dynamic-block parameter/grip graph required |
| VISIBILITYPARAMETERENTITY | UT | UT | UT | UT | UT | UT | UT | UT | Dynamic-block parameter/grip graph required |
| XYGRIPENTITY | UT | UT | UT | UT | UT | UT | UT | UT | Dynamic-block parameter/grip graph required |
| XYPARAMETERENTITY | UT | UT | UT | UT | UT | UT | UT | UT | Dynamic-block parameter/grip graph required |

## Public Entity API Checklist

- [x] Point: POINT
- [x] Line: LINE
- [x] Circle: CIRCLE
- [x] Arc: ARC
- [x] Ellipse: ELLIPSE
- [x] Polyline: POLYLINE
- [x] Polyline2D: POLYLINE2D
- [x] Polyline3D: POLYLINE3D
- [x] LwPolyline: LWPOLYLINE
- [x] Text: TEXT
- [x] MText: MTEXT
- [x] Spline: SPLINE
- [x] Helix: HELIX
- [x] Dimension: DIM_* (9 cases)
- [x] Hatch: HATCH_SOLID / HATCH_PATTERN
- [x] Solid: SOLID
- [x] Face3D: 3DFACE
- [x] Insert: INSERT / MINSERT / ATTRIB
- [x] Block: BLOCK (indirect)
- [x] BlockEnd: ENDBLK (indirect)
- [x] Ray: RAY
- [x] XLine: XLINE
- [x] Viewport: VIEWPORT
- [x] AttributeDefinition: ATTDEF
- [x] AttributeEntity: ATTRIB
- [x] Leader: LEADER
- [x] MultiLeader: MULTILEADER
- [x] MLine: MLINE
- [x] Mesh: MESH
- [x] RasterImage: IMAGE
- [x] Solid3D: 3DSOLID_* (7 cases)
- [x] Region: REGION
- [x] Body: BODY
- [x] Surface: SURFACE_* (7 cases)
- [x] Table: TABLE
- [x] Tolerance: TOLERANCE
- [x] PolyfaceMesh: POLYFACE
- [x] Wipeout: WIPEOUT
- [x] Shape: SHAPE
- [x] Underlay: PDFUNDERLAY / DWFUNDERLAY / DGNUNDERLAY
- [x] Seqend: SEQEND (indirect)
- [x] Ole2Frame: UT
- [x] PolygonMesh: POLYGON_MESH
- [x] Light: LIGHT_* (3 cases)
- [x] SectionSymbol: UT
- [x] ViewBorder: UT
- [x] Extended: CAMERA / SECTIONOBJECT / RTEXT / POSITIONMARKER / ARCALIGNEDTEXT plus the unsynthesized families above
- [x] Unknown: UT

Checkboxes mean cataloged, not compatible. UT/NA and proxy/failure cells remain unresolved.

Rebuild: `scripts/entity_status_matrix.ps1`. The standard entity-version-controls and entity-matrix-isolated* corpora are discovered automatically; pass `-IsolatedRoots` to select explicit corpora. Regenerate and validate isolated drawings when changing the writer. Machine-readable cell data and evidence hashes are in `entity_status_matrix.json` beside this document.

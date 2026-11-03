# Native Surface Fixtures

`native_surfaces.dwg` was authored through AutoCAD 2027 Core Console on 2026-09-10 and saved as AC1021. No third-party drawing data is included. Native AUDIT reported zero errors.

The four REF_* layers contain EXTRUDEDSURFACE, LOFTEDSURFACE, REVOLVEDSURFACE and SWEPTSURFACE examples. The atlas reads their modeler geometry and construction parameters, resets database ownership, then translates each surface to its numbered position. It does not copy the source drawing's object graph or substitute a generic surface.

Authoring commands, with `SURFACEASSOCIATIVITY=0` and `DELOBJ=1`:

- EXTRUDE a line from `(20,20,0)` to `(80,20,0)` by 40.
- LOFT between that line and a line from `(25,55,35)` to `(75,55,35)` using the default cross-sections-only options.
- REVOLVE a line from `(60,40,0)` to `(60,40,40)` by 180 degrees about the axis from `(40,40,0)` to `(40,40,40)`.
- SWEEP a line from `(20,20,0)` to `(60,20,0)` along a line from `(20,20,0)` to `(20,60,40)` using the default alignment.

The retained path LINE is not an atlas case. Embedded profiles are preserved as opaque bodies when the library cannot re-encode their meaningful bits exactly. Audit and native type presence do not certify editing history or geometric equivalence for arbitrary surfaces.

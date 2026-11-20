# Fixture provenance

## bambu-cube.3mf / bambu-cube.gcode.3mf

- Upstream: `ichris97/multimaterial-3d-printing`, commit
  `c6d883218c7dc32cca5946c8dcff53450cc0bbd6`
  (`https://github.com/ichris97/multimaterial-3d-printing`), paths
  `samples/inputs/Cube.3mf` and `samples/inputs/Cube.gcode.3mf`.
- License: MIT, copyright (c) 2024 Ioannis Christodoulou. The verbatim license
  text ships beside these fixtures as `SAMPLES-LICENSE` and must accompany any
  copy of the fixture bytes.
- Both containers were produced by BambuStudio 02.04.00.70 (embedded 3MF
  metadata, creation date 2025-12-19). `bambu-cube.gcode.3mf` is the sliced
  variant: it embeds `Metadata/plate_1.gcode` (114 layers, G2/G3 arcs with XY
  IJ centres and helical `G3 Z… I… J… P1` moves). `bambu-cube.3mf` is the same
  model without plate G-code, used to prove the model-only route keeps the
  geometry viewer.
- Role: read-only parser test inputs; no license is asserted or granted beyond
  the upstream MIT terms.

Other fixtures (`cube20.stl`, `fdm-cube20.gcode`, `fdm-plate-two-solids.gcode`,
`sla-cube20.ctb`) predate this change and are covered by the FloePrintKit
predevelopment package records.

## cad-child-2mm-box.gcode

Floe-owned reproduction from the CAD→Print registered-tools contract run
(2026-11-21): a 2 mm box sliced at 0.25 mm layer height by the internal FDM
adapter (result asset SHA256
`a21edf6c961a061627883a4fd81fe9d110914bf236bc79729a682b72b7e822ee`). Eight printing
heights (0.255…2.005 mm) plus z-hops; used to prove Z-only layer moves advance
the parser's coordinate state (8 layers, not 1).

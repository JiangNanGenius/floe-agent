# Offline printing qualification

R10 source-only update: adapter p0-2 adds an owned mesh snapshot, explicit Float32 precision rejection and locked FDM geometry options. The new `EngineJS/node/mesh-fidelity.test.mjs`, an additional host-contract case and a native STL-plane case are provided for mainline execution. None has run in R10. Counts/results below describe the frozen 2026-11-03 baseline only; commands are future qualification instructions, not current evidence.

This standalone host does not modify the production App. Node executes the real pinned Kiri FDM/CTB pipeline; an independent Go decoder reads every CTB layer and a separate Python state reader checks G-code movements. These runtime results do not assert an implemented iPad WebKit bridge or physical printer execution.

From repository root:

```sh
node FloeAgent/Qualification/Printing/EngineJS/node/run-slices.mjs <output-directory>
node --test FloeAgent/Qualification/Printing/EngineJS/node/host-contract.test.mjs
```

Inputs are original synthetic 20 mm cube and two-solid plate fixtures. Settings are owned, immutable generic profiles; unknown overrides, scripts, unsupported formats, invalid geometry and concurrent use are rejected. Output is staged, read back and hashed before publication in the output directory. Current limits are one million triangles, 64 MiB G-code and 128 MiB resin output. Binary writer peak memory remains an iPad qualification item.

The Go module in `Validation/` pins MIT `github.com/ezrec/uv3dp v1.2.12` as a **qualification-only independent decoder**, not as a maintained production engine. Keep its lock; use a task-specific GOCACHE/GOMODCACHE and `GOMAXPROCS=6`:

```sh
go run . <output-directory>/sla-cube20.ctb <readback-directory>
```

Run that command from `Validation/`. It decodes all 200 layers, exposure/motion/size metadata, lit-pixel bounds and volume, and writes first/middle/last PNGs. Then, from repository root:

```sh
python3 FloeAgent/Qualification/Printing/Validation/inspect_outputs.py <output-directory> <preview-directory> <readback-directory>
```

The Python tool needs Pillow for review PNGs. It does not load any Kiri writer/reader. Assertions check bed bounds, 100/60 FDM layers at 0.2 mm, 200/60 °C settings, CTB dimensions/exposures, every raster's exact nonzero bounds and no stray pixels. Its numeric checks are tied to the supplied fixtures, not a claim about arbitrary meshes.

The native package's eight Swift tests consume actual generated files and verify STL/format/readback/input identity, rejected settings and cancellation ownership. Four JS tests cover controlled settings, invalid meshes, shared-realm exclusion and cancellation. Real files and inspected previews are the delivery gate; exhaustive printer ownership/physical printing is not required.

Mainline collection must supply the native compute binding, native workbench, file/CAD entry points, existing jobs/tools integration and broader machine/preparation/project support. Preserve stable outer navigation and the user's 18 settled QA decisions.

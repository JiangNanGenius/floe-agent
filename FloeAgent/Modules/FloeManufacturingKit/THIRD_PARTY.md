# Sources, licenses and local changes

R10 source-only amendment: original MIT/Apache-2.0 `NativeRust/src/bounded_mesh.rs` restricts reconstruction to the declared stock domain, repairs only collinear T junctions, and fails explicitly on unclosed/non-manifold output or exhausted budgets. Stock checkpoints retain the original physical upper planes. No upstream file, revision, license or C ABI changes. The older outside-air halo remains an extraction implementation detail and no longer defines the returned physical bounds. Swift adds the source/library capability check and exact-bound continuation checks under MPL-2.0. These edits are not compiled or executed; the packaged Rust binaries remain R9 recovery bytes until rebuilt. R9 already superseded historical display-fairing descriptions below.

This is a separate research component and qualification host. The source and
license records remain with the component; there is no main-App distribution
clearance implied by this handoff.

| Component | Pinned source | Reuse and retained license |
|---|---|---|
| LibLathe | `dubstar-04/LibLathe@4bac3400813f40a15e0bf22e12998453e337d96e` | Eleven C++ geometry files unchanged in `Sources/TurningNative/Vendor/liblathe/base`. Face/rough/profile/tool operations mechanically ported from Python to C++; GPL-2.0 text and mapping in the target's `Vendor/liblathe/LICENSE` and `ATTRIBUTION.md`. |
| OpenMill | `charlatanshost/OpenMill@0432a8c540d1187dc6cb9383ce1b4f2dd97287f6` | Four byte-identical kinematics modules in `NativeRust/upstream/{default_machines,table_table,traits,types}.rs`; R2 extracts the holder silhouette and linear `radius_at` subset to `NativeRust/upstream/tool_holder.rs`, with the tool-tip frame conversion stated explicitly. MIT option selected, upstream MIT/Apache notices retained. R4 additionally extracts tool-profile, raster/pocket, hole-cycle, surface-normal and swarf subsets in `NativeRust/upstream/r4`, with per-file change maps. Analytic circle/rectangle contours are local adapters. The upstream vertex-only holder collision and incomplete adaptive/Voronoi strategies are not integrated. |
| MillSimSharp | `nyarurato/MillSimSharp@3cdd4f54ef94e6b95f2a149dad246b4e73aad4e9` | Finite-cylinder signed-distance geometry mechanically ported to f64 Rust in `NativeRust/src/sdf.rs`; MIT text in `NativeRust/upstream/LICENSE-MillSimSharp-MIT.txt`. No .NET runtime. |
| isosurface | `mikolalysenko/isosurface@22eba3c8c646a478a79a3871223bab0608fb1c04` | Marching-tetrahedra table/algorithm ported through the prior qualified C# implementation to `NativeRust/src/tetra.rs`; MIT text in `NativeRust/upstream/LICENSE-isosurface-MIT.txt`. |
| Parry3d | `0.17.6` | Native cylinder/sphere-vs-box queries, pinned by `NativeRust/Cargo.lock`; R2 adds shank/holder solids against fixtures and current voxel stock. Tapers use conservative outer and inner bounds; unsupported, failed and envelope-only queries remain unresolved. License text stays in the bundled crate. |
| Floe A/C adapter | prior component-qualified bounded adapter | `NativeRust/src/ac.rs`, MPL-2.0 provenance retained. One intersecting table-table topology only. |
| Floe orchestration/UI | this research source snapshot | MPL-2.0, package `LICENSE`. C++ derivative target remains GPL-2.0. |
| FreeCAD CAM parameter research | `FreeCAD/FreeCAD@67c6ba006e2ce524833af6c62d4f40270e6a7871` | CAM field/shape metadata references in `FloeManufacturingParameters`; no FreeCAD runtime or Python dependency is linked. Pinned research files and their license headers remain under the task's `parameters-evidence/sources`; field mapping and explicit metadata gaps are in `parameters-evidence/SOURCES.md`. |

The exact Cargo transitive versions, declared license expressions and bundled
license paths are exported as `licenses/RUST_DEPENDENCIES.json`. The offline
crate cache is retained for reproducible local builds, including its original
notices. Apple system frameworks and the developer toolchain are not vendored.

Local integration changes after the component workers released ownership:

- Turning boundary explicitly rejects a non-0.4 mm nominal nose. R4 adds the
  actual C/D/V/S/T/R two-dimensional insert constructors and rotation; these
  affect defeaturing without implementing nose-radius compensation. Finish paths use zero final stock
  allowance. Finite profile/step/coordinate limits prevent excessive work.
- Initial, remaining, removed and phase volumes now all use cell occupancy;
  analytic cylinder volume has a separate output. Phase removals are incremental.
- The bounded one-pass milling slot requires width equal to cutter diameter.
- Native stock meshing adds an outside-air layer at domain faces so the mesh
  closes. Original open-boundary STL failures and original source remain in the
  task evidence. This is still an approximate voxel mesh, not exact stock B-rep.
- Build scripts stage complete XCFrameworks before replacing a good artifact.
  The optional TurningNative static XCFramework is built from the same C++
  target source that SwiftPM compiles.

The original component `READY.json` and handoffs are preserved as historical
receipts. Their original hashes and pre-integration volume wording are not the
final artifact hashes/semantics. Use the final source/artifact manifest.

R4 native changes are recorded in `r4/native/HANDOFF.md`,
`r4/turning/HANDOFF.md` and their frozen APIs. In particular the local adapter
repairs silent tiny-pocket skips, makes move/feed/dwell semantics explicit,
converts ball-centre coordinates to the common tool-tip convention, and keeps
query failures or uncovered samples visible. New SDF shapes do not turn
envelope-only collision hits into proven intersections. All previous licenses
and original unchanged geometry attribution remain attached.


R5 additions (no new external dependency or upstream revision):

- Original MPL-2.0 cell program/planner/executor, continuation/archive/UI adapters and process assessment. Separate tool/process ownership and commanded spindle state do not imply controller feedback.
- `NativeRust/src/machine.rs` reuses pinned nalgebra/Parry for declared forward chains and sampled body queries. Root repairs intermediate nested-rotation sampling and leaves unproven triangle-mesh containment unresolved. `stock.rs` checkpoints exact voxel occupancy and negative-end facing on the original grid.
- `FloeEngineeringCore` is original native Swift MPL-2.0 source: tet4 isotropic elasticity/conduction, bounded skyline LDLᵀ support certification, PCG, material/load/BC/export contracts and examples. It links Foundation/CryptoKit only. Solver and material provenance are retained in its source; library values are typical, uncertified research records.
- Root integration changes and original failed source/test checkpoints are recorded in `r5/evidence/ROOT_REVIEW.md`. These supersede preliminary worker scope wording without rewriting those original handoffs.


R6 additions (original MPL-2.0 Swift, with no new third-party dependency):

- VirtualCellReplay reuses the source-bound Cell schedule, CuttingTimeline, rigid transforms and existing task controls. Scene construction uses the existing native query boundary; display uses Apple SceneKit/Charts and the existing bounded display fairing.
- SpindleDynamics implements an explicitly stated lumped rotational balance I*domega/dt = drive - resistance, with bounded midpoint integration and zero/target events. This is new research code, not a port or measured controller model. Units/limits and energy accounting are recorded in source and the handoff.
- Optional declared C travel extends Cell input while preserving old nil/single-turn archive identity. The existing Rust/C++ source, pinned Cargo manifests and six static-library files match R5; provenance/readback accompanies R6.
- Original cancelled delegation receipts, compile/test failures and screenshot-transport failure remain separate from Root's actual implementation and final evidence. No preliminary worker output is represented as implemented code.

R7 additions (no new external dependency or upstream revision):

- Original MPL-2.0 Swift source binds study/Cell results to a portable CAM preview,
  operation workflow, actual TCP/axis playback and native solid machine/tool
  presentation. Configured insert outlines and cutter/assembly dimensions are
  reused; unspecified headstocks/holders are generic display geometry, excluded
  from the native safety query. The combined GPL research host remains isolated.
- Local MIT/Apache-2.0 stock adapter changes in `NativeRust/src/stock.rs` and
  `core.rs` recognize filled radial discs and reconstruct closed circular rings.
  Untouched discs retain the declared blank radius; machined discs use
  voxel-area-equivalent radii and retained axial shoulders. Holes, slots and
  asymmetric cuts use the existing tetrahedral surface extractor with fractional
  incident-cell occupancy samples instead of binary +/-1 nodal quantization;
  half-density ties retain the historical inside policy with an explicit
  nonzero value, preserving the pinned extractor's strict-domain checks.
  Occupancy, reported removal volume and toolpaths remain unchanged. This is an
  approximate stock representation, not a new machining-tolerance guarantee.
- Three Rust arm64 slices were rebuilt for iOS, iOS Simulator and macOS. Existing
  LibLathe C++ source/slices, C ABI, upstream extracts, Cargo pins and notices
  remain unchanged. The final native manifest supersedes R7's historical
  pre-correction `NATIVE_PARAMETER_REUSE.json` receipt.
- Display-only bounded fairing/shared-edge refinement and smooth normals retain
  a raw-view option. General non-axisymmetric stock remains voxel approximate;
  original input/result archives are not silently upgraded on reopen.

- R7 machine presentation additionally maps the already-pinned zero-pivot
  OpenMill A/C table-table formula `Rx(A) Rz(C)` to the physical table/workpiece
  and a fixed machine-Z spindle. Original joint values and neutral source paths
  remain intact; interpolation/view geometry do not add machine IK or collision
  coverage. Three-axis uses vertical-Z display coordinates. Lathe insert-pocket,
  square shank and generic machine context are original presentation geometry.

- R7 machining/inspection presets, per-component display opacity, visible-only camera bounds and archive-compatible `CAMPreviewSettings` are original MPL-2.0 presentation code. SOLIDWORKS CAM/CAMWorks screenshots were viewed as design research only; no screenshot or vendor machine CAD asset is bundled in product resources. Circular native rings retain exact ring positions and crease-separated cap/side normals; noncircular display fairing remains bounded and optional.

R8 additions (original MPL-2.0 Swift; no upstream/native/library changes):

- Source-owner operation inspection resolves through the actual job/path metadata, including legacy typed slot milling; read-only UI reuses the complete scoped parameter catalog without changing runtime support.
- Screen-space polyline selection uses the active renderer projection, independent visible source paths, clipped-point breaks and an explicit segment budget. It does not perform machine collision or change/replan CAM. Native accessibility entries select the same operations; background camera gestures remain available.
- Shared neutral PBR materials/lighting and declared turning-fixture envelope edges are presentation only. Source mesh/physical pose/queries remain unchanged; old saved visibility states are respected.

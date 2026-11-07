# FloeManufacturingKit — independent native manufacturing research

The App integration repair adds native path-prefix stock replay through
`fm_core_preview`: tool position, progressive remaining stock and sampled
collision feedback now share one source cursor. Scrubbing is coalesced and
cancellable off the main actor; completed-path checkpoints accelerate forward
playback without reusing partial cuts. Rapid/retract moves never remove stock.
Real insert outlines retain flat caps/sharp polygon edges and rounded sides.
See [the replay contract](NativeRust/BOUNDARY_CONTRACT.md). The historical
retained-stage-only playback descriptions below apply to those frozen versions.

The canonical App module now contains the R11 native correction: cylindrical mixed-stock meshes intersect the declared radial domain before tetrahedral extraction, retaining bores/slots without folded cap edges. The 137 Rust library checks pass; iOS arm64, iOS Simulator arm64 and macOS arm64 frameworks compile, and a macOS C client links the packaged framework and reads back the original three regression requests plus cancellation. The static framework keeps cargo's original archive symbols; build candidates can use `FLOE_NATIVE_XCF_OUTPUT` before coordinated promotion. See [the native contract](NativeRust/BOUNDARY_CONTRACT.md). These are component/C-ABI results, not R11 full-App, iPad, machine or full-E38 acceptance. Historical R10 source-only/prebuilt-library warnings below describe that frozen delivery and are superseded for the canonical module.

R10 is a **source-only, uncompiled and untested** boundary correction. Pristine box stock retains its declared planes/corners; reconstructed stock is constrained to its physical domain and must retain closed, consistently oriented edges. Cylinder end planes no longer follow ceil-rounded grid height. New stock checkpoints carry optional `declaredMaxMM`; ambiguous legacy checkpoints remain archive-readable but must be regenerated before new continuation. The C ABI is unchanged. Cut surfaces/volumes remain voxel approximations; this is not an exact B-rep reconstruction.

**Rebuild the Rust XCFramework before fresh computation.** The included `Vendor/FloeMachiningNative.xcframework` retains the R9 library bytes for recovery and does not implement these edits. `NativeEngine` requires `declared-stock-boundary-v1` from a fresh execution to prevent accidental use of the older geometry. C++ sources/slices, upstream pins and the original 322-field catalog are unchanged. Mainline owns compilation, regression execution and App/UI verification. R1–R9 evidence below is historical evidence for its exact frozen source. See `../../r10/HANDOFF.md` and `../../r10/COLLECTION_INDEX.md` for the full collection, printing companion and pending checks. R9 supersedes all historical display-fairing descriptions below.

R9 adds independent `FloeNCProgram` numeric decoding, analytic arcs/helices/Bezier/rational spline preview, validated word encoding, semantic readback, cancellation and `.floenc` save/reopen. `FloeManufacturingNC` posts actual fixed +Z milling or separate X/Z turning paths, verifies every original segment and records all added clearance/approach moves, tools, active speed/feed laws and explicit fallback RPM settings. `NCProgramWorkbenchView` imports, edits, verifies, previews and exports locally; the CAM workbench generates a real file and opens it through the same decoder. Machine-specific five-axis/turn-mill/multi-channel post mapping remains open.

R9 supersedes generic display fairing: source vertices and triangles stay unchanged. Per-corner shading normals preserve hard edges and true right angles; existing analytic cylinder/cap normals remain. Source polylines stay linear in the post, with explicit G61 rather than invented corner rounding. Native voxel precision and collision-query coverage are unchanged. See `../../r9/HANDOFF.md` for exact support, tests, sources and gaps. The temporary qualification app/runner was backed up and uninstalled after the R9 Simulator flows; compiled component hosts and source are retained separately.

R8 adds actual visible-toolpath selection, an operation/tool inspector and read-only access to the complete scoped parameter catalog, including rare/unknown values and their existing runtime-support status. Source inspection follows the job and original path metadata, supporting legacy typed slot milling without inventing a CAM operation. New turning previews show their declared fixture envelopes; saved visibility is respected. Neutral materials/lighting refine the current presentation. No native source, dependency, C ABI or safety-query coverage changes.

R7 adds a source-bound CAM preview, familiar setup → generate → simulate workflow, solid spindle/chuck/jaws and actual insert/cutter/assembly presentation. `CAMPreviewProgram(source:)` consumes `.study(study, artifact)` or `.cell(virtualProject, cellArtifact)`; `frame(at:)` returns real TCP, tool axes, source joints, paths and retained-stage stock. `CAMPreviewArchive.save/open` keeps the source/result and bounded view settings in `.floepreview`. Untimed paths use geometric progress rather than invented seconds. Default machining view hides the bed/column and keeps the cutter/holder and independently translucent spindle/workholding. Inspection view restores machine context. Public Codable `CAMPreviewSettings` preserves layer modes, transparency and camera in the same source-bound archive; visible-only fitting keeps the part readable. Three-axis is vertical Z; the pinned zero-pivot A/C table-table presentation follows actual `Rx(A) Rz(C)` joints without general IK.

R7 rebuilds the local Rust stock adapter: verified filled discs use closed circular rings; mixed stock uses fractional occupancy-density tetrahedra, retaining slots and bores. Occupancy, reported removal and toolpaths stay unchanged. Display fairing/refinement is separate and optional. Existing archives keep their saved meshes. No new third-party dependency/pin or C ABI change. Generic machine housings/unspecified holders are presentation only and excluded from safety queries. Continuous per-time removal, full machine IK and whole-machine collision certification remain open. Exact final qualification and source/library identities are recorded in the R7 delivery; physical-device/full-E38 acceptance is not claimed.

The original 322-field catalog, including 197 rare parameters and detailed editors, is retained. Stored-only parameters do not become runtime-supported merely by appearing in the editor.

The following R6 capabilities remain available:

R6 adds configured virtual spindle/chuck/workpiece/tool replay and a separate lumped drive calculation to the existing native Swift/C++/Rust research package. Product runtime has no Python/.NET/shell or remote compute dependency.

```swift
let project = VirtualMachineProject.demonstration()
let artifact = try VirtualMachineEngine().compute(project)
try VirtualMachineArchive.save(project: project, artifact: artifact, to: fileURL)
let (input, result) = try VirtualMachineArchive.open(fileURL)
```

`VirtualCellReplay` consumes actual source-bound R5 schedules and CuttingTimeline samples. Material rotates while turning TCP stays on its declared meridian; receiver acquisition/release binds the part without a jump, then carriage retraction moves it. C-mode/synchronization changes follow nominal command completion boundaries; no missing transition sweep or general machine IK is invented. Explicit C travel preserves multiple turns; unspecified legacy Cell inputs retain single-turn indexing.

`VirtualMachineSceneBuilder` places configured housings/chucks/jaws, raw retained stage stock, active tool solids/envelopes and fixed fixtures. Unlocated ejected parts are omitted with uncovered-travel warnings; an authored catcher placement is optional. Current-pose queries reuse the existing Parry C ABI with intentional contact receipts. Some mesh/body queries remain incomplete/unresolved. Static configured geometry is not a continuous whole-machine certificate; inactive turret/tool geometry and full turning-tool bodies are still incomplete.

`SpindleDriveSolver` accepts explicit SI inertia, torque/power, opposing load/drag and efficiency. It returns signed speed, unwrapped phase, saturation, time/step termination and mechanical/electrical/regenerative energy. Fixed-step midpoint dynamics is approximate, stops at first reach, and does not retime nominal replay or assert measured servo/bearing/thermal behavior.

The existing `ManufacturingStudy`/service/archive, multi-resource Cell engine, voxel-stock continuation and `FloeEngineeringCore` static/thermal module remain available. R/Z uses radius. Typed owner fields govern active inputs; the322-field catalog including197 rare settings remains97 active bindings/222 stored/3 fixed. New typed cell/scene/drive/C-travel fields are additional. Unknown vendor values remain inside owner parameter records. Display fairing never changes computation, collision, archives or raw STL.

R6 qualification:8 distinct new checks, actual Swift6 objects/iOS arm64 host, component save/reopen/source-tamper checks, frozen-R5 archive reuse and a canonical iPad Simulator new-view observation. Unchanged native source/pins/static slices and earlier R5 evidence were reused. Physical-device/full functional/industrial E38 acceptance is not claimed. Full support/gaps, original failures and artifact identity are in the research delivery r6/HANDOFF.md and FEATURE_MATRIX.json.

LibLathe GPL-2.0 derivative and the combined qualification host stay independent. A thin C ABI does not clear main-App combination/distribution. Retain THIRD_PARTY.md, LICENSE, native notices and licenses/. No machine-specific G-code, external execution adapter or main-App integration is added.

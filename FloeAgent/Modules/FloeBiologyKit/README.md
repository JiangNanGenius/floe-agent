# FloeBiologyKit

Independent iPad biology component. Five workspaces share a revisioned project, service-owned calculations, native views and a complete scoped AI tool family. The optional [Floe host adapter](Integration/FloeBiologyHostAdapter/README.md) implements real tool-registry and scientific-job integration; the main App owner connects its existing entrypoints and task ownership.

## Package products

| Product | Responsibility |
| --- | --- |
| `FloeBiologyCore` | Typed data, bounded scientific formats, native algorithms/geometry, immutable originals, revisioned storage |
| `FloeBiologyEngine` | Authorized service, durable runs, cancellation, file handles, replay receipts, AI contracts/provider loop |
| `FloeBiologyUI` | Native SwiftUI/Canvas/SceneKit/Charts workbench, editing/undo/history, recently deleted, Files import/export |
| `FloeBiologySamples` | Digest-checked synthetic examples and real RCSB 1UBQ PDB/mmCIF |
| `FloeBiologyWorkerResources` | Verified scripts, 66 pinned external Python dependencies and license metadata; no interpreter execution |

Swift 6; iOS/iPadOS 26+, core/engine on macOS 15+. No external Swift dependency in this package. The separate adapter depends on Floe's real existing services. Scientific dependencies run only in the host's selected Linux environment in production.

## Workspaces

| Domain | Native component | Optional mature engines |
| --- | --- | --- |
| Sequence | FASTA/FASTQ, bounded GenBank, range/annotation editing, map, translation, six-frame ORFs, linear-gap alignment, Newick tree/layout/selection | Biopython rich records, affine alignment, genetic codes, neighbor joining, rich exports |
| Structure | PDB/mmCIF, model/chain/atom selection, distance/contacts, Metal-backed atom/backbone/ribbon scenes with 4× MSAA, temporal antialiasing and static jitter; continuous Cα ribbon frames with deposited helix/sheet annotations | Gemmi parsing/selection, KD-tree contacts, Kabsch superposition using current edited coordinates |
| Microscopy | Numeric image/PGM, C/Z/T and ROI, segmentation/measurements, MRC/CCP4 physical-axis slices and bounded native isosurfaces | tifffile/Zarr bounded pyramid regions, OME calibration/series metadata, scikit-image segmentation/morphology/overlay |
| Omics | CSV/TSV, matrix edits, gene/cell selection, heatmap, QC, normalization/log1p/gene statistics | AnnData H5AD/MTX, Scanpy PCA/Leiden/UMAP, Welch/BH comparisons and export |
| Network | Species/reaction/rate editing, reaction map, RK4 trajectories, sweeps and Charts | SciPy solvers, libSBML import/export, libRoadRunner/CVODE general SBML with rate/assignment rules and events |

There are 21 native and 32 optional mature methods. Available methods are filtered by the actual format and installed-engine probe. All previews/results are bounded; originals retain exact bytes. A derived asset records the source result/revision/digest and rejects stale data. Sequence edits invalidate overlapping annotations and measured quality. No secondary structure, density, measurements or provider answers are fabricated.

## Workbench layout

The iPad workbench keeps the dataset stage, materials navigation and analysis inspector separate. Analysis opens in a native inspector; its method, execution location and applicable input parameters are grouped, with a fixed Run action. Data editing, annotation and network editing are in **More**. Compact toolbars keep undo/redo in that menu. All choices and primary/secondary actions share 44-point control geometry, with matching input borders and aligned content margins.

Sequence and matrix stages scroll in smaller windows. Matrix fields adapt between two equal columns and a vertical layout. Protein and density viewports retain the native antialiased renderer. Network/result time-course charts use measured rows and original units, with a bounded preview (up to 12 series and about 6,000 plotted points); the full result remains available for export. Editors, notes, history, the assistant and the diagnostic console use page-sized native presentations with inline titles. Notes provide one document surface; diagnostic responses have their own bounded scroll area.

## AI and host integration

Keep one `BiologyService(store:backends:fileAccess:authorize:)` per workspace. Present `BiologyLibraryView` or `BiologyWorkbench` inside the App's existing feature without replacing its outer split view. `onAI` uses the host's ordinary model/task services; `onInsertInNotes` saves through the existing Notes service without sharing editor state. `executionOwner` resolves the real task/run for a native scientific launch. `makeTools` supplies an authorized diagnostic session.

`BiologyToolSession` exposes 22 tools (creation requires a host grant): `projects`, `create`, `read`, `methods`, `describe`, `import`, `importProject`, `edit`, `update`, `select`, `analyze`, `job`, `status`, `stop`, `derive`, `export`, `file.read`, `history`, `restore`, `deleteProject`, `deleted`, `restoreDeleted`, all prefixed `biology.`. Exact JSON schemas, pagination, current revisions and option limits are discoverable. `describe` also returns the verified optional dependency requirements. Installation uses the existing `exec.shell`/environment workflow, with no second installer or execution alias.

Scope, owner, resolved environment and approval come from the host, never model JSON. Mutations atomically commit a bounded replay receipt keyed to the real task/run/call and argument digest. Replayed or concurrent calls do not repeat accepted work. The adapter revalidates grants and capability ceilings on dispatch and excludes temporary/public-web-only chat. Add `bridge.descriptors(for:)` to the host's effective catalog and call `bridge.register(in:)`; merely linking a package does not expose tools to a model.

`BiologyAssistant` is an optional provider-neutral bounded real tool loop. A host must supply a real provider; the qualification host supplies no synthetic AI answer. Floe's ordinary agent runtime can dispatch the registered tools directly.

Scientific transport stages verified scripts and exact snapshots/file bytes through existing resolved Linux `exec.shell` jobs. It checks real background-job ownership, environment, payload, exact attempt identity, input/output digests and stop acknowledgement. Runs outlive views. Cancellation joins the actual owned job. A lost stop acknowledgement persists as an unresolved worker and blocks deletion/history restoration until exact host reconciliation; a disconnected worker is never silently treated as stopped. Call `recoverInterruptedNativeRuns()` only after proving previous native workers are gone.

`BiologyWorkspaceFiles` implements immutable streaming storage (1 MiB chunks, default 8 GiB configurable to 512 GiB). Models receive opaque project/environment-bound IDs, bounded reads and export receipts. Saved-project import accepts an authorized `fileID` + `sourceProjectID`, so large project JSON never needs to enter the model argument buffer. A trusted native file-picker URL can register an original; native large-original export streams to a verified temporary file for the Files picker and cleans it after completion/cancellation. A custom host file service must implement this native handoff if it wants that UI path. No filesystem path is returned to a model.

Storage uses `flock`, no-follow reads, immutable revisions, checked HEAD and staged atomic writes. CAS rejects stale edits; history restores monotonically increase revisions. Recently Deleted is a soft-deleted HEAD with retained revisions and a restore UI. Active or unresolved workers prevent deletion/restoration. Project JSON import clears incoming execution authority and rejects file references requiring a fresh host grant.

## Validation and boundaries

See the [iPad host](../../Qualification/Biology/README.md), [backend checks](Backends/README.md), [design/research guide](../../../docs/FLOE_BIOLOGY_WORKBENCH_RESEARCH_AND_DESIGN.zh-CN.md) and [second-round evidence](../../../docs/FLOE_BIOLOGY_COMPONENT_CLOSURE_20261107.zh-CN.md).

This is a bounded component, not an entire sequencing/microscopy platform. Native MRC: at most 2 million voxels/16 MiB and 30,000 surface triangles. TIFF regions: at most 1 million pixels/64 MiB decompression chunk; multi-file OME acquisition stitching is not supported. H5AD import caps expanded memory at 128 MiB/2 million values or nonzeros. General SBML rejects algebraic/delay equations and unsupported extension packages explicitly. Welch cell comparisons do not model biological replicates/covariates. No molecular dynamics, sequence-to-structure prediction, instrument control or automated wet-lab execution is implemented. File-backed project JSON contains references, not a portable archive of large originals; importing it requires explicit file regrant/packaging by the host.

Scientific methods have actual pinned-CPython numerical tests. The adapter has real Floe registry/job contract tests with an explicitly labeled shell fixture, not a Linux execution claim. Main-App entrypoints, a selected Linux guest, real provider calls and physical iPad/Pencil acceptance remain separate. No App version, TestFlight upload or formal-review state is changed here.

# FloeBiologyKit

Independent biology workbench predevelopment for iPad. Five native workspaces share a revisioned project and service-owned analyses: sequences, protein coordinates, microscopy, expression matrices and biochemical networks. Production App entrypoints, model calls and Linux job transport remain host responsibilities.

## Package products

| Product | Responsibility |
| --- | --- |
| `FloeBiologyCore` | Typed datasets, bounded import/export, native algorithms, immutable source bytes and revisioned storage |
| `FloeBiologyEngine` | Authorization callbacks, durable runs, cancellation, configured worker protocol and scoped AI tools |
| `FloeBiologyUI` | Native SwiftUI workbench, Canvas scientific views, Charts, editing, undo/redo, history and Files export |
| `FloeBiologySamples` | Digest-checked synthetic examples and real RCSB 1UBQ PDB/mmCIF files |
| `FloeBiologyWorkerResources` | Digest-checked worker scripts, pinned Python versions and upstream dependency metadata; no interpreter execution |

Deployment: iOS/iPadOS 26+, Swift 6. Core/engine tests also run on macOS 15+. The native package has no external Swift dependencies. Scientific Python libraries are optional dependencies in the host's configured execution environment.

## Implemented behavior

| Domain | Native workspace and analysis | Optional scientific worker |
| --- | --- | --- |
| Sequence | FASTA/FASTQ, bounded GenBank subset, ranged editing/annotations, circular/linear map, nucleotide/protein statistics, translation, reverse complement, linear-gap local/global alignment, complete six-frame ORFs | Biopython rich GenBank records, affine alignment, genetic codes, neighbor-joining tree and rich exports |
| Structure | PDB/mmCIF hierarchy, model/chain selection, rotating native coordinate projection, Cα backbone or atoms, selection, distance, contacts and geometric statistics | Gemmi parsing/selection, KD-tree contacts and Kabsch superposition |
| Microscopy | Original-precision PGM/JSON samples, channel/z/time selection, native image and label boundaries, threshold/Otsu segmentation, count/area/intensity measurements | tifffile TIFF/OME metadata, scikit-image segmentation/morphology, measured PNG overlay and native dataset conversion |
| Omics | CSV/TSV counts, gene/cell selection, heatmap, QC, library normalization, log1p and gene statistics | AnnData H5AD/MTX, Scanpy QC/normalization/PCA/Leiden/UMAP, Welch/BH group comparison and native matrix conversion |
| Network | Species/rate editing, reaction map, RK4 trajectories, parameter sweep and Charts time courses | SciPy adaptive solvers, stoichiometric conservation, sweeps and libSBML inspection/export |

Tables retain full exported data while previews are bounded. Imported originals are immutable. Derived outputs are explicit new assets with source run/digest provenance and reject stale inputs. Sequence edits invalidate overlapping annotations and measured quality values. Exports include original bytes, supported current formats, result CSV/text and the complete project.

## Host integration

Construct one long-lived `BiologyService` with `BiologyProjectStore(root:)` in the existing workspace storage and a required `authorize` callback into Floe's existing policy. Present `BiologyWorkbench(service:projectID:onAI:onInsertInNotes:executionOwner:)` inside the existing feature; keep the outer App split view stable. `BiologyLibraryView` provides the independent project's library.

`onAI` receives a question and explicit project/asset/revision/result context. It must call the host's existing model/task services. `BiologyToolSession` accepts host-authorized project IDs and a host-owned task/run; model arguments cannot enlarge that scope. `onInsertInNotes` is an explicit host callback. These callbacks do not share editor/undo/conversation state with Notes or chemistry.

For advanced methods, probe/install only through the resolved Linux environment's existing jobs and package service, then initialize `ConfiguredBiologyBackend` with actually usable methods, `environmentID`, engine version and trusted execute/stop callbacks. The transport carries exact snapshot bytes and digests, project/object/revision, task/host run, calculation run and attempt. Accept a response only after the real job stopped and the trusted host receipt matches. Cancellation must stop the actual owned job before returning. No `Process`, language-specific execution tool, installer, shell command from a dataset or host-interpreter fallback exists in shipping code.

Native tasks outlive views. Call `recoverInterruptedNativeRuns()` once at process startup after establishing previous native workers are gone. Reconcile remote jobs through the host's existing lifecycle. Never automatically resubmit imported or historical active runs.

Storage uses cross-instance `flock`, bounded no-follow reads, immutable revisions, digest-checked HEAD and staged atomic writes. Revision CAS prevents stale overwrites; restoration assigns new monotonically increasing revisions. Active workers block restoration and deletion. Deletion retains project files in `Trash`; a trash restoration UI and automatic crash-orphan repair are not implemented.

## Validation and limits

Use the [independent iPad host](../../Qualification/Biology/README.md), [backend qualification instructions](Backends/README.md), [Chinese design/research guide](../../../docs/FLOE_BIOLOGY_WORKBENCH_RESEARCH_AND_DESIGN.zh-CN.md) and [dated evidence](../../../docs/FLOE_BIOLOGY_PREDEVELOPMENT_20261107.zh-CN.md).

This component is not a replacement for an entire sequencing, microscopy or omics platform. Native protein display is a projection of actual coordinates with Cα backbone, without inferred ribbon/secondary structure, density maps or molecular dynamics. Native GenBank edits support simple ranges; the original retains compound/fuzzy features and multiline metadata. Trees currently export Newick text. Large volumes, pyramidal/multi-file OME datasets, general SBML equation execution, biological replicate statistics, sequence-to-structure prediction and real instrument control remain future work.

The qualification host uses only native analyses. Mature engines are exercised separately in the explicitly pinned CPython qualification environment, including one real Swift-envelope/Python-response test. Full-App Linux jobs/model calls, physical iPad/Pencil and App Store/TestFlight delivery are separate integration/acceptance work.

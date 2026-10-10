# Design workflow (brief → spec → revisions → feedback → candidate → adopt → export)

Status: shared domain model, persistence, DESIGN.md codec and agent tools are implemented and unit-tested; **content-specific editor panels, adapters and verified export are not connected yet** and are reported as unavailable with concrete reasons. Canvas remains the owner of the project graph.

## Model / where things live

| Piece | Location |
|---|---|
| Workflow state machine | `FloeAgent/Sources/FloeCore/DesignWorkflow.swift` |
| DESIGN.md import/edit/export | `FloeAgent/Sources/FloeCore/DesignMDCodec.swift` |
| Subdocument codec (binding + bounds) | `FloeAgent/Sources/FloeCore/DesignCanvasMetadata.swift` |
| Capability registry | `FloeAgent/Sources/FloeCore/DesignCapabilities.swift` |
| Canvas-authority service + adoption grants | `FloeAgent/FloeApp/Workspace/DesignCanvasService.swift` |
| Agent tools (`canvas.design*`) | `FloeAgent/FloeApp/Workspace/DesignAgentTools.swift` |
| Panel (separate view) | `FloeAgent/FloeApp/Workspace/DesignWorkflowPanel.swift` |

Design state is a **typed subdocument of the bound Canvas node** (node metadata key `canvas.design`), persisted only through the existing `FileCanvasDocumentRepository` + `CanvasProjectFileWriter` compare-and-swap authority — so backup, sync, fork and revision-conflict handling are the Canvas ones. There is **no independent design store, gallery or project identity**: the node ID is the only identity, it is required, verified on decode, and a binding mismatch fails closed. Node, connections and layout stay in `CanvasProject`.

## Lifecycle guarantees

- **Brief** optional goal/audience/constraints; **spec** optional palette/typography/layout/spacing/brand assets/voice/prohibitions plus raw `DESIGN.md`.
- **Frozen run.** `freezeRun(operationID:inputRevisionID:targetRevisionID:)` pins the input revision, the spec hash and the target before generation/editing; later edits cannot silently change a run's basis.
- **Revisions are append-only and recoverable.** Every save is a revision; `restore` appends a new revision pointing at the recovered bytes. Revision compare-and-swap (`expectedRevisionID`) turns stale editors into conflicts, never overwrites.
- **Anchored feedback** is bound to `artifactID + revisionID + anchor` (region/time/page/stable object ID). Changing the artifact's revision marks open anchors `staleAnchor`; the user must relocate them. Validation rejects empty/negative anchors.
- **Feedback resolution requires a real change:** the referenced revision must be the artifact's *current* revision and its content hash must differ from the anchored revision. Model text can never resolve feedback.
- **Candidates are proposals.** `propose` records a proposed revision and a candidate; the artifact is untouched. `adopt` requires a pending candidate, a real content change and (optionally) the expected current revision; `reject` leaves the artifact unchanged.
- **Adoption modes.** `updateOriginal` keeps the artifact and its Canvas identity (name/position/size/connections) and promotes the proposed revision; `variant` creates a branch artifact and records the branch point without touching the original.
- **DESIGN.md is preserved.** Known sections round-trip; the preamble and every unknown section are re-emitted verbatim (byte-stable re-export, verified by test).
- **Persistence is safe.** Writes go through the Canvas CAS (one revision advance per mutation); the subdocument is schema-versioned and bounded (2 MiB); a newer schema or binding mismatch fails closed; operation IDs are recorded for idempotent replay.
- **Templates** carry honest capabilities/inputs/dependencies/formats/license/source/hash/version and an optional rollback version+hash. The signed content service remains the install channel; the registry here only describes what is connected.

## Typed adapter capabilities

`DesignCapabilityRegistry` records only **actually connected** operations per content type. Every unavailable operation must carry a clear reason (`Not connected in this build` is the floor, with more specific reasons in the app). `canvas.designCapabilities` exposes this to the agent, and the app registers the honest default (`designCoreDefaults()`):

- Available for every type today: anchored feedback, revision-bound candidates, compare/adopt/reject/restore (payload-agnostic, persisted, callable).
- Not connected yet: source import, generation, region editing, preview, source export, verified export — each with a per-type reason. No screenshot/PDF is ever presented as an editable original.

## Agent tools

`canvas.designGetState`, `canvas.designCapabilities`, `canvas.designCreate`, `canvas.designUpdateBrief`, `canvas.designUpdateSpec`, `canvas.designRegisterRevision`, `canvas.designAddFeedback`, `canvas.designPropose`, `canvas.designAdopt`, `canvas.designReject`, `canvas.designRestore`.

All take explicit `canvasID` + `nodeID` (+ `expectedRevision` and an `operationID` for mutations); they read/write only through the Canvas authority. `adopt` additionally requires a `grantID` from a single-use, expiring user grant minted by the panel (`DesignAdoptionGrantStore`) — the agent cannot self-adopt. `adopt`/`restore` are side-effecting and approval-gated. Input data cannot grant permissions.

## Tests

`Tests/FloeCoreTests/DesignWorkflowTests.swift`: freezing, candidate-not-applied-until-adopt, no-op proposal rejection, variant branching, anchor staleness/relocation, resolution requiring a real change, revision conflicts, restore, DESIGN.md round-trip and spec hashing, canvas-subdocument binding/malformed/newer-schema safety, operation-ID dedup and capability honesty.

## Open gates

Content-specific adapters/panels and verified export remain to be implemented and device-accepted; the UI coordinator owns visual acceptance. See the private acceptance checklist for the current gate list.

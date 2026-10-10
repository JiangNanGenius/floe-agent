# Design workflow (brief → spec → revisions → feedback → candidate → adopt → export)

Status: the full loop is implemented on the existing Canvas/editor services: brief/spec/DESIGN.md → import/generate where the real editor supports it → anchored feedback → revision-bound candidates → compare/adopt that updates the **actual node content in one Canvas CAS commit** → verified export with real reopen parsers. Canvas remains the owner of the project graph. Capabilities not genuinely connected (office/presentation canvas files) say so with reasons.

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

## Typed adapter capabilities (actual state)

`DesignCapabilityRegistry` records only **actually connected** operations per content type; every unavailable operation carries its real reason. `canvas.designCapabilities` re-resolves per call. Connected today:

| Type | Connected operations | Real path |
|---|---|---|
| image | import, generate (when a model is configured), preview, verified export | asset ingestion, media generation, CGImageSource reopen |
| video | import, preview, verified export | ingestion, AVAsset reopen (time anchors) |
| pdf | import, preview, verified export | ingestion, PDFKitGate reopen |
| notes | import, preview, verified export | text/markdown bytes, UTF-8 reopen |
| webpage/prototype | import, capture (as revision), verified export | browser capture bound to the exact task, locator-only snapshot |
| cad | verified export (2D same-format, 3D exchange formats) | CadDocumentCenter; edits stay in the CAD proposal flow |
| office/presentation | not connected for canvas-bound files | office proposal flow owns chat-task workspaces — stated as the reason |

Adoption always updates the real node: media/file nodes get a new verified asset reference, text nodes get the text body, layout/connections are preserved; `variant` creates an actual new node. Revision payloads live in the shared artifact store (`DesignRevisions/<canvas>/<node>/<artifact>/<revision>`), are immutable (identical re-store is a replay, different bytes a conflict), and are published **before** the single CAS commit so a crash never leaves a revision pointing at missing bytes. Exports use the recorded format only — no conversion is claimed — and reopen with the real parser before "verified" is reported. No screenshot/PDF is ever presented as an editable original.

## Agent tools

`canvas.designGetState`, `canvas.designCapabilities`, `canvas.designCreate`, `canvas.designUpdateBrief`, `canvas.designUpdateSpec`, `canvas.designRegisterRevision`, `canvas.designImportSource` (payload published before one CAS commit; replay returns the recorded result, changed arguments are rejected), `canvas.designExportRevision` (recorded format only, real reopen validation), `canvas.designAddFeedback`, `canvas.designPropose`, `canvas.designAdopt` (replay is checked **before** the consumed grant; the durable decision outbox records the intent before the CAS and launch reconcile repairs crashes), `canvas.designReject`, `canvas.designRestore` (restores real node content).

All take explicit `canvasID` + `nodeID` (+ `expectedRevision` and an `operationID` for mutations); they read/write only through the Canvas authority. `adopt` additionally requires a `grantID` from a single-use, expiring user grant minted by the panel (`DesignAdoptionGrantStore`) — the agent cannot self-adopt. `adopt`/`restore` are side-effecting and approval-gated. Input data cannot grant permissions.

## Tests

`Tests/FloeCoreTests/DesignWorkflowTests.swift`: freezing, candidate-not-applied-until-adopt, no-op proposal rejection, variant branching, anchor staleness/relocation, resolution requiring a real change, revision conflicts, restore, DESIGN.md round-trip and spec hashing, canvas-subdocument binding/malformed/newer-schema safety, operation-ID dedup and capability honesty.

## Templates

Built-in templates ship with the app; user templates are stored in `Application Support/FloeAgent/DesignTemplates` with immutable version directories and atomic pointer swaps (rollback restores the real previous bytes). Templates delivered by the **signed content-update service** (kind `templates`) are materialized read-only into the same library with hash verification; install/update/rollback stay in Content Update settings. Template UI lives in the design panel (Creative), not Skills.

## Tests

Beyond the engine suites: whole-project adoption (real node content in one CAS, layout preserved, replay skips content work), the decision outbox (first write/reopen, corrupt/newer-schema read-only with observable errors, pending never pruned, hard cap), the payload store (traversal/symlink/overwrite/cross-canvas), template persistence, and FloeAppTests integration (image end-to-end import→adopt→export, notes text adoption, cross-task capture fail-closed).

## Open gates

Office/presentation canvas adoption stays delegated to the office proposal flow; real-provider generation loops need configured credentials; visual acceptance and physical-device checks belong to the coordinator/user. See the private acceptance checklist.

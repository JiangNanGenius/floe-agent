# Design workflow (brief → spec → revisions → feedback → candidate → adopt → export)

<!-- docs-updated: 2026-10-10 -->

Status: the full loop is implemented on the existing Canvas/editor services: brief/spec/DESIGN.md → import/generate where the real editor supports it → anchored feedback → revision-bound candidates → compare/adopt that updates the **actual node content in one Canvas CAS commit** → verified export with real reopen parsers. Canvas remains the owner of the project graph. Operations that require an explicit workspace binding (office/presentation/CAD) report that requirement as their reason. Last updated: 2026-10-10 (project-spec authority, current-node source entry, single durable decision transaction, template payload/digest authority, variant binding, built-in Markdown/HTML/SVG card sources, real Office/CAD reopen gates).

## Model / where things live

| Piece | Location |
|---|---|
| Workflow state machine | `FloeAgent/Sources/FloeCore/DesignWorkflow.swift` |
| DESIGN.md import/edit/export | `FloeAgent/Sources/FloeCore/DesignMDCodec.swift` |
| Subdocument codec (binding + bounds) | `FloeAgent/Sources/FloeCore/DesignCanvasMetadata.swift` |
| Capability registry | `FloeAgent/Sources/FloeCore/DesignCapabilities.swift` |
| Canvas-authority service + adoption grants | `FloeAgent/Sources/FloeCore/DesignCanvasService.swift` |
| Shared UI/tool transaction (decide, apply template, use current node) | `FloeAgent/FloeApp/Workspace/DesignWorkflowActions.swift` |
| Agent tools (`canvas.design*`) | `FloeAgent/FloeApp/Workspace/DesignAgentTools.swift` |
| Panel (separate view) | `FloeAgent/FloeApp/Workspace/DesignWorkflowPanel.swift` |

Design state is a **typed subdocument of the bound Canvas node** (node metadata key `canvas.design`), persisted only through the existing `FileCanvasDocumentRepository` + `CanvasProjectFileWriter` compare-and-swap authority — so backup, sync, fork and revision-conflict handling are the Canvas ones. There is **no independent design store, gallery or project identity**: the node ID is the only identity, it is required, verified on decode, and a binding mismatch fails closed. Node, connections and layout stay in `CanvasProject`. The canvas-level project brief/spec authority lives **on the `CanvasProject` itself** (`designProjectAuthority`, an additive optional field; old packages decode with nil) — not a parallel store.

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
- **Project (canvas) brief/spec authority.** `canvas.designSetProjectSpec` (tool) and the panel's brief/spec/propagate actions write the authority in ONE Canvas project CAS: the authority record and every existing design subdocument inherit the payload in the same commit, and new subdocuments inherit on creation. Replay is keyed by operationID **and the full-payload identity** (a changed payload under a reused operation ID is rejected; an identical payload dedupes without a revision bump). Unrelated node edits never change which payload is authoritative, and frozen runs keep their recorded spec hash.
- **Use current node.** `canvas.designUseCurrentNode` (tool) and the panel's “Use current node content” freeze content that already exists on the node — text/markdown body, retained asset bytes, the bound CAD/Office workspace document, or a built-in Markdown/HTML/SVG card's typed text — into a `currentNode` revision through the existing adapter guards, with no external export/reimport. Missing content fails with a precise localized reason; mutable editor state/drafts are not touched.
- **Durable decisions.** Panel and tool adoption/rejection share one transaction (`DesignWorkflowActions`): candidate origin is resolved from the candidate's persisted originating task (a missing origin fails closed — never a fallback to the current chat); a durable outbox intent with the exact node + full operation fingerprint (candidate/decision/operation/mode/base/expected revision) is written BEFORE the CAS; the throwing durable ingress is acknowledged only after it persists, so a crash or failed delivery leaves the decision pending for launch reconcile. Repeated decisions dedupe by fingerprint.
- **Signed templates.** Materialization verifies the canonical package digest against the signed entry, requires the `DESIGN.md` entrypoint, reads the license from a real LICENSE file (otherwise explicitly unspecified), follows rollback/removal through reconciliation, and refuses to apply a template whose stored payload does not match its manifest digest.

## Typed adapter capabilities (actual state)

`DesignCapabilityRegistry` records only **actually connected** operations per content type; every unavailable operation carries its real reason. `canvas.designCapabilities` re-resolves per call. Connected today:

| Type | Connected operations | Real path |
|---|---|---|
| image | import, generate (when a model is configured), preview, verified export | asset ingestion, media generation, CGImageSource reopen |
| video | import, preview, verified export | ingestion, AVAsset reopen (time anchors) |
| pdf | import, preview, verified export | ingestion, PDFKitGate reopen |
| notes | import, preview, verified export | markdown/plain-text bytes (md/markdown/txt), UTF-8 + format reopen |
| webpage/prototype | import, capture (as revision), verified export | browser capture bound to the exact task, locator-only snapshot; HTML/JSON and SVG reopen with a bounded XML/SVG parse |
| cad | 2D dwg/dxf: import, preview, source export, verified export (same-engine reparse). **3D verified export is currently unavailable** — glb/step/stl/obj/3mf/usdz/floecad fail explicitly rather than claiming a verified export | CadDocumentCenter; engine edits stay in the CAD proposal flow |
| office/presentation | import, preview, source export, verified export **only for a node with an explicit Canvas-owned workspace binding** (`canvas.designBindDocument`), via OfficeCommandCenter + bounded OOXML reopen (docx/xlsx/pptx) | engine-command edits stay in the office proposal flow — that delegation, not "not connected", is the stated reason for unbound nodes |

### Built-in Canvas source nodes

The Canvas "add built-in" menu creates typed source **cards** (`metadata.builtinPlugin`) whose text IS the source and which render through dedicated views:

- `markdown` card → `notes` content type, recorded format `md`
- `html` card → `webpage`, recorded format `html`
- `svg` card → `webpage`, recorded format `svg`

"Use current node" freezes the exact card bytes under the plugin's format (the adapter parser reopens them first); a proposal/adoption is written back into the **same card text** through the original render path, preserving node kind, `builtinPlugin` metadata, layout and title. Format compatibility is enforced: e.g. SVG/HTML bytes cannot be adopted into a Markdown (notes) card, and non-SVG bytes renamed `.svg` are rejected. An unknown/non-text builtin (e.g. `panorama3D` without a retained asset) fails with a precise, localized reason rather than falling back to generic card text.

Adoption always updates the real node: media/file nodes get a new verified asset reference, text nodes get the text body, layout/connections are preserved; `variant` creates an actual new node. Revision payloads live in the shared artifact store (`DesignRevisions/<canvas>/<node>/<artifact>/<revision>`), are immutable (identical re-store is a replay, different bytes a conflict), and are published **before** the single CAS commit so a crash never leaves a revision pointing at missing bytes. Exports use the recorded format only — no conversion is claimed — and reopen with the real parser before "verified" is reported. No screenshot/PDF is ever presented as an editable original.

## Agent tools

`canvas.designGetState`, `canvas.designCapabilities`, `canvas.designCreate`, `canvas.designUpdateBrief`, `canvas.designUpdateSpec`, `canvas.designGetProjectSpec`, `canvas.designSetProjectSpec`, `canvas.designRegisterRevision`, `canvas.designImportSource` (payload published before one CAS commit; replay returns the recorded result, changed arguments are rejected), `canvas.designUseCurrentNode`, `canvas.designExportRevision` (recorded format only, real reopen validation), `canvas.designAddFeedback`, `canvas.designPropose`, `canvas.designAdopt` (replay is checked **before** the consumed grant; the durable decision outbox records the intent before the CAS and launch reconcile repairs crashes), `canvas.designReject`, `canvas.designRestore` (restores real node content).

All take explicit `canvasID` + `nodeID` (+ `expectedRevision` and an `operationID` for mutations); they read/write only through the Canvas authority. `adopt` additionally requires a `grantID` from a single-use, expiring user grant minted by the panel (`DesignAdoptionGrantStore`) — the agent cannot self-adopt. `adopt`/`restore` are side-effecting and approval-gated. Input data cannot grant permissions.

## Tests

`Tests/FloeCoreTests/DesignWorkflowTests.swift`: freezing, candidate-not-applied-until-adopt, no-op proposal rejection, variant branching, anchor staleness/relocation, resolution requiring a real change, revision conflicts, restore, DESIGN.md round-trip and spec hashing, canvas-subdocument binding/malformed/newer-schema safety, operation-ID dedup and capability honesty.

## Templates

Built-in templates ship with the app; user templates are stored in `Application Support/FloeAgent/DesignTemplates` with immutable version directories and atomic pointer swaps (rollback restores the real previous bytes). Templates delivered by the **signed content-update service** (kind `templates`) are materialized read-only into the same library with hash verification; install/update/rollback stay in Content Update settings. Template UI lives in the design panel (Creative), not Skills.

## Tests

Beyond the engine suites: whole-project adoption (real node content in one CAS, layout preserved, replay skips content work), project-spec authority (three nodes inherited in one commit, repeated different payloads, changed operation payload rejected, stale revision conflict, unrelated node edit, frozen run preserved, new-node inheritance, reopen), the decision outbox (full fingerprint dedupe across relaunch, legacy-envelope backfill, first write/reopen, corrupt/newer-schema read-only with observable errors, pending never pruned, hard cap), the payload store (traversal/symlink/overwrite/cross-canvas), template persistence and signed-package digest authority, the retained-image evidence policy (real PNG/JPEG/WebP/GIF bytes, MIME spoof, over-limit pre-decode rejection, duplicate/two-result attribution, Chat/Responses/Anthropic serialization), and FloeAppTests integration (image end-to-end import→adopt→export with delivery-failure reconcile, missing-origin fail-closed, project-spec tools across three nodes, use-current-node text + precise localized unavailable reasons, built-in Markdown/HTML/SVG cards source→propose→adopt→restore→verified-export and precise unsupported states, cross-task capture fail-closed).

## Open gates

Engine-command edits for office/presentation stay delegated to the office proposal flow even though a bound workspace document supports import/verified export; 3D CAD verified export (exchange/mesh formats and `.floecad` packages) has no connected single-payload reader yet and must not be claimed as verified; real-provider generation loops need configured credentials; visual acceptance and physical-device checks belong to the coordinator/user. See the private acceptance checklist.

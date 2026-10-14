# Design workflow (brief → spec → revisions → feedback → candidate → adopt → export)

<!-- docs-updated: 2026-10-13 -->

Status: this page documents two states that must not be mixed.

- **Released:** the Canvas-anchored design workflow in the “Released” sections below shipped with the 1.7.29 (270) source (tag `v1.7.29`; internal availability recorded in [CURRENT_STATUS.md](CURRENT_STATUS.md)). The 1.7.30 (271) hotfix changes provider-name normalization and Bluetooth authorization timing only, not this workflow.
- **Unreleased work in progress:** branch `codex/design-workflows-20261013` (baseline `734e97f5`) adds the conversational natural-language entry, the three work modes (create/modify/restructure), a service-native trusted restructure-authority gate, a live capability matrix and honest Canvas source classification, plus CAD creation/import and runtime receipt repairs. That source is not committed and not released; on 2026-10-14 it passed the local full App build, the changed App test suites and one live-model representative design loop (see Local/Private/design-workflow-repair-20261013/integration/CONTINUATION-EVIDENCE.md); fine-grained GUI acceptance remains with the coordinator. Sections marked **[Unreleased]** describe module-level work: the core/runtime pieces passed focused module tests, while CAD create/import and the presentation reader were still in acceptance when this page was written. Exact UI wording/buttons and the model-facing tool wiring still have to be calibrated by the integration lane (see the [tool contract](DESIGN_WORKFLOW_TOOLS.md)).

## Quickstart — released Canvas panel (actual UI)

1. Open a Canvas, select the node you want to design from (a text/card node, media/file node, or a built-in Markdown/HTML/SVG card), and add or import its content.
2. Open the Canvas view menu and choose **Design workflow** (`canvas.designWorkflow`). The panel acts on the selected node and reports that node's real capabilities.
3. Save the brief/spec (**Save brief**, **Save spec**); **Apply this spec to the whole canvas** writes the canvas-level spec authority in one Canvas CAS commit, and existing plus new design subdocuments inherit it.
4. Freeze the source: **Use current node content** reads the node's real text, retained asset bytes, bound CAD/Office workspace document or built-in card source through the adapter guards; **Import source…** ingests an external file.
5. Let the assistant/tools propose a revision, inspect it under the candidate section (**Show previews**), then **Adopt** or **Reject**. Assistant adoption additionally needs **Authorize assistant adoption**, which mints a single-use expiring grant.
6. **Export verified…** exports only the recorded format and reopens the bytes with the real parser first; **Restore previous revision** appends a recovery revision instead of overwriting.

## [Unreleased] Conversational entry: one task, three modes

Product rules this round implements in source (module-verified; UI and tool wiring still pending):

- **Natural language starts and continues the same task.** A creative description starts an ordinary, scoped task through the existing atomic task launch; there is no type-selection menu and no mandatory brief/audience form, and no hidden duplicate form remains reachable. Saved briefs, specs, history and candidates are preserved and shown as an editable summary; an old saved target restores its original task when one is bound, and merely reading old data never launches a model run.
- **Four entrances, one service.** Ordinary chat, Creative home, a live workspace file and an original chat attachment all use the same design owner workflow, target/binding, revision authority and adoption confirmation. A Canvas node keeps its existing panel and tools on the same services. No hidden Canvas, second chat, second project or parallel runtime is created.
- **The design view is a view.** The real preview/comparison is the main region with the conversation beside it; summary/spec/materials/candidates expand on demand; per-family sidebars (page list, video timeline, services/ports) replace a universal terminal/file tree. Closing the view does not cancel runs or stop services; a finished task does not silently resume.
- **Canvas keeps its own graphics scope.** Layout, connections, shape/group/card operations, image models and native editors stay on the Canvas transactions. Canvas cannot start Linux, does not receive the ordinary task's full tool set, and never stores a web project directory, dependencies or dev servers.
- **File and attachment bindings are explicit.** The target is the fixed original file or the original task's attachment, never a changing “current selection”; file writes stay inside the guarded workspace root; a result for a chat attachment returns to the original task only.

Three work modes (Core API: `DesignWorkMode`, `DesignWorkIntent` and `DesignWorkScope` in `FloeAgent/Sources/FloeCore/DesignWorkflow.swift`):

| Mode | Before starting | Execution | Preview and completion |
|---|---|---|---|
| create | one natural-language goal; a short follow-up only when a material input is genuinely missing; no form | create the real editable artifact through the connected service; keep materials, inputs and workspace ownership | show the real artifact and continue in natural language; complete only after save/reopen and format validation |
| modify | freeze the stated revision; map the user's location to the real page, selection, fragment or object | edit inside the frozen scope; content outside the scope and the original/manual draft stay recoverable | show the change and the out-of-scope check; adoption updates the explicit original target |
| restructure | read the current state; first confirm in conversation what content, data, behavior and format must be preserved and what may change | reorganize inside a separate candidate; the original is never overwritten first; a manual edit invalidates the old baseline | compare and verify each preservation constraint; only the user's adoption replaces the original; variants can be saved separately |

“Optimize this a bit” is not automatically a rebuild: a local reversible change is a modify, a whole-structure/behavior change is confirmed as a restructure first. Switching modes keeps the current artifact and constraints in the same task. `DesignWorkIntent.validated(family:)` rejects a restructure without complete preservation constraints, an empty object id, a negative page index, non-positive regions/time ranges and a format/family mismatch (`DesignWorkIntentError`).

## [Unreleased] Restructure authority: data is not permission

- `DesignPreservationConstraints` and `DesignPreservationConfirmation` record *what* the user confirmed. They are `Codable` data with a publicly computable digest, so raw model JSON can reproduce them exactly — they are never authority.
- Authority is a non-`Codable` `DesignRestructureAuthorityReceipt` minted by a trusted handler (`DesignRestructureAuthorityHandler`) only after a real single-use claim. The service builds the exact `DesignRestructureAuthorityRequest` (owner target stable key, operation ID, original task owner, resolved base revision, constraints digest) and validates the receipt field-by-field (`DesignRestructureAuthority.validate`).
- The gate runs **before any candidate byte is staged** (`DesignOwnerWorkflow.propose`) and before generation (`DesignWorkflowEngine.freezeRun` / `proposeCandidate`). A nil hook, a denied/expired grant, or a stale/other-owner/digest/operation-mismatched receipt fails closed with zero staged bytes; the new throwing `freezeRun` overload leaves the old non-throwing signature source-compatible. Replaying a recorded operation returns the recorded candidate and does not claim twice; a replay with different preservation requirements is `replayMismatch`.
- The adopt-time single-use claim (`claimAuthorization`) is unchanged and still required to adopt a restructure candidate (`DesignOwnerWorkflowError.restructureRequiresTrustedConfirmation`). No tool-argument string/boolean/JSON field may ever mint this authority; the model's `source`/`digest` values are data only.
- Integration status: the App-side handler that claims the existing approval grant and the tool arguments that pass modes are owned by the integration lane and are **not wired yet**. Until they land, only module-level tests prove these rules; no UI has been accepted.

## [Unreleased] Capability matrix and source classification

- `DesignCapabilityMatrix.assess` answers per `(mode, content family, operation, environment)`. Availability is static wiring **and** a live probe; an unavailable result carries a real reason and a recovery action (`DesignCapabilityAssessment`). Environment keys keep `officeEngineSession`, `linuxGuest`, `mediaGenerationModel`, `cadKernelSession` and `notesPDFService` separate: offline OOXML operations do not require an engine session, and operations that need one report unavailable without it.
- **Capture is not generation.** `importSource` is marked `isCaptureOperation`; `DesignRevisionOrigin.isCapture` (import/current node) and `.isGeneration` (only `.generate`) stay distinct. A web capture saved as a revision is never described as creating a webpage.
- **Layout is not a webpage.** Canvas layout objects (card/shape/group/audio/generation task) classify as `.composition`; an unrecognized but real format is `unsupported(format:)`; an unknown input stays `unknown` and is inspected, never guessed into a webpage. The old card→webpage fallback is gone.
- **Per-family boundaries stay separate.** Image/video generation uses the existing persistent media tasks and the models actually configured for the provider — no capability is promised before it is connected; PDF work stays behind the existing `PDFKitGate`; Notes pages/storage remain an independent workspace, not a design subdocument or chat state; Office/presentation distinguishes offline OOXML operations from operations that need a live engine session, and a PDF/HTML/screenshot never substitutes for the real editable format (for example a validated PPTX).
- Integration status: the live probes are assembled by the integration lane from real services. Until then the matrix honestly reports “not connected + reason” and never claims readiness.

## Model / where things live

| Piece | Location |
|---|---|
| Workflow state machine | `FloeAgent/Sources/FloeCore/DesignWorkflow.swift` |
| Work modes, preservation constraints, authority receipts **[Unreleased]** | `FloeAgent/Sources/FloeCore/DesignWorkflow.swift` |
| Shared owner workflow (propose/adopt, authority hook) | `FloeAgent/Sources/FloeCore/DesignOwnerWorkflow.swift` |
| Capability matrix + source classification **[Unreleased]** | `FloeAgent/Sources/FloeCore/DesignCapabilities.swift`, `DesignCanvasService.swift` |
| DESIGN.md import/edit/export | `FloeAgent/Sources/FloeCore/DesignMDCodec.swift` |
| Subdocument codec (binding + bounds) | `FloeAgent/Sources/FloeCore/DesignCanvasMetadata.swift` |
| Canvas-authority service + adoption grants | `FloeAgent/Sources/FloeCore/DesignCanvasService.swift` |
| Shared UI/tool transaction (decide, apply template, use current node) | `FloeAgent/FloeApp/Workspace/DesignWorkflowActions.swift` |
| Agent tools (`canvas.design*`, `design.*`) | `FloeAgent/FloeApp/Workspace/DesignAgentTools.swift` |
| Panel (separate view) | `FloeAgent/FloeApp/Workspace/DesignWorkflowPanel.swift` |

Design state is a **typed subdocument of the bound Canvas node** (node metadata key `canvas.design`), persisted only through the existing `FileCanvasDocumentRepository` + `CanvasProjectFileWriter` compare-and-swap authority — so backup, sync, fork and revision-conflict handling are the Canvas ones. There is **no independent design store, gallery or project identity**: the node ID is the only identity, it is required, verified on decode, and a binding mismatch fails closed. Node, connections and layout stay in `CanvasProject`. The canvas-level project brief/spec authority lives **on the `CanvasProject` itself** (`designProjectAuthority`, an additive optional field; old packages decode with nil) — not a parallel store.

## Lifecycle guarantees

- **Brief** optional goal/audience/constraints; **spec** optional palette/typography/layout/spacing/brand assets/voice/prohibitions plus raw `DESIGN.md`.
- **Frozen run.** `freezeRun(operationID:inputRevisionID:targetRevisionID:)` pins the input revision, the spec hash and the target before generation/editing; later edits cannot silently change a run's basis. **[Unreleased]** the additional overload validates a restructure's trusted receipt *before generation* and stores the work mode, preservation digest and desired format on the run (`DesignRunFrozen.desiredFormat/workMode/preservationDigest`, optional Codable fields that decode nil for old payloads).
- **Revisions are append-only and recoverable.** Every save is a revision; `restore` appends a new revision pointing at the recovered bytes. Revision compare-and-swap (`expectedRevisionID`) turns stale editors into conflicts, never overwrites.
- **Anchored feedback** is bound to `artifactID + revisionID + anchor` (region/time/page/stable object ID). Changing the artifact's revision marks open anchors `staleAnchor`; the user must relocate them. Validation rejects empty/negative anchors.
- **Feedback resolution requires a real change:** the referenced revision must be the artifact's *current* revision and its content hash must differ from the anchored revision. Model text can never resolve feedback.
- **Candidates are proposals.** `propose` records a proposed revision and a candidate; the artifact is untouched. `adopt` requires a pending candidate, a real content change and (optionally) the expected current revision; `reject` leaves the artifact unchanged. **[Unreleased]** the proposal replay fingerprint binds work mode + preservation digest: replaying the recorded operation returns the same candidate, and a replay with different preservation requirements is refused as `replayMismatch`.
- **Adoption modes.** `updateOriginal` keeps the artifact and its Canvas identity (name/position/size/connections) and promotes the proposed revision; `variant` creates a branch artifact and records the branch point without touching the original. **Revision conflicts protect the original:** a manual edit moved the baseline, so an update-original adoption raises `revisionConflict` (never overwrites) while a variant branches safely — locked by new module tests.
- **Notifications stay on the original task:** adopted chat/creative results return through the existing stores to the originating task only; the durable decision outbox records the intent before the CAS and dedupes by full fingerprint.
- **DESIGN.md is preserved.** Known sections round-trip; the preamble and every unknown section are re-emitted verbatim (byte-stable re-export, verified by test).
- **Persistence is safe.** Writes go through the Canvas CAS (one revision advance per mutation); the subdocument is schema-versioned and bounded (2 MiB); a newer schema or binding mismatch fails closed; operation IDs are recorded for idempotent replay.
- **Templates** carry honest capabilities/inputs/dependencies/formats/license/source/hash/version and an optional rollback version+hash. The signed content service remains the install channel; the registry here only describes what is connected.
- **Project (canvas) brief/spec authority.** `canvas.designSetProjectSpec` (tool) and the panel's brief/spec/propagate actions write the authority in ONE Canvas project CAS: the authority record and every existing design subdocument inherit the payload in the same commit, and new subdocuments inherit on creation. Replay is keyed by operationID **and the full-payload identity** (a changed payload under a reused operation ID is rejected; an identical payload dedupes without a revision bump). Unrelated node edits never change which payload is authoritative, and frozen runs keep their recorded spec hash.
- **Use current node.** `canvas.designUseCurrentNode` (tool) and the panel's “Use current node content” freeze content that already exists on the node — text/markdown body, retained asset bytes, the bound CAD/Office workspace document, or a built-in Markdown/HTML/SVG card's typed text — into a `currentNode` revision through the existing adapter guards, with no external export/reimport. Missing content fails with a precise localized reason; mutable editor state/drafts are not touched.
- **Durable decisions.** Panel and tool adoption/rejection share one transaction (`DesignWorkflowActions`): candidate origin is resolved from the candidate's persisted originating task (a missing origin fails closed — never a fallback to the current chat); a durable outbox intent with the exact node + full operation fingerprint (candidate/decision/operation/mode/base/expected revision) is written BEFORE the CAS; the throwing durable ingress is acknowledged only after it persists, so a crash or failed delivery leaves the decision pending for launch reconcile. Repeated decisions dedupe by fingerprint.
- **Signed templates.** Materialization verifies the canonical package digest against the signed entry, requires the `DESIGN.md` entrypoint, reads the license from a real LICENSE file (otherwise explicitly unspecified), follows rollback/removal through reconciliation, and refuses to apply a template whose stored payload does not match its manifest digest.

## Typed adapter capabilities (released state)

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

**[Unreleased]** CAD gains tool-level `create` and `import` (see the [tool contract](DESIGN_WORKFLOW_TOOLS.md)): the built-in package factory creates a legal `.floecad` package and reads it back; importing STEP/IGES/STL/OBJ/GLB/glTF geometry into an existing package drafts a proposal and changes nothing until preview + UI grant + apply. Imported geometry never fabricates a parametric feature tree, IGES shells/faces and mesh formats stay render-only, and the verified-export gate above is unchanged.

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

**[Unreleased]** `cad.document` adds `create` and `import` actions; the `design.*`/`canvas.design*` names and parameters are unchanged. Passing work modes and restructure authority through the model-facing arguments, and wiring Canvas actions to pass an optional work intent, are owned by the integration lane; no raw string/boolean “authorization” argument may be added.

## Templates

Built-in templates ship with the app; user templates are stored in `Application Support/FloeAgent/DesignTemplates` with immutable version directories and atomic pointer swaps (rollback restores the real previous bytes). Templates delivered by the **signed content-update service** (kind `templates`) are materialized read-only into the same library with hash verification; install/update/rollback stay in Content Update settings. Template UI lives in the design panel (Creative), not Skills.

## Tests

**Released engine suites:** `Tests/FloeCoreTests/DesignWorkflowTests.swift`: freezing, candidate-not-applied-until-adopt, no-op proposal rejection, variant branching, anchor staleness/relocation, resolution requiring a real change, revision conflicts, restore, DESIGN.md round-trip and spec hashing, canvas-subdocument binding/malformed/newer-schema safety, operation-ID dedup and capability honesty. Beyond the engine suites: whole-project adoption (real node content in one CAS, layout preserved, replay skips content work), project-spec authority (three nodes inherited in one commit, repeated different payloads, changed operation payload rejected, stale revision conflict, unrelated node edit, frozen run preserved, new-node inheritance, reopen), the decision outbox (full fingerprint dedupe across relaunch, legacy-envelope backfill, first write/reopen, corrupt/newer-schema read-only with observable errors, pending never pruned, hard cap), the payload store (traversal/symlink/overwrite/cross-canvas), template persistence and signed-package digest authority, the retained-image evidence policy (real PNG/JPEG/WebP/GIF bytes, MIME spoof, over-limit pre-decode rejection, duplicate/two-result attribution, Chat/Responses/Anthropic serialization), and FloeAppTests integration (image end-to-end import→adopt→export with delivery-failure reconcile, missing-origin fail-closed, project-spec tools across three nodes, use-current-node text + precise localized unavailable reasons, built-in Markdown/HTML/SVG cards source→propose→adopt→restore→verified-export and precise unsupported states, cross-task capture fail-closed).

**Module evidence for the unreleased source (2026-10-13, branch `codex/design-workflows-20261013`, Xcode 27.0/Swift 6, focused SwiftPM harness):** FloeCore ran 495 tests including 20 new intent/classification tests; the authority follow-up ran 141 focused tests including 8 new authority tests (forged matching source+digest denied with zero staged bytes, genuine bound claim accepted, stale/wrong-owner/digest/operation refused, idempotent replay does not claim twice). Runtime/log-repair evidence is listed in the [tool contract](DESIGN_WORKFLOW_TOOLS.md). This is module-level evidence; the 2026-10-14 continuation added the full App compile, 15 changed App suites (78 Swift Testing + 53 XCTest cases), 26 native-CAD App tests, the conversational-entry UI test and one live-model design loop, and the real PPTX artifact passed independent python-pptx/openpyxl readback. Fine-grained GUI and on-device acceptance remain with the coordinator.

## Open gates

Engine-command edits for office/presentation stay delegated to the office proposal flow even though a bound workspace document supports import/verified export; 3D CAD verified export (exchange/mesh formats and `.floecad` packages) has no connected single-payload reader yet and must not be claimed as verified; real-provider generation loops need configured credentials. **[Unreleased]** the conversational UI, the mode/authority tool wiring and the capability live probes are not integrated yet, so none of them may be presented as accepted or installable; visual acceptance and physical-device checks remain pending and are never implied by a passing unit test or a green build.

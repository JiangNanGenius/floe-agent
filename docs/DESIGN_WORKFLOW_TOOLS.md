# Design workflow tools (shared AI + UI)

Status: implemented by T5 (typed shared-target tools). The schemas below are
the compiled tool contracts the model sees; this page is the human reference.

Delivery state: the Canvas-anchored design tools described here shipped in the
1.7.29 (270) source (tag `v1.7.29`). Branch `codex/design-workflows-20261013`
(baseline `734e97f5`) carries **unreleased** additions: work modes and the
trusted restructure-authority seam for the owner workflow, `cad.document`
create/import, structured delegate receipts, unknown-outcome reconciliation
and per-call timing, and optional presentation bullets. As of the 2026-10-14 continuation, the local full App build, 15 changed App suites,
26 native-CAD App tests, the conversational-entry UI test and one live-model design
loop have passed, and the real PPTX artifact passed independent python-pptx/openpyxl
readback; fine-grained GUI acceptance remains with the coordinator. Sections marked
**[Unreleased]** are not in any installed build.
TestFlight/public installation state is tracked in
[CURRENT_STATUS.md](CURRENT_STATUS.md), not on this page.

The design workflow has ONE state machine (`DesignWorkflowEngine` over a
`DesignProject`) and TWO owner authorities:

- **Canvas nodes** — the Canvas document CAS (`DesignCanvasService`, node
  metadata `canvas.design`), exposed through the legacy `canvas.design*`
  tools and the design panel.
- **Everything else** — file documents, original chat attachments and
  creative creation targets, through the shared owner workflow
  (`DesignOwnerWorkflow`, owner envelope + payload store on the existing
  artifact authority).

Both share the same validation, revision-bound proposal/candidate/adopt/
reject/restore/export and the same durable decision events. The generic
owner workflow refuses `.canvasNode` (no second Canvas authority); typed
Canvas mutations return an explicit pointer to the compatible canvas tool.

## Typed target descriptor

Every `design.*` tool takes one frozen target:

```json
{
  "kind": "fileDocument",
  "ownerID": "8C2B0A8E-...-workspace UUID",
  "documentID": "",
  "sourceID": "specs/home.md",
  "environmentID": "optional",
  "revision": "frozen base token returned by design.resolveTarget/freezeInput",
  "originConversationID": "provenance only",
  "requestedOutputKind": "creative START only"
}
```

Rules:

- `kind` is one of `canvasNode`, `fileDocument`, `chatAttachment`,
  `creativeDocument`.
- File `sourceID` is a workspace-relative reference resolved through the
  live workspace permission/bookmark services — an absolute path or
  `../` is never authority.
- Chat `ownerID` is the ORIGINATING conversation, `sourceID` the
  attachment reference. The original attachment is never modified or
  deleted; the adopted result is returned as a NEW attachment in that
  same task only.
- `originConversationID` cannot widen authority. When the run has a
  durable task binding, a mismatching value is rejected; the stored
  provenance comes from the live run context. A run can only use a chat
  attachment owned by its own task.
- `revision` is a frozen base token. Mutable manual edits move it; a
  candidate whose base no longer matches is rejected at adoption
  (`revisionConflict`) instead of overwriting.

## Tool reference

Read-only:

| Tool | Purpose |
| --- | --- |
| `design.resolveTarget` | resolve a typed target to verified metadata (format, content family, current revision token, editability, origin) with an honest unavailable reason |
| `design.getState` | shared design state: brief, spec, frozen run, artifacts/revisions, feedback, candidates (canvas kinds read through the Canvas service) |
| `design.compare` | candidate vs base from retained bytes; digest change proof plus bounded unified diff with `diffTruncated`/`diffNote` |

Mutations (require `operationID`; owner revision compare-and-swap):

| Tool | Purpose |
| --- | --- |
| `design.updateBrief` / `design.updateSpec` | brief / design spec (DESIGN.md import supported) |
| `design.freezeInput` | freeze the resolved source as the base input revision |
| `design.registerEdit` | record a manual/generated save as a new revision (payload bytes read and hash-verified by the tool) |
| `design.addFeedback` / `design.resolveFeedback` | anchored feedback; completion only against a verified changing revision |
| `design.creativeBegin` | persist a creative START request (requested kind + brief/spec) before any material exists |
| `design.creativeBindFirstResult` | bind the FIRST real generated result (verified bytes); later edits use `registerEdit`/`propose` |
| `design.propose` | revision-bound candidate from real app-storage bytes; stays pending until adopted |
| `design.adopt` | adopt with a user-confirmed single-use grant (see below) |
| `design.reject` | reject a pending candidate; durable event to the originating task only |
| `design.restore` | restore an earlier revision (retained bytes re-verified) |
| `design.exportVerified` | export retained bytes after a real format reopen; no format conversion |

## Trusted confirmation (cannot be minted by the model)

Adoption requires a single-use grant minted by the user's explicit
confirmation, bound to the EXACT target stable key, candidate, baseline
revision, proposed revision and mode:

```swift
let grantID = await DesignOwnerAuthorization.shared.issueOwnerAdoption(
    targetStableKey: target.stableKey,
    candidateID: candidate.id,
    baselineRevisionID: candidate.baseRevisionID,
    proposedRevisionID: candidate.proposedRevisionID,
    mode: .updateOriginal,
    scope: .aiTool)   // hand to the run; .trustedUI for a direct UI adoption
```

Then:

```json
{
  "target": { "…": "…" },
  "operationID": "adopt-brief-1",
  "expectedOwnerRevision": 2,
  "candidateID": "cand-…",
  "mode": "updateOriginal",
  "grantID": "grant-…"
}
```

- The confirmation is CLAIMED ATOMICALLY inside the shared adoption
  transaction, immediately before the first side effect (durable intent /
  owner write): the exact target stable key, candidate, baseline revision,
  proposed revision, mode and caller scope are checked and burned in ONE
  `ApprovalGrantStore` call. A missing, expired, revoked, already-claimed
  or mismatched grant fails with zero side effects, and a mismatch never
  burns the grant. A grant for `updateOriginal` cannot be replayed as
  `variant`.
- A claimed grant authorizes exactly ONE frozen operation. A failure after
  the claim (even a proven zero-write failure) requires a FRESH user
  confirmation; the store never silently re-arms a claimed grant.
- Replaying the recorded operation returns the recorded result without
  claiming again and without duplicating files or events; a replay with a
  changed mode is refused as a mismatch.
- `design.propose` replay is exact and implemented in the shared service:
  the operation → candidate record (candidate id, proposed revision and
  payload pointer, plus a canonical fingerprint of artifact/base/format/
  bytes/summary/diff/feedback/origin) is committed in the SAME envelope
  transaction as the candidate. A repeated `operationID` returns the
  recorded candidate and payload with no second revision, candidate or
  staged payload; changed bytes, format, artifact, base, summary, feedback
  or origin is refused as `replayMismatch` before any staging. The same
  bytes under a DIFFERENT operation ID are a legitimate new proposal, and
  the record survives workflow reopen and persistence encoding.
- Default adoption (`updateOriginal`) updates the original authorized
  target (workspace file in place, verified by readback) and returns
  immutable-owner results (chat/creative) to a NEW destination through
  the existing stores. `variant` explicitly branches instead.

## [Unreleased] Work modes and restructure authority (owner workflow)

The approved round adds an optional `DesignWorkIntent` (mode
`create`/`modify`/`restructure`, real desired format, precise scope,
preservation constraints, original task owner, confirmation record) to the
shared owner workflow. The core API is source-compatible: every new parameter
has a default, and `DesignRunFrozen`/`DesignCandidate` gain optional
`workMode`/`preservationDigest`/`desiredFormat` fields that decode nil for
old payloads. A `restructure` intent without complete preservation
constraints is rejected (`DesignWorkIntentError.preservationConfirmationRequired`).

Authority rules (data ≠ permission):

- `DesignPreservationConfirmation` is the **record** of what the user
  confirmed: it is `Codable` with a publicly computable digest, so model JSON
  can reproduce it. It is never authority.
- Authority is a non-`Codable` `DesignRestructureAuthorityReceipt` minted by a
  trusted `DesignRestructureAuthorityHandler` only after a real single-use
  claim. The service builds the exact request (owner target stable key,
  operation ID, original task owner, resolved base revision, preservation
  digest) and validates the receipt field-by-field.
- The gate runs before any candidate byte is staged
  (`DesignOwnerWorkflow.propose`) and before generation
  (`DesignWorkflowEngine.freezeRun`/`proposeCandidate`); nil hook,
  denied/expired claim, or a stale/wrong-owner/digest/operation receipt fails
  closed with zero staged bytes. Replaying a recorded operation does not
  claim twice; different preservation requirements on replay are
  `replayMismatch`.
- Adopting a restructure candidate still requires the existing adopt-time
  single-use claim (`claimAuthorization`) or fails with
  `restructureRequiresTrustedConfirmation`. No tool argument (string,
  boolean or JSON) may mint authority; a model-provided `source`/`digest` is
  data only.
- **Integration status:** the App-side handler that claims the existing
  approval grant and the tool arguments that carry modes/authority are not
  wired yet. Until then these rules are module-level verified only; do not
  present them as connected UI.


## Design freeze and ordinary write tools (original protection)

**[Unreleased]** While a candidate is pending, the original workspace file bound as a
design target is frozen: the model's ordinary `workspace.writeFile`/`createFile(overwrite)`/
`applyPatch`/`moveFile`/`deleteFile`/destination-side `copyFile`/binary writes to that path
return a structured refusal (`DesignFreezeError.sourceFrozen`, naming the owning task and
the recovery — stage the change as a `design.propose` candidate, or let the user
reject/cancel first). The freeze matches canonical path AND (device, inode) identity:
`../` traversal, symlink swaps, delete-and-recreate and hard-link aliases cannot bypass it.
Reads, new files, staging, unrelated files and package installs stay open; trusted manual
edits (UI path) are not intercepted but invalidate the candidate base — the adoption
optimistic gate fails closed and preserves the user's change. The freeze lifts after a
verified adoption or when the last pending candidate is rejected. Raw guest VFS writes
from the Linux guest are out of Swift gate scope (marked unsupported backend): if the
guest changes the original, the adoption frozen-SHA gate refuses to overwrite and keeps
the current bytes.

## Creative source authorization

A creative creation target pre-exists independently of any workspace or
canvas containment, so containment alone cannot authorize it. An agent run
calling `design.creativeBegin` / `design.creativeBindFirstResult` must
carry the RUNTIME approval for that exact call
(`ToolContext.approvalGrantID`, minted by the policy/human gate and
validated against the tool descriptor before execution); without it the
call fails with an explicit reason. In addition, the creation target and
any bound result asset must belong to the run's own task (live run→task
linkage) — a foreign or unknown-owner asset fails closed. Trusted in-app
UI calls the workflow directly (`runID == nil`) and is unaffected. There
is no private grant store and no blanket allow.

## Examples

Resolve and freeze a workspace file:

```json
{ "tool": "design.resolveTarget",
  "target": { "kind": "fileDocument", "ownerID": "<workspace-uuid>",
              "sourceID": "specs/home.md" } }
{ "tool": "design.freezeInput",
  "target": { "kind": "fileDocument", "ownerID": "<workspace-uuid>",
              "sourceID": "specs/home.md" },
  "operationID": "freeze-1" }
```

Propose and compare:

```json
{ "tool": "design.propose",
  "target": { "…": "…" },
  "operationID": "propose-1",
  "expectedOwnerRevision": 1,
  "artifactID": "<artifact from freeze>",
  "payloadRelativePath": "ChangeArtifacts/edit-1.md",
  "summary": "tighten the intro" }
{ "tool": "design.compare",
  "target": { "…": "…" }, "candidateID": "<candidate from propose>" }
```

Adopt a chat-attachment result (only the original task is notified and
receives the new attachment):

```json
{ "tool": "design.adopt",
  "target": { "kind": "chatAttachment",
              "ownerID": "<originating-conversation-uuid>",
              "documentID": "<message-uuid>",
              "sourceID": "att-original" },
  "operationID": "adopt-1",
  "expectedOwnerRevision": 2,
  "candidateID": "<candidate>",
  "mode": "updateOriginal",
  "grantID": "<user-confirmed grant>" }
```

Creative start before material exists:

```json
{ "tool": "design.creativeBegin",
  "target": { "kind": "creativeDocument",
              "ownerID": "<creative-owner>",
              "sourceID": "<creation-id>",
              "requestedOutputKind": "image" },
  "operationID": "creative-start-1",
  "goal": "product hero shot",
  "audience": "launch page" }
```

Then generate with the existing media services and bind the result with
`design.creativeBindFirstResult` (`boundResultID` + verified
`payloadRelativePath`).

## Legacy Canvas tools (compatibility)

`canvas.designGetState`, `canvas.designCreate`, `canvas.designUpdateBrief`,
`canvas.designUpdateSpec`, `canvas.designRegisterRevision`,
`canvas.designImportSource`, `canvas.designUseCurrentNode`,
`canvas.designExportRevision`, `canvas.designAddFeedback`,
`canvas.designPropose`, `canvas.designBindDocument`, `canvas.designAdopt`,
`canvas.designReject`, `canvas.designRestore` and the project-spec tools
keep their names, parameters and return shapes. They remain the Canvas
wrappers over `DesignCanvasService` (integer canvas revision CAS,
`canvas.designAdopt` user grant). A typed `design.*` mutation invoked with
`kind:"canvasNode"` returns
`{"migrationError": true, "compatibleTool": "canvas.designPropose", …}`
(status 2) — an explicit migration pointer, never a second Canvas path.

## [Unreleased] CAD creation and import (`cad.document`)

Two actions are added to the existing one tool; both are native-engine only
(DWG/DXF 2D drawings keep their own read/edit surface):

| Action | Arguments | Contract |
| --- | --- | --- |
| `create` | `path` (new `.floecad` location), optional `name` | Creates a new EMPTY native package through the host factory: sanitized unique name, guarded local-workspace path, non-overwriting atomic commit, then a real store read-back. The model never writes package bytes and never guesses the internal directory/manifest layout. |
| `import` | `path` (an EXISTING `.floecad`), `source_path`, optional `format`, `unit_scale`, `name`, `summary` | Adds the geometry of a workspace STEP/STP, IGES/IGS, STL, OBJ, GLB or glTF file by drafting a proposal on a throwaway copy; it returns a preview and changes nothing until the user confirms in the CAD UI and the returned proposal is applied with that UI-issued grant. |

Format boundaries are stated per format by the tool (`geometry_class` and
`note` in the capabilities reply): STEP/IGES solids import as exact B-rep
bodies (IGES shells/faces stay render-only; IGES export is not available in
this build); STL/OBJ/GLB/glTF import as render meshes with **no parametric
history**; loose `.obj`/`.gltf` keep their material/texture siblings; the
source file is read through the workspace guard and never modified. Errors
distinguish a missing file, a non-package, an unreadable manifest, an
unsupported format/engine and a permission refusal. `capabilities` without a
document reports the 2D and native-3D engines separately, so a 2D limitation
is never read as “3D unavailable”. Creation/import is a write operation and
stays approval-gated; `create` is refused against a staged Canvas draft (that
staging authorizes one existing document, not new packages).

## [Unreleased] Runtime receipts: subagents, unknown outcomes, per-call timing

- **Delegated subagents return structured outcomes.** `SubagentOutcome.Status`
  is `completed` / `partial` / `budgetExhausted` / `cancelled` /
  `providerError` / `toolError`; only `completed` is success. The `delegate`
  tool receipt renders `status=ok` for completed and the real status name
  otherwise, always with `iterationsUsed=N`, plus bounded `evidence:`/
  `unfinished:` lists. Non-ok outcomes map to `exitStatus=1` and therefore to
  a failed `ToolResult` — a partial/budget/cancel/error can never be read as
  an ok subtask. The final summary is capped at 8 KiB and appends an explicit
  `[summary truncated]` marker instead of silently dropping the tail; the last
  budget slot is reserved for a bounded wrap-up instead of an unbounded loop.
- **Unknown outcomes are categorized and only narrowly reconciled.** The
  durable suppression receipt records `interruptedDispatch` (app relaunch or
  suspension after dispatch), `capabilityRemoved`, or legacy `unattributed`.
  Suppression wording states the real category (an app-restart interruption
  is never described as a capability removal) and its readable escape paths.
  A typed reconciler may dissolve a receipt **only** for
  `interruptedDispatch`, and the Linux reconciler only for the start-class
  `environment.startLinux` route when authoritative read-only state proves a
  quiet stop (no registered instance, engine not running, not quarantined)
  and the retry's explicit shape matches the saved startup shape. Arbitrary
  commands, restarts and unknown paid submissions are never reconciled, and
  insufficient evidence keeps the suppression. The ledger overflow sentinel
  is never reconciled.
- **Linux channel honesty.** The command channel now traces
  admitted/sent/guestAccepted/cancelRequested/stopConfirmed/completed/
  guestExited/poisoned with environment/generation/lease/request identity but
  **no command bodies**. The exit-125/timeout messages state that the session
  was torn down and the next command cold-starts a fresh guest with the last
  successful configuration, without claiming whether the interrupted command
  ran. The root cause of the channel stalls observed in the supplied logs was
  not reproduced on this host; the instrumentation and the reconciliation
  bridge are the delivered work, not a proven root-cause fix.
- **Per-call timing is real and monotonic.** Tool-result payloads persist
  `durationMs` (real dispatch→finish execution measured with a monotonic
  clock), `queuedMs` (only for genuinely dispatched calls) and
  `dispatched` true/false. A call that was suppressed, denied, cancelled or
  recovered without dispatch records `durationMs=0` and
  `dispatched=false` — a missing measurement is never fabricated into a
  non-zero duration, and queue time is not counted as execution time. This
  changes telemetry only, not execution concurrency.
- **Integration status:** the typed runtime seam exists, but the App-side
  adapter that supplies the Linux reconciler (bound to the run's environment
  identity, never inferred from model text) is not wired yet; until it is,
  unknown outcomes stay fully suppressed as before.

## [Unreleased] Presentation schema: bullets are optional

`document.presentation.createDeck` accepts object-only slides: a slide needs
only `title`, and an omitted `bullets` decodes to an empty list. Explicit
`null` or a wrong type is still rejected rather than silently accepted, and
the JSON schema's required list agrees with the decoder (`["title"]`). Charts
embed a real editable `.xlsx` workbook and images/shapes are native OOXML —
a validated PPTX, never an HTML/PDF/screenshot substitute. Module-level DTO
compilation and object checks passed; full PPTX generation, an independent
reader and the complete App build were still pending when this page was
written.

## Honest limits

- A tool result is a state report: a candidate is NOT adopted and an
  immutable-owner result is NOT returned until `resultPublication` says
  `published`. `resultPublication:"pending"` keeps the durable record open
  for launch reconcile and must not be shown as a completed return.
- `diffTruncated:true` / `diffNote` mean the displayed diff is not the
  complete change set; digests are the change proof.
- Format support reflects the real connected parsers: unsupported formats
  return an unavailable reason instead of a fallback.
- Remote submission state is never guessed: duplicate operations replay
  the recorded result; the durable outbox reconcile owns retries.
- **[Unreleased]** work-mode/authority, CAD create/import, runtime receipt and
  timing additions are verified at module level only. Their App compilation,
  tool argument wiring, UI presentation and live-model behaviour have not run,
  and the CAD lane's create/import acceptance tests plus the full PPTX reader
  check were still in progress when this page was written; do not read this
  page as an integration or release claim.

## [Unreleased] Preview-first design page, entry policy, routing and pre-dispatch protection (2026-10-14)

- **Preview-first design page.** The design workbench for a bound task is a real artifact
  preview (web engine / image / video / Quick Look / text) beside the SAME conversation;
  brief/spec/work-mode/feedback live in a collapsed inspector, never as the landing form.
  Fullscreen is an in-page mode over the same view tree (one explicit Done, no nested
  presentation), so the preview, session, composer draft and selection are retained through
  fullscreen/rotation/split. Family limits are explicit: CAD has no inline renderer and routes
  through the existing professional handoff; office previews are labeled read-only with the real
  editor handoff; presentation/office payloads are never faked as editable HTML/PDF.
- **Entry policy (shared, testable).** A design entry appears only from durable truth: an
  explicit binding plus a retained, really presentable artifact (per-format preview table,
  separate from generate/edit capability). Ordinary Q&A, keywords, attachments alone or an
  empty binding never show an entry and never auto-open anything. Default make/modify delivery
  completes in the original flow; the entry is a lightweight “view artifact” that only opens on
  a user click. Restore/relaunch republishes the same state from durable records.
- **Candidate decisions are on demand.** While a pending candidate lens is selected: one
  primary adopt plus a compact menu (compare / variant / reject / assistant authorization);
  nothing stays resident for the current artifact, a resolved candidate collapses the bar, and
  cadence decisions never squeeze the long-term preview.
- **Original-write protection lifecycle.** An explicit bound modify/restructure freezes the
  original at launch and on every continuation (fail closed when it cannot), pre-dispatch
  guest/native execution gates refuse arbitrary commands while frozen (read-only inspection
  keeps working), model-controlled decisions never lift the freeze, verified adoption re-arms
  the new baseline, and the freeze lifts only at a completed run with nothing pending, a trusted
  user resolution, or conversation deletion. Per-target release scope: resolving one target
  never unfreezes a sibling target’s pending original; multi-owner entries are independent;
  directory/webroot originals freeze existing files and parent mutations. Persistence is proven
  by a store round-trip; a save failure fails the required launch closed.
- **Creative destination routing + canvas handoff.** `creative.chooseDestination` routes a
  creative request to a real canvas (created durably, opened through the existing canvas
  surface) or to a NEW ordinary project + task under the same authorized provider/model, with
  the full request digest as the idempotency identity (same id + different payload = conflict).
  `canvas.startOrdinaryTask` transfers explicit canvas materials as verified immutable
  snapshots (bounded, uniquely named, manifest with node/hash/size) into an atomically reserved
  workspace; the durable record is persisted before the deferred task starts, replays/restores
  never duplicate or re-send, and unknown outcomes converge by querying the durable rows. The
  handoff transfers no execution authority: the canvas stays visual-only and the new ordinary
  task uses its own capabilities and approvals.
- **Honest limits.** Live Linux guest verification was not run this round (dispatch-level +
  module coverage only); the design-page GUI judgment (visual polish, rotation feel) is
  primary-coordinator acceptance, not claimed here. Everything above is [Unreleased] and not a
  release or full-App acceptance claim.

## 2026-10-14 round-2 amendments (current source)

- **Canvas model handoff is actually callable.** `canvas.startOrdinaryTask` is now part of
  `CanvasAgentToolPolicy.nativeToolNames`, so a real canvas run's allowed tool names include it
  (no Linux/shell/workspace-write names enter the canvas ceiling through it). Its execution is
  bound to the durable `CanvasRunContextStore` record of the calling run: a supplied canvas id
  that differs from the binding, a run without a binding, or a node outside the user's
  selected/named set is refused BEFORE any material byte is read. The destination is explicit
  (exactly one of an existing project workspace — verified to exist — or `createProject=true`),
  the aggregate material size is preflighted from asset metadata before loading, staged files
  keep the original UTF-8 display name plus a content-hash suffix, and the route record carries
  the source document id and inspected project revision next to every material hash.
- **Route lifecycle is crash-safe.** A stale `prepared` record reconciles against the real
  launch facts (RunLaunchStore commits conversation+run in one transaction before provider
  I/O): an existing launched destination converges to `started` and is never re-sent; a bare
  conversation without its run fails closed; store reads fail closed (a read error is never an
  empty store); concurrent identical calls coalesce on per-operation in-flight ownership; a
  conversation that is itself a route destination cannot recursively spawn another destination;
  no `fatalError` remains on recoverable paths.
- **Destination assessment is intent-based.** A Linux need always routes to an ordinary
  project — `hint=canvas` can never accept a canvas+Linux plan. Native CAD visual composition
  may stay on the canvas; Office originals route by real native/live capability and are never
  replaced by HTML/PDF. The model's explicit `hint` is honored (project always; canvas for
  visual families, otherwise refused with the reason) — family alone never silently re-routes
  an explicit choice.
- **Navigation is delivered visibly.** Foreground route delivery dismisses the root-owned
  covers (canvas destination cover, design page cover) before selecting the destination
  conversation; the foreground probe also accepts the run whose canvas is the presented canvas.
  The canvas destination opener shows a truthful error with retry/close instead of an infinite
  spinner.
- **Design page layout/fullscreen.** The page is a root full-screen cover (whole available
  window, no dimmed margins); the in-page fullscreen toggle only clips the conversation pane to
  zero width — the same live web view, media player, QuickLook/editor host, chat, drafts and
  selection stay mounted. The format/byte badge reserves its own strip above the preview
  (never over the page heading); the details panel is genuinely trailing (spacer-based, width
  clamped 280–360, no hardcoded 360); compact widths get an explicit segmented preview/chat
  switch (`design.page.sectionPicker`, 44pt); the editor handoff can no longer re-present the
  design page on top of itself.

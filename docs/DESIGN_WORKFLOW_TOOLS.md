# Design workflow tools (shared AI + UI)

Status: implemented by T5 (typed shared-target tools). The FloeApp object
compile and the integrated behavioral run are executed by T7 in the full
App; the schemas below are the compiled tool contracts the model sees.
Localization of panel copy is T6-owned; this page is the human reference.

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

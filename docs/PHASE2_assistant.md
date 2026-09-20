# Phase 2 — assistant: local-model lifecycle, cross-conversation access, Notes grants, native mind map

Status: **assistant worker contract, published before implementation completes.**
Date: 2026-09-21. Base: `46422286` (post Build211). Worktree: `codex/tinyemu-phase2-assistant`.

This page is the cross-worker contract for the assistant repair scope: local
model tool-call lifecycle and context handling, cross-conversation discovery
and search, Notes assistant permissions/tool efficiency, and the native mind
map layout/drag cost repair. It records the interfaces this worker consumes
and provides, and the exact integration points that remain open. Dated test
evidence and the final SHA land in the report section at the bottom.

中文摘要见文末。

## 1. Scope consumed from other workers

- **Migration worker** (`codex/tinyemu-phase2-migration`, `docs/PHASE2_migration.md`):
  the §4 grant/isolation contract. Notes guest work runs in the Notes task's
  **own session environment and workspace share** — never a shared
  Notes-wide interpreter and never a project-wide VM belonging to another
  task. `exec.localPython` / `exec.shell` names and schemas are unchanged.
- **Engine worker** (`codex/tinyemu-phase2-engine`): the guest 9p server must
  reject `..` walks and symlink escapes outside the exported share roots.
  The Notes auto-grant below relies on that enforcement plus the per-task
  share list; path conventions and task IDs are **not** the isolation
  mechanism (migration contract §3.3/§4.1).

## 2. Notes assistant grant and enforcement (provided to migration/app workers)

The previous `NotesDocumentApprovalPolicy` auto-allowed only `notes.edit` and
delegated everything else to the human card, so every Python/Shell call in an
already-authorized document task prompted repeatedly. The repaired grant:

1. **Per-task confined execution root.** Every Notes assistant conversation
   (purpose `.notes`) runs with its own scratch workspace root
   (`Application Support/FloeAgent/Notes/AssistantWorkspaces/<conversationID>/`).
   That root is the run's `workspaceRootURL`, so the existing execution
   boundary — `ToolContext.authorizeWorkspacePath`, the
   `EnvironmentExecutionCoordinator` ownership checks, and the guest's
   per-environment 9p share list — confines every script to that task's own
   mounts. Staged inputs and generated outputs (charts, converted files)
   live only inside this root; `notes.attachFile` imports outputs back into
   the document as one undoable edit.
2. **Session environment is explicitly Linux-backed.** When a Notes run is
   prepared, the app ensures the conversation's session environment with an
   explicit `.linuxVM` backend. If that environment cannot be ensured, the
   policy does **not** auto-grant execution and falls back to the human card.
   When the Linux component is missing or the guest is not running, the
   migration facade fails honestly with the reason; there is no silent
   native fallback inside an auto-granted Notes task.
3. **Scoped handlers auto-grant; no script-text screening.** String
   detection (`curl`/`requests`/…) is **not** used as a permission boundary:
   it misses aliases/obfuscation and re-prompts legitimate current-task
   downloads. The policy deterministically auto-grants every tool whose
   handler is concretely scoped to the current document or the current
   task's confined scratch:
   - `notes.read` / `notes.search` / `notes.edit` (owned document),
     `notes.attachFile`, `notes.stageAttachment`;
   - the bounded scratch file tools (`workspace.listDirectory/readFile/
     searchFiles/inspectFileMetadata/createFile/writeFile/applyPatch/
     createDirectory/moveFile`) — the workspace ceiling confines them to
     the task scratch at execution time;
   - `document.pdf.inspect` / `document.pdf.render` /
     `document.office.inspect` / `image.ocr` on scratch files;
   - `exec.localPython` / `exec.shell`, **including** installing compatible
     packages into the task-owned environment (`packages` / `pipCommand` /
     `pip install`);
   - `conversation.search` / `conversation.read` / `conversation.list`,
     `checklist.readPlan` / `checklist.updatePlan`, `memory.recall`,
     `tools.search` / `tools.list`.
   The actual enforceable network lever is the **task network policy**, not
   text matching: when `TaskPolicy.networkAllowed == false`, any call whose
   catalog risk labels include `networkAccess` (exec, shell, package
   installs) escalates to the user; when the policy permits networking,
   already-authorized processing — downloads included — inherits scope
   without a prompt. A generic code/software-install label alone never
   triggers a prompt.
4. **What still asks.** Everything outside the scoped set keeps the human
   card: external share/send/transmission actions (mail, browser, SSH,
   remote/git publication, Apple shares), provider-backed semantic sends of
   document bytes (`image.inspect`), other documents, destructive or remote
   effects, and any non-`.local` scope. The catastrophic gate still runs
   before this policy. Document text and tool output are never consulted to
   grant scope, and the policy claims **no** script-content containment —
   semantic review stays advisory; containment is the share list, the
   engine 9p walk/symlink enforcement, the workspace ceiling and the task
   network policy, and these limits are documented honestly.
5. **Authorized inputs.** A new bounded `notes.stageAttachment` tool copies
   an attachment of a document the conversation already holds a grant for
   into the task workspace (read grant, size-capped, name-sanitized), so
   Python/Shell processing (conversion, charts, OCR) works on real bytes
   without any host path access.
6. **Tool exposure ceiling.** Notes runs receive the reduced catalog
   described above (scoped handlers plus `image.inspect` for explicit
   user-approved visual questions) instead of the full app catalog, with
   `tools.search`/`tools.list` on-demand discovery bounded inside that
   ceiling. The MLX local-model admissible list gains the bounded
   `notes.read`/`notes.search`/`notes.edit` entries so a local model in a
   Notes session is no longer tool-blind.

## 3. Local model tool-call lifecycle (providers/agent runtime)

User report: any tool call on a local model crashes; context explodes and
compaction fails. Build211 crash evidence (report `856863bd-…`, received
2026-09-20T12:25:13Z): the documents worker's dSYM symbolication resolves the
22:01:31 SIGABRT to
`getItemND(src:operations:stream:)` (`MLXArray+Indexing.swift:695`) ←
`Qwen35GatedDeltaNet.generalConv(convState:qkv:)` (`Qwen35.swift:445`) ←
`Qwen35DecoderLayer` ← `LLMModel.prepare` ← `withPreparedCache`
(`KVCache.swift:128`) — inside the pinned mlx-swift-lm's Qwen3.5 gated-delta
**prefill** graph (the conv-state slice at the end of `generalConv`). The
22:10:31 FOUNDATION termination with ios_system/text/pthread frames is a
separate event, possibly shell-originated; the documents worker owns its
symbol fetch. Inspection of the pinned Qwen35 state shapes shows
`zeroStates`/`generalConv` keep the conv state at `kernel-1` rows in every
reachable path, so the remaining consistent mechanism is an uncatchable Metal
evaluation abort surfacing at that slice's sync point during chunked prefill
— and every local turn (and every tool-invocation repair) re-prefills the
whole bounded transcript, so each turn is repeated exposure. This worker
therefore ships the bounded repairs that are independent of the final
upstream answer:

- **The tool-invocation repair no longer re-prefills the whole transcript,
  and does not lose referents either.** Its prompt is a bounded referential
  context: the newest recent turns, settled and pending tool evidence with
  call IDs (so "继续" / "把它导出" still resolve to their files and results),
  the full current request, then the directive — all byte-clipped, old bulk
  transcript excluded. This halves prefill exposure on the exact "model must
  call a tool" path and cuts repair latency.
- **GDN prefill chunk ceiling (targeted mitigation, pending device
  evidence).** The pinned upstream shapes are provably valid on every path
  reachable from Floe's single-batch, fresh-cache, one-prefill-per-turn
  usage, so the `generalConv:445` abort is consistent with — not proof of —
  a Metal evaluation failure whose transient graph scales with the prefill
  chunk. Qwen3.5/3.8 (GDN) models now cap `prefillStepSize` at 32, the value
  the constrained tier already ships for this abort class (the Gemma
  precedent in `LocalInferenceResourcePolicy`); other families keep their
  profile. Logged per engine load as `gdnChunkCapped`. This is a bounded
  mitigation traded against prefill latency, recorded here as requiring
  on-device confirmation; it is not claimed as a proven root-cause fix.
- **Tool-gap breadcrumbs.** The local adapter emits structured, byte-bounded
  log markers when a local turn ends in a tool request (engine unloaded for
  the tool-execution gap) so the next termination report identifies the
  phase (decode / tool gap / reload) unambiguously.
- **Compaction that cannot shrink no longer fails the run, and can no
  longer degrade silently either.**
  `HybridContextEngine.compact` previously threw
  "did not reduce the estimated token count" whenever the protected tail
  plus the summary was not smaller than the input — exactly the
  tail-dominated local-window case — and the forced retry then failed the
  run. Acceptance now requires fitting the usable window (not merely
  `after < before`); a failed or empty summarizer always continues through
  the deterministic summarizer so a real retained record is evaluated
  (cancellation always propagates); the degrade path then halves the summary
  budget and drops the oldest summarized messages behind the durable notice
  with an accurate dropped count; notice-only is the explicit last resort;
  and an honest, accurately-worded failure is reserved for the state where
  system context + protected tail + the minimal notice alone exceed the
  window. Small windows get a short notice so the fixed text is not what
  overflows.
- Tool-call ID preservation, replay bounding and the
  unload-before-tool-execution ownership were verified already present
  (replay planner, checkpoint pairing, `finishSuccess` unload) and are
  covered by focused regression tests rather than rewritten.
- **Deliberately not done here:** no mlx-swift-lm pin bump. Upstream main
  carries prefill/prompt-cache work (#475 persisted prompt state would
  remove the repeated-prefill exposure entirely) but also reworks compiled
  decode paths; that is a separate intentional dependency change with full
  local-model retest, not an expedited hotfix. Recorded as an integration
  option in §6.

## 4. Cross-conversation discovery and search

- New `conversation.list` tool: discovery of recent searchable tasks (id,
  title, updated time, workspace) **separate from FTS**, excluding the
  current conversation and Notes-purpose sessions, with the same untrusted
  envelope rules as `conversation.search`.
- `conversation.search` keeps FTS5 ranking but now also matches **titles
  and CJK substrings** (unicode61 whole-token semantics could never match a
  Chinese substring); substring hits merge after FTS hits, deduplicated per
  conversation, within the same limit and the same
  `is_searchable`/`purpose='ordinary'` filters.
- Historical index repair: migration **v44** rebuilds `message_fts` from
  the messages table (`INSERT INTO message_fts(message_fts)
  VALUES('rebuild')`) so rows written before the triggers or by bulk
  imports are searchable again. Empty search keeps returning the explicit
  `noResults` envelope with "do not re-run the identical query" guidance;
  search → read (paginated) → answer flow is unchanged.

## 5. Native mind map layout/drag

- `MindMapLayout.frames` was O(n²)-plus on every body evaluation: `measure`
  re-walked each subtree once per sibling per pass, and `orderedChildren`
  re-filtered/sorted the whole node list per parent. The layout pass now
  builds the children index once and memoizes subtree heights per pass;
  output is unchanged (same inputs → same frames), covered by regression
  tests. The view additionally caches frames keyed by (document, sizes)
  instead of recomputing on every SwiftUI body evaluation.
- Drag keeps the existing transient-state + single undoable commit
  (`commitDrag` on gesture end); zoom coordinate transforms
  (`CanvasViewportTransform.zoomed(around:)`) were verified anchor-correct.
- Add-child/add-sibling no longer float over the canvas as a second
  cluster: `NoteMindMapView` publishes bounded topic actions
  (`MindMapTopicActions`) and the surrounding surface renders them inside
  its own compact icon control group — the document header's mind-map
  section in the full editor (collapses into the compact "文档操作" menu on
  narrow phones) and the floating map window's control row (its condensed
  menu when height-constrained). 44×44 targets, accessibility labels and
  the existing `notes.mindmap.addChild/addSibling` identifiers are
  retained; add-sibling is disabled when the reference topic is the root.
  Editor state, undo and sessions are unchanged.

## 6. Open integration points (reported early)

1. **Engine worker:** 9p server walk/symlink escape enforcement (shared
   dependency with migration §7). Notes auto-grant containment is the
   declared share list + that server check; without it, confinement rests
   on the app sandbox alone and the grant should stay disabled (the policy
   fails closed to the human card when no `.linuxVM` session environment
   can be ensured).
2. **Migration worker:** when a Notes session environment's guest is not
   running, `exec.localPython`/`exec.shell` must fail with the explicit
   component/backend reason (contract §2 "no silent native fallback").
   This worker's auto-grant relies on that honesty.
3. **Documents worker:** Build211 crash symbol fetch (report
   `856863bd-…`); the 22:01:31 SIGABRT is now resolved to the pinned
   mlx-swift-lm Qwen3.5 GDN prefill (`generalConv` conv-state slice,
   `Qwen35.swift:445`). The 22:10:31 FOUNDATION/ios_system event's exact
   UUID/offset is still with the documents worker; the breadcrumbs in §3
   make the next report unambiguous either way.
4. **Upstream/dependency option (evaluated, deliberately deferred):**
   bumping pinned mlx-swift-lm past `d5d8b290` would pick up #475
   (persisted prompt state — removes repeated-prefill exposure), #514,
   #569/#589, but reworks compiled decode paths and needs a full local-model
   retest cycle; not an expedited hotfix. No pin change in this branch.
4. **App shell (out of scope here):** `ConversationCenter` Notes wiring in
   this branch touches run preparation only; Execution/Linux backend files
   stay with the migration/engine workers.

## 7. Evidence

- Commit SHA: `34188ba5` (branch `codex/tinyemu-phase2-assistant`, base `46422286`)
- Focused tests (executed, macOS arm64, Swift 6.4/Xcode-beta, SwiftPM
  scratch on internal disk; GRDB/MLX/llama frameworks from the existing
  verified caches — no dependency downloads, no device inference):
  - `ConversationSearchTests` (12): notes-purpose exclusion, FTS ranking,
    workspace/date filters, CJK substring + title fallback, SQL-side
    exclusion before LIMIT, `conversation.list` envelope + current-task
    filter — **all passed**.
  - `ContextCompactionDegradeTests` (5): tiny-window fit, failing summarizer
    fallback with key-fact retention, cancellation propagation, unresolved
    tool-pair preservation, honest fixed-floor failure — **all passed**.
  - `MindMapLayoutRegressionTests` (3): memoized layout byte-identical to
    the legacy recursive algorithm across 18 direction/seed/collapse
    combinations, determinism, 300+ topic tree — **all passed**.
  - `V44ConversationSearchIndexRepairTests` (1): rebuild repairs a
    historically unindexed row; index/table counts agree — **passed**.
  - `LocalHistoryAdmissionTests` + `LocalReplayedToolEvidenceTests` +
    `LocalModelLifecycleTests.gdnPrefillChunkCeiling` (9 executed): MLX
    admissible lists (notes.\*/conversation.list), referential repair
    prompt, GDN prefill chunk ceiling — **all passed**.
  - Host dyld note: `FloeLocalModelsTests.xctest` initially failed to load
    `@rpath/llama.framework`; resolved by linking the already-present
    `out/Products/Debug/llama.framework` into `PackageFrameworks` inside
    the scratch dir (no downloads). Earlier `swift test` runs rewrote
    `Package.resolved` (dropped whisperkit pin + originHash); the lockfile
    was restored and is byte-identical to the base commit.
- Compiled but not executed locally:
  - `NotesDocumentApprovalPolicyTests` (Qualification/NativeNotes host,
    iOS-only XCTest): scoped-handler grants, exec confinement/network
    gates, out-of-scope escalation. App-side SwiftUI files
    (NoteMindMapView, NotesLinkedMindMaps, NotesDocumentEditor,
    ConversationCenter, AppEnvironment) compile only in the iOS app/host
    targets — **deferred to the cloud release compile** per the lightweight
    verification instruction (Swift 6 SIL/object diagnostics included);
    no local typecheck claim is made for them.
- Not run (by design): full app build, device inference, UI loops, whole
  test matrix.

---

## 中文摘要

本次修复覆盖四个范围。一、本地模型：工具调用后的"引擎卸载→执行工具→
重新加载"间隙加入有界结构化诊断日志，便于下次崩溃报告精确定位阶段；
修复本地小窗口下"压缩无法缩小即失败"的上下文压缩死循环，压缩现在会
确定性降级（更短摘要→丢弃最旧已摘要消息，原文仍在持久记录中），仅在
受保护尾部本身超过窗口时才如实失败。二、跨会话访问：新增
`conversation.list` 任务发现工具（与 FTS 分离）；`conversation.search`
在 FTS 之外合并标题与中文子串匹配（unicode61 无法匹配中文子串）；
新增 v44 迁移重建 message_fts 历史索引；空搜索仍返回明确的 noResults
指引信封。三、手记助手权限：每个手记会话使用独立受限工作区与显式
`.linuxVM` 会话环境。凡处理器具体限定在当前文档/当前任务暂存区的工具
一律自动授权：notes.*（读/搜/改/附件/暂存附件）、受限暂存文件工具、
PDF/Office/OCR 检查、`exec.localPython`/`exec.shell`（含任务环境内
依赖安装）、跨会话只读历史与计划/记忆只读工具。网络杠杆是任务网络
策略本身（`networkAllowed == false` 时带 networkAccess 风险的调用才
升级人工），不做脚本字符串扫描——别名与混淆既拦不住，也会给合法的
当前任务下载制造无谓弹窗。外部分享/发送/远程动作、把文档字节发给
provider 的语义检查、其他文档、破坏性或远程影响仍走人工审批；灾难性
命令闸门不变。文档文本与工具输出永远不能放大授权，也不声称对脚本
内容形成容器级约束，语义审查仅为建议性。新增 `notes.stageAttachment`
把已授权文档附件复制进任务工作区作为脚本输入；手记运行的工具目录
收敛到上述上限并保留按需发现。四、原生导图：布局引擎由每遍 O(n²) 改为每遍一次
子节点索引+子树高度记忆化，视图按（文档, 尺寸）缓存帧；拖拽保持
瞬态+单次可撤销提交；紧凑图标工具栏合并添加子/同级主题，根主题时
禁用"添加同级"；旧格式导入导出不变。

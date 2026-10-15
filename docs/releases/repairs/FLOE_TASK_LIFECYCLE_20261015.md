<!-- docs-updated: 2026-10-16 -->
# Floe task-lifecycle round — source record (2026-10-15; release freeze 2026-10-16)

Status: **source frozen for release 1.7.33 (274)** on branch `codex/temporary-subagent-perf-20261015`
(baseline `923b1e48`). Archive, upload and distribution state are recorded separately in the release
notes and the dated delivery record; when the body below was written these were still unreleased
working changes (no version bump, no commit, no tag, no App build, no upload, no distribution had
started). Build 273 remains the previously delivered internal Floe QA build, and Build 269 stays
internal-only. The next qualified build is authorized for public TestFlight.

This page records the round in the same honesty terms as the qualification notes: what was
implemented, what was actually executed, and what remains for the final integration/release
owner. It is not a release note and does not predict a version number.

## 1. Round areas and state

State vocabulary: **implemented** (source complete in its lane scope) · **component-verified**
(module/parse/harness/script checks actually executed) · **full-App pending** (needs the single
integration App compile / Simulator run) · **upload not started**.

### 1.1 Temporary chat and task-surface repair — implemented, component-verified, full-App pending

- Starting a temporary chat is now the New Task launchpad's entry only. The in-thread
  temporary switch is gone, so a saved conversation can never be converted from its own
  thread. The launchpad carries typed text into the session, and the active-session badge
  menu (hint, voice note, Keep, End) is unchanged.
- Temporary sends run the ordinary agent turn with the audited read-only tool ceiling
  actually applied to the model request (search/discovery + configured read-only tools);
  writes, execution, installs, VM lifecycle, background jobs, delegation and schedule
  changes stay closed. The ceiling policy itself was not widened.
- Duplicate "design decision recorded" rows: a trusted origin marker distinguishes automatic
  (tool-originated) decisions from user decisions. An automatic notice is projected as one
  compact line inside the tool card that caused it; user decisions and historical rows keep
  their standalone, decision-specific sentence. No durable message is deleted or reworded.
- Child-agent inspector and delegate cards now read the durable child-run store (active and
  finished children, paged transcript, tool results, honest state mapping, no invented
  percentage) with bounded live refresh; the delegate card's "View" action opens the same
  detail view. The previous hand-written query against a never-existing column is removed.
- Progress inspector: waiting runs parked on required background work show
  **Waiting for background work** (with the job ids) instead of "completed"; background jobs
  appear with real stage/phase/measured units, cancellation and an explicit bounded result
  preview; non-terminal runs use an indeterminate state instead of a fake progress bar.
- User-visible strings render inline bilingual fallbacks where the central string catalog
  entry is not yet merged, so no raw key can appear.

### 1.2 Background jobs, child runs and scheduling — in progress, component-level

- The service-side temporary configuration is canonicalized independently of the UI, and the
  dependency wait marker (`awaiting.finite.job:<ids>`) parks a parent run durably instead of
  completing it. A parked parent keeps waiting in the same task round and can accept more
  user input while it waits.
- Child runs have their own durable tables and entries (register → transition → append →
  finish), so children do not appear as ordinary parent runs. Completed or failed children
  never restart automatically; a job result resumes the original task as its next round
  rather than opening a new unsolicited conversation.
- Full job output is retrievable page by page with a stable cursor; the reader reports total
  size, explicit truncation and UTF-8-safe boundaries. A short summary/preview is not the
  whole output and is not a reason to rerun the job.
- Scheduling extends the existing task-schedule store and Home surface: once / daily / weekly
  / fixed interval, plus "after a selected task run succeeds" firing exactly once for that
  run. Occurrences are claimed atomically and idempotently, timezone-anchored, missed repeats
  coalesce into the latest occurrence, and the original task's success event is deduplicated.
  A schedule stores the model, workspace, environment and permission policy chosen at
  creation and revalidates them before every execution; the model cannot grant itself extra
  authority through a schedule.
- iOS decides background eligibility. When the system lets Floe run, the due occurrence
  starts; otherwise it stays **Pending (waiting for the app to run)** and one informational
  notification is posted. The notification never keeps the App alive and is a reminder, not
  a guarantee of execution. Future timers do not pin the VM or the Picture-in-Picture
  surface.
- Honest gap: this area's source was still being completed during this round. Its focused
  checks pass at parse/component level only where they exist; the central tool registration,
  central string entries and the full-App/UI acceptance are integration items. Exact
  tool-argument names are still subject to change and are tracked in the private handoff so
  no published example goes stale.

### 1.3 Per-model provider capability metadata — implemented, component-verified, full-App pending

- The bundled provider catalog carries verified per-model metadata. A newly added model
  starts with those verified capabilities (for example vision input); models saved before
  the metadata existed are never rewritten silently — a one-time reviewed diff shows
  Before → After per model and writes only on explicit apply.
- A capability bit the user decided (on or off, including bits accepted through the reviewed
  migration) is recorded as owned by the user: catalog refresh and sync never flip it. A
  reviewed-but-empty decision is distinct from a legacy record with no provenance.
- The supplier picker keeps "Supports text/images/video" for the roles actually verified per
  entry; the four presets that cannot execute without OAuth/deployment-scoped endpoints
  (GitHub Copilot, Azure, Amazon Bedrock, Google Vertex) are no longer offered when adding a
  new provider, while saved connections to them remain listed and editable.
- The bundled catalog baseline moved to 1.1.1 so devices holding the older installed package
  switch to the bundle; a later published package with a higher version still wins. No
  content package was built, signed or published.
- Explicit boundary: metadata-source verification is not a real-API inference test, and the
  Google `v1beta/openai` conversation connection with a real key remains an integration-run
  item.

### 1.4 CAD drawing/assembly discoverability — implemented, component-verified, full-App pending

- One authoritative catalog now describes every workbench service operation (drawing,
  assembly, script, mesh) with kind/action, mutate flag, exact typed arguments and runnable
  examples, aligned item-by-item with the engine router and its mutating-action sets.
- `three_d_drawing` / `three_d_assembly` requests must name one operation
  (`payload.action`, or the documented legacy `payload.op` `<kind>.<action>`). A missing or
  unknown action is refused with a structured error listing the known operations instead of
  silently defaulting to a read; a near miss suggests the intended action.
- The full catalog is served on demand through `capabilities` (`drawing` / `assembly` /
  `script` / `mesh`), paged to stay inside the model-visible budget, so the every-turn schema
  stays small.
- Mutating drawing/assembly operations keep the ordinary propose → apply path and the task's
  own authorization; no new grant gate and no model-supplied confirmation shortcut.
  Drawing PDF/SVG/DXF export requires the page id returned by a drawings query.
- Verification executed in this lane: Swift 6 strict-concurrency module typecheck (0 errors),
  a logic harness driving the real catalog/tool against a recording host (74/74 checks) and
  independent Python source-parity checks against the engine router (66/66). The App-level
  closure suite (page → project → save → export real bytes; assembly instance/constraint/DOF
  with save+reopen; malformed refusals; decision origin) is written and awaits the
  integration App build. Those checks lock the contract; they are not independent geometry
  acceptance and do not replace the real engine's own suites or device results.
- The Canvas 3D entry label "3D Workbench" was confirmed already clean; no change was made.

### 1.5 Linux guest performance — measurement pending (no new numbers)

- Already shipped in the 273 source: the release Linux interpreter with throughput-oriented
  (-O2) optimization and the SMP arm/drain fast-store changes. **Do not re-run or re-publish
  those as new work.**
- Current architecture facts, unchanged: there is no JIT, no host-side SHA offload and no
  instruction-set substitution. Runtime admission remains 1 hart default per guest, at most
  3 per guest and 4 total across the pool; three-hart use still requires a verified image.
- The new profiling round is in progress in parallel: fixed workloads across 1/2/3 harts and
  a shared-guest parent + two children, with original multi-round hashes retained, and a
  merge bar of a reproducible ≥10% gain with no reproducible >5% regression elsewhere. Its
  results are **not ready**, so this record quotes no new speedup, no parity claim and no
  device number. Measurement is pending.
- Python provisioning work (immutable seed materialized per environment rather than a shared
  mutable venv at a shadowed path) is part of the same in-progress lane; no user-facing
  promise is made here.

## 2. Verification actually executed (this round, component scope)

| Area | Executed check | Result |
| --- | --- | --- |
| Task-surface UI sources | `swiftc -parse` over the modified App files + tests | 11/11 parse clean |
| Decision/child logic | Extracted byte-identical pure-logic harness | 37 assertions passed |
| Provider metadata | Swift Testing suites via a linked runner + standalone harness + importer self-tests | 25 tests / 6 suites, 45/45 checks, 11/11 importer |
| CAD catalog | Swift 6 strict-concurrency module typecheck; logic harness; Python source-parity | 0 errors; 74/74; 66/66 |
| Background/child/scheduling | `swiftc -parse` and focused component tests where the target is in scope | parse clean; full suites deferred |
| Whole App | `xcodebuild build-for-testing` + Simulator/UI runs | **not run — integration gate** |

## 3. What is explicitly not claimed

- No full-App compile, Simulator acceptance, UI walkthrough, physical-device result or real
  model/provider call was executed for these changes.
- No new version, build number, tag, signed build, TestFlight submission or review state.
- No content package, website, GitHub release or scheduled-follow-up change.
- Real API inference quality is not proven by catalog metadata; CAD contract checks are not
  third-party drawing compatibility or geometric certification; background scheduling
  execution is best-effort per iOS policy, not guaranteed.
- These changes are not in internal build 273 and must not be described as present in any
  installed build until the release owner freezes, builds and delivers them.

## 4. Integration / release owner checkpoints (G)

1. Compile the App and run the changed suites; fix seam errors (the lanes did not compile the
   App target).
2. Merge the pending central items: string-catalog entries, `task.schedule` tool
   registration, project regeneration for the new files, and the sync merge invariant for
   explicit capability decisions.
3. Re-check the exact `task.schedule` argument names against the final source before any
   published example (they are still being corrected).
4. After the freeze: bump version/build from the actual project state, build and archive,
   retain exact-source artifacts, verify Apple processing, then follow the authorized
   TestFlight path. Do not reuse stale numbers or pre-write release notes.
5. Update the user guides and this record only with observed release-state facts.

## 中文摘要

本轮工作分支（基线 `923b1e48`）在其范围内完成了：临时会话入口收敛为仅“新建任务”启动台、只读上限真正作用于模型请求、决定回执按来源去重；后台有限作业/子运行/调度完成源码级实现；逐模型能力元数据与一次性复查；CAD 绘图/装配权威操作目录与显式拒绝；Linux 客体性能专项仍在测量中。执行过的验证为组件级（解析、纯逻辑桩、模块类型检查、独立脚本校验），**未做完整 App 编译、模拟器、真机或任何发布步骤**；当前内部构建仍是 1.7.32（273），新一轮公测构建尚未开始。不得把这些改动描述为已交付，也不得预写版本号或发布说明。

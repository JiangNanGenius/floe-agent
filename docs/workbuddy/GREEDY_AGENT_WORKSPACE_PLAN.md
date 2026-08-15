# Greedy Agent Workspace — Implementation Plan

> Records implementation order, dependencies and live progress for this run.
> Not a static plan — updated as vertical slices land. Audience: Codex (audit)
> and the delivery team. This file does NOT make safety/release claims.

## Context

- Branch: `agent/alpha-daily`, workdir `/Volumes/TECLAST/IOS AI AGENT`.
- Baseline: prior Alpha run delivered persistence v3, provider config +
  discovery, a persisted streaming agent thread, a five-tab iPhone /
  three-column iPad shell, SSH/VNC session ownership, and a Files + local
  image pipeline. 199 SPM tests green at baseline.
- This run pushes Floe from "entry points + debug pages" toward a daily-use
  iPhone/iPad AI Agent workspace. Interaction depth references ChatGPT /
  Kimi / Codex / WorkBuddy without copying assets or trademarks.

## Confirmed gaps at start (from code reading)

1. `CatalogToolExecutor.execute` (Sources/FloeAgentRuntime/AgentRuntime.swift)
   returns a stub failure — no real tool runners are registered. P1/P3 must
   implement real file/script runners.
2. Assistant/markdown text renders via plain `Text` — `###`, lists, code
   blocks show as raw source. P0 must add real Markdown rendering.
3. Home is a workbench (composer + task cards), not Chat-first. P0 rebuilds
   it around an always-visible composer.
4. Settings is a placeholder (`SettingsPlaceholder` in MoreView). P2 builds a
   real settings center.
5. No Workspace/Project model. P1 adds it (schema v5, append-only).
6. No JavaScript/Python execution. P3 adds JS via JavaScriptCore and layered
   Python (remote real, local honest-unavailable unless a shippable
   interpreter is viable).
7. No right-side file inspector. P1 adds it.

## Execution order (P0 → P4), greedy

Each bullet is a vertical slice: UI + state + persistence + error handling +
tests. A slice is "done" only when it compiles and its tests pass. If a slice
is blocked by environment (no live host, sandboxed xcodebuild), record the
fact and continue with the next implementable slice.

- [ ] **P0 — Chat-first home + thread experience**
  - [ ] Home rebuilt: open-and-type, always-visible multiline composer,
        attachment/model/project/mode controls, send→thread, send↔stop.
  - [ ] No-model state: full app reachable, only AI send disabled, concise
        model-setup entry. Files/Hosts/Settings never locked.
  - [ ] iPad: left nav + center conversation + on-demand collapsible right
        inspector (no empty placeholder column). iPhone: composer + recent
        tasks; history/projects/files via navigation/sheet.
  - [ ] Thread: typed components for user/assistant/reasoning/tool/approval/
        error; real Markdown rendering (headings, lists, quotes, links,
        inline + fenced code, copy); reasoning as collapsible "思考过程";
        tool steps with name/status/duration/IO summary; localized
        human-readable states (no raw `preparing`/`endTurn`); errors end the
        loading state with retry/diagnostics.
  - [ ] Inline approval cards: read-only ops don't full-screen; writes show
        target/command/diff; scopes (once / this task / project / host);
        approvals inline in thread; full-control keeps catastrophic gate.

- [ ] **P1 — Project workspace + file inspector**
  - [ ] Workspace/Project model (name, security-scoped root bookmark,
        last-opened, linked conversations, execution target, inspector
        state, optional instructions file). Schema v5 append-only migration
        + tests. No file bodies in DB; no secrets in DB.
  - [ ] File inspector: iPad collapsible right column / iPhone sheet;
        Files/iCloud Drive picker, bookmark restore, searchable lazy file
        tree, text/Markdown/JSON/Swift/Python/JS preview, Quick Look,
        text edit+save, create/rename/move/delete, attach to conversation,
        diff view, external-modification conflict, recent files.
  - [ ] Path safety: no `../` escape, no symlink escape, no out-of-root
        access, size caps, secret-file exclusion.
  - [ ] Agent file tools (real, not stubbed): list_directory, read_file,
        search_files, create_file, write_file, apply_patch, move_file,
        delete_file, inspect_file_metadata. Results returned to model +
        written to run events; write shows diff; delete shows exact target;
        cancellation + output limits + structured errors.

- [ ] **P2 — Full settings center**
  - [ ] Replace placeholder with real sections: General; Models & Providers
        (keep 3 wire protocols); Auxiliary models (gen/edit, honest
        capability); Agent & permissions (default approval mode, full
        control, grants view/revoke, catastrophic-gate status); Execution
        environment (JS/Python/remote status, target, timeout, max output);
        Files & iCloud (workspaces, default project, sync); Hosts & remote
        sessions (SSH/VNC defaults, idle disconnect, fingerprints); Privacy
        & Security (Keychain state, clear local records, redaction notes);
        Diagnostics & About (version/build, schema version, capability
        summary, logs, licenses, privacy).
  - [ ] iPad master-detail, iPhone navigation. Every control backed by real
        storage or an explicit unavailable state. No placeholder text.

- [ ] **P3 — JavaScript / Python / agent tool loop**
  - [ ] JavaScript via JavaScriptCore: script in, stdout/stderr capture,
        JSON in/out, cancel, timeout, output cap, no FS/network by default,
        no arbitrary ObjC/Swift object exposure, no infinite-loop hang.
        Results saveable as run artifacts. `ScriptExecutionService` +
        `CodeExecutionTool` + tests.
  - [ ] Python (layered, never faked): remote `python3` over configured SSH
        (reuse long-connection/approval/cancel/streaming); honest error when
        no host or no python3. Local Python: only if a no-JIT, no-download,
        signable interpreter is viable — otherwise runtime protocol + UI +
        capability probe + explicit unavailable state, documented.
  - [ ] Agent loop: multi-step tool calls, runtime arg/capability
        validation, policy execution, results back to model, continue or
        final answer, consecutive steps, cancel/timeout/failure recovery/
        bounded retry, infinite-loop guard, per-step event+duration+summary.
        Workspace/selected files/execution target in run context. Compile-
        time tool registry (no dynamic download).

- [ ] **P4 — Visual, localization, tests, engineering closeout**
  - [ ] SF Symbols (no emoji as icons), Floe brand kept, native SwiftUI +
        existing design system, iOS 26 first, Liquid Glass only for
        navigation/overlays, dark + light, Dynamic Type, VoiceOver, keyboard
        nav, Reduce Motion.
  - [ ] Full zh-Hans + English, no mixed-language strings; every visible
        state/button/error/capability localized.
  - [ ] Tests: unit, migration, bookmark, path-boundary, file CRUD + diff,
        JS output/exception/timeout/cancel/limit, remote-Python capability
        probe, agent multi-step loop, approval state, run cancel/fail
        finalization, settings persistence, zh/en resource completeness.
  - [ ] iPhone + iPad Debug build, Release build, key UI tests,
        `git diff --check`. Record exactly what could not run in this
        environment (sandboxed xcodebuild, no live host/device).

## Dependency notes

- P1 file tools depend on the Workspace model + path-safety layer.
- P3 agent loop depends on P1 file tools and P3 script execution.
- P2 settings surface reads capability state from P1/P3; build the storage
  first, then wire honest status.
- v5 migration must be append-only and must not disturb v1–v3 data.

## Boundaries (not done here)

- No code/security/privacy/UX audit, no release sign-off, no "audited /
  safe / shippable" claims — those belong to Codex.
- No Xcode Cloud / TestFlight / App Store Connect, no PR merge, no release
  build distribution, no new branch / worktree / clone.
- No accounts, ads, analytics SDK, proxy server, or dynamic plugin store.
- MPL-2.0 unchanged. No secrets printed/committed/transmitted.

## Progress log

- 2026-08-15 — Run start. Baseline read; gaps confirmed (above). Plan file
  created. **Baseline: 224 SPM tests pass, 0 fail** (`swift test
  --disable-sandbox --build-path /tmp/floe-build`, Xcode-beta DEVELOPER_DIR).
  Worktree clean on `agent/alpha-daily` @ `afb0bc7`. Team assembled;
  dispatching architect for P0–P1 design + task decomposition.
- 2026-08-15 — Team `software-floe-agent` created. Architect (高见远)
  dispatched for P0–P1 architecture + task decomposition (critical path).
  Product manager (许清楚) dispatched in parallel to distill the spec into a
  requirement pool + acceptance matrix (QA baseline). Reading engineer-facing
  existing code (ThreadDetailViewModel, HomeWorkbenchViewModel) to hand
  accurate context to the engineer and avoid rework.
- 2026-08-15 — **PM (许清楚) delivered PRD** `FloeAgent/docs/PRD_AGENT_WORKSPACE.md`:
  66 atomic requirements across 10 domains, 6 acceptance scenarios as
  step-by-step test scripts, 14 verifiable security/credential constraints.
  Relayed 4 open decisions to the architect (Markdown depth incl. GFM
  tables; local-Python viability landing; path-safety thresholds + secret
  file rules; catastrophic-vs-full-control destructive list ownership).
  Lead read remaining engineer-facing code (ConversationCenter,
  AppEnvironment, FilesCenter, ApprovalPolicy, DatabaseManager, AgentThread,
  FloeError, SSHConnectionService) — schema is at v4, Workspace migration
  will be v5 (append-only). Awaiting architect P0–P1 design (critical path).
- 2026-08-15 — **Architect (高见远) delivered** `FloeAgent/docs/ARCHITECTURE_AGENT_WORKSPACE.md`
  (Mermaid class/sequence/dependency diagrams, v5 DDL, 9-tool spec table,
  state-localization map, file list with new/modified + module ownership).
  Key decisions: self-hosted FloeMarkdown block parser (zero new deps,
  heading/list/quote/fenced-code/GFM-pipe-table, code block copy button);
  ToolRunnerRegistry type-erasure + new FloeWorkspace module for 9 real file
  tools; WorkspacePathGuard as the single path-safety choke point (reject
  absolute, expand `..`, resolveSymlinks, root-prefix check, secret-file
  denylist, 10MiB read / 4MiB write caps); schema **v5** append-only
  (workspaces / workspace_conversations / workspace_recent_files /
  approval_grants) — confirmed code is at v4 not v3; approval chain
  unchanged (gate → policy, catastrophic gate not weakened). Ordered tasks
  T01→T02→T03→T05 and T01→T04→T05 (T02 ∥ T04). Lead confirmed the
  architect's 4 open assumptions as reasonable. Dispatching engineer for
  T01 (data + execution foundation — root dependency).
- 2026-08-15 — **T01 DONE** (engineer 寇豆码): commit `650aaf9`, 244 tests
  green (224→244, +20: V5Workspace 13 + ToolRunnerRegistry 7). Workspace
  model, v5 append-only migration (4 STRICT tables), WorkspaceStore,
  ToolRunnerRegistry + AnyAgentTool type-erasure, CatalogToolExecutor filled
  in, FloeMarkdown/FloeWorkspace module scaffolding in Package.swift. Four
  justified deviations noted. IS_PASS: YES, no blockers.
  **T02 + T04 dispatched in parallel** (disjoint file areas): T02 =
  FloeMarkdown parser + thread components + RunStateLocalizer
  (engineer-2); T04 = WorkspacePathGuard + 9 real file tools + registration
  (engineer-t04).
- 2026-08-15 — **T04 DONE** (engineer-t04): commit `59ede94`, 10 files
  +2626. WorkspacePathGuard filled in (escape/symlink/secret/size guards),
  WorkspaceFileService (list/read/search/write/patch/move/delete/metadata/
  diff with mtime+sha256 conflict detection), 9 real file tools, dual
  registration, AppEnvironment wiring. 33 PathGuard/FileTools tests.
- 2026-08-15 — **T02 DONE** (engineer-2): commit `6b25308`, 17 files +4066.
  FloeMarkdown block parser (heading/list/quote/fenced-code/GFM-table) +
  inline renderer + snapshot tests; MarkdownRendererView/CodeBlockView +
  User/Assistant/Reasoning/ToolCall/Error components + RunStateLocalizer +
  ThreadEventView/ThreadDetailView rework + Localizable (~2850 lines).
  **Merged state: 306 SPM tests green, 0 fail; git diff --check clean.**
  Mid-run parallel-write turbulence (temp park/restore + cross-member DMs)
  was cleaned by lead; both engineers reined in to lead-mediated flow.
- 2026-08-15 — **T03 DONE** (engineer-2): commit `6f0909f`, 12 files
  +1318/−579, 294 tests green (pure App layer, no new SPM tests — expected).
  ChatHomeView (always-visible bottom composer + recent threads + send→
  thread + send↔stop + no-model full-app-usable), ThreadComposerView
  (attachment/model/project/target/mode), HomeWorkbench slimmed to iPad
  overview, ApprovalCardView inline upgrade (target/summary/scope-4-tier/
  gate red-flag), AppRouter inspector state, pbxproj registered. xcodebuild
  sandbox-blocked locally (mitigated: SPM green + swiftc -parse clean +
  cross-file symbol check) — flagged for Codex to run an iOS build.
  **T05 dispatched** to engineer-t04 (owns FloeWorkspace file service):
  WorkspaceCenter + FileInspector/Tree/Preview/Editor/Diff/Picker UI +
  composer context wiring. T05 is the last P1 slice.
- 2026-08-15 — **P2 design DONE** (architect 高见远):
  `FloeAgent/docs/ARCHITECTURE_SETTINGS.md`. Storage three-tier split
  (DB v6 `app_settings` key-value for cross-session behavior prefs;
  UserDefaults for instant UI prefs; read-only probes for capability
  state; Keychain unchanged — secrets never in DB). v6 DDL =
  `app_settings(key, value_json, updated_at) STRICT` only. Honest
  `CapabilityProbe`/`CapabilityState` for JS/Python/image adapters
  (P3-pending → greyed `unavailable`, never faked). Ordered tasks
  T06→T07→T08→T09→T10 (linear). Confirmed current schema is v5, so the
  new settings table is v6 (T05 is UI-only, does not consume v6).
  **T06 dispatched** to engineer (settings storage foundation + v6
  migration) — runs parallel with T05 (disjoint SPM vs App-UI areas).
- 2026-08-15 — **T05 DONE** (engineer-t04): commit `9e71a12`, 15 files
  +1940/−35. WorkspaceCenter (bookmark resolve + stale refresh + conflict
  detect + FLOE.md via guard + toolRootProvider), FileInspector/Tree/Preview/
  Editor/Diff/Picker UI, AppEnvironment wiring to real tool root, composer
  project picker wired to real workspaces, file→conversation-context attach.
  **P0 + P1 complete (T01–T05 all committed).** Lead cleaned a stray
  duplicate `FloeApp/Workspace/DiffView.swift` at repo root (byte-identical
  residue from a relative-path slip). T06 (engineer) in flight: 2 failing
  V6 tests (STRICT negative + v5-survives-v6) reported back for fix before
  commit.
- 2026-08-15 — **T06 DONE** (engineer): commit `af4249a`, 318 tests green
  (294→318, +24: V6AppSettings 6 + SettingsStore 6 + grant mgmt). v6
  `app_settings` STRICT table, AppSettings value types, CapabilityProbe
  protocol, SettingsStore, WorkspaceStore.allGrants/deleteGrant. Engineer
  fixed a latent T1 bug (InspectorState synthetic Codable dropped defaults,
  breaking `inspector_state_json DEFAULT '{}'` decode) and corrected the
  STRICT negative-test approach via a real C-API probe (TEXT has flexible
  numeric affinity; use BLOB→TEXT). Noted parallel-turbulence: shared
  build-path + a file wipe; lead now assigns isolated build-paths per
  engineer. **T07 dispatched** (SettingsCenter + probes + destructive
  actions + ConversationCenter policy-by-defaultMode).
- 2026-08-15 — **P3 design DONE** (architect 高见远):
  `FloeAgent/docs/ARCHITECTURE_EXECUTION.md`. JS via JavaScriptCore with a
  dedicated serial queue + per-run JSContext + timeout-abandon (reliable
  cancel semantics; JS-side watchdog proven infeasible); console bridging
  to a bounded buffer; no Swift object injection (JSCore has no FS/network
  by default). Python: remote real via Citadel executeCommandStream +
  `python3 -` over stdin (withExec is macOS-15-only, avoided); **local
  Python honestly NOT done this round** (PythonKit macOS-only rejected;
  self-compiled CPython/MicroPython out of scope +30–80MB; iOS forbids
  downloading executables) — surfaced as honest `unavailable`. Tool-loop
  hardening gaps: maxToolSteps=32 (the only reliable anti-infinite-loop
  guard), per-step durationMs into toolResult payload, run-context system
  message injection. Ordered tasks T11→T13→T14, T12 parallel.
  **T12 dispatched** to engineer-t04 (runtime tool-loop hardening,
  isolated build-path) — parallel with T07.
- 2026-08-15 — **T07 DONE** (engineer): commit `17c0a46`, 318 tests green.
  SettingsCenter (@MainActor aggregator over SettingsStore + UserDefaults +
  CapabilityProbes + grants), SettingsProbes (JavaScriptCore real probe;
  Python honest `unavailable`; iCloud/Keychain canary probes),
  SettingsActions (clear history / clear model config + Keychain cascade /
  revoke grant / redacted diagnostics export — all real deletes with
  ClearReport counts, secrets never in DB). ConversationCenter.runService
  now builds policy from `agent.defaultMode`; approvalModel/fullControl
  honestly fail-closed to human (no fake channel), gate untouched.
  **T08 dispatched** (settings shell + General/Providers/Auxiliary).
- 2026-08-15 — **T12 DONE** (engineer-t04): commit `5ede613`, 324 tests
  green (318→324, +6). maxToolSteps=32 anti-infinite-loop guard (counts
  ALL tool requests incl. denied — conservative), per-step durationMs into
  toolResult payload (ToolResult model + schema untouched), run-context
  system-message injection (not persisted). Fixed a fixture bug where a
  reused call id let idempotency mask the loop. **T11 dispatched**
  (JavaScript engine via JavaScriptCore, new FloeExecution module) —
  parallel with T08.
- 2026-08-15 — **T11 first run FAILED (engineer-t04 aborted, category
  unknown)**. Partial output: ScriptExecutionService.swift skeleton (57
  lines, good — reused) + a Package.swift edit registering
  FloeExecution/FloeExecutionTests pointing at a non-existent
  Tests/FloeExecutionTests dir (would break the SPM manifest). Lead reverted
  Package.swift (manifest verified loadable) and kept the skeleton. T11
  re-dispatched to engineer-t04 with the skeleton to reuse. Failure surfaced
  honestly; no fabricated completion.
- 2026-08-15 — **T11 DONE (retry)** (engineer-t04): commit `e7a4254`, +520.
  FloeExecution module + JavaScriptExecutionService (serial queue `floe.jsexec`,
  per-run JSContext, bounded console buffer, printJSON, timeout/cancel race —
  `while(true){}` measured returning timedOut at 0.507s). Reused T07's
  JavaScriptCoreProbe (no dup). 12 JS tests.
  **T08 DONE** (engineer): commit `8edb337`, 9 files +1277/−512. SettingsRoot
  (iPad master-detail / iPhone nav) + General + Providers/Auxiliary (thin
  embeds of existing ProviderListView/AuxiliaryModelsView per design).
  **Merged: 335 SPM tests green, 0 fail, diff --check clean.**
  **T09 + T13 dispatched in parallel**: T09 = five settings sections
  (engineer, FloeApp/Settings); T13 = exec.javascript tool wiring
  (engineer-t04, FloeExecution).
- 2026-08-15 — **T13 DONE** (engineer-t04): commit `17fb1c3`, 346 tests
  green (336→346, +9). exec.javascript AgentTool (non-side-effecting,
  auto-allow, JSCore sandbox); jsException/timedOut map to model-recoverable
  results (exitStatus 1/124, shell convention) not tool-level failure;
  timeout/output hard-capped (120s/256KiB) to prevent bypassing the loop
  guard. Full CatalogToolExecutor round-trip test (console.log(1+1) → "2").
  registerExecutionTools not yet wired into AppEnvironment (FloeApp area —
  lead will coordinate at the end). **T14 dispatched** (remote Python +
  real RemotePythonProbe; local Python honestly unavailable, never faked).
- 2026-08-15 — **T09 DONE** (engineer): commit `c43b219`, 5 settings
  sections (AgentPermissions / ExecutionEnvironment / Files / Remote /
  PrivacySecurity) all backed by real storage or honest-unavailable probes;
  destructive actions with double-confirm + ClearReport counts; credentials
  never stored or echoed. T09 surfaced two engineer-t04 issues for lead to
  relay: T14's WIP SSHExecService.swift broke the full build (protocol
  conformance + missing `import FloeTools` for CancellationToken +
  non-Sendable static registry), and 2 T13 JS tests reported as 10s-timeout
  failures (unreproducible while the build is broken — relayed to
  engineer-t04 to fix compile + verify the JS tests). **T10 dispatched**
  (diagnostics & about + redacted export + FloeLogger ring buffer +
  SettingsFlowTests) — the last P2 slice, parallel with T14.
- 2026-08-15 — **T10 DONE** (engineer): commit `784eff8`, 353 tests green
  (measured with engineer-t04's un-compilable T14 WIP temporarily set
  aside — T14 is the current full-build blocker). FloeLogger ring buffer
  (500 entries, NSLock, redacted on write), DiagnosticsAboutView (version/
  build/DB-version-6/capability summary/log view/redacted export/licenses/
  privacy), DiagnosticsExporter (render + SecretRedactor + atomic temp
  file), SettingsFlowTests + FloeLoggerBufferTests. Engineer fixed a latent
  T7 overload-resolution bug (setDefaultWorkspace passed String hitting the
  raw-JSON overload → corrupt decode). **P2 settings center COMPLETE
  (T06–T10), all 9 sections wired.** T14 (engineer-t04) still not compiling
  (now Swift-6 sending-closure data-race errors) — relayed fix guidance.
  **P4 phase-1 dispatched** (visual + localization completeness +
  LocalizationCompletenessTests) to engineer — parallel with T14.
- 2026-08-15 — **T14 compile fixed** (engineer-t04): `swift build` now 0
  errors (Swift-6 sending-closure data race resolved). But lead's full test
  run surfaced 2 failing RemotePythonToolTests (error-path mapping: timeout
  throws instead of returning `.timedOut`; cancellation throws
  SSHExecError.cancelled instead of FloeError.cancelled). Relayed to
  engineer-t04 to align with the T13 JS-tool semantics. T13's earlier JS
  test timeouts are now runnable again (build fixed).
- 2026-08-15 — **T14 DONE** (engineer-t04): commit `6fc6a19`, 356 pass.
  exec.remotePython (side-effecting, full gate→policy→approval chain),
  SSHExecService.executeBounded (Citadel executeCommandStream — withExec is
  macOS-15-only, stdin not feedable on iOS, so **base64 `python3 -c` path**
  chosen per design fallback), RemotePythonService (detectPython3 + no-host/
  no-python3/timeout/cancel structured errors), real RemotePythonProbe in
  FloeExecution. 11 fake-SSH tests. **P3 execution loop COMPLETE
  (T11–T14).** Two follow-ups parked for lead: (a) wire
  registerExecutionTools into AppEnvironment; (b) reconcile the duplicate
  RemotePythonProbe (FloeCore placeholder vs FloeExecution real — UI
  binding). Engineer's in-flight P4 LocalizationCompletenessTests flagged 6
  legacy bare keys (adjust/crop/… from ImageEditorView) — that is the P4
  test doing its job; engineer is mid-fix (view refs now namespaced
  `editor.*`, xcstrings translations being added).
- 2026-08-15 — **P4 phase-1 DONE** (engineer): commit `b33d1df`, **367 tests
  green, 0 fail**, worktree clean. Honest audit — exactly ONE real issue
  found & fixed (6 legacy bare keys renamed to `editor.*`, view + catalog
  in sync, convention test red→green). Confirmed clean: 322 view-referenced
  keys all defined + bilingual, 462 keys full en+zh-Hans, pure SF Symbols
  (no emoji icons), colors all via tokens, accessibility on
  composer/approval/inspector/settings.   LocalizationCompletenessTests (3
  cases) read the real catalog and pass. **T15 (execution-tool wiring +
  RemotePythonProbe reconciliation) in flight** (engineer-t04) — the last
  technical task before QA + report + push.
- 2026-08-15 — **T15 DONE** (engineer-t04): commit `b0a1da8`. Execution
  tools wired in AppEnvironment (exec.javascript local + exec.remotePython
  via RemoteHostStore/SSHConnectionService, Keychain resolved only at call
  site, no-host → structured noHostConfigured); UI switched to the real
  FloeExecution RemotePythonProbe (FloeCore placeholder now unreferenced,
  deletion parked). Also fixed the T13 JS flaky at its root (shared serial
  queue starved by an abandoned `while(true){}` run → per-run queue),
  which explains the earlier 10s JS test timeouts. **Confirmed on clean
  HEAD: 367 SPM tests green, 0 fail, worktree clean.**
  **ALL IMPLEMENTATION SLICES COMPLETE (T01–T15 + P4 phase-1).**
  Dispatching QA (严过关) for independent verification next.
- 2026-08-15 — **QA round-1 DONE** (严过关, independent): 367 SPM tests
  green (two runs), SEC-01~14 all PASS (append-only v5/v6, no secrets in
  DB, Keychain-only credentials, separate SSH/VNC key refs, local-only host
  creds, delete-provider cascades Keychain, catastrophic gate intact before
  policy, redacted export, JS no-FS/network sandbox), honesty checks PASS
  (no faked success, local Python honestly unavailable, no placeholder
  text). Two real deviations found:
  - **Bug-1 (medium)**: iPad sidebar Settings/Privacy/Runs route to
    ShellPlaceholderView instead of real screens (FloeAgentApp.swift
    MoreDestinationView) — iPhone routes correctly. Violates SET-01/SET-12;
    settings unreachable on iPad. → engineer dispatched to fix.
  - **Bug-2 (low)**: JS execution merges stderr into stdout (no separate
    stderr field) — PRD JS-01 deviation. → engineer-t04 dispatched to fix.
  Cannot-verify items honestly flagged: xcodebuild iOS Debug/Release,
  on-device/simulator cold-start, iCloud reconnect, live SSH host,
  VoiceOver, full XCUITest coverage. QA confirmed it did NOT trigger any
  cloud build/TestFlight. Awaiting the two fixes, then QA round-2.
- 2026-08-15 — **QA round-2 PASS** (严过关): both bug fixes independently
  verified (Bug-1 iPad routing consistent both idioms; Bug-2 JS stderr
  separated, all 8 `.ok(` call sites synced), 368 tests green, no
  regression, no new issues. **Implementation verification complete.**
- 2026-08-15 — **DELIVERED.** Docs committed (`2b59e27`), implementation
  report written (`docs/workbuddy/AGENT_WORKSPACE_IMPLEMENTATION_REPORT.md`,
  committed `0d1cbb1`), branch pushed `afb0bc7..0d1cbb1` (20 commits: 18
  implementation + docs + report). Final state: 368 SPM tests green, 0
  fail, worktree clean. No Xcode Cloud / TestFlight / App Store Connect
  triggered by the team; push may run the repo's own GitHub Actions CI on
  the draft PR (repository CI, not cloud distribution). Codex independent
  audit is the next gate — top item: run the iOS Debug/Release build on a
  machine where xcodebuild is not sandbox-blocked.

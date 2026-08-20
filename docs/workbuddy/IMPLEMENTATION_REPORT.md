# Floe Agent — Daily-Use Alpha Implementation Report

> WorkBuddy implementation report, per `docs/workbuddy/REVIEW_HANDOFF.md`.
> Audience: Codex (independent audit). This report distinguishes production
> behavior, fixture/demo behavior, and unavailable behavior, and is explicit
> about what was and was not validated in the authoring session.

## Summary

- **Branch and final commit:** `agent/alpha-daily` @ `70fd685c602a2d4f0d6f8715b11b71dc6580da92`
- **Implementation start/end:** 2026-08-14 (single greedy run). Baseline `892879b`; final `70fd685`.
- **Daily-use journeys completed:** provider configuration with presets + `/models` discovery + connection test; persisted streaming conversation thread (messages, typed parts, append-only run events, usage, redacted errors); canonical foldable thread UI with approval cards; production five-tab iPhone / three-column iPad shell; Home workbench; SSH/VNC session ownership moved off views with honest `unknown`/`suspended` states; Files + deterministic local image pipeline foundation.
- **Largest known gaps:** iOS Release build, on-device simulator *smoke* (launch/interaction), and 13-inch iPad validation were **not run in the authoring session** — `xcodebuild` is sandbox-blocked there (`sandbox-exec: sandbox_apply: Operation not permitted`). The iOS **Debug compile** for iPhone and iPad is verified green on GitHub CI. SSH/VNC live round-trip, VNC rendering, and real-device iCloud/Keychain sync remain unexercised end-to-end (no live hosts/devices in this session). Office editing engine remains a stub (deferred per non-goals).

## Commits

Each commit SHA, subject, and phase. Baseline for the Alpha work is `892879b`.

| SHA | Subject | Phase |
| --- | --- | --- |
| `b2c0166` | feat(persistence): schema v3 with agent thread, run/session stores | 1 |
| `b110e45` | feat(providers): adapter factory, presets, /models discovery, connection test | 2 |
| `7feff45` | feat(providers): offline contract tests + secret redaction | 2 |
| `5d2aed3` | feat(runtime): ConversationRunService persists the agent thread | 3 |
| `4269023` | feat(images): capability-aware remote image adapter foundation | 6 (foundation) |
| `2c04199` | docs(architecture): daily-use Alpha design for phases 4-6 | design |
| `914798a` | feat(shell): T01 app-shell infrastructure and navigation | 4 |
| `1b604f2` | ci: regenerate Xcode project for T01 app-shell sources | CI fix |
| `78919a9` | feat(chat): T02 conversation center + chat/thread UI | 3/4 |
| `ecad8d1` | ci: regenerate Xcode project for T02 chat/thread sources | CI fix |
| `02c965c` | fix(chat): add missing FloePersistence/FloeSecurity imports | CI fix |
| `8131fdd` | feat(home-providers): T03 home workbench + providers + onboarding + more | 2/4 |
| `5d6efec` | fix(runtime): expose run identity non-isolated for @MainActor coordinators | CI fix |
| `ed233f6` | feat(remote): T04 SSH terminal + VNC session ownership | 5 |
| `b390074` | fix(remote): rename M0 diagnostics trust sheet to avoid redeclaration | CI fix |
| `402847f` | feat(files): T05 files + images + hardening | 6 |
| `70fd685` | fix(remote): import FloeSecurity and await async secret resolution | CI fix |

The five "ci:/fix:" commits repair app-target compile issues that the local SPM
build cannot surface (SPM builds macOS modules, not the iOS app target); each
was caught by GitHub CI `xcodebuild` and fixed the same day. See "Known issues".

## Implemented behavior

### Phase 1 — Production shell + persistence v3 (PRODUCTION)

- `V3AgentDaily` migration (append-only; v1/v2 frozen): `message_parts`,
  `attachments`, `run_events`, `run_usage`, `run_errors`, `checkpoints`,
  `remote_sessions`. All STRICT, all secret-free.
- New stores with deterministic ordering + cancellation-safe writes:
  `ConversationStore`/`SQLiteConversationStore`, `RunStore`/`SQLiteRunStore`,
  `RemoteSessionRegistry`/`SQLiteRemoteSessionRegistry`. New domain types in
  `FloeModels/AgentThread.swift` (`MessagePart`, `AttachmentRef`,
  `RunEventRecord`, `RunUsageRecord`, `RunErrorRecord`, `RemoteSessionRecord`).
- `AppEnvironment` (live/preview) owns the database + stores + Keychain +
  catastrophic gate, and vends the three app coordinators.
- Key files: `Sources/FloePersistence/Migrations/V3AgentDaily.swift`,
  `ConversationStore.swift`, `RunStore.swift`, `RemoteSessionRegistry.swift`,
  `PersistenceCodec.swift`, `FloeApp/App/AppEnvironment.swift`.

### Phase 2 — Provider configuration + discovery (PRODUCTION)

- `ProviderAdapterFactory` maps wire protocol → adapter; `ProviderPreset.all`
  covers OpenAI Responses, OpenAI Chat Completions, Anthropic, Volcengine Ark
  (compatible), Alibaba Model Studio (compatible), and custom. Compatible
  gateways reuse the Chat Completions wire adapter.
- `/models` discovery (`ModelDiscovery`) for OpenAI-compatible and Anthropic
  endpoints, with a manual-model fallback shape on failure. `testConnection`
  default probe. `SecretRedactor` masks credential-shaped substrings at
  provider error surfaces (`WireTranslator.httpError`, `ModelDiscovery`).
- Key files: `Sources/FloeProviders/ProviderAdapterFactory.swift`,
  `ModelDiscovery.swift`, `ProviderAdapter.swift`,
  `Sources/FloeCore/SecretRedactor.swift`.

### Phase 3 — Real conversation + agent thread (PRODUCTION)

- `ConversationRunService` (per-run actor) owns a `FloeAgentRuntime` and mirrors
  its event stream into the durable stores: user/assistant messages with typed
  content parts, the append-only `run_events` thread (assistant/tool/approval/
  status), per-run usage, and structured redacted errors. Sink callbacks forward
  into the actor via closures (no retain cycle). `runID`/`conversationID` are
  `nonisolated` for `@MainActor` coordinators.
- `ConversationCenter` (app) owns live run services keyed by runID; cancel /
  retry / model-switch funnel through it; API keys resolve from Keychain only at
  the call site.
- Key files: `Sources/FloeAgentRuntime/ConversationRunService.swift`,
  `FloeApp/Remote/ConversationCenter.swift`.

### Phase 4 — Daily-use UI + localization (PRODUCTION)

- Locked IA: iPhone five tabs (Home, Chat, Files, Hosts, More); iPad
  three-column `NavigationSplitView`. One `AppRouter` drives both, owns
  selection/sidebar/column visibility/selected IDs and the scene-phase →
  `PlatformBackgroundPolicy` wiring.
- Home workbench (composer + Active Tasks + Pending Approvals + Recent Sessions
  + Connection Status, not a card grid); canonical foldable thread
  (`ThreadDetailView`/`ThreadEventView` by `RunEventRecord.Kind`); approval
  cards (action/scope/risk/expiry, Approve/Deny); provider editor with presets,
  discovery, test connection, iCloud Keychain toggle, honest `waitingForSecret`;
  onboarding (no Floe account); More (Runs/Providers/Settings/Privacy/
  Diagnostics-DEBUG).
- `FloeTheme` semantic tokens (no hard-coded hex in views); `Localizable.xcstrings`
  English + Simplified Chinese (178 keys, valid JSON); M0 diagnostics remain
  reachable under More → Diagnostics in DEBUG.
- Key files: `FloeApp/Shell/AppRouter.swift`, `AppDestination.swift`,
  `FloeApp/Design/FloeTheme.swift`, `FloeApp/Home/*`, `FloeApp/Chat/*`,
  `FloeApp/Providers/*`, `FloeApp/Onboarding/*`, `FloeApp/More/*`,
  `FloeApp/Resources/Localizable.xcstrings`.

### Phase 5 — SSH terminal + VNC session ownership (PRODUCTION ownership model; live round-trip UNVALIDATED)

- `RemoteSessionCenter` owns `SSHSessionOwner`/`VNCSessionOwner` **independent
  of any view** (the key correctness fix over the view-bound M0 model).
  `RemoteSessionSnapshot` is the value-type UI projection. Host CRUD via
  `RemoteHostStore`; secrets via `KeychainSecretStore`; TOFU `HostKeyTrustSheet`;
  Terminal (SwiftTerm) and VNC surfaces with persistent emergency stop.
- Honest state machine: an unmanaged disconnect surfaces `unknown`, **never**
  `paused`; on backgrounding the app marks `suspended` and reconciles on resume.
  VNC connects only through the SSH loopback forwarder (no public listener).
- Key files: `FloeApp/Remote/RemoteSessionCenter.swift`,
  `RemoteSessionSnapshot.swift`, `FloeApp/Hosts/*`, `FloeApp/Terminal/*`,
  `FloeApp/VNC/*`.

### Phase 6 — Files + images (local pipeline PRODUCTION; remote adapters capability-gated foundation)

- `FilesCenter` + Files UI: document picker, security-scoped bookmarks, Quick
  Look, working copies, Save As, conflict-safe writeback. Office editing engine
  remains the committed stub — open/preview/safe-writeback/Save-As only, with an
  explicit "editing unavailable" state (never a fake editor).
- `ImagePipeline` (deterministic, pure Core Image) + `ImageEditSession`
  (value-type undo/redo, never mutates source). `ImageProviderAdapter` is
  capability-gated; unsupported operations throw `unsupportedOperation` and the
  UI shows `RemoteImageUnavailableView` — never emulated success.
- Key files: `Sources/FloeImages/ImagePipeline.swift`,
  `ImageEditSession.swift`, `FloeApp/Files/*`,
  `Sources/FloeProviders/ImageProviderAdapter.swift`, `ImageAdapters.swift`.

### Fixture/demo vs unavailable behavior

- **Fixture/demo (offline contract):** provider wire/discovery decoding,
  redaction, image-adapter capability sets, schema/migration, store CRUD,
  run-thread persistence — all covered by fixture tests with no live credentials.
- **Unavailable (honest, labelled):** Office editing (stub), remote image
  edit-family for OpenAI and Ark/DashScope wire calls (labelled pending),
  Anthropic/custom remote image (no adapter). No invented live data anywhere.

## Database and compatibility

- **Schema version and migrations:** current `user_version = 3`. Migrations
  `v1` (initial), `v2` (config sync), `v3` (agent daily) are append-only;
  `v1`/`v2` are never modified. `DatabaseManager.currentSchemaVersion = 3`.
- **Backward-compatibility evidence:** `DatabaseManagerTests` asserts the v1/v2
  table set survives v3 and that migration is idempotent; `V3AgentDailyTests`
  asserts v1/v2 core tables (`providers`, `models`, `conversations`, `messages`,
  `runs`, `audit_entries`, `hosts`, `config_sync_metadata`) persist after v3.
  No v1/v2 fixture databases existed in-repo to migrate; the migration path is
  exercised fresh (v1→v2→v3) in every test.
- **Secret storage/redaction evidence:** no secret columns in any v3 table;
  providers store only `SecretReference` (Keychain account + synchronizable
  flag). `SecretRedactor` masks bearer/`x-api-key`/`sk-…`/token shapes at error
  surfaces (6 redaction tests). `ConversationRunService` redacts provider error
  messages before persisting `run_errors`. gitleaks scan of full history: no
  leaks (see Validation).

## Validation evidence

All commands run from `/Volumes/TECLAST/IOS AI AGENT/FloeAgent` unless noted.

- **Swift package tests** (authoritative local check; 199 pass, 0 fail, 10 suites):
  ```
  SWIFTPM_NO_SANDBOX=1 DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
    swift test --disable-sandbox --build-path /tmp/floe-build
  # → TOTAL: 199 passed, 0 failed
  ```
  (The `--build-path /tmp/floe-build` redirect is required: the default `.build`
  on this exFAT volume fails manifest writes with NSCocoaErrorDomain 513.)
- **App unit/UI tests:** none added as a separate XCTest bundle this iteration;
  coverage is via the SPM test targets above. (Gap — see Known issues.)
- **iPhone simulator build/smoke:** Debug **compile** verified on GitHub CI
  (`xcodebuild iPhone Simulator` step, run 31776798344 → success). On-device
  launch/interaction smoke **not run** (xcodebuild sandbox-blocked locally).
- **13-inch iPad simulator build/smoke:** CI builds `iPad mini (A17 Pro)`
  (`xcodebuild iPad mini (A17 Pro)` step → success). A 13-inch iPad target was
  **not** run; Debug compile for an iPad simulator is green.
- **Release build:** **not run** (xcodebuild sandbox-blocked locally). CI builds
  Debug only. (Gap — flagged for Codex.)
- **Secret scan:**
  ```
  scripts/secret_scan.sh   # gitleaks detect --redact (38 commits)
  # → no leaks found; secret_scan OK
  ```
- **Pin/license checks:**
  ```
  scripts/pin_check.sh          # → pin_check OK: 18 dependencies pinned
  scripts/license_inventory.sh  # → license_inventory OK: 18 inventoried
                                 #    (cryptoswift: license undetected, pre-existing manual-review flag)
  ```
- **GitHub CI:** PR [#4](https://github.com/JiangNanGenius/floe-agent/pull/4)
  (draft, **not merged**). Latest run
  [31776798344](https://github.com/JiangNanGenius/floe-agent/actions/runs/31776798344)
  → **success**. `build-test`: gen_project, resolve+pin-check, SPM build, SPM
  test, xcodebuild iPhone, xcodebuild iPad mini (A17 Pro), secret scan, SBOM,
  license inventory — all success. `spm-linux-build` → success.

## Manual acceptance matrix

| Journey | Device/simulator | Result | Evidence or limitation |
| --- | --- | --- | --- |
| Onboarding/provider setup | iPhone/iPad sim (compile) | Compiles | CI xcodebuild green; presets/discovery/connection-test fixture-tested offline. Live provider onboarding not exercised (no credentials). |
| Streaming chat/cancel/retry | iPhone/iPad sim (compile) | Compiles; persistence unit-tested | `ConversationRunService` tests prove persisted streamed thread, usage, redacted errors, cancel. Live provider stream not exercised end-to-end. |
| Approval and catastrophic gate | SPM | Unit-tested | 33 security tests incl. 40+/40- catastrophic corpus; gate independent of full control, not weakened. |
| SSH terminal/reconnect | iPhone/iPad sim (compile) | Compiles | Session-ownership model + honest `unknown`/`suspended`. Live SSH round-trip NOT run (no lab host). |
| VNC connect/input/stop | iPhone/iPad sim (compile) | Compiles | Ownership + emergency stop + SSH-loopback-only. Live VNC render/input NOT run. |
| Files round trip | SPM (pipeline) + sim (compile) | Pipeline unit-tested | Bookmark round-trip, conflict-safe writeback, cancellation tests pass. |
| Local image edit/export | SPM | Unit-tested | ImagePipeline determinism (same op+source → identical bytes), resize/crop, undo/redo. 11 tests. |
| Relaunch recovery | SPM | Unit-tested | Checkpoint upsert/read, run-event ordering, remote-session reconcile. |
| VoiceOver/Dynamic Type/dark mode | — | By construction | FloeTheme semantic tokens, 44pt targets, Dynamic Type, Reduce Motion, light/dark. Not exercised on a running simulator. |

## Known issues and follow-ups

1. **iOS Release build + simulator smoke not run locally (P1, environmental).**
   `xcodebuild` package resolution is sandbox-blocked in the authoring session
   (`sandbox-exec: sandbox_apply: Operation not permitted`, even for
   `-showBuildSettings`; env overrides do not help). The M0 report shows it
   worked ~2026-08-13, so this is a transient seatbelt state, not a repo defect.
   *Next:* Codex (or CI) runs a Release build and iPhone + 13-inch iPad smoke.
2. **No app-target XCTest/UI test bundle (P2).** Verification is via SPM test
   targets; there is no separate XCUITest for the SwiftUI surfaces.
   *Next:* add iPhone/iPad UI smoke tests for empty/loading/streaming/approval/
   error/disconnected states.
3. **App-target compile errors surface only in CI (P2, process).** SPM builds
   macOS modules, so iOS-app-target errors (missing imports, actor isolation,
   type redeclaration) were caught by CI `xcodebuild`, not locally — five such
   fixes (`1b604f2`, `ecad8d1`, `02c965c`, `5d6efec`, `b390074`, `70fd685`).
   *Next:* retain the missing-import self-check and the
   regenerate-`project.pbxproj`-per-commit rule (both now team convention).
4. **Live SSH/VNC/iCloud round-trips unexercised (P1, needs environment).**
   Require a lab host (Tools/M0Lab), a VNC server, and two signed iCloud devices.
   *Next:* run per `FloeAgent/docs/M0_VALIDATION_REPORT.md` §"完成 M0 所需操作".
5. **Office editing engine stub (P2, deferred per non-goals).** Open/preview/
   safe-writeback/Save-As only. *Next:* Collabora integration (later milestone).
6. **Remote image edit-family + Ark/DashScope wire calls pending (P2).**
   Capability-gated and labelled; OpenAI generate is wired. *Next:* wire the
   multipart edit path and Ark/DashScope calls behind the same capability gate.
7. **cryptoswift license undetected (P3, pre-existing).** Manual review flag in
   the inventory; not introduced by this branch.

## Codex review entry point

**Highest-risk files (review first):**
1. `FloeAgent/Sources/FloeAgentRuntime/ConversationRunService.swift` — the
   persistence/secrets boundary for the run thread (redaction, append-only
   events, actor isolation, the new `nonisolated` identity).
2. `FloeAgent/FloeApp/Remote/RemoteSessionCenter.swift` — SSH/VNC session
   ownership, credential resolution from Keychain, honest `unknown`/`suspended`
   state machine.
3. `FloeAgent/Sources/FloePersistence/Migrations/V3AgentDaily.swift` + the three
   new stores — schema correctness, append-only invariants, secret-free columns.
4. `FloeAgent/Sources/FloeSecurity/CatastrophicActionGate.swift` (unchanged) and
   its call sites in `AgentRuntime.swift` — confirm the gate still runs before
   every approval mode and was not weakened.

**First three flows to independently inspect:**
1. Configure a provider (presets → `/models` discovery / manual fallback →
   connection test → Keychain secret) and confirm no secret reaches the DB/logs.
2. Run a streamed conversation → cancel → relaunch, and confirm the persisted
   thread (messages, run events, usage, errors) survives and reconciles.
3. Connect an SSH host with TOFU, background the app, and confirm the session
   reports `suspended`/`unknown` honestly (never `paused`) on resume.

**Xcode Cloud/TestFlight status:** **not triggered.** No Xcode Cloud workflow,
no TestFlight build, no cloud build hours were started by this work. The only CI
run is the repository's own GitHub Actions workflow on the draft PR. Cloud
distribution remains reserved for Codex after independent review.

---

_Worktree is clean at `70fd685`. The branch is pushed. Codex can begin its
independent audit._

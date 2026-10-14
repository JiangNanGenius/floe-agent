# Local qualification evidence — capability closure round (2026-10-14)

This page records what was actually executed on the local M5 Pro Mac mini with Xcode 27.0
(27A266a) for the unified capability-closure round on branch `codex/design-workflows-20261013`
(base `92ca4882`). It is redacted engineering evidence, not a release approval. Versioning,
the Git freeze, the device archive and TestFlight remain with the serialized release owner.

## What was actually compiled and executed

| Check | Result |
| --- | --- |
| Full Xcode 27 Simulator App `build-for-testing` (6 jobs, isolated internal derived data) | **TEST BUILD SUCCEEDED**, 0 errors, several incremental rebuilds |
| `FloeAgentRuntimeTests` (macOS host) | **476/476 passed** |
| `FloeExecutionTests` (macOS host) | **271/271 passed** |
| Focused FloeAppTests suites on the iPad simulator | **22/22 passed** (personal pagination; provider save regression; provider service-offer editor; subagent execution incl. a real browser human-takeover denial) |
| iPad provider UI (`ProviderCatalogPickerUITests`) | **passed twice** with screenshots (unified supplier field, local search, custom-name preservation, one-time multi-role prompt decline/no-repeat) |
| iPhone provider UI (adaptive sheet) | **passed** |
| Office App automatic copy (real pinned engine through the App service host) | **7/7 passed**, including **Task-cancellation** and unacknowledged-close quarantine lease cases — authorized copy with runtime-issued authority, verified reopen, real-engine Excel recalculation cached-value/type verification, output-conflict and mismatched-authority refusals, plus service-lease lifecycle (bounded/cancellable wait, Task cancellation, unacknowledged-close quarantine) |
| Office/cancellation lifecycle (`FloeDocumentsTests`) | **113/113 passed** — unacknowledged close / unsafe open retain the working copy and report typed failures; a cancelled run whose close fails is not reported as a clean cancellation; Task cancellation at a safe boundary cancels and closes; the inline tool forwards the real cancellation and a pre-cancelled context has no host effect |
| Notification App suites (real intake + delegate routing) | **14/14 passed** |
| Native-job safety (`FloeExecutionTests`) | **294/294 passed** — an actual job cancel+unsafe-error run fails truthfully instead of a clean `cancelled` |
| Legacy manual Office UI slideshow flow | **passed — all 22 receipt phases `ok` (201.5 s)** on the real pinned engine: import → preview → edit → insert slide (2→3) → real presentation of [cover, inserted blank, green oval] with per-page marker verification → exit → 120 s idle → save/close → remembered reopen → insert (3→4) → save/close → reopen-2 verifying the persisted 4-slide deck; reruns use a unique per-run fixture identity (`floe-sim-qual-<runid>`) and trash only the exact document id recorded by their own previous receipt |
| Office job-safety discriminant regression (shared contract) | **passed**: `FloeDocumentsTests` Office suite **14/14** (the real enum marks exactly `sessionCloseUnacknowledged`/`sessionOpenUnsafe` unsafe; every other case, incl. `.cancelled`, is safe; the legacy host forwarding refuses a pre-cancelled context), `FloeExecutionTests` Native-job policy suite **10/10** (a conforming-but-safe error + cancelled token stays a clean `cancelled`), and the App-hosted `OfficeJobSafetyDiscriminant` suite **3/3** (real `OfficeAutomaticExecutionError` produced by the real executor through the real App adapter mapping and a real `BackgroundJobService`: clean cancel → `cancelled`; ordinary `.sourceChanged` → `failed` without unsafe/staging wording; unacknowledged close + cancel → `failed` with retained-staging truth) |
| Localization catalog validator | OK — all keys bilingual (EN + zh-Hans) |

## Newly exercised behavior in this round

- **Unified supplier field**: tapping the Provider field opens one searchable selector containing
  built-in presets and verified catalog entries plus an explicit manual/custom choice; selecting
  keeps a custom display name and raises the one-time optional-role prompt.
- **Main-only callable boundary**: the runtime's tool-name-bound provenance refuses
  `delegate`/`conversation.spawn` from a delegated child, a rebuilt context, a legacy child budget
  and even a main-run wrapper that forwards its own identical run/call context into the raw
  registry entry; genuine main-run spawn and delegation still work.
- **Bounded web-search producer**: oversize citation URLs are omitted rather than shortened, and
  escape-heavy queries / huge provider failures are bounded with explicit truncation markers so the
  runtime's 4096-character prefix always receives valid JSON.
- **Background-job progress contract** (`ToolContext.taskProgress`) and App-level prepared-operation
  adapters for authorized Office/media apply jobs, wired through `registerBackgroundJobTools(adapters:)`.

## 2026-10-15 integration addendum

- Full current App build-for-testing passed with the verified Linux boot-pair resource. A read-only pre-build check rejects missing or mismatched firmware/kernel/manifest bytes.
- Temporary-chat App suite: **36/36 passed (2.947 s)**, including atomic ordinary-history ownership and rollback/retry when workspace persistence fails.
- Temporary iPad UI: **seven behaviours passed** across the relevant attempts (New Chat, Home toggle, populated-chat separation/leave, End, Keep, rotation and background return). Compact iPhone 17 Pro: **3/3 passed (40.323 s)** without forced iPad traits. Background checks activate the existing live process and compare a unique unsent RAM draft; they do not relaunch the fixture. See [temporary-chat evidence](../20261015-temporary-chat.md).
- Notification App suites: **33/33 passed (3.659 s)**. **Actual system warm and killed-App cold taps both passed (2/2)**, verifying the destination title and exactly one intake/route/completion dispatch/delivery per tap. This supersedes the initial host-blocked state below; the original physical Build 271 exception remains unreproduced.
- Linux boot-asset module closure: **32/32** upgrade tests, **97/97** lifecycle/registry/concurrency tests and **54/54** additional registry tests passed. The new upgrade case verifies that adoption writes to the same Runtime v2 expanded-image directory used at boot.
- The actual Simulator App guest/child-tool suite subsequently passed **2/2 (273.012 s)** with the pinned dependency graph: guest `uname` reported **6.18.56**, Shell and Python produced files with matching hashes, sibling children ran, nested delegation was refused and browser takeover was respected. The first run booted 4.15 despite an adoption log; later runs exposed an early HELLO probe lost before the guest console was ready. Both original failures are retained. The fix shares the real boot directory and retries the protocol probe within its original bounded deadline, without weakening the protocol gate. Cancellation and selection-preservation edge tests are recorded separately before release freeze.
- A repeat of the affected temporary-chat and notification App suites on that pinned graph passed **69/69 (7.43 s)**. All five previously divergent App dependency checkouts now match the original root pins; no dependency upgrade was accepted as a substitute.
- Final Linux lifecycle edges have module/object evidence: **13 new tests passed**, covering cancellation before/after a silent HELLO waiter registers, normal chunked responses, stale replies, and transactional boot-selection preservation across real re-materialization APIs. Two focused regression batches passed **211/211** and **54/54**. A bounded pre-fix mutation reproduced the orphan-waiter failure; restoring the fix passed. A malformed or uncopiable selection now aborts before replacing the old tree, and an explicit rollback marker survives even when its payload is missing. These tests ran on the macOS module host; the final App compilation is a separate step.
- The final temporary-chat closure supersedes its earlier 36-test run: **49/49 App tests**, **184/184 persistence tests**, **7/7 iPad UI** and **4/4 compact iPhone UI** passed. It preserves message-empty ordinary chats that already own resources and fences late toggle completions after navigation. The same App test build compiles the final Linux cancellation/selection fixes. See the [updated temporary-chat record](../20261015-temporary-chat.md) for exact scopes and limitations.
- Bundled dependency notices were checked against the actual pinned App graph: **234 components / 36 notices / 38 Swift rows**, with **92/92 generator tests**. The inventory distinguishes the native OCCT library from its WebAssembly viewer and includes the four linked CAD Swift packages plus the exact OpenShape3D-derived FloeCADKit notice. Provenance records do not constitute a legal certification.

## Honest limitations

- The real-guest App smoke was **not executed in the initial 2026-10-14 attempt** because the kernel handoff was not ready. The actual new-kernel App run in the 2026-10-15 addendum supersedes that pending state; it does not replace physical-iPad acceptance. Native VideoToolbox frame processing is verified on macOS hosts and is unsupported in the Simulator by Apple's headers; physical-iPad acceptance remains pending.
- The legacy manual Office UI slideshow check is **resolved**: the frame-by-frame 41 s screen
  recording plus the XCUITest action log proved the old helper mistook the slideshow chrome appearing
  for a page turn (the canvas tap advances; a horizontal swipe advances but *ends* the show on the
  last slide). The helper now verifies the caller's exact page identity per step and advances with
  real canvas taps only; no assertion was weakened. Reruns use a unique run identity
  (`floe-sim-qual-<runid>` title + receipt) and trash only the exact document id recorded by their own
  previous receipt — never a name-based match. No simulator erase or destructive reset was performed
  and reused-simulator user data was preserved.
- The initial OS-notification smoke was blocked by a shared CoreSimulator host failure before a test runner could launch. The original service/launch failures are retained. Following authorized host recovery, the actual warm/cold tests were executed successfully as recorded in the 2026-10-15 addendum; no app-container erase or historical-result substitution was used.
- The Office App suites additionally print the pinned engine's process-exit abort
  (`std::__1::system_error: mutex lock failed`) from `COOLWSDServer`/`SocketPoll` static destruction
  after all tests have passed; it is host teardown at XCTest exit, not a document/verification
  failure, and the raw reports are retained under
  `Local/Private/capability-closure-20261014/integration/evidence/office-attempts/`.
- The original physical notification-tap exception was not reproduced; the delegate bridge repair is
  proven by the real intake/routing suites and the iOS-SDK object compile, not by a device crash
  reproduction.
- Local results are not Apple processing, TestFlight availability or physical-device acceptance.

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

## Honest limitations

- The new Linux kernel boot asset is owned by the parallel Linux lane and had not reached a
  verified, source-stable handoff when this evidence was recorded. The real-guest App smoke was
  therefore **not executed in this round** (the opt-in test was gated/skipped by design): no guest
  acceptance is claimed here, old-image or new-kernel. Once the Linux handoff lands, the exact-source
  App smoke must run on the verified new boot asset and will replace this pending entry only when it
  truly runs. Native VideoToolbox frame processing is verified on macOS hosts and is unsupported in
  the Simulator by Apple's headers; physical-iPad acceptance remains pending.
- The legacy manual Office UI slideshow check is **resolved**: the frame-by-frame 41 s screen
  recording plus the XCUITest action log proved the old helper mistook the slideshow chrome appearing
  for a page turn (the canvas tap advances; a horizontal swipe advances but *ends* the show on the
  last slide). The helper now verifies the caller's exact page identity per step and advances with
  real canvas taps only; no assertion was weakened. Reruns use a unique run identity
  (`floe-sim-qual-<runid>` title + receipt) and trash only the exact document id recorded by their own
  previous receipt — never a name-based match. No simulator erase or destructive reset was performed
  and reused-simulator user data was preserved.
- **Actual OS notification tap smoke: prepared and compiled, not executed.** The DEBUG fixture hook
  (`--ui-test-notification-fixture`), the two UI tests (`NotificationTapUITests.testA…` warm,
  `testB…` cold) and the host trace summarizer are in the tree and compile into the App/UI-test
  targets. Execution was blocked by a host-wide CoreSimulator failure that began after the Office UI
  run: **every** app launch (`simctl launch`, including system apps) hangs, test sessions stall before
  the runner launches, and `xcodebuild` reports `Mach error -308`/`Invalid device state`. Device
  reboots, a CoreSimulator service restart and device-level kickstarts did not restore it; the
  concurrent simulator workflow was failing with the same service errors. No OS-level tap result is
  claimed; exact commands and the handoff state are in
  `Local/Private/capability-closure-20261014/integration/REMAINING-T5-CONTINUATION.md`.
- The Office App suites additionally print the pinned engine's process-exit abort
  (`std::__1::system_error: mutex lock failed`) from `COOLWSDServer`/`SocketPoll` static destruction
  after all tests have passed; it is host teardown at XCTest exit, not a document/verification
  failure, and the raw reports are retained under
  `Local/Private/capability-closure-20261014/integration/evidence/office-attempts/`.
- The original physical notification-tap exception was not reproduced; the delegate bridge repair is
  proven by the real intake/routing suites and the iOS-SDK object compile, not by a device crash
  reproduction.
- Local results are not Apple processing, TestFlight availability or physical-device acceptance.

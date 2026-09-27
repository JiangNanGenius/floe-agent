# Build 231 — local-model no-reply and first-message navigation repair

Status: source fix on `codex/build231-device-regressions`. Component tests pass on
the macOS host with deterministic engine doubles. The Build 231 actual-weight
cloud qualification (run 36290562417, macOS host) then passed ordinary
generation and the first `workspace.readFile` call before stalling in decoding
until the 180 s watchdog; that stall was traced to the stream framer and is
fixed below. **Cloud real-weight recheck 36292248126 passed two tool-enabled
conversation turns after the fix; iPad and full-App acceptance remain open.**
This document separates component-host evidence from device behavior.

## Reported failures (Build 230, iPad device feedback)

1. The on-device model no longer crashed, but the turn produced **no reply**.
2. The **first message sometimes did not navigate** to the chat; the thread was
   only reachable from the sidebar.

The matching device log upload was not on the log server at repair time and the
iPad was offline, so the notes below are source-level findings. They do not
claim to establish the exact stall point inside MLX.

## Source-level findings

### No-reply / no terminal state

- `MLXTextEngine.generateGuarded` accumulated every decoded chunk and only
  returned from `completeMeasured` after the upstream stream ended. The first
  user-visible token could therefore only appear after the whole generation.
- `LocalProviderAdapter.stream` awaited that entire call (and, for action
  requests, a second missing-tool repair pass) before yielding a single
  `textDelta`. A slow or stuck turn was an unbounded, silent wait.
- `AgentRuntime.startProviderWatchdog` deliberately disables the cloud
  no-progress watchdog for local providers (`providerWatchdogDisabled
  reason=onDeviceGeneration`), so nothing bounded the wait.
- `visibleAnswerMissing` emitted an empty `completed(endTurn)`. That is the
  intended trigger for the harness's **bounded** no-visible-answer
  continuation (`AgentRuntime.noVisibleAnswerContinuationCount`), which runs at
  most once and then fails recoverably with the run state saved — it is not an
  invisible success. The adapter now logs an explicit
  `reason=emptyVisibleAnswer` terminal diagnostic for that path.

### Follow-up stall — the stream framer's scan loop (actual-weight run)

The Build 231 actual-weight qualification (`run 36290562417`) generated, ran the
first `workspace.readFile`, and then stopped decoding: the follow-up turn never
returned, the watchdog fired at 180 s and the host footprint reached ~7.5 GB
(`Local/Private/build231/mlx-cloud-failed.log`). The primary agent compiled the
real `LocalStreamFramer` alone and proved
`ingest("Result: {\"content\":\"probe\"}")` does not return; the child had to be
killed by its 3 s subprocess timeout (`Local/Private/build231/framer-loop-probe.json`).

Two verified defects in `scanProse` caused it:

- `.notPayload` cleared `candidateStart` and returned `true` without consuming
  the rejected candidate, so `drain` re-detected the same non-tool JSON object
  forever. A closed fenced non-tool payload had the same shape.
- `scanProse` appended prose directly to `emitted` before an embedded
  `<think …>` block or a recognized tool envelope, but `ingest` returned only
  `releaseProse()`. Those prefixes were counted as delivered and could never
  reach the caller; `finish` then treated them as already shown.

A later review of the same code found one more chunk-boundary leak: a lone
trailing `{`/`[` was not recognized as a candidate and the line holdback only
covered lines that *start* with JSON, so `["Before: {", "\"tool_call\":…"]`
released the envelope's first byte and then its body as prose.

### First-message navigation

- `HomeLaunchpadViewModel.sendNewTask` awaited `load()` after
  `center.startTask`, and `ConversationCenter.startTask` awaited `reload()` —
  which awaits `reconcileLocalModelConfiguration()` → `adapter.listModels()`
  (Apple availability plus installed-model scans) — and a workspace reload
  before returning the durable identity. Home then ran a second `load()`.
- The conversation/run/message transaction was already durable before either
  refresh, so navigation was waiting on auxiliary catalog/history work.

## Changes

| File | Change |
| --- | --- |
| `Sources/FloeLocalModels/LocalInferenceLifecycle.swift` | Adds `LocalInferenceProgress` (categorical/numeric only: stage, prefilled/total input tokens, **emitted chunk count** — never a token claim) and the `streamMeasured` engine requirement with a buffered default for deterministic doubles. |
| `Sources/FloeLocalModels/MLXTextEngine.swift` | `streamMeasured` forwards decoded chunks as they arrive and emits `preparing` → `prefill (0/N)` → `prefill (N/N)` → `decoding` progress (throttled at 0.5 s). `completeMeasured` delegates to the same core with nil sinks. Tool-call envelopes keep the existing newline-separated encoding. The scoped `MLX.withError` error box and the per-turn GPU drain/clear teardown are unchanged. |
| `Sources/FloeLocalModels/LocalGenerationWatchdog.swift` | Bounded no-progress policy (first activity 300 s, idle 180 s, production) and a thread-safe progress ledger. Expiry only cancels the Swift task; cancellation is cooperative and the runtime/engine teardown drains the GPU stream before anything is freed, so a timeout never releases a container with in-flight GPU work. |
| `Sources/FloeLocalModels/LocalStreamFramer.swift` | Incremental display framer: releases provably visible prose; withholds cross-chunk `<think …>` blocks, whole-payload/fenced/one-per-line JSON tool envelopes and `Thinking Process:` scratchpads. `finish(visibleAnswer:)` reconciles the streamed prefix with the authoritative answer so content is never displayed twice. Build 231 followed up: every scan pass provably progresses (`candidateSearchStart` skips a rejected candidate by exactly its consumed region), `ingest` returns exactly the text it appended to `emitted` so a released prefix can never be counted but not delivered (including prose before an embedded think block/envelope), and an opening brace/bracket followed only by whitespace is held as an undecided candidate so a chunk split immediately after `{`/`[` cannot leak an envelope as prose. Deterministic regressions live in `FloeAgent/Tests/FloeLocalModelsTests/LocalStreamFramerRegressionTests.swift` (bounded per-scenario supervision) and the supervised harness `Local/Scratch/build231-framer-fix`. |
| `Sources/FloeLocalModels/LocalProviderAdapter.swift` | `LocalModelRuntime.streamMeasured` keeps the exact admission/lease/prefill/retry/teardown ownership and forwards progress + decoded text. The adapter streams prose through the framer, keeps JSON tool parsing/reasoning extraction/tool budget unchanged, logs explicit end reasons (`toolUse`, `endTurn`, `emptyVisibleAnswer`, `missingToolInvocation`), and adds the supervisor. The transparent decode retry is skipped once any output was delivered (a replay would duplicate the visible answer). |
| `FloeApp/Remote/ConversationCenter.swift` | `startTask` publishes the durable conversation into `conversations` synchronously and runs `reload()`/workspace reload afterwards without blocking the returned identity. |
| `FloeApp/Home/HomeLaunchpadViewModel.swift` | `sendNewTask` returns the durable conversation id immediately; the overview refresh runs in an unstructured main-actor task. Failed sends still keep the draft and create no thread. |

## Terminal-state matrix (adapter)

| Outcome | Emission | Notes |
| --- | --- | --- |
| Visible answer | streamed `textDelta`s + `usage` + `completed(endTurn)` | Reconciliation emits only the not-yet-displayed remainder. |
| Tool call | `toolRequest(s)` + `completed(toolUse)` | Tool JSON is never shown as prose; parsing is unchanged. |
| Empty output | `usage` + `completed(endTurn)`, warning `reason=emptyVisibleAnswer` | Harness runs one bounded continuation, then fails recoverably. |
| No progress | one `.error` (network, "本地模型长时间没有输出…") + finish; work task cancelled | Container is not released until the generation call returns and drains. |
| User cancel | stream ends / `CancellationError` | No extra error event; engine observes cancellation before teardown. |
| Repair required but no call | `validationFailed` (existing message) | Unchanged semantics. |
| Context overflow / memory | normalized recoverable events (existing) | Unchanged. |

## Tests run (macOS host, deterministic doubles — no weights)

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
swift build --package-path FloeAgent --scratch-path FloeAgent/.build \
  --force-resolved-versions --jobs 2 --target FloeLocalModelsTests
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  /Applications/Xcode-beta.app/Contents/Developer/usr/bin/xctest \
  FloeAgent/.build/out/Products/Debug/FloeLocalModelsTests.xctest
```

Result at the time of writing: **151 tests in 25 suites passed**, including the
new `Local stream framer`, `Local generation watchdog state` and
`Local streamed delivery` suites:

- prose streams before completion and exactly once;
- cross-chunk think markup never reaches the visible stream;
- a split tool envelope yields `toolRequest`/`toolUse` with no prose;
- an empty generation ends as an explicit empty `endTurn`;
- a stalled generation ends with one explicit no-progress error and the engine
  observes cancellation first;
- consumer cancellation propagates to the engine;
- a two-turn tool flow keeps the settled receipt and returns a non-empty
  answer; the continuation prompt/instructions actually received by the engine
  contain the bounded Qwen tool-protocol text and the receipt (asserted, not a
  minimal prompt);
- a retriable decode failure retries exactly once and then surfaces the
  failure with no text and no completion;
- a cold-load (`preparing`) stage extends the long first-activity window
  instead of switching to the shorter idle deadline.

During verification, a full `swift test` initially encountered region-isolation
errors in the parallel VM task. That task subsequently corrected them and
reported its module checks passing. The MLX evidence above comes from the
separately built and executed FloeLocalModels bundle, not the full App.

### Build 231 framer regression run (same host/toolchain, `--jobs 2`)

- Full `FloeLocalModelsTests` bundle after the framer fix: **162 tests in 26
  suites passed** (`xctest` returncode 0), including the 11 new
  `Local stream framer regressions (Build 231)` tests:
  - `ingest` of the primary reproduction returns promptly and character-exact;
  - ordinary non-tool JSON is exact at every two-way split and character-wise;
  - several rejected candidates advance to later ones;
  - a real offered envelope is hidden at every two-way split (78/78),
    including `["Before: {", …]` and `["List: [", …]`, and the closed
    non-tool fence no longer spins;
  - embedded think markup is hidden and the visible answer exact at every split
    (24/24);
  - the prose prefix before an envelope/think block is delivered, and
    `emitted` always equals what the caller received.
  Each scenario runs on a dedicated thread with a bounded wait, so a regression
  fails the expectation instead of hanging the suite.
- Standalone supervised harness (`Local/Scratch/build231-framer-fix`, compiled
  against a byte-identical copy of the real source plus an adapter-parser
  double): 20 tests in 2 suites passed; probe 9/9 scenarios.
- Pre-fix baseline (`faba3df6…`) against the same tests: the primary
  reproduction fails in a bounded 5 s supervised wait; the envelope sweep
  reports 13 issues including `delivered="Before: {"` and
  `emitted="Before: {\"tool_call\":`; the standalone probe is killed at the
  60 s wall clock (`timedOut: true`). Evidence: `Local/Private/build231/framer-fix/`
  (`swift-test-*.log/json`, `probe-*.json`, `floelocalmodels-xctest.log/json`,
  `sources-*.txt`).

## Not proven here

- Full-App inference through the complete task/runtime and UI. The cloud
  recheck below uses the production model adapter in a qualification host
  with controlled input; it does not execute the entire iPad App.
- Any iPad behaviour: streamed prefill latency, watchdog thresholds under real
  memory pressure, and the first-message navigation timing.
- The exact Build 230 stall point; without the device log the fix is bounded
  wait + explicit terminal + streaming progress, not a proven root cause.

## Hooks for the main thread (outside this task's scopes)

- Cloud real-weight recheck completed as recorded below. The App build and
  device acceptance remain coordinator-owned gates.
- Optional UI progress during prefill (stage/liveness text) would need an
  owner-runId-aware hook in `FloeApp/Settings/LocalModelsSettingsView.swift`
  or `ConversationCenter` feeding `backgroundRunCoordinator.didUpdateProgress`;
  the runtime already emits bounded progress but the app does not surface it.
- This document is linked from `docs/README.md`.

## Cloud real-weight recheck after the framer repair

[Run 36292248126](https://github.com/JiangNanGenius/floe-agent/actions/runs/36292248126)
passed at `c7b9dd78be93cd353c84640c007648f173c2b49b` on 2026-09-27.
The actual Qwen 4B snapshot completed constrained batch48 and balanced batch96
profiles, then two conversation turns with two distinct `workspace.readFile`
call IDs and receipt digests. `tool-roundtrip-complete` reports
`conversationTurns=2` and `answerContainsReceipt=true`; final shutdown completed.
The recorded platform is **macOS-host-not-iPad**. This resolves the newly
reproduced parser stall in this cloud path, not the original device diagnosis
or physical-iPad acceptance. The original failed run `36290562417` remains
recorded above. See [the compact evidence](evidence/build231/model-cloud-check.json).

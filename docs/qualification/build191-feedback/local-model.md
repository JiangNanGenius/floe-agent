# Build 191 feedback — local-model lifecycle races (admission + cancellation)

Date: 2026-09-19. Branch `codex/build191-feedback-repair`. Scope:
`FloeAgent/Sources/FloeLocalModels` and the new tracked harness
`FloeAgent/scripts/tests/local_model`. No App/CI build, no simulator or device
run, no root SwiftPM, no download, no commit.

The build191 foreground SIGABRT (`Qwen35GatedDeltaNet` chunked-prefill
`gatedDeltaUpdate`) remains **unproven fixed**. Nothing in this record claims
otherwise: the changes below close app-side lifecycle ordering races and refuse
the on-device GPU paths iOS rejects, but the fused GDN kernel itself is
unchanged and still has no app-side bypass.

## 1. Races closed in this round

The first round registered local generations only *after* creating the
generation task and installed the UIKit observers only on first registration.
That left three windows in which a local generation could submit GPU work while
the app was not active:

| # | Window (code reading) | Consequence | Change |
| --- | --- | --- | --- |
| 1 | Task creation preceded `register(...)`, so a `willResignActive` delivered in between found an empty registry. | The registered cancel closure did not exist yet; the prefill loop could keep submitting while the app was inactive — exactly the state upstream mlx-swift-lm PR #423 expects the app to cancel in. | Registration runs before the task is created; the task's cancel forwarder is attached afterwards through `LocalInferenceCancellationRelay`, which remembers a cancellation that arrived in between and reports it at attach time. |
| 2 | The first local generation after the app was already backgrounded installed the observers too late: the delivered notification is never replayed, and no probe consulted `applicationState`. | A background agent continuation (the harness keeps runs alive through a short background lease) could start a local generation whose lifecycle notification was already missed. | `registerForeground` refuses to hand out a token while the app is not active, and `LocalModelRuntime.completeMeasured` additionally probes foreground eligibility *before* mapping weights. The registration lock compares a lifecycle epoch snapshotted before the probe, so a transition that lands during the probe is not overwritten by the stale result. |
| 3 | After `cancelAll` emptied the registry, a new registration could still be accepted while the app stayed background. | No future notification would cancel the new entry until the app became active again. | Admission is gated on the live foreground probe; rejection marks the registry suspended so concurrent registrations with a stale epoch also refuse. |

Additional lifecycle properties:

* The UIKit probe uses `await MainActor.run { UIApplication.shared.applicationState == .active }`
  (non-blocking hop). `DispatchQueue.main.sync`, timers and sleeps do not appear
  in the registry.
* Background observers (`willResignActive`, `didEnterBackground`) stay installed
  for the process lifetime; `didBecomeActive` clears the suspended state. There
  is no remove/re-add window.
* Caller cancellation is preserved: the unstructured generation task is still
  wrapped in `withTaskCancellationHandler`, the relay forwards it, and a
  cancellation that races the admission is re-checked before the task is
  created.
* Remote providers are not touched. The registry is only consulted by the
  on-device MLX path.
* A refusal is a `CancellationError`, so a refused local turn follows the same
  interrupted-run handling as an ordinary stop rather than a model failure.
* `preload(modelID:)` (Settings page, direct user action) is deliberately not
  admission-gated; it does not run the agent's decode/prefill path.

## 2. Source changes

| File | Key lines |
| --- | --- |
| `FloeAgent/Sources/FloeLocalModels/LocalInferenceBackgroundCanceller.swift` (new, 276 lines) | `isForegroundEligible` :83 · `registerForeground` :97 · `unregister` :129 · `applyLifecycleTransition` :150 · UIKit observers :180-206 · `MainActor.run` probe :212 · test probe seam :228 · `LocalInferenceCancellationRelay` :242-272 |
| `FloeAgent/Sources/FloeLocalModels/LocalProviderAdapter.swift` | foreground gate before `prepareEngine` :200-205 · register-before-task + relay :238-273 · caller-cancellation re-check :257 · `withTaskCancellationHandler` :276-280 |
| `FloeAgent/scripts/tests/local_model/` (new) | `run_local_model_lifecycle_checks.sh`, `canceller_lifecycle_probe.swift`, `runtime_pattern_probe.swift`, `extract_and_assert.py`, `README.md` |

The earlier `MLXTextEngine.swift` changes (scoped `MLX.withError` teardown
helper, prefill/decode diagnostic markers, cancellation classification) are
unchanged and still structurally asserted by the harness.

## 3. Reproducible checks (executed on this checkout)

```bash
bash FloeAgent/scripts/tests/local_model/run_local_model_lifecycle_checks.sh
```

Actual result: exit 0, `RESULT: PASS (static + fixture + lifecycle + macOS SIL +
iOS SIL/object)`.

| Leg | Actual output |
| --- | --- |
| Static assertions + helper extraction | no `STATIC FAIL`; ordering proved textually on the real `completeMeasured`: gate < `prepareEngine` < `registerForeground` < cancellation re-check < task creation < relay attach < `withTaskCancellationHandler` |
| Extracted MLX helper fixtures | `fixture checks: 15 passed, 0 failed` |
| Lifecycle fixture compiled against the production canceller | `canceller lifecycle fixtures: 39 passed, 0 failed` — foreground admission, already-background refusal, transition-during-probe race, `didBecomeActive` recovery, unregister suppression, late registration after a delivered notification, 32-task transition storm, 64-task foreground storm, both register→attach orderings, relay exactly-once forwards |
| macOS SIL (canceller + runtime ordering pattern) | exit 0, 300,744-byte `.sil` (Apple Swift 6.4, CLT) |
| iOS SIL (`arm64-apple-ios26.0`, iPhoneOS27.0 SDK, Xcode-beta) | exit 0, 383,492-byte `.sil`; `ios_sil_uikit_branch=present` (`UIApplication.applicationState` emitted) |
| iOS object (`arm64-apple-ios26.0`, same SDK) | exit 0, 127,696-byte Mach-O arm64 object; `ios_object_observers=present`, `ios_object_relay=present` (`nm`) |

`swiftc -parse -swift-version 6` over the three scoped sources: exit 0.

Fixture sensitivity (mutation) check: removing the probe-epoch guard from a
scratch copy of the canceller (the production file was not modified) makes the
lifecycle fixture fail 3 checks — `a transition during the probe beats a stale
active probe`, `no registration survives the transition storm`, `storm
closures are never retained`. The race assertions are therefore not vacuous.

## 4. Limits (not covered here)

* No cloud App build. `LocalProviderAdapter.swift` cannot be compiled on this
  host (its `FloeCore`/`FloeModels`/`FloeProviders`/`FloeLocalModelCatalog`
  modules only exist in a full build); its ordering is asserted textually and
  mirrored by the SIL pattern probe. The App build remains the first semantic
  compile of that file (Swift 6 region isolation of the generation task, the
  `MLX.withError` overloads and the UIKit probe).
* No simulator or device run. The `UIApplication.applicationState` probe and
  the observers' real delivery timing are device-side evidence.
* The iOS SIL/object leg compiles the canceller and the ordering pattern, not
  the App target.
* The foreground `gatedDeltaUpdate` abort is not addressed and is not proven
  fixed. The background refusal/cancellation reduces the known class of
  GPU-submission-while-inactive failures; it cannot catch a terminate raised
  outside the Swift task on the foreground path.
* If the app is genuinely `.inactive` when a local run is requested (for
  example during an app-switch transition), admission refuses that run and the
  turn is recorded as interrupted; the user can retry once active.

## 5. Device confirmation (user)

1. Install a build containing these changes (cloud build; build 192+).
2. With a local model, start the large-prompt chat, then press Home or lock the
   screen during prefill. Expected: `localInferenceBackgroundCancelled
   trace=…` and the run ends interrupted — no SIGABRT.
3. Start a local run only after returning to the app when the previous one was
   refused: expected `localInferenceBackgroundRefused trace=… stage=…` while
   background, and a normal foreground run afterwards.
4. Stop button during prefill: expected cancellation (no
   `localInferenceFailed … decodeFailed`).
5. If a SIGABRT still occurs, retrieve the `.ips` report and compare it with
   the retained build191 frame table (the `gatedDeltaUpdate` /
   `Qwen35GatedDeltaNet.forward` frames identify the same upstream path), and
   report any `localInferencePrefillFailed message=<real MLX text>` marker.

## 6. Private evidence

The private build191 follow-up directory keeps the full device frame table,
prior evidence and this record's raw run log
(`Local/Private/build191-feedback/local-model-final/`).

中文摘要：本轮封闭本地 MLX 生成的三个生命周期竞态：(1) 生成任务早于注册创建，
`willResignActive` 落在注册前会被漏掉；(2) 首次本地生成时 App 已在后台，观察者安装
过晚且通知不会重放；(3) `cancelAll` 清空后应用仍停留后台时仍可注册。实现为
`registerForeground` 前景准入（注册锁内比较生命周期 epoch，避免被过期的 probe 结果
覆盖）、注册先于 GPU 任务创建、`LocalInferenceCancellationRelay` 记住
注册→启动窗口内的取消、`MainActor.run` 异步探测（避免主线程阻塞/死锁），并保留
caller 取消；远端 provider 与前台生成不受影响。39 项真实生产代码夹具、15 项 MLX
诊断夹具、macOS SIL 及 iPhoneOS27.0 SDK 的 iOS SIL/object 编译全部通过。**不宣称
修复前台 GDN `gatedDeltaUpdate` SIGABRT**：该融合内核路径未改动，仍需云端 App 编译
与真机确认。

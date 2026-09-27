# Floe 231 — Linux Guest Lifecycle Tools

Status: implemented in `FloeExecution` (+ `FloeTools` routing); focused module
tests. The hard-restart stop→start window race found in integration review is
repaired on the shared registry/service path (see
"Hard-restart stop→start window repair"); soft restart remains NOT implemented
(its section below names the real prerequisite). Dual-core is now exposed for
on-device testing on an image whose verified manifest proves SMP: S0–S4
correctness passed in cloud, the equal-work S5 benchmark is still slower on
two harts (so no speedup is claimed), and the production release cap was
removed by explicit user policy on 2026-09-27. Physical-device acceptance
remains a separate gate. This document records only sanitized engineering
findings.

## What exists now

Five model-facing lifecycle tools over one environment-owned TinyEMU guest.
They are registered only when the app injects a lifecycle service, exactly like
`environment.prepareLinux`:

| Tool | Effect | Purpose |
| --- | --- | --- |
| `environment.startLinux` | mutating | Cold start with explicit `vcpus`/`memoryMB` (default: 1 core, 256 MiB, matching the engine worker default). Reuses a running guest untouched. |
| `environment.linuxStatus` | read-only | Truthful running/stopped state, actual granted vCPU/RAM, image id, launch generation, last error. |
| `environment.stopLinux` | mutating | Stops the actual guest instance, verifies it left, releases its lease; preserves disk/shares. |
| `environment.softRestartLinux` | mutating | Safe in-guest flush+restart; currently returns an explicit unsupported capability (see below). |
| `environment.hardRestartLinux` | mutating | Stops the actual TinyEMU instance/threads, verifies the stop, then boots a fresh instance at the requested shape. Never deletes the environment. |

Implementation:

* `Sources/FloeExecution/Linux/LinuxGuestLifecycle.swift` — typed
  `LinuxGuestLifecycleConfig`, truthful `LinuxGuestLifecycleReceipt`, typed
  `LinuxGuestLifecycleError`, and the serializing `LinuxGuestLifecycleManager`
  actor.
* `Sources/FloeExecution/Tools/LinuxLifecycleTools.swift` — the five tools plus
  shared argument/rendering/exit-code mapping. Refusals are rendered as
  structured nonzero results, never as opaque tool crashes.
* `Sources/FloeExecution/Linux/LinuxGuestService.swift` — `LinuxGuestControlling`
  gained an explicit-shape `startGuest(environmentID:taskID:shape:)` and
  `runtimeStates()`, with default implementations that refuse honestly
  (never silently substitute another shape). It also carries the exclusive
  `LinuxGuestLifecycleTransaction` seam
  (`begin/end/stopFor/startForLifecycleTransaction`) with conservative
  defaults for backends that cannot hold an environment across a restart.
* `Sources/FloeExecution/Linux/LinuxGuestRegistry.swift` — `start` accepts an
  explicit typed shape which is merged onto the resolved descriptor and
  admitted strictly under the release gate; the shape-less overload is
  unchanged. The registry owns the transaction implementation: it holds the
  existing per-environment lifecycle lock (`ownerIsShapeChange`, so the
  existing `guestBusy` predicate guards direct starts), drains/detects an
  already-in-flight start through the existing `pendingStops` mechanism, and
  refuses `run`/`openSession`/`guestSpawn`/`setShape` while a transaction is
  held.

## Hard-restart stop→start window repair

The integration review found a real race the earlier cross-concurrency test did
not cover: `LinuxLifecycleManager.hardRestart` called `controller.stopGuest`,
whose registry teardown cleared `teardownsInFlight` and released the lifecycle
lock on return. During the manager's subsequent `waitUntilStopped` /
`startWithPreparation` window a direct `exec.shell` start could acquire the
environment first: it would boot a guest at another shape, the restart's own
start would then "reuse" it, and the receipt could claim success while
requested and actual vCPUs/RAM disagreed. The earlier test parked inside the
engine stop, so it only exercised the teardown gate.

Repair (all on the shared registry/service path, reusing the existing lock):

1. `beginLifecycleTransaction` acquires the environment's lifecycle lock as a
   shape-change-like owner and keeps it from before the old stop until after
   the replacement start. A start already in flight is signalled to abort with
   the existing `pendingStops`/arbiter-cancel mechanism and the transaction
   waits, bounded, for its marker to clear; a start already past that point is
   refused by the post-await shape-change re-check added at the end of
   `registry.start` (synchronous with the in-flight marker insertion, so the
   two can never interleave).
2. `stopForLifecycleTransaction` runs the same destructive teardown body as an
   explicit stop without re-acquiring the lock (no re-entrant deadlock) and
   keeps the `teardownInFlight` refusal for the stop itself.
3. `startForLifecycleTransaction` is the only path allowed through the
   transaction's shape-change refusal; every other guard (teardown marker,
   quarantine, admission, release gate) still applies.
4. The manager re-reads the running shape under the transaction (a direct
   start that completed between its probes and the transaction acquisition is
   still stopped and restarted, never mistaken for the replacement), verifies
   the granted vCPU/RAM against the resolved request after the start, and
   releases the transaction on success, cancellation, refusal or failure. A
   quarantine left by an unconfirmed stop survives the release.

Deterministic coverage: `LinuxLifecycleManager` exposes an internal
`setRestartWindowBarrier` interleaving hook (never set by app code). The
cross-concurrency suite parks exactly at the point where the old stop is fully
complete and the replacement has not started, then lands a direct start,
execute, terminal and shape change. Before this repair the direct start won the
environment (reproduced deterministically: the new test failed on the direct
start assertion); after it all four are refused with `guestBusy`, exactly one
replacement engine boots, and the final registry state is 1 vCPU / the
requested RAM.

## Honesty invariants

* **Requested vs actual.** Every receipt reports `requestedVCPUs`/`requestedMemoryMB`
  (the caller's typed choice) separately from `actualVCPUs`/`actualMemoryMB`
  read back from the runtime's own session table, plus `reused` and
  `launchGeneration`.
* **No silent reshape.** Guest vCPU and RAM are fixed at create time. An
  explicit shape that contradicts the running guest is refused with
  `runningShapeMismatch` / `runningMemoryMismatch`; the running guest is never
  reset to satisfy a later start. Every dimension the caller leaves unspecified
  is PRESERVED from the running guest, so a hard restart never silently resets
  an explicitly configured VM to the cold-start default; only a restart with no
  running guest (or a cold start) uses the default single-core shape.
* **No silent rounding.** Configuration values are validated server-side on the
  expressible guest ladder: `vcpus` must be 1 or 2 and `memoryMB` must be
  exactly one of 256/512/768/1024/1536/2048. An out-of-ladder value (e.g.
  600 MiB or `vcpus=3`) is refused with `invalidConfiguration` and nothing
  boots; it is never clamped or rounded onto another shape. The JSON-schema
  enums are a convenience for the model, not the authority.
* **Reuse.** A start with no explicit conflict reuses the running guest and
  says `reused=true`. A parameterless `exec.shell` therefore keeps an
  explicitly configured guest exactly as it is.
* **Hard restart is a real stop + start.** It stops the actual instance,
  waits for the runtime to report it gone, and only then starts a fresh
  instance; it also verifies the launch generation rotated and that the
  replacement was really granted the resolved vCPU/RAM (a mismatch is refused,
  never smoothed into a success receipt). The environment, its persistent disk
  and its shares are never deleted or reset. A guest-shell `reboot` cannot
  control the host.
* **Disruption gates.** An open interactive terminal blocks stop/hard-restart
  (`activeInteractiveTerminal`); remaining managed services are terminated and
  counted in the receipt. The tools carry `RiskLabel`s so the existing
  approval/risk system decides authorization. Both start paths run inside the
  registry's existing heavy-runtime (MLX) arbitration; the optional injected
  image-preparation closure gives the same prepare-then-retry behavior as the
  shell path.
* **Shared-layer concurrency.** Cross-concurrency gating lives on the shared
  registry/lease path (in-flight start/teardown markers, lifecycle lock,
  reservation/quarantine), not only on the manager actor, so a direct shell
  start cannot slip into a hard restart's stop→start window. A hard restart
  additionally holds an explicit **lifecycle transaction** on the shared
  service (`startForLifecycleTransaction` / `stopForLifecycleTransaction` /
  `endLifecycleTransaction`): it reuses the registry's existing
  per-environment lifecycle lock (no second lock, no parallel owner) from
  before the old stop until after the replacement start is registered. While
  it is held, a direct `start`, guest command (`run`), terminal
  (`openSession`), managed-service spawn and shape change are refused with
  `guestBusy` instead of preempting; a shape-change-like `destroy`/`stop` path
  queues behind it through the same lock. The transaction's own stop runs the
  same destructive body and keeps the existing `teardownInFlight` refusal for
  the stop window; a quarantine left by an unconfirmed stop survives the
  transaction release. Every failure, cancellation or refused start releases
  the transaction, so the environment is never left locked.

## Dual-core: exposed for on-device testing (correct, currently slower)

`GuestReleaseShapePolicy.production` now qualifies up to **two harts** (user
policy, 2026-09-27; the old one-hart cap existed only because the equal-work S5
benchmark was slower, and that performance-only cap is not a correctness
gate). Nothing else became permissive:

* An untyped request still resolves to the default **one hart**; ordinary
  shells are unchanged.
* The second hart is granted ONLY when the verified image manifest proves SMP
  (`RuntimeV2ImageStatus.smpCapability`), which requires the image's own kernel
  and firmware to be the reworked CONFIG_SMP pair. The image declares that with
  `smp_capable: true`; `build-guest-image.sh --smp-capable` refuses to write it
  without a real `SMP-BUILD.txt` multi-hart evidence file, so a bare
  `vcpus=2` change on the 2018 UP pair cannot boot a fake dual guest.
* Memory/quota/lease/stop guards are unchanged: the pool still admits on
  vCPU+RAM+VM, the heavy-runtime arbiter still serializes with local inference,
  and explicit 2-core requests are never silently reduced to one hart.

Evidence status:

* Cloud runs 36004192418 / 36009075837 pass S0–S4 with the real SMP pair: boot,
  `/proc/cpuinfo` = 2 processors, `fork/exec`, parallel 9P, per-hart retired
  instructions.
* S5 equal-work is still **slower** on two harts (medians 1.69 s vs 1.93 s,
  ratio 0.876× < 1.10×). The UI and tool descriptions state that truthfully;
  no speedup is claimed and device thermal/performance acceptance stays with
  the user.
* The engine's `riscv_cpu.c` reservation/store ordering was NOT changed for
  this exposure: the already-S0–S4-verified global-lock implementation is the
  one shipped, and the patch series still reproduces the vendored tree
  (`regen_smp_patch.sh --check`). A faster lock design remains future work and
  must not land before a green S0–S4 rerun.

Residual prerequisites for calling dual-core a *release* capability:

1. Publish and install an SMP-capable image (component-image-ci
   `smp_image=true`, `smp_capable` declared) and boot it on device.
2. Re-run the cloud S0–S5 contract on the immutable candidate before any
   claim that dual is faster or broadly qualified.
3. User device acceptance (thermal, memory, actual workload behavior).

## Soft restart: NOT implemented

The current guest image has no ordered
flush + durable restart agent. `environment.softRestartLinux` therefore returns
an explicit `capabilityUnsupported` result (exit 125) that names the missing
agent and points at hard restart, rather than pretending success. Soft restart
becomes available only when a guest agent implements a real ordered
flush+restart and is injected via `LinuxGuestSoftRestartPerformer`; until then
the lifecycle loop is complete only through start/status/stop/hard-restart.

## App assembly seam (owned by the app target)

The app injects the manager after `TinyEMULinuxCommandService` exists, e.g.:

```swift
let lifecycleManager = LinuxGuestLifecycleManager(
    controller: linuxGuests,
    // optional, recommended: same prepare-then-retry as the shell path
    prepareImage: { _, cancellation in
        _ = try await FloePlatformServices.shared.prepareLinuxEnvironment(
            cancellation: cancellation ?? CancellationToken()
        )
    }
)
```

then passes it to `registerExecutionTools(linuxLifecycle: lifecycleManager)`.
`AppEnvironment.swift` is owned by the coordinator; the module never reaches
into it, and `FloeExecution` performs no image/URL resolution of its own.
The optional `prepareImage` hook is intended to be wired to the app's existing
`linuxPreparation` closure so a missing/unqualified image takes the same
prepare-then-retry route `exec.shell` already uses.

## Focused verification

`FloeExecutionTests` covers: default single-core cold start, explicit
single-core carried to the runtime descriptor, explicit dual carried to the
runtime under production / refused under a narrower release ceiling with no
boot, dual starts and reshapes recorded with the ACTUAL granted hart count,
running-guest reuse (untouched generation), vCPU/RAM mismatch refusal, restart
shape preservation (unspecified dimensions kept), out-of-ladder
`vcpus`/`memoryMB` rejected without rounding, terminal-blocked stop,
service-stop counting, soft-restart unsupported, hard-restart generation
rotation, dual hard restart applied under production and refused before
disruption under a narrower ceiling, cancellation (start and hard restart),
image prepare-then-retry, status truthfulness, ungranted-shape refusal for cold
start and restart (scripted preemption), real JSON → handler dispatch for all
five tools, and cross-concurrency on the real registry: a direct start during
the parked stop, a direct start/execute/terminal/shape change in the parked
stop→start window (all refused, one replacement engine, requested shape
verified), a failed replacement start releasing the transaction, an unconfirmed
stop keeping its quarantine while releasing the transaction, and a
release-ceiling (dual-core) refusal releasing the transaction without
disrupting the running guest. The pool tests cover the production dual path
(admitted with the verified image SMP proof, refused with the typed image error
without it). `FloeToolsTests` covers the guest routing of the five names.

Observed results (Xcode-beta 27.0, macOS host; full logs in
`Local/Private/active/build231-race/`):

* `swift build --target FloeExecution -j 2` and `--target FloeExecutionTests
  -j 2` (object compilation, not typecheck) → exit 0.
* `xcrun xctest -XCTest LinuxGuestLifecycleTests` → 23 tests, 0 failures.
* `xcrun xctest -XCTest LinuxLifecycleToolDispatchTests` → 6 tests, 0 failures.
* `xcrun xctest -XCTest LinuxLifecycleCrossConcurrencyTests` → 5 tests,
  0 failures. The same test run on the pre-repair source failed
  deterministically at the stop→start window assertion (a direct start owned
  the environment), which is the reproduced race.
* `xcrun xctest -XCTest LinuxGuestShapeLifecycleTests` → 30 tests, 0 failures
  (the pre-existing reshape/teardown interleavings still hold).
* `xcrun xctest -XCTest LinuxLifecycleRoutingTests` (FloeToolsTests) →
  3 tests, 0 failures.
* Full `FloeExecutionTests` bundle → 361 XCTest tests + 222 Swift Testing
  tests, 0 failures.

A pre-existing, unrelated failure remains in the `FloeToolsTests` bundle:
`MCPRemoteToolSourceTests.canvasPolicyDefaultsClosed` expects a hardcoded
canvas/notes list that omits `video.models`, which
`CanvasAgentToolPolicy.nativeToolNames` has deliberately contained since
commit 97377878. It names no Linux lifecycle tool and is not caused by this
work.

# Runtime scheduling probe

This macOS probe exists for one bounded question: can ordinary main-queue /
MainActor work run while a long-lived, main-thread driver loop is alive?

It is **not** XCTest-validity evidence. It does not load the DDI, XCTest,
UIKit or the Bridge host. The real proof remains a physical-device run of the
signed BridgeHost with the embedded `BridgeTests.xctest`.

## Scenarios

| Scenario | Entry | Driver |
| --- | --- | --- |
| `gcd-nested-runloop` | `DispatchQueue.main.async` (current defect) | synchronous nested `RunLoop.run` forever |
| `runloop-nested-runloop` | `CFRunLoopPerformBlock` on the main run loop | synchronous nested `RunLoop.run` forever |
| `runloop-isolated-nested-runloop` | same run-loop block | `@MainActor` synchronous nested driver |
| `runloop-cooperative` | same run-loop block | `@MainActor async` driver with bounded `Task.sleep` |

Each scenario measures, for two seconds after entry:

- `hostActorTaskTicks`: a main-run-loop `Timer` whose callback hops with
  `Task { @MainActor in ... }` — the exact `BridgeAppModel` / host command
  poller shape.
- `mainQueueBlocks`: a self-rescheduling `DispatchQueue.main.asyncAfter` chain.
- `runLoopTimerTicks`: a direct main-run-loop timer (proves the nested run
  loop itself is pumping).
- `heartbeatTicks`: a private-queue `DispatchSourceTimer` (proves the process
  and non-main executors stay alive).
- `driverIterations`, `driverThreadIsMain`, `driverEntered`.

The expected defect reproduction is: driver alive, run-loop timer and
heartbeat advancing, but both `hostActorTaskTicks` and `mainQueueBlocks` stuck
at zero. The candidate entry must show all four progressing.

## Run

```sh
bash FloeIOSBridge/Tests/RuntimeScheduling/run_scheduling_probe.sh
```

Defaults:

- scratch/binary: `Local/Scratch/ios-bridge-20261031/cooperative-repair`
- evidence: `Local/Private/ios-bridge-20261031/cooperative-repair/scheduling`

Override with `FLOE_BRIDGE_SCHEDULING_SCRATCH` and
`FLOE_BRIDGE_SCHEDULING_OUTPUT`. Exit status is non-zero if any scenario does
not match its expected primitive behavior.

## Supplementary XCTest shape probe

`run_async_xctest_probe.sh` builds a small macOS `.xctest` whose only test is a
never-returning `@MainActor async` method with a main-run-loop `Timer` that
hops with `Task { @MainActor in ... }` — the `BridgeEngineTests` shape. It runs
the test under the real XCTest runner for a few seconds, samples the JSON the
test writes, then terminates the runner. This confirms the async test method is
discovered and that host-style MainActor work progresses while it is alive; it
is still not device, DDI or UI evidence.

The probes are command-line macOS tools and are not part of any Xcode target in
`project.yml`.

## Liveness callback isolation regression

Run `python3 FloeIOSBridge/Tests/RuntimeScheduling/run_liveness_callback_probe.py`
from the repository root with Xcode 27.1 selected through `DEVELOPER_DIR`.
Outputs default to the repository's private evidence and scratch folders.

This Darwin qualification compiles a legacy MainActor-created timer callback
and the handler extracted from `BridgeLivenessMonitor.swift`. The legacy child
must terminate with SIGTRAP; the fixed child must execute at least three
callbacks off the main thread while MainActor is deliberately blocked, then
cancel its timer and exit successfully. The original failure, compiler output,
generated source and measurements are retained. Child core dumps are disabled
without changing system crash-report settings.

It verifies actual callback execution, not iOS launch, DDI, cross-App or
background acceptance. Run it again when changing the heartbeat handler.

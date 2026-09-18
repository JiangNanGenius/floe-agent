# Local-model lifecycle regression harness

Tracked companion to `FloeAgent/Sources/FloeLocalModels/LocalInferenceBackgroundCanceller.swift`.
It closes and keeps closed the on-device MLX lifecycle races behind the
build191 local-chat crash follow-up:

* a local generation must not start (or continue) while iOS would reject GPU
  submissions because the app is not active;
* registration for background cancellation must happen **before** the GPU task
  is created, and a transition delivered in the register→launch window must
  still cancel that task;
* a background agent continuation must not start local GPU work after the
  resign-active notification was already delivered (or never observed);
* caller cancellation keeps working for the unstructured generation task;
* no dispatch/timer/signal workaround may appear in the registry.

## Run

```bash
bash FloeAgent/scripts/tests/local_model/run_local_model_lifecycle_checks.sh
```

Exit 0 = every leg passed. Exit 2 = SKIP: the iPhoneOS SDK for the SIL/object
leg is unavailable and the remaining legs passed. Exit 1 = FAIL.

`HARNESS_SCRATCH=<dir>` overrides the scratch directory;
`SWIFTC=/path/to/swiftc` overrides the compiler; `IOS_SDK=<path>` or
`DEVELOPER_DIR=<Xcode.app/Contents/Developer>` selects the SDK for the iOS leg
(Xcode-beta is probed first).

## Legs

| Leg | What it proves |
| --- | --- |
| `extract_and_assert.py` | Textually extracts `boundedRuntimeDiagnostic`/`isCancellation` from `MLXTextEngine.swift` (drift fails the harness) and asserts the structural invariants of the canceller, the MLX teardown/diagnostic guards and the `completeMeasured` ordering. |
| extracted helper fixtures | 15 checks over the extracted MLX helpers (domain/code preserved, newline flattening, 240-character bound, cancellation classification). |
| `canceller_lifecycle_probe.swift` | 39 checks against the **production** canceller + relay compiled from the real source: foreground admission, already-background refusal, transition-during-probe race, `didBecomeActive` recovery, unregister suppression, late registration after a delivered notification, 32-task transition storm, 64-task foreground storm, and both register→attach orderings. |
| macOS SIL | Swift 6 SIL emission for the production canceller + a probe mirroring the runtime ordering (gate → register → task → attach → await). |
| iOS SIL + object | Same sources compiled for `arm64-apple-ios26.0` with the iPhoneOS SDK. The leg asserts the UIKit branch really emitted (`UIApplication.applicationState` in SIL, `installObserversIfNeeded`/relay symbols in the object). |

## Fixture sensitivity

The race assertions are not vacuous: removing the probe-epoch guard from a
scratch copy of the canceller (production file untouched) makes the lifecycle
fixture fail 3 checks — `a transition during the probe beats a stale active
probe`, `no registration survives the transition storm`, `storm closures are
never retained`.

## Limits

This is a host harness. It is **not** an App build, simulator run, device run
or acceptance of the build191 foreground `gatedDeltaUpdate` abort, which stays
unproven fixed. `LocalProviderAdapter.swift` cannot be compiled here (its Floe
modules exist only in a full build), so its ordering is asserted textually and
mirrored by the SIL pattern probe; the cloud App build remains the first
semantic compile of that file.

The background branch of the canceller is driven through the production
`applyLifecycleTransition(isBackground:)` and the documented
`installForegroundProbeForTesting` seam on the non-UIKit host; the UIKit probe
itself is compiled (SIL/object) but its `UIApplication.applicationState`
behavior is device-side evidence.

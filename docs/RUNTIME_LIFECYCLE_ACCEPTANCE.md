# Runtime lifecycle acceptance — service restart, environment deletion, Lua install

> Historical record (builds 184-185). The `apt install floe/lua` entry point named below was later replaced by
> installation from the verified signed WASI catalog (`wasm.packages`); the lifecycle/acceptance scope recorded
> here is preserved as written. Current behavior is described in the [user guide](USER_GUIDE.md).

Status: **tests authored, source-reviewed and syntax-checked locally, not
executed here.** Target membership is wired in `project.yml` and both CI/release
selectors; the real FloeAppTests run must still happen in cloud CI on an iOS
Simulator with network access. No `xcodebuild`, simulator boot, app source
change or dependency install was performed on this Mac.

Reviewed production baseline: branch `codex/build178-feedback`,
`e0c846f93c48d690fe71433ea0418faaad221aa5`. The two executable-check files and
their `project.yml`/workflow wiring were added on top in `5e7a609e`; they
executed in the build 184 cloud App regression (`8e0cf69`) and are present
unchanged at the build 185 candidate `42ecc452`. The
runtime/execution/package paths were byte-identical
through `e0c846f9` to the green CI source `955e346a` recorded in
`docs/qualification/build179-release/runtime/README.md`; that checkpoint lists
three open acceptance items for which this change adds executable checks:

| Open item (runtime/README.md) | Acceptance added |
| --- | --- |
| "Explicit service restart ... lack direct acceptance coverage" | `LocalServiceLifecycleTests.restartLocalServiceServesRealHTTPForNodeAndPython` |
| "environment-deletion shutdown lack direct acceptance coverage" | `LocalServiceLifecycleTests.environmentDeletionStopsOwnedServicesAndLeavesOthersRunning` |
| "Full-App `apt install floe/lua` to shell command acceptance remains open" | `LuaShellInstallTests.aptInstallRunsLuaAndRemoveDisablesIt` |

## What the tests exercise (production runtime, no mocks)

### 1. `BackgroundJobService.restartLocalService` → real HTTP

`FloeAgent/Tests/FloeAgentUITests/LocalServiceLifecycleTests.swift`
(`restartLocalServiceServesRealHTTPForNodeAndPython`)

- Creates a real project environment through
  `FloePlatformServices.shared.prepareWorkspaceEnvironment(root:)`, so
  `ToolEnvironmentRouting.shared` (wired to `EnvironmentExecutionCoordinator`
  in `FloeApp/App/AppEnvironment.swift:356`) resolves the real writable layer.
- Persists a **terminal** `exec.localService` job (the exact precondition of
  `restartLocalService`, `Sources/FloeExecution/BackgroundJobService.swift:225`).
- Registers a real `LocalServiceTool(store:)` bound to the same durable store,
  then calls `restartLocalService(id:)`.
- Waits (bounded, 250 ms polls) for the durable `previewURL`, performs a real
  `URLSession` GET against it, asserts the Node/Python server body, cancels the
  job, waits for a terminal state, and asserts the port is no longer reachable
  and the runtime reports no active worker (`FloeNodeHasActiveTask` /
  `CPythonLocalRuntime.hasActiveWork`). It also re-checks that
  `BrowserURLPolicy.validate` now rejects the revoked preview URL.
- Runs for both `node` and `python`.

### 2. Environment deletion waits for owned services (port unreachable)

Same file (`environmentDeletionStopsOwnedServicesAndLeavesOthersRunning`)

- Creates two independent real project environments and starts real services
  owned by them: a Node + Python service for the environment to delete, a Node
  service for the survivor.
- Calls the production `FloePlatformServices.shared.deleteEnvironment(id:)`
  (`Sources/FloePackages/EnvironmentManagementService.swift:154` →
  `Sources/FloeEnvironments/ContainerLifecycle.swift:54` → `stopWork` hooks in
  `FloeApp/App/AppEnvironment.swift:361-382`).
- Asserts that when `deleteEnvironment` returns, both owned ports are already
  unreachable, no owned worker remains, the deleted record is gone, and the
  unrelated environment is still registered and still serving HTTP.

### 3. App-layer `apt install floe/lua` → execute → remove

`FloeAgent/Tests/FloeAgentUITests/LuaShellInstallTests.swift`
(`aptInstallRunsLuaAndRemoveDisablesIt`)

- Drives the real shell command registry (`IOSSystemShellBackend` →
  `floe-shell-command-main`) with an attached real `ToolEnvironment`, so the
  registered `apt` command uses the app `PackagesCLI` +
  `ShellWasmCapabilityRouter` (`FloeApp/Execution/CapabilityStoreAdapters.swift:40`)
  and the app `CapabilityInstaller`/`SignedWasmCapabilityStore`
  (`FloeApp/Execution/FloeShellCommands.swift:627-631`,
  `FloeApp/Execution/FloeShellCommands.swift:305-354`).
- `apt install -y floe/lua` downloads the artifact pinned by the signed bundled
  catalog, verifies SHA-256, and activates `floe-lua`.
- `floe-lua -e "print(2 + 40)"` executes a real Lua script through the WASI
  runtime and must print `42`.
- `apt remove -y floe/lua` then `floe-lua ...` must fail closed with exit 127
  and an "is not installed" message.

Local static verification of the catalog assumptions (no app build):

```
python3 ...  # Ed25519 verify catalog.sig over b"FLOE-CAPABILITY-CATALOG-V1\n"+catalog.json
SIGNATURE_VALID
catalog_sha256 81ad32f4eca06d232598ad7bf6f4f92bab4864a5b5d0f4da036e159b2efdf049
disk_sha256    81ad32f4eca06d232598ad7bf6f4f92bab4864a5b5d0f4da036e159b2efdf049
match True
command floe-lua version 5.4.8 minApp 1.7.0
```

(`FloeAgent/FloeApp/Resources/Capabilities/catalog.json`, `.sig`,
`public-key.json`; artifact `capability-hub/packages/floe-lua/5.4.8/lua.wasm`,
671 143 bytes.)

## Target membership and CI selectors (applied)

`FloeAgent/project.yml` routes the runtime tests in `Tests/FloeAgentUITests`
into the `FloeAppTests` **unit-test** bundle (hosted by the app,
`TEST_HOST`/`BUNDLE_LOADER`, so `@testable import FloeApp` links), and excludes
them from the `FloeAgentUITests` UI-test bundle. Both new files are now wired:

1. `FloeAgentUITests.sources.excludes` — `LocalServiceLifecycleTests.swift`,
   `LuaShellInstallTests.swift` (`project.yml:724-725`).
2. `FloeAppTests.sources` — both paths (`project.yml:761-762`).
3. `.github/workflows/ci.yml` `-only-testing:FloeAppTests/LocalServiceLifecycleTests`
   and `.../LuaShellInstallTests` in both the build-for-testing and the
   test-without-building phases (`ci.yml:340-341`, `413-414`).
4. `.github/workflows/release-unsigned-ipa.yml` selects both in its App
   regression phases (`release-unsigned-ipa.yml:406-407`, `899-900`).
5. `FloeAgent/scripts/verify_app_regression_xcresult.py:27-28` requires
   `LocalServiceLifecycleTests >= 2` and `LuaShellInstallTests >= 1`.

`FloeAgent/Tests/FloeAgentUITests/LocalShellRuntimeTests.swift` is already a
`FloeAppTests` member and was intentionally **not modified**; its Node/Python
HTTP start/get/stop fixture is reused by the new tests.

The main Xcode project was regenerated and now includes these tests with build
185. The generated project and `project.yml` are part of the same candidate.
Cloud execution is recorded below.

## Cloud execution observed in build 184

The build 184 two-SDK App regression on source `8e0cf69` (run
[`35287358993`](https://github.com/JiangNanGenius/floe-agent/actions/runs/35287358993))
actually executed the app-hosted unit bundle. Each SDK leg passed 203/204:

- `LocalServiceLifecycleTests` passed on both legs (`FloeApp.LocalServiceLifecycle`
  is listed as passing and the strict verifier requires both cases). The real
  restart and environment-deletion cases therefore have cloud execution evidence.
- `LuaShellInstallTests.aptInstallRunsLuaAndRemoveDisablesIt` failed on both legs
  with `floe-lua ... validationFailed("WASM input exceeds limits")` — the old
  32-variable WASI cap rejecting the real shell export set, not a Node/Python
  lifecycle failure.

[Original regression record](qualification/build184-release/sdk27-app-regression.json).
UI gates, signing and upload were skipped; the unsigned device recovery archive is
retained ([record](qualification/build184-release/device-recovery.json)).

The Lua failure is repaired in source `f908cce1`. The new
`WasmEnvironmentContract` bounds variable count, per-key/value bytes and total
`KEY=VALUE` payload bytes with value-free diagnostics; `WasmKitCommandRuntime`
validates and forwards the caller's environment unchanged
(`WasmKitCommandRuntime.swift:54,71`), and the committed
`FloeShellCommands.swift:334` keeps the shell-authoritative
`context.shellVariables` without re-merging the dependency snapshot, so an
`unset` variable is not resurrected for WASM commands. Seven actual Swift
Testing cases passed on macOS, including the real signed Lua fixture, plus eleven
boundary/real-Lua checks
([evidence](qualification/build185-release/lua-environment.json)). The release
workflow now stages the signed fixture before the module tests (`0fff2c3b`), so
the fixture-gated case is not skipped on the release-only path. The app-level
`LuaShellInstallTests` rerun belongs to the build 185 full-App regression and is
not yet observed.

## Source-backed API review (2026-09-18)

Both test files were re-read against the production declarations; no
constructor-label, access-level or Swift 6 isolation error was found, so no
implementation-mirror change was needed:

- `LocalServiceTool.Arguments(runtime:entry:arguments:cwd:port:)`,
  `BackgroundJob(...)`, `BackgroundJobStore(database:)`,
  `BackgroundJobService(store:registry:)`, `ToolRunnerRegistry()`,
  `NodeRunRequest(...)`, `ScriptExecutionRequest(...)`,
  `PythonExecutionContext(...)`, `ShellRunRequest(...)` and
  `ToolEnvironment(...)` all match their synthesized/declared initializers.
- `FloePlatformServices`, `BrowserURLPolicy`, `IOSSystemNodeRuntime` and
  `CPythonLocalRuntime` members used by the tests are `internal`/`@testable`
  reachable; `FloeNodeHasActiveTask` comes from the app bridging header, which
  the already-green `LocalShellRuntimeTests` proves is visible to the
  `FloeAppTests` bundle.
- Cleanup on failure was hardened: `cleanup(_:)` now stops the environment's
  owned Node/Python services before deleting it, so a failure before the
  restarted job reaches a terminal state cannot leak a native worker into
  later tests.

## Cloud runbook (to be run by the primary agent)

1. Regenerate and commit the Xcode project after the `project.yml` edit above
   (`bash FloeAgent/scripts/gen_project.sh`).
2. Build and run the app-hosted unit bundle, e.g. on the accepted-SDK host:

```
xcodebuild -project FloeAgent.xcodeproj -scheme FloeAgent -configuration Debug \
  -destination 'platform=iOS Simulator,name=<iPad simulator>' \
  -only-testing:FloeAppTests/LocalServiceLifecycleTests \
  -only-testing:FloeAppTests/LuaShellInstallTests test
```

3. Network must be permitted: `floe/lua` is downloaded from the HTTPS URL in the
   signed catalog and SHA-256 verified. No default Debian source is required.

Expected pass criteria:
- `restartLocalServiceServesRealHTTPForNodeAndPython` passes for node and python.
- `environmentDeletionStopsOwnedServicesAndLeavesOthersRunning` passes.
- `aptInstallRunsLuaAndRemoveDisablesIt` passes (`42`, then exit 127).

## Honest limits / unverified here

- **Executed in cloud, not locally.** No local `xcodebuild`, simulator or test
  run was performed for this record. The two lifecycle cases did execute and pass
  in the build 184 cloud App regression; the Lua install/run case executed and
  failed there. The `f908cce1` Lua repair itself has macOS focused-test evidence
  but no full-App execution yet.
- The tests require the app host to have run `AppEnvironment.live()` and injected
  `FloePlatformServices` / `ToolEnvironmentRouting` / `FloeShellCommandRegistry`.
  If that did not happen they fail loudly via `#require(..., message)`; they never
  `skip`.
- Lua execution depends on the pinned WASI artifact and `WasmKitCommandRuntime`
  being available in the built app.
- No production API gap was found for these paths; the tests add coverage without
  modifying App source. If the cloud run exposes a production defect, the minimal
  fix point must be identified separately (do not weaken these assertions).

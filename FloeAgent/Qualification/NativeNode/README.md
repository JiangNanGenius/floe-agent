# Retired qualification host (pre-Phase-2)

This host qualified the bundled nodejs-mobile runtime, which left the app in
the Phase 2 TinyEMU migration (local Node.js now runs inside each
environment's TinyEMU Linux guest). The recipe pins are archived under
`FloeAgent/ThirdParty/NativeRuntimeArchive/`; there is no current CI leg for
this host. Current guest qualification lives in `Qualification/TinyEMULinux`.

---


This small iOS App links the actual pinned NodeMobile XCFramework and production
bridge/host and Swift IOSSystemNodeRuntime adapter. The minimal FloeExecution target
compiles the production NodeExecutionService.swift contract, not the complete
execution module. It writes `Documents/node-results.json` after every case. It does not
link Floe's chat, Office or model modules. The fixture is not whole-App acceptance.

1. Run `scripts/pin_node_tools.sh` from FloeAgent and verify with `--check`.
2. Generate this project with `xcodegen generate --spec Qualification/NativeNode/project.yml`.
3. Build `FloeNodeSmoke` for a dedicated iOS Simulator and install/launch the App.
4. Read its data container using `xcrun simctl get_app_container <simulator> dev.floe.node-smoke data`.
5. Assert nine results: statuses `[0,0,0,2,0,0,3,0,0]`, exit zero for ordinary jobs,
   exact stdout, `truncated=true` only for case 2, and `workerStopped=true` throughout.

The cases exercise environment, stream stdin, output bounds, CPU timeout, repeat
execution, synchronous fd 0 input, running cancellation, execution after cancel,
and relative filesystem access without changing the App process cwd.
`node-adapter-results.json` must contain four successful adapter checks plus
`passed=true`: stdin, invalid output limit, timeout, and running cancellation.
A test result is valid only for its recorded bridge/host revision and platform.

The adapter record also checks live native stdin without EOF, cancellation of a synchronous input reader, and a real HTTPS request with an authorized TLS socket. `passed` must include all adapter checks.

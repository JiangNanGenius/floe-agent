# Native Node qualification

This small iOS App links the actual pinned NodeMobile XCFramework and production
bridge/host. It writes `Documents/node-results.json` after every case. It does not
link Floe's chat, Office or model modules. The fixture is not whole-App acceptance.

1. Run `scripts/pin_node_tools.sh` from FloeAgent and verify with `--check`.
2. Generate this project with `xcodegen generate --spec Qualification/NativeNode/project.yml`.
3. Build `FloeNodeSmoke` for a dedicated iOS Simulator and install/launch the App.
4. Read its data container using `xcrun simctl get_app_container <simulator> dev.floe.node-smoke data`.
5. Assert eight results: statuses `[0,0,0,2,0,0,3,0]`, exit zero for ordinary jobs,
   exact stdout, `truncated=true` only for case 2, and `workerStopped=true` throughout.

The cases exercise environment, stream stdin, output bounds, CPU timeout, repeat
execution, synchronous fd 0 input, running cancellation and execution after cancel.
A test result is valid only for its recorded bridge/host revision and platform.

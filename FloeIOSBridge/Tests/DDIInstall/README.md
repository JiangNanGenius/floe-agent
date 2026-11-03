# Native DDI boundary checks

`bash FloeIOSBridge/scripts/build_idevice.sh` verifies pinned original input and
all patched source digests, runs native Rust tests from the same patch, builds
the actual arm64 iOS static library, and verifies the generated ABI/header.
`--check` only reads the recipe/patch hashes and never fetches or rewrites a lock.

The native tests exercise pending async stages, a shared absolute deadline,
cancellation while pending, future destruction before callback context release,
callback fencing, and exclusive operation ownership across OS threads. They use
synthetic transport; they do not establish device mount or reboot recovery.

The normal worker scopes tunnel connection, service prechecks, asset load,
cryptex/personalized mutation and service postchecks under one native 180-second
budget. Native errors include codes only and Rust tracing is compiled out.
Read-only reconciliation after an interrupted mutation gets a separate maximum
15 seconds. A protected marker under Application Support/Bridge/DDIRecovery prevents an uncertain install from being retried. It survives asset replacement/cache deletion; legacy asset markers are migrated conservatively.

Run `verify_swift.sh` for Swift 6 object compilation of the changed manager and
its actual BridgeCore, using test-only declarations for unchanged host services.
This compiles against the generated native header without building the App. `verify_recovery_marker.sh` exercises legacy marker migration, asset replacement, cache deletion and service reconstruction using the actual recovery-state code.

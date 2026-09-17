# Floe runtime patch record

Upstream: https://github.com/swiftwasm/WasmKit/tree/0.3.1
Revision: 0.3.1 tag (wasmkit-0.3.1.tar.gz sha256 bdde81dccfedb18cfbaca91ae20c04adbdbfe8cbdc0c13652b9e2201f0870f48). License: MIT.

- Runtime-only package excludes the CLI, debugger, component-model and tooling targets.
- Token interpreter checks a caller-supplied execution budget every 1024 instructions,
  including loops that never call WASI. Floe always selects token dispatch.
- The WASI descriptor table admits at most 256 guest-owned entries.

0.3.1 already carries the earlier Floe semantics upstream: POSIX stat values use
`.init()`, host stdio descriptors are always borrowed (a guest close cannot close
the host's handles), and the bridge closes remaining owned descriptors on `close()`.
Floe's runtime now calls `WASIBridgeToHost.close()` explicitly; the upstream deinit
precondition traps otherwise.

Keep these changes explicit when updating upstream. Tests must cover pure loops,
stdin/stdout, resource limits, descriptor cleanup and preopen confinement.

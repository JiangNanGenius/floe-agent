# Floe runtime patch record

Upstream: https://github.com/swiftwasm/WasmKit/tree/0.2.2
Revision: 5c389084423c08136040ab8a41f73d4e76fb7b21. License: MIT.

- SystemExtras initializes POSIX stat values with `.init()` to avoid Swift System 1.8 method-name ambiguity.
- Runtime-only package excludes the CLI, debugger and tooling dependencies.
- Token interpreter checks a caller-supplied execution budget every 1024 instructions,
  including loops that never call WASI. Floe always selects token dispatch.
- WASI optionally borrows host stdio; guest close cannot close the host's handles.
- WASI tears down remaining descriptors on destruction and caps open files at 256.

Keep these changes explicit when updating upstream. Tests must cover pure loops,
stdin/stdout, resource limits, descriptor cleanup and preopen confinement.

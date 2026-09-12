# Floe 1.7 Node runtime

The App starts NodeMobile once per process. A permanent host serializes tasks into
worker threads and only reports completion after the worker exits. Cancellation
terminates the worker, awaits exit, then releases its environment ownership. If
native code prevents termination, the bridge retains ownership and rejects another
job until termination is observed; it never frees live runtime memory or sends a
process-terminating signal.

Job input supports both streamed `process.stdin` and synchronous fd 0 reads. Unread
stdin does not keep a finished worker alive. Output is drained continuously and
retained under a shared byte limit with an explicit truncation flag. Worker environment
maps, argv, and cwd are supplied from the execution context. The host restores cwd
when the worker exits. This remains dependency/data layering, not a security sandbox.
Cross-runtime concurrency involving process-wide cwd still requires qualification.

## Reproducible inputs

- NodeMobile 18.20.4, ABI 108: official iOS XCFramework, pinned SHA-256 in
  `FloeAgent/scripts/node_tools.lock.json`. The publisher does not provide a separate
  digest for this release asset; the reviewed HTTPS download digest is committed.
- npm 10.9.2, pnpm 9.15.9, yarn 1.22.22: official registry archives were checked
  against registry SHA-512 integrity values, then pinned by SHA-256.
- The original Node license is bundled and hash checked; tool archives retain licenses.
- `scripts/pin_node_tools.sh` installs from these inputs. `--check` verifies archive
  digests and extracted file contents without fetching, extracting or rewriting the lock.
- Standard App bootstrap installs/verifies the same inputs for CI and distribution.

Upstream: https://github.com/nodejs-mobile/nodejs-mobile/releases/tag/v18.20.4
Worker API: https://github.com/nodejs/node/blob/v18.20.4/doc/api/worker_threads.md
Platform limitations: https://nodejs-mobile.github.io/docs/api/differences/

## Evidence and open gates

- `node --test FloeAgent/scripts/tests/node_host.test.cjs`: four host tests exercise
  repeated tasks, cwd/env/stdin, output limits, exit codes, cancellation/timeout and
  all three pinned package-manager version commands on the macOS host.
- `FloeAgent/Qualification/NativeNode`: nine bridge cases and four Swift adapter checks passed against the actual
  NodeMobile framework on iOS Simulator. Results are in
  `docs/evidence/floe-1.7/native-node-adapter.json`. The worker lifetime assertions
  are recorded with each result.
- `FloeExecution` compiles locally using Xcode 27 beta.
- Outstanding: full App linkage, true-device resource profiling, interactive shell
  stdin forwarding, package installation/upgrade scenarios, cross-runtime cwd
  concurrency and complete environment deletion integration.

The runner supports script files, `-e`, `-p` and `--version`; other command-line
switches fail explicitly. Worker APIs differ from main-thread Node (notably
`process.chdir`). Linux executables, child_process and unverified native extensions
are not implied to work. A package manager printing its version is not installation
or package compatibility acceptance.


## Per-worker current directory qualification

The host no longer calls process.chdir for a job. A worker-local shim resolves common fs and fs.promises relative paths against the job directory, including streams, Buffer paths and file URLs. Native NodeMobile qualification passed 9 cases; every case kept the app process cwd unchanged and left no active worker. Four host tests passed, including filesystem operations and pinned package-manager startup.

This is path routing, not native-code isolation. Child workers and relative filesystem calls inside native addons still require qualification. Dynamic import from the current `node -e` VM path is not implemented; file entry points support it.

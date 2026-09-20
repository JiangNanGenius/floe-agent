# Phase 2 — TinyEMU engine / Linux backend (engine worker)

Date: 2026-09-21. Owner: engine worker (`codex/tinyemu-phase2-engine`,
base 46422286). Scope (re-scoped 2026-09-21 after coordinator split):
`Sources/FloeExecution/Linux/LinuxGuestCommandChannel.swift`,
`TinyEMUGuestRuntime.swift`, `LinuxGuest/runner` + host Swift/runtime checks,
channel-focused tests, this doc.

The vendored engine (`ThirdParty/TinyEMU`) and native Qualification hosts are
owned by the adapter worker (landed as `ead56b95`, integrated
`138fd5af`): per-VM slirp, cross-thread reentrancy and containment are that
worker's contract and their tests are not repeated here. The persistent-disk
runner upgrade in `LinuxGuestRegistry.swift`, `LinuxGuestRuntimeImage.swift`,
`LinuxGuestService.swift` and `LinuxGuestImageStore.swift` (verified
`runnerArtifact`, compatible origin metadata, live HELLO verification) is
owned by helper job-`f036006c7339406c` in `../tinyemu-phase2-upgrade`; those
four files stay uncommitted in this worktree and the engine worker did not
edit them.

## Cross-worker interface (for the upgrade helper / component release)

### Guest protocol v3 (framing backward compatible, negotiated)

The runner (`LinuxGuest/runner/floe_exec.c`) executes **multiple commands and
PTY sessions concurrently**, routed by token:

- `EXEC <token>`: up to `MAX_CONCURRENT_COMMANDS = 8` commands run in
  parallel, each with its own pipes, cwd, process group and cancellation
  state. A full table answers END 125 "command table full".
- `OPEN <token>`: up to `MAX_CONCURRENT_SESSIONS = 4` independent PTY
  sessions, each with its own master fd, session leader, process group and
  `FLOE-IN`/`SIGNAL`/`CLOSE` routing. A full table answers OUT + reason +
  END 125.
- **Section labelling**: the runner keeps one global console section owner
  and re-announces `OUT <token>` / `ERR <token>` whenever another token wrote
  since the last frame. Without this, interleaved command output was
  misrouted (host check: "A stdout empty / B leaked A output").
- Targeted cancellation: `FLOE-SIGNAL <token> INT|TERM|KILL|WINCH [rows]
  [cols]`. The requested signal is sent first (INT by default), then TERM
  after 750 ms, then SIGKILL, and END is emitted **only after the process
  group is really reaped**. A child that survives SIGKILL past the 5 s hard
  deadline is quarantined: `FLOE-FAILED <token> unreaped`, never END.
- `HELLO`/`CAPS`: `FLOE-CAPS <token> runner=<semver> protocol=3
  maxCommands=8 maxSessions=4` + END before any other frame.
- `SPAWN/KILL/ALIVE` control frames are accepted while commands/sessions run.

### Host Swift API (`LinuxGuestCommandChannel`, all additive/internal)

- `send(_ frames:)` serializes whole frame groups through one console writer,
  so concurrent tokens can never interleave a frame (or chunked payload
  group) mid-stream.
- `probeCapabilities(timeout:requireCurrentProtocol:)` is bounded by a
  monotonic deadline and wakes its own token stream on timeout: a silent
  legacy runner fails closed with `runnerUpgradeRequired` instead of hanging
  the channel. A transport stream that closes during the probe throws
  `consoleUnavailable` (never "old runner").
- Concurrent `run()` calls share one HELLO probe (`negotiationTask`) and the
  channel starts exactly one transport reader (`routerStarting` guard). Two
  iterators on the transport's `AsyncStream` are a split-frame bug; the
  primary confirmed empirically that cancelling a for-await reader
  terminates the stream permanently (`Local/Private/stream-handoff-check`).
- **Runner-upgrade seam (single reader, no stream replacement)**:
  `enterLegacySerialMode()` (idle-only), `leaveLegacySerialMode()`,
  `resetRouterState()`. The upgrade helper must NOT create a second channel
  over the same transport. Flow: probe → `enterLegacySerialMode()` →
  upload/install with the same channel (legacy one-exchange-at-a-time) →
  `handle.stop()`/`start()` (the machine's stop does not finish the console
  stream) → `resetRouterState()` → `leaveLegacySerialMode()` → HELLO again on
  the same reader.
- `LinuxGuestInteractiveSession` now sends through the channel's serialized
  writer instead of holding the transport directly.
- `SessionParser` accepts BEGIN as the session opener (an output-less session
  no longer hangs) and strips re-announced OUT markers instead of delivering
  their bytes as terminal output.
- Router frame validation: only `BEGIN/OUT/ERR/END/FAILED/PID/CAPS` with a
  printable token (≤96 bytes) are consumed as frames; raw 0x1e bytes, leading
  newlines and `\x1eFLOE-UNKNOWN …` sequences are preserved byte-for-byte.
- Cancellation keeps the token registered after sending INT and surfaces
  `timedOut`/`cancelled` only after END (reap proof) or FAILED (quarantine);
  silence past the stop-recovery window (`interruptGrace + 8`, minimum 1 s)
  poisons the channel with `consoleUnavailable`, never "stopped".

### Swift runtime (`TinyEMUGuestRuntime.swift`)

- `write()` delivers the whole frame or throws: the engine's 64 KiB input ring
  accepts a prefix and returns the count, so the runtime retries under a
  bounded deadline (`consoleInputDeadline`, 30 s) rather than truncating a
  frame; a permanently full ring fails with `consoleUnavailable`.
- The VM pointer is used under the same lock that `finishStop()` takes, so
  `stop()` can never destroy a VM between pointer read and console/forward
  call.
- `waitForRunLoopExit` is a cancellation-aware monotonic poll: a stop timeout
  leaves the VM retained and reports `isRunning == true`; it can no longer
  hang on a checked continuation or spin after cancellation.
- `start()` resets `exited`, so a restart followed by stop cannot observe the
  previous run's exit flag and destroy a live VM.

### Guest image / runner component need

Only `/usr/local/bin/floe-exec` changes; no rootfs rebuild:

1. `make -C FloeAgent/LinuxGuest/runner riscv64` (pinned
   `riscv64-linux-gnu-gcc`, `-static`; toolchain pin per
   `LinuxGuest/image/README.md`).
2. `sudo bash FloeAgent/LinuxGuest/image/install-into-image.sh --image
   <existing verified rootfs.ext4> --runner <new floe-exec-riscv64>` replaces
   the single file and re-hashes; existing environment disks are upgraded
   in-guest by the helper's registry path (no disk wipe).
3. `LinuxGuest/image/write-image-manifest.py` emits the new manifest entry
   with `runnerVersion`, runner source SHA and binary SHA-256; kernel
   4.15/bbl bytes and package bytes are reused unchanged.
4. The host requires protocol ≥ 3 (bounded HELLO/CAPS), so shipping the host
   without the new runner fails closed with `runnerUpgradeRequired`.

## Implemented (this worker)

- Runner: concurrent commands/PTY sessions, global section labelling, targeted
  signals with INT→TERM→KILL escalation, reap-before-END, `FAILED` quarantine,
  session-shaped OPEN failures, per-token assembly tables. **Committed as
  `f8f93dcd`** (runner source only) for the cloud component build.
- Channel: protocol-3 negotiation (bounded, fail-closed), token router with
  raw-byte preservation and known-frame validation, per-token bounded
  streams, serialized whole-group console writes, single reader, session
  parser fixes, truthful cancellation/quarantine states.
- Runtime: full-delivery console writes, locked VM pointer use, bounded
  cancellation-aware stop, lifecycle reset on restart.
- Checks: runner real-stdio harness expanded; new production-channel
  transport/router harness; new runtime lifecycle harness against a stub
  engine (real `TinyEMUGuestRuntime.swift` compiled unchanged).

## Verification evidence

Commands and actual results on 2026-09-21 (macOS arm64, host `cc` + Apple
Swift 6.4):

- `bash FloeAgent/LinuxGuest/tests/host_protocol_check.sh`
  - runner real-stdio checks: **113/113 passed** (argv/stdin/cwd, binary and
    marker bytes, large output, cancellation, chunked EXEC, PTY sessions,
    SPAWN/ALIVE/KILL, HELLO/CAPS, concurrent commands, concurrent output
    isolation, concurrent PTY sessions, targeted cancel, fragmented frames,
    quarantine ordering, control responsiveness).
  - strict `swiftc -swift-version 6 -typecheck` of the extracted production
    channel module: **clean**.
  - production transport/router harness: **18/18 passed** (negotiation,
    bounded silent-runner probe, raw RS/LF preservation, unknown-sequence
    preservation, interleaved tokens, timeout + late FAILED, confirmed-reap
    timeout/cancellation, bounded quarantine, control exchanges, sessions
    incl. output-less and OPEN-failure shapes, chunked-group contiguity,
    single-reader legacy mode switch).
  - runtime lifecycle harness (stub engine + real `TinyEMUGuestRuntime.swift`,
    Swift 6): **5/5 passed** (start/stop/restart truthfulness, bounded stop
    timeout without destroy-while-slicing, post-stop errors, partial input
    acceptance with no truncation + truthful full-ring failure, poweroff).
- `swiftc -parse FloeAgent/Tests/FloeExecutionTests/LinuxGuestBackendTests.swift`
  clean; the new channel XCTest cases were not executed locally (SwiftPM
  XCTest needs the package build that this worktree deliberately avoids).
- Evidence retained under `Local/Private/guest-check/` (harness log,
  `floe-exec` binaries, probes) and `Local/Private/floe-dbg-evidence/`
  (original raw runner probe showing the pre-fix misrouting).

## Limitations / integration notes

- The new XCTest cases (channel router, session markers, legacy mode switch,
  concurrent negotiation) are cloud-pending: they compile in the package test
  target but were not run here (no SwiftPM build in this worktree). The
  standalone harnesses above execute the same production code paths locally.
- Full App compile/SIL and real guest-image boot are the cloud/integration
  gates. The stub-engine lifecycle checks prove lifecycle logic, not a
  riscv64 boot.
- `LinuxGuestRegistry.swift`, `LinuxGuestRuntimeImage.swift`,
  `LinuxGuestService.swift` and `LinuxGuestImageStore.swift` contain
  uncommitted helper-owned work and were not committed here. The
  `LinuxGuestLimits` fields already added there (`maxConcurrentCommands`,
  `maxConcurrentSessions`, `runnerUpgradeRequired`) are used by this channel;
  the helper's commit must land with or before the channel commit.
- `FloeAgent/Package.resolved` drift was restored to HEAD before committing.
- Wire escape constraint: in-band framing means command output that contains
  a byte-exact `\x1eFLOE-<known name> <valid token>\x1e` sequence is
  interpreted as that frame; every other byte is preserved.

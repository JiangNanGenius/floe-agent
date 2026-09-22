# Floe Local Shell Substrate — Architecture

Status: 1.7 current. TinyEMU/Linux is the primary local runtime (see
[Linux backend](FLOE_LINUX_GUEST_BACKEND.md) and [Build 219 notes](RELEASE_NOTES_1.7.0_BUILD_219.md));
the native `ios_system` substrate described below remains as the explicit
compatibility backend for environments set to **Native**. Physical-device
acceptance remains with the user.

> Implementation audit 2026-09-12: the mini-root filesystem-isolation claim below
> is not established by the pinned ios_system binaries. Treat security/concurrency
> statements as requirements, not verified behavior. See PLAN_LOCAL_SHELL.md
> implementation checkpoint for the blocking decision and current evidence.
Audience: maintainers. This document is the authority for the local shell,
terminal and package surfaces; it supersedes the earlier statements in
`PRODUCT.md`, `DEVELOPMENT_PLAN.md` and `SECURITY.md` that the app offers no
local command environment.

## 1.7 integration status and boundary

The shell substrate is integrated with explicit workspace/conversation environment ownership. Environment layers do not isolate same-process native execution. Path checks on App file operations and per-tool permission decisions remain necessary; a mini-root or changed working directory is not an OS-level containment boundary.

In a Linux-backend environment the shell itself runs inside the guest, and every Linux-required entry point (shell, guest Python, Node/npm, apt/dpkg, background services, language packages) runs the same shared, cancellable prepare/download/verify/install/start flow before resuming the original command. The native simulator host below passes 26 command cases and interactive input, covering scope, literal argument transport, exports, pipelines, bounded output, cancellation and worker shutdown. It uses callback fixtures for runtime dispatch. The App no longer bundles an in-process CPython or NodeMobile runtime, so those older integration entries are historical; dash routes expanded argv through literal delimiters before `ios_execve`, and compound or builtin pipeline consumers that cannot run safely fail explicitly. Signed WASI commands install from the verified catalog and run in the WasmKit sandbox. Apt candidate entries and model catalog entries are not automatically usable: see [compatibility](FLOE_1_7_COMPATIBILITY.md).

## 1. What this adds

| Surface | Tool / command | Mode |
|---|---|---|
| One-shot commands | `exec.shell` | pipelines, redirections, globs, scripts; ≤120 s (600 s under `jobs.submit`) |
| Interactive sessions | `shell.open` / `shell.exchange` / `shell.close` / `shell.signal` | long-lived stdin/stdout, ≤4 sessions, 30 idle minutes |
| Background | `jobs.submit` targeting `exec.shell` | durable job record, completion steer + notification |
| Packages | `apt` tool + `pkg` / `apt-get` / `dpkg -l` in the shell | catalog query in-shell; installs always through the reviewed `apt` tool |
| Human terminal | SwiftTerm `LocalTerminalView` owner (M3 follow-up) | same session backend as `shell.*` |

The shell is deliberately separate from the other substrates: guest Python
(`exec.localPython`, inside the task environment's TinyEMU Linux guest since
Phase 2), the remote Executor (`ssh.execute`) and the remote interactive
Terminal (`ssh.shell*`). None of them is a prerequisite for another. In a
Linux-backend environment the shell itself runs inside the same guest; the
native ios_system substrate remains as the explicit compatibility backend.

## 2. Layering

```
Agent tools:  exec.shell   shell.*   apt            jobs.submit(exec.shell)
                  │           │        │
                  ▼           ▼        ▼
        LocalShellService  ShellSessionCenter   CapabilityInstaller
                  │           │                    ├─ T1/T2 pure Python (managed pip, reviewed)
                  └─────┬─────┘                    ├─ pkg WASM commands (WasmKit + WASI)
                        ▼                          └─ dpkg data payloads (ar/tar, ELF rejected)
        LocalShellBackend (protocol, FloeExecution)
                        ▼
        IOSSystemShellBackend (app target) → FloeShellBridge (Obj-C++)
                        ▼
        ios_system command bus (BSD-3): sh/dash + files/text/shell/tar/awk
        + Floe replacement commands (python3, ping, traceroute, dig, nc,
          sha256sum, apt/pkg/dpkg) registered via replaceCommand
```

`LocalShellBackend` is a value-typed protocol so the package never links
iOS-only binary frameworks and tests can inject fakes. The app injects
`IOSSystemShellBackend`. Production builds require the pinned native frameworks; missing linkage fails the build. Runtime availability failures remain explicit.

### 2.1 One-shot execution

`FloeShellRunCommand` serializes one-shot runs, binds thread-local output to
continuously drained pipes with a shared output cap, and runs ios_system on a
worker thread. Cancellation and deadlines set a per-session flag. Floe's dash
checks it on the interpreter thread and exits with 130; the caller receives the
cancelled or timed-out outcome. The bridge does not invoke a process-global
signal handler on the calling Swift executor.

Output drain is bounded: after the command's own write ends close, each pipe
reader stops at EOF, at a short quiet window, or at a hard deadline. A
descendant or detached engine thread that inherited the pipe write end can no
longer block finalization or turn a completed command into a fabricated
timeout; the bytes captured before the deadline are still returned.

A blocking native command without a cooperative checkpoint can outlive the
caller's deadline and the bounded cancellation grace. The bridge then
quarantines the run: it detaches the worker, stops its output readers at the
bounded reclaim deadline and returns the timeout/cancel outcome with the bytes
already captured, but it deliberately does NOT release the process-wide run
gate, because that worker may still be executing inside ios_system and may
still mutate process-global state (working directory, environment, mini root,
session registries). The gate is released exactly once by the quarantined
worker's own teardown after ios_system has returned: a later command only
enters the engine after the old worker is proven stopped, and until then new
commands report not-started (exit 75) with quarantine diagnostics — never a
fabricated timeout, and never two concurrent engine users. The quarantined
worker keeps its own engine session, thread-local streams and pipes, and its
active-worker record stays retained until it finishes, so environment deletion
still refuses while native work remains. This is lifecycle scoping, not strong
isolation of native code; a native command that truly never stops leaves the
local shell quarantined (busy) until it returns or the app restarts.

### 2.2 Interactive sessions

`FloeShellOpenSession` creates two pipes and runs the program on an NSThread
with thread-local stdio bound to them. Interactive sessions are engine users
exactly like one-shot runs: opening a session acquires the same process-wide
run gate (bounded, cancellation-aware; a `Busy` open is rejected with gate
diagnostics instead of entering the engine alongside another worker) and the
gate is released exactly once by the session thread's own teardown after its
engine call has returned. A live session therefore serializes with one-shot
commands both ways; a session whose program never returns keeps the gate
quarantined just like a non-cooperative one-shot worker.

The pipes are not a PTY: there is no line discipline. `shell.exchange` writes
input bytes as-is (a line-oriented program executes a command only once it
ends with `\n`); an input of exactly `\u{3}` is routed to cooperative
interruption (SIGINT semantics) and exactly `\u{4}` closes the session's
stdin write end so the program observes a real EOF. `shell.exchange` reports
`alive`, `exitCode` and the cumulative byte counters so "the program wrote
nothing" stays distinguishable from "output was drained". `shell.signal`
requests cooperative cancellation for the selected session. Closing a session
also closes its owned pipes; no process-terminating signal is sent. The
session registry lives in `ShellSessionCenter` (run-scoped ownership) and
expires through the shared `SessionExpiryScheduler`.

Interactive exchange input is never re-screened by `ShellCommandPolicy`:
it is user keystrokes on an already-approved session, and per-keystroke
filtering breaks ordinary typing. The policy boundary stays on the session's
opening command and on one-shot `exec.shell` runs.

### 2.3 Replacement commands

The bridge registers `floe_shell_command_main` under Floe-managed names with
`replaceCommand`. The single C entry point dispatches on `argv[0]` to Swift
handlers (`FloeShellCommandRegistry`), which call the same backing services
as the agent tools:

| Command | Backend |
|---|---|
| `python3` (`-c`, file) | the task environment's Linux guest Python (`LocalPythonService` guest route) |
| `sha256sum` | `FloeDigest` |
| `ping`, `traceroute`, `dig`/`nslookup`/`host`, `nc` | device network tools (`NetworkPingTool`, `NetworkTracerouteTool`, `NetworkDNSLookupTool`, `NetworkTCPProbeTool`) |
| `apt`/`apt-get`/`pkg`, `dpkg -l` | Inside a Linux environment: routed to the guest's real Debian apt/dpkg. In a native environment: `CapabilityInstaller` catalog query; installs return a structured hint to the catalog tool |
| `git` | honest error pointing at `git.*` (libgit2) or a remote host |
| `curl` | upstream `curl_ios` framework (per-command approval already applies) |

## 3. Package management

### 3.1 Catalog

`FloeAgent/Sources/FloeExecution/Resources/CapabilityCatalog.json` is the
single manifest. Kinds: `pythonPackage`, `skill`, `font`, `model`,
`debData`, `wasmCommand`. Tiers: `bundled` (ships in the app), `managed`
(reviewed download), `wheelhouse` (retired iOS wheelhouse), `deb`
(data-only), `wasm` (sandboxed command). Since Phase 2 every Python package
entry is `managed` and installs through the environment's guest pip; nothing
Python, Node or Ruby is bundled in the app.

In a Linux environment, larger packages including `lxml`-dependent ones install
from the guest's configured index through the shared venv; the retired in-process
`Application Support/FloeAgent/PythonPackages` path is no longer used there.

### 3.2 Installation rules (capability surface)

- Audited skill installs remain pure Python only: `--only-binary=:all:
  --platform=any --implementation=py --abi=none`, staged, with native
  artifacts rejected after install and by the wheel inspector. Environment
  package pages, `pip` and `exec.localPython` package requests use the Linux
  guest's own pip and venv instead.
- `apt install/remove/download` and `exec.localPython` package requests and
  `exec.shell` package requests all route to the package-review backend
  (`ApprovalPolicy.isSoftwareInstallRequest`). Nothing downloads silently.
- Data-only `.deb`: `dpkg -x` runs `DebDataInstaller`, which parses `ar`,
  rejects any member whose payload starts with ELF/Mach-O magic, skips
  symlinks/hardlinks/devices and caps entries/expanded bytes. No maintainer
  scripts, no dpkg database mutation.
- WASM command packages install from the signed catalog only and run in a
  WASI sandbox with no sockets (workspace + `/tmp` preopens). The runtime is
  WasmKit; without the dependency the pkg path reports unavailability.

## 4. Security model

Hard boundaries (unchanged by design):

- Every shell tool is approval-gated (`exec.shell`, `shell.*`, `apt`); none is
  deterministically exempt.
- `CatastrophicActionGate` + `ShellCommandPolicy` patterns (curl-pipe-to-sh,
  sudo, power commands, raw device writes, force-push) stop high-confidence
  forms before execution.
- Mini-root confinement to the task workspace; absolute paths and `..` are
  rejected by validation and re-checked in handlers.
- Network egress for Floe implementations stays on `HTTPRequestService`
  (public HTTPS, redirect re-validation, size caps). WASM has no sockets.
- No native ELF execution, no fork/exec, no daemons; `sudo` is unavailable.
- Output caps (256 KiB), timeouts, session caps, ring buffers and the
  `shell-journal.jsonl` audit trail.

Explicitly relaxed (approved):

- External commands may read any file inside the mini-root, including
  dotfiles that the workspace path guard would classify as secret. The
  approval card discloses that the command is a full shell command.
- Per-command risk labels collapse into the tool-level risk set.
- Interactive sessions may run `less`/`ed`-style programs (never daemons).
- WASM command packages from the signed catalog are downloadable executables
  behind an interpreter sandbox.

App Review position: only the App Store command set is embedded
(`sideLoading = false`; `chown/chgrp/df/id/w` stay out), no JIT entitlement is
required (WasmKit is an interpreter; `curl_ios` uses the normal TLS stack),
and every download path is approval-gated with provenance review. The
a-Shell precedent (ios_system, BSD-3, on the App Store since 2020) is the
closest prior art; the Floe-specific delta is the stricter review pipeline.

## 5. Linux fidelity and honest limits

- Shell dialect is POSIX `sh` (dash/libshell). bash/zsh are not shipped
  (GPLv3 / size); bashisms are documented as unsupported.
- File/text commands come from the BSD userland: `sed -i` needs a backup
  suffix, `ls`/`grep`/`date` flags may differ from GNU. Agent tools remain
  available when exact GNU behavior matters.
- `sudo`, native binaries, process control (`ps`/`top`/`kill` namespaces),
  device nodes and `/proc` do not exist. `traceroute`/`ping` are real device
  ICMP (unprivileged datagram sockets), not root-based utilities.
- `python3 -m pip` inside the shell of a Linux environment is the guest's
  real pip against the environment's configured index; native-backend shells
  have no Python.
- `$HOME`, `$TMPDIR` and `PATH` point at Floe-owned directories
  (`ShellHome`, `ShellTmp`, `Packages/bin`) in the native backend, and at the
  guest's environment layer in the Linux backend.

### 5.1 Linux guest disk, cache and install state

- Each Linux environment owns a raw ext4 disk cloned from the compact
  verified base image (APFS copy-on-write `clonefile` when the volume
  supports it, otherwise a byte copy). The container is grown **sparsely and
  grow-only** to a logical 8 GiB (`LinuxGuestDiskLayout`); the host file
  keeps the base image's physical footprint until the guest writes into the
  new blocks. On the next boot the guest runs an online, idempotent
  `resize2fs` to extend the filesystem. Older, smaller disks are migrated in
  place — never replaced — and the origin sidecar records schema
  (v1→v2) and capacity provenance. A failed grow/resize is surfaced as a
  repair state while the guest stays usable at its previous capacity.
- Temp and package caches are routed into the persistent environment write
  layer instead of the compact RAM-backed root partition: `TMPDIR`/`TMP`/
  `TEMP` → `/floe/env/tmp` (01777), `PIP_CACHE_DIR` → `/floe/env/cache/pip`,
  `XDG_CACHE_HOME` → `/floe/env/cache/xdg`, `npm_config_cache` →
  `/floe/env/cache/npm`. This keeps a pip source build without a riscv64
  wheel (e.g. Pillow) from filling the root partition. The runner creates
  the directories at boot and falls back to `/tmp` only when the share is
  missing or unwritable. The Swift authority is `LinuxGuestWritablePaths`.
- One authoritative install/environment state (`LinuxGuestInstallState`
  derived by `LinuxGuestInstallStateDerivation` from verified image, disk
  migration and live runtime facts) drives both Settings and the terminal
  card. A verified installed or running guest can never render the
  "download and start" card; phases are download (with progress/cancel),
  installed-stopped, running, repair and update. First Linux use
  (shell/Python/services/apt/npm) runs the shared, cancellable preparation
  job automatically — concurrent callers share one download, both at the
  service (`installTrustedImage` coalescing) and UI job (`runShared`)
  layers; the model does not have to discover `environment.prepareLinux`.
- The 9P backend propagates `unlinkat` flags and verifies target type with
  `AT_SYMLINK_NOFOLLOW`: empty directories are removable on Darwin hosts
  (whose `unlinkat(...,0)` returns EPERM), a non-empty directory is still
  `ENOTEMPTY`, and a symlink is removed as a link without touching its
  target. `Txattrwalk` answers a list request with an empty list and a
  named query with `ENODATA` instead of the upstream bogus status 524, so
  GNU `ls -l` no longer prints "Unknown error 524". Verified by
  `FloeAgent/LinuxGuest/tests/ninep_semantics_check.sh`.

> Device-validation limit: the disk grow, in-guest `resize2fs`, temp/cache
> routing and 9P behavior are unit/host-tested here but are only proven on a
> physical iPad guest by the cloud TinyEMU/Linux qualification; no on-device
> result is claimed by this change.

## 6. Third-party components

| Component | Version | License | Use |
|---|---|---|---|
| ios_system + frameworks (`files`, `text`, `shell`, `tar`, `awk`, `curl_ios`) | 3.0.4 binary targets | BSD-3-Clause; awk one-true-awk; curl MIT | command bus and BSD userland |
| `commandDictionary.plist` / `extraCommandsDictionary.plist` | upstream `master` | BSD-3-Clause | command registry resources |
| WasmKit / WasmKitWASI (future dependency) | TBD | Apache-2.0 | WASM command runtime |
| SwiftTerm (existing) | 1.10.0 | MIT | terminal rendering |

Not embedded: TeX (GPL), perl (size/licensing policy), `ssh_cmd`/scp/sftp
(Floe has its own SSH stack), GNU coreutils (GPLv3). Lua, Ruby and PHP are not
embedded runtimes: they install as signed WASM capabilities from the verified
catalog.

## 7. Verification status (historical landing record, 2026-09)

Ultra-light verification was requested for this landing:

- `xcrun swiftc -parse` on every new Swift file: pass.
- `swift build --target FloeExecution` and the affected targets
  (`FloeSkills`, `FloeDocuments`, `FloeImages`, `FloeWorkspace`,
  `FloeProviders`, `FloeAgentRuntime`): build complete.
- `plutil -lint` on both shell plists; `python3 -m json.tool` on the catalog:
  pass.
- Not yet run (explicitly deferred): full `swift test`, app-target build with
  the ios_system package, device smoke tests, TestFlight release. The bridge
  deadline/session semantics and the app wiring need a device pass before
  release; see `docs/PLAN_LOCAL_SHELL.md` §Remaining.

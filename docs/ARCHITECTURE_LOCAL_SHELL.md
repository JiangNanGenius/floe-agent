# Floe Local Shell Substrate — Architecture

Status: incomplete working-tree implementation after 1.6.6 (candidate 1.6.7 / build 143).

> Implementation audit 2026-09-12: the mini-root filesystem-isolation claim below
> is not established by the pinned ios_system binaries. Treat security/concurrency
> statements as requirements, not verified behavior. See PLAN_LOCAL_SHELL.md
> implementation checkpoint for the blocking decision and current evidence.
Audience: maintainers. This document is the authority for the local shell,
terminal and package surfaces; it supersedes the earlier statements in
`PRODUCT.md`, `DEVELOPMENT_PLAN.md` and `SECURITY.md` that the app offers no
local command environment.

## 1. What this adds

| Surface | Tool / command | Mode |
|---|---|---|
| One-shot commands | `exec.shell` | pipelines, redirections, globs, scripts; ≤120 s (600 s under `jobs.submit`) |
| Interactive sessions | `shell.open` / `shell.exchange` / `shell.close` / `shell.signal` | long-lived stdin/stdout, ≤4 sessions, 30 idle minutes |
| Background | `jobs.submit` targeting `exec.shell` | durable job record, completion steer + notification |
| Packages | `apt` tool + `pkg` / `apt-get` / `dpkg -l` in the shell | catalog query in-shell; installs always through the reviewed `apt` tool |
| Human terminal | SwiftTerm `LocalTerminalView` owner (M3 follow-up) | same session backend as `shell.*` |

The shell is deliberately separate from the three existing substrates:
bundled CPython (`exec.localPython`), the remote Executor (`ssh.execute`) and
the remote interactive Terminal (`ssh.shell*`). None of them is a prerequisite
for another.

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
`IOSSystemShellBackend`; when the frameworks are absent the tool honestly
reports `status=engineUnavailable` (exit 125) instead of pretending.

### 2.1 One-shot execution

`FloeShellRunCommand` (bridge) serializes runs with a process-wide lock,
redirects the calling thread's `thread_stdout`/`thread_stderr` to temp files,
sets the mini-root to the task workspace and runs `ios_system(command)` on a
dedicated pthread with a watchdog. A timeout sends SIGINT and reports exit
124 with partial output; the abandoned thread is documented (same boundary as
the JS engine's timeout semantics).

### 2.2 Interactive sessions

`FloeShellOpenSession` creates two pipes and runs the program on an NSThread
with thread-local stdio bound to them. `shell.exchange` writes the input pipe
and drains the output pipe non-blocking; EOF marks the session dead.
`shell.signal` maps INT/TERM/KILL to `pthread_kill`. The session registry
lives in `ShellSessionCenter` (run-scoped ownership) and expires through the
shared `SessionExpiryScheduler`.

### 2.3 Replacement commands

The bridge registers `floe_shell_command_main` under Floe-managed names with
`replaceCommand`. The single C entry point dispatches on `argv[0]` to Swift
handlers (`FloeShellCommandRegistry`), which call the same backing services
as the agent tools:

| Command | Backend |
|---|---|
| `python3` (`-c`, file) | bundled CPython (`LocalPythonService`) |
| `sha256sum` | `FloeDigest` |
| `ping`, `traceroute`, `dig`/`nslookup`/`host`, `nc` | device network tools (`NetworkPingTool`, `NetworkTracerouteTool`, `NetworkDNSLookupTool`, `NetworkTCPProbeTool`) |
| `apt`/`apt-get`/`pkg`, `dpkg -l` | `CapabilityInstaller` catalog query; installs return a structured hint to the `apt` tool |
| `git` | honest error pointing at `git.*` (libgit2) or a remote host |
| `curl` | upstream `curl_ios` framework (per-command approval already applies) |

## 3. Package management

### 3.1 Catalog

`FloeAgent/Sources/FloeExecution/Resources/CapabilityCatalog.json` is the
single manifest. Kinds: `pythonPackage`, `skill`, `font`, `model`,
`debData`, `wasmCommand`. Tiers: `bundled` (ships in the app), `managed`
(reviewed download), `wheelhouse` (build-time pinned native wheel), `deb`
(data-only), `wasm` (sandboxed command).

Preset coverage (T1) ships ~32 small pure-Python packages in the bundled
site-packages (build script: `scripts/install_python_bundled_packages.py`,
lock: `scripts/python_bundled_packages.lock.json`) so common data, text,
document and network-adjacent workflows need no download. Larger pure
packages and `lxml`-dependent packages install on demand through the
reviewed managed-pip path.

### 3.2 Installation rules (capability surface)

- Pure Python only for managed installs: `--only-binary=:all:
  --platform=any --implementation=py --abi=none`, staged and atomically
  swapped into `Application Support/FloeAgent/PythonPackages`, native
  artifacts rejected after install and by the wheel inspector.
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
- `python3 -m pip` inside the shell is blocked by the CPython audit hook;
  installation goes through `apt`.
- `$HOME`, `$TMPDIR` and `PATH` point at Floe-owned directories
  (`ShellHome`, `ShellTmp`, `Packages/bin`, `Packages/pybin`).

## 6. Third-party components

| Component | Version | License | Use |
|---|---|---|---|
| ios_system + frameworks (`files`, `text`, `shell`, `tar`, `awk`, `curl_ios`) | 3.0.4 binary targets | BSD-3-Clause; awk one-true-awk; curl MIT | command bus and BSD userland |
| `commandDictionary.plist` / `extraCommandsDictionary.plist` | upstream `master` | BSD-3-Clause | command registry resources |
| WasmKit / WasmKitWASI (future dependency) | TBD | Apache-2.0 | WASM command runtime |
| SwiftTerm (existing) | 1.10.0 | MIT | terminal rendering |

Not embedded: TeX (GPL), perl/lua (size/licensing policy), `ssh_cmd`/scp/sftp
(Floe has its own SSH stack), GNU coreutils (GPLv3).

## 7. Verification status (this change)

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

# Floe Linux guest side (runner + image startup)

This directory is the **guest half** of the Floe Linux environment backend
(TinyEMU RV64). It contains the long-lived console runner that executes
`exec.shell`, package-manager and service commands inside the guest, plus the
startup/mount material the guest image needs. The host half lives in
`Sources/FloeExecution/Linux/` and `FloeApp/Execution/LinuxGuestBackend.swift`;
the wire contract is documented in
[`docs/FLOE_LINUX_GUEST_BACKEND.md`](../../../docs/FLOE_LINUX_GUEST_BACKEND.md)
and [`docs/FLOE_LINUX_GUEST_PROTOCOL_EXTENSIONS.md`](../../../docs/FLOE_LINUX_GUEST_PROTOCOL_EXTENSIONS.md).

| Path | Purpose |
| --- | --- |
| `runner/floe_exec.c` | The guest runner: FLOE-EXEC framing, chunked envelopes, PTY sessions, background services, cancellation |
| `runner/Makefile` | Host build (`host`) and static riscv64 cross build (`riscv64`) |
| `image/floe-guest-init` | POSIX sh startup/mount script (pseudo-fs + 9p) |
| `image/install-into-image.sh` | Loop-mount injector for the whole-disk ext4 guest image (CI helper) |
| `tests/host_protocol_check.sh` + `tests/HostProtocolCheck.swift` | Real-stdio protocol check: compiles the repo's real `LinuxGuestFraming` and drives the runner through real child processes |

## Build

```sh
# Developer host / CI protocol checks:
make -C FloeAgent/LinuxGuest/runner host        # CC variable, default cc
# Guest image (GitHub ubuntu-latest: apt install gcc-riscv64-linux-gnu):
make -C FloeAgent/LinuxGuest/runner riscv64     # CROSS_CC variable, default riscv64-linux-gnu-gcc
```

Artifacts (relative to the repository root):

- `FloeAgent/LinuxGuest/runner/floe-exec` — host build, used by the check.
- `FloeAgent/LinuxGuest/runner/floe-exec-riscv64` — **static** riscv64 build
  linked with `-static`. Static is required: the pinned 2018 demo kernel
  cannot load Debian's versioned modules, and the init process must not depend
  on the guest dynamic loader.

## Install into the guest image

Target paths (confirmed with the qualification workflow):

| Host artifact | Guest path | Mode | Required |
| --- | --- | --- | --- |
| `runner/floe-exec-riscv64` | `/usr/local/bin/floe-exec` | 0755 root:root | yes |
| `image/floe-guest-init` | `/usr/local/lib/floe/floe-guest-init` | 0755 root:root | optional |

```sh
sudo bash FloeAgent/LinuxGuest/image/install-into-image.sh \
  --image <work>/debian13-rootfs.img \
  --runner FloeAgent/LinuxGuest/runner/floe-exec-riscv64 \
  --script FloeAgent/LinuxGuest/image/floe-guest-init
```

The script loop-mounts the **whole-disk ext4** image (no partition table: the
2018 kernel cannot parse GPT), installs the files, prints the sha256 of the
installed artifacts, and unmounts. `--dry-run` prints the plan and hashes
without touching the image.

## Boot

Preferred: the runner is the init process and mounts everything itself
(`init=` cannot take arguments; the runner detects PID 1):

```
console=hvc0 root=/dev/vda rw init=/usr/local/bin/floe-exec
```

Alternative: the explicit startup script does the mounts and execs the runner:

```
console=hvc0 root=/dev/vda rw init=/usr/local/lib/floe/floe-guest-init
```

On start (PID 1 path) the runner mounts `proc`, `sysfs`, `devtmpfs`,
`devpts`, `/dev/shm`, `/tmp`, `/run`, then every 9p tag the host exported
(missing tags are skipped, never fatal):

| 9p tag | Guest mount | Meaning |
| --- | --- | --- |
| `floe` | `/floe` | qualification share |
| `floe-env` | `/floe/env` | environment write layer |
| `workspace` | `/workspace` | workspace root |

Mount options match the verified form: `trans=virtio,version=9p2000.L`
(no `msize`). The runner exports `FLOE_SHARE_DIR`, `FLOE_ENV_DIR` and
`FLOE_WORKSPACE_DIR` when the mount exists, sets a default `PATH`, `HOME`,
`TMPDIR`, `LANG` and `DEBIAN_FRONTEND=noninteractive`, and uses
`/workspace` → `/floe/env` → `/root` → `/` as the default cwd when the host
sends none.

## Python / apt bootstrap (no circular dependency)

The runner is pure C and needs no interpreter. `apt-get`/`dpkg` are native
programs, so package installation works through the same runner with no
Python present. `python3` (needed by the host's localPython path) is installed
by the guest itself:

```
apt-get update && apt-get install -y python3 python3-pip
```

That requires the guest to be started with networking
(`LinuxGuestEnvironmentDescriptor.networkEnabled == true`, i.e. the engine's
slirp). The app currently starts Linux environments with
`networkEnabled: false`; enabling it is a host-side decision, and the runner
does not pretend an offline image can install packages. For offline use,
bake `python3` into the image at build time — no Python is required to
*execute* commands.

## Protocol summary

One-shot (inline `< ~3.8 kB`, else chunked):

```
host: \x1eFLOE-EXEC <token> <base64 payload>\n
      or \x1eFLOE-EXEC <token> <bytes> <chunks>\x1e\n + FLOE-CHUNK… + \x1eFLOE-RUN <token>\x1e\n
guest: BEGIN → OUT/ERR sections → \x1eFLOE-END <token> <exit>\x1e
```

`payload = u32 fieldCount + per field (u32 length + bytes)`, fields
`[cwd, stdin, argv0, argv1, …]`. argv is executed verbatim with `execvp` —
never re-parsed by a shell. The host's `exec.shell` therefore still runs the
user's command through the guest's own `/bin/sh -c`, unchanged.

- Cancellation: a raw `0x03` byte kills only the current command's process
  group (SIGTERM, then SIGKILL after 750 ms) and ends it with exit 130.
  A child that stays unkillable is abandoned after 5 s so the channel cannot
  hang; PID 1 reaps it later.
- Output: streamed per section and capped at 4 MiB per stream on the guest
  side (the host keeps at most `LinuxGuestLimits.maxOutputBytes`).
- One command or session runs at a time per guest; a second envelope gets an
  honest ERR + END 125 instead of a silent hang.

PTY sessions and background services are documented in
[`docs/FLOE_LINUX_GUEST_PROTOCOL_EXTENSIONS.md`](../../../docs/FLOE_LINUX_GUEST_PROTOCOL_EXTENSIONS.md)
(agreed with the host worker). The runner implements both:
`FLOE-OPEN`/`FLOE-IN`/`FLOE-SIGNAL`/`FLOE-CLOSE` for interactive terminals and
`FLOE-SPAWN`/`FLOE-KILL`/`FLOE-ALIVE` for detached services that append to a
9p log path. `FLOE-KILL`/`FLOE-ALIVE` only ever answer for pids this runner
spawned (bounded table of 32); unknown pids get END 3 and are never
signalled.

## Verification

```sh
bash FloeAgent/LinuxGuest/tests/host_protocol_check.sh
```

The check builds the runner for the current host, extracts the repository's
real `LinuxGuestFraming` parser/envelope, and drives the runner through real
pipes and real child processes: argv escaping (quotes, spaces, newlines,
0x1e bytes, UTF-8), stdin/cwd, stdout/stderr separation, exit codes, exec
failures, Ctrl-C cancellation with process-group escalation, channel reuse,
chunked reassembly of a >3.8 kB payload, PTY input/WINCH/close, and
SPAWN/ALIVE/KILL with a 9p-style log file. It is a host-side protocol check,
**not** image qualification: it does not boot TinyEMU and makes no claim
about riscv64 execution, apt or python3.

The image injection, static cross build and boot (`init=/usr/local/bin/floe-exec`
must reach the runner without panicking) are verified by the qualification
workflow (TinyEMU core job). Until that run passes, no part of this directory
is evidence that a modern Linux guest is usable.

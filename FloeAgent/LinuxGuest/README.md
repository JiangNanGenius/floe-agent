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
| `runner/floe_clock.h` | Bounded `/proc/cmdline` reader + strict `floe.epoch=` parser (pure; no clock side effects) |
| `runner/floe_net.h` | First-boot network plan: resolver/interfaces/git-safe-directory renderers and the `net=` status vocabulary (included into the static runner; pure native check via `check-net`, the ioctl/probe side is compiled out) |
| `runner/Makefile` | Host build (`host`), static riscv64 cross build (`riscv64`) and the pure clock/network checks (`check-clock`, `check-net`) |
| `image/floe-guest-init` | POSIX sh startup/mount script (pseudo-fs + 9p) |
| `image/install-into-image.sh` | Loop-mount injector for the whole-disk ext4 guest image (CI helper) |
| `tests/host_protocol_check.sh` + `tests/HostProtocolCheck.swift` | Real-stdio protocol check: compiles the repo's real `LinuxGuestFraming` and drives the runner through real child processes |
| `tests/clock_arg_check.c` | Native pure-function check for the `floe.epoch=` parser and the bounded cmdline reader |

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

## Image build (component CI)

`FloeAgent/LinuxGuest/image/build-guest-image.sh` builds, boot-verifies and
packages the Debian 13 candidate from the pinned inputs
(`FloeAgent/ThirdParty/TinyEMU/guest-image/pinned-inputs.json`), and
`collect-corresponding-sources.sh` assembles the kernel/bbl/runner/glibc and
per-package Debian corresponding sources. The
[`component-image-ci`](../../.github/workflows/component-image-ci.yml)
workflow runs both on `ubuntu-latest` and uploads the zip, `manifest.json`
(the `LinuxGuestImage` schema) and evidence artifacts; nothing is published.
Details, gates and honest limits: [build guide](../../../docs/FLOE_LINUX_GUEST_IMAGE_BUILD.md).

## Boot

Preferred: the runner is the init process and mounts everything itself
(`init=` cannot take arguments; the runner detects PID 1). The fallback
kernel has no RTC, so the host must also pass the boot clock; the app derives
this on every start (`LinuxGuestImage.effectiveCmdline`):

```
console=hvc0 root=/dev/vda rw init=/usr/local/bin/floe-exec floe.epoch=<unix seconds>
```

As PID 1 the runner parses that one bounded parameter (no shell, no other
keys) and sets `CLOCK_REALTIME` before accepting the first command frame; a
missing or malformed value leaves the clock unset and is reported on the
console instead of pretending to be synchronized. Non-PID-1 runs (developer
host checks) never touch the host clock.

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
sends none. After the mounts (and before serving any frame) PID 1 also applies
the host-supplied boot clock described below.

## First-boot network (device + DNS)

The guest can only configure `eth0` when the host actually attached a
virtio-net device. The adapter creates that device (and the per-VM slirp
backend) only for a VM created with `FloeVMConfig.net_enable = 1`; the App
sets it from `LinuxGuestEnvironmentDescriptor.networkEnabled`
(`FloeApp/Execution/LinuxGuestBackend.swift`), and the qualification host uses
the `floe_vm_host --net` switch. Without the switch `eth_count` stays 0,
TinyEMU registers no network device, the kernel has no `eth0`, and the runner
honestly reports `net=down` (`interface configuration failed: No such
device`) — the state of run 35645930554.

With the device present, PID 1 configures it before answering HELLO (no DHCP
client, no init system):

1. `SIOCSIFADDR`/`SIOCSIFNETMASK`/`SIOCSIFFLAGS` on `eth0` with the slirp
   defaults (`10.0.2.15/24`, gateway `10.0.2.2`), then a default route.
2. Renders `/etc/resolv.conf` (slirp's own `10.0.2.3` alias first, then four
   fixed public resolvers), `/etc/network/interfaces.d/eth0` and
   `/etc/gitconfig` from `runner/floe_net.h`.
3. Runs a bounded UDP DNS probe over that ordered list (2 s per resolver, at
   most 4 attempts) and reports the state in `FLOE-CAPS`:
   `net=up` (a resolver answered), `net=partial` (interface configured, no
   answer inside the budget) or `net=down` (interface could not be
   configured). The host never treats `partial`/`down`/missing as ready.

Why `10.0.2.3` comes first: it is slirp's name-server alias, and the pinned
engine rewrites a guest datagram sent there to the host's own first resolver
(`socket.c: sosendto` → `get_dns_addr()`), so a network that forces its own
DNS still answers. Qualification run 35500083112 proved the path end to end:
with only `nameserver 10.0.2.3` in the guest, `apt-get update`, an apt install
and an HTTPS fetch all succeeded. The public resolvers remain as fallbacks for
a host whose resolver slirp cannot read (it then falls back to loopback).

## Boot clock (`floe.epoch=`)

The pinned guest kernel has no usable RTC (`CONFIG_RTC_CLASS` is not enabled),
so without help the guest clock starts at the image build date and TLS/apt
signature checks fail. The host therefore appends one fresh parameter on every
boot (`LinuxGuestBootArguments.commandLine` in
`Sources/FloeExecution/Linux/LinuxGuestService.swift`):

```
console=hvc0 root=/dev/vda rw loglevel=4 init=/usr/local/bin/floe-exec floe.epoch=1758366000
```

- Only the guest **PID 1** applies it, and only after `guest_bring_up()` mounted
  `/proc`: `floe_exec.c` reads `/proc/cmdline` with a fixed
  `FLOE_EPOCH_CMDLINE_MAX` (4096-byte) bound and calls
  `clock_settime(CLOCK_REALTIME)`, falling back to `settimeofday`. Non-PID-1
  processes (the native host build, the protocol harness) compile the apply
  step out or skip it and never change the host clock.
- The parser (`runner/floe_clock.h`) is strict and side-effect free: exactly one
  `floe.epoch=` token anchored at a field boundary, canonical digits only
  (no `-`/`+`, no leading zeros, no trailing characters), value in
  `[0, 253402300799]` (= 9999-12-31T23:59:59Z), no wrap on long digit strings.
  A second occurrence is ambiguous and is rejected — neither value is used.
- It never runs a shell and accepts no other kernel parameter; the console
  command protocol is unchanged.
- Missing, empty, invalid, out-of-range and duplicated values (and an
  unreadable or truncated cmdline) leave the clock untouched and emit one
  bounded stderr line, e.g. `floe-exec: clock NOT set: floe.epoch missing`; a
  successful set logs `floe-exec: clock set from floe.epoch=<n>`. These
  unframed boot diagnostics are dropped by the host parser before the first
  `BEGIN`. The guest never reports a clock it did not actually set.

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
slirp). The app starts Linux environments with `networkEnabled: true`
(`AppLinuxGuestEnvironmentProvider`), so the guest has `eth0` and the resolver
path described under "First-boot network" above; the runner still reports the
actual state (`net=partial`/`down`) instead of pretending an offline image can
install packages. For offline use, bake `python3` into the image at build
time — no Python is required to *execute* commands.

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
# Boot-clock parser/reader only (fast: native compile + pure checks, no
# protocol run, no command execution and no clock change):
make -C FloeAgent/LinuxGuest/runner check-clock

# First-boot network plan (resolvers/interfaces/git config + net= vocabulary,
# pure: no ioctl, no file write, no network):
make -C FloeAgent/LinuxGuest/runner check-net

# Full host protocol suite (real runner child processes over real stdio):
bash FloeAgent/LinuxGuest/tests/host_protocol_check.sh
```

`check-net` compiles the real `floe_net.h` with the runner's `-Werror` flags
and checks the ordered resolver plan (slirp's alias first, public fallbacks
behind it), the rendered `interfaces`/`gitconfig` files, the probe bounds and
the `up`/`partial`/`down` taxonomy with unknown/missing values mapping to
`down`. The ioctl and DNS-probe side only runs in a booted guest; the component
boot check (`guest_protocol_check.py`) proves it there with a guest-side
`/sys/class/net/eth0` read and a userland resolution, and fails on
`net=down`/`net=partial`.

`check-clock` compiles the real `floe_clock.h` with the runner's `-Werror`
flags and checks a valid current epoch, zero, whitespace/token-boundary
handling, very long digit strings, negative/signed values, empty values,
duplicates, the exact upper bound, embedded near-miss keys, and the bounded
reader's truncation reporting (including a key hidden beyond the bound).

The protocol check builds the runner for the current host, extracts the repository's
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

# TinyEMU Linux qualification host

Minimal non-interactive host that drives the Floe embeddable VM API
(`ThirdParty/TinyEMU/adapter/floe_vm.h`) against a real guest and records
transcripts. This is a *qualification* tool — its success is evidence about
the engine, not full-app acceptance.

## Contents

| Path | Purpose |
| --- | --- |
| `floe_vm_host.c` | CLI host: boots a VM, feeds a timed `@sec command` script to the guest console, records a transcript, exits 0 when `--until MARKER` is observed or the guest requests poweroff |
| `run_local_smoke.sh` | end-to-end local driver: pinned fetch → GPL gate → build → boot → console/9p/network markers (~40 MB, no root) |
| `tools/pty_boot.py` | PTY harness used to drive the pristine upstream `temu` CLI for comparison evidence |
| `guest-scripts/` | timed guest command scripts |

## Local quick start

```sh
cd FloeAgent/Qualification/TinyEMULinux
./run_local_smoke.sh              # Linux host
MACOS=1 ./run_local_smoke.sh      # macOS host (build shims, console-only)
```

## Measured status (2026-09-20, host: Apple Silicon macOS, interpreter)

Observed with the embeddable API host + TinyEMU 2018 RV64 demo image
(Linux 4.15, buildroot — smoke fixture, **not** the target userland):

- Real boot to shell: yes (guest kernel boot ~0.11 s guest-time; wall ≈2–4 s
  including interpreter startup; RAM 128 MB, host RSS ≈3–4 MB at idle boot).
- Console bytes both directions via `floe_vm_console_input` + output
  callback: yes (scripted `uname`, arithmetic marker observed).
- virtio-blk root mount (ext2 via ext4 subsystem): yes.
- virtio-9p share: guest wrote `floe_smoke_9p.txt` into the host directory.
- slirp: ICMP ping to 10.0.2.2 OK; outbound TCP connect to a literal-IP
  HTTP server OK. DNS via slirp was **not** observed working with the
  busybox guest (to be re-tested with the glibc Debian guest).
- Guest `poweroff` did **not** terminate the VM with this 2018 kernel/bbl
  (returned to prompt); host-side stop used. The adapter patch makes
  HTIF poweroff observable when a guest does signal it.
- No JIT, no private APIs, no background tricks: pure interpreter loop.

Open qualification items run in cloud CI
(`.github/workflows/tinyemu-linux-qualification.yml`): Debian 13 riscv64
modern kernel vs. 2018 bbl SBI compatibility (expected blocker, recorded as
evidence), Debian 13 userland on the old kernel fallback, APT / python3 /
node / numpy, file-persistence across reboot, PTY/fork/exec/signal checks,
boot/memory/time measurements. iPad performance: **pending** — no device
measurements exist yet; never extrapolate from the above.

## Notes for app integration (phase 2B handoff)

The engine is ready to be driven by the shell/localPython backend work:
one `FloeVM` per environment, console bytes bridged to the shell UI, 9p
share per environment workspace, `run_slice` on a dedicated thread. The
shared `LocalShellBackend` (6 methods today) will still need: byte-oriented
I/O (not line-only), real signal delivery (guest `kill` via console input
is only shell-level), capability reporting, and backend/environment
routing. Those are phase 2B concerns — this task intentionally does not
change app defaults or remove existing fallbacks.

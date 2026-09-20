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

## Cloud results (2026-09-20, ubuntu-latest, raw transcripts kept as artifacts)

Honest status, including what does **not** work:

- **Modern Debian 13 (kernel 6.12.107) does not boot on the 2018 bbl.**
  Stage B produced a 0-byte console transcript (rc=2 timeout): Linux removed
  the legacy SBI v0.1 interface that bbl implements in 5.9, so the kernel
  never reaches the virtio console. A modern guest needs FDT generation +
  OpenSBI in the engine — future work, not a configuration tweak. The 2018
  demo image is a smoke fixture, **not** a complete Linux.
- **The 4.15 fallback kernel could not use the Debian GPT cloud image.**
  Stage C/D/E panicked with `VFS: Unable to mount root fs on
  unknown-block(254,1)`; the guest saw only the protective MBR and mapped
  `vda1` to the whole disk. Root cause (reproduced locally with a synthetic
  GPT that macOS accepts): the pinned 2018 buildroot kernel has no
  EFI/GPT partition parser, while the disk read path is byte-exact (guest
  `dd` md5 matched the host). Fix in the workflow: extract the ext4
  partition to a partitionless image and boot `root=/dev/vda`; D/E only run
  when Stage C shows real guest-shell evidence.
- **Lean push run (build + lifecycle + Stage A): passing.** Stage A markers
  come from real guest output (markers are assembled at runtime, so a TTY
  echo of the input line cannot fake them), and `lifecycle_test` passes
  repeatable create/destroy, hostfwd bind/remove/destroy checked by real TCP
  connects, oversized BIOS/kernel recoverable failures, and the RAM-OOM
  negative case on Linux (2 GB guest under a 1 GB `RLIMIT_AS` fails create
  cleanly through the `floe_ram_oom` path instead of exiting the host).

## Evidence rules for this qualification

Guest markers are only ever emitted by commands that build them at runtime
(`echo X_$((6*7))`, `printf 'X_%s' OK`) and `--until` uses the same form, so
`grep`/`--until` cannot match the console echo of the input line. Command
exit codes are captured from the command itself (`cmd >log 2>&1; printf
'RC=%d\n' $?`), never from the tail of a pipeline, and raw apt/dpkg logs are
exported to the host through the 9p share. Debian stages are opt-in
(`workflow_dispatch` input `run_debian`), so a push stays a few-minute check.

## Notes for app integration (phase 2B handoff)

The engine is ready to be driven by the shell/localPython backend work:
one `FloeVM` per environment, console bytes bridged to the shell UI, 9p
share per environment workspace, `run_slice` on a dedicated thread. The
shared `LocalShellBackend` (6 methods today) will still need: byte-oriented
I/O (not line-only), real signal delivery (guest `kill` via console input
is only shell-level), capability reporting, and backend/environment
routing. Those are phase 2B concerns — this task intentionally does not
change app defaults or remove existing fallbacks.

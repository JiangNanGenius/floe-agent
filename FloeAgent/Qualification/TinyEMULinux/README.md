# TinyEMU Linux qualification host

Minimal non-interactive host that drives the Floe embeddable VM API
(`ThirdParty/TinyEMU/adapter/floe_vm.h`) against a real guest and records
transcripts. This is a *qualification* tool — its success is evidence about
the engine, not full-app acceptance.

## Contents

| Path | Purpose |
| --- | --- |
| `floe_vm_host.c` | CLI host: boots a VM, feeds a timed `@sec command` script to the guest console, records a transcript, exits 0 when `--until MARKER` is observed or the guest requests poweroff. `--vcpu N` selects the hart count (0/1 = legacy single hart, 2 = dual hart on two host threads), `--stats-file` samples `FloeVMStats` as JSON lines (per-hart retired insns, host threads), and the host refuses to run when a `--until` marker appears verbatim in a scripted input line (TTY echo could otherwise fake it) |
| `smp_host_test.c` | FLOE-SMP qualification via the public adapter API: capability/config probes (`vcpu_count > max` rejected), a real dual-hart guest boot with concurrent stats sampling from a second host thread, per-hart execution proof (`host_threads=2` + hart 1 retired insns — never host `nproc`), 9p IO, repeated stop+flush destroy cycles and a single-hart control |
| `lifecycle_test.c` | repeatable create/destroy, hostfwd bind/remove/destroy, recoverable oversized-BIOS/kernel and RAM-OOM failures |
| `two_vm_test.c` | two networked VMs on two host threads (isolated slirp/forwarding/cleanup); with `<bios> <kernel> <disk>` also two concurrent real guest boots with per-VM console markers and per-VM 9p shares |
| `containment_test.c` | drives the patched `fs_disk.c` directly: `..`, `/`, symlink traversal, rename escape, file-fid children, and FIFO/device metadata-only handling (no blocking open) |
| `run_local_smoke.sh` | end-to-end local driver: pinned fetch → GPL gate → build → boot → console/9p/network markers (~40 MB, no root) |
| `tools/pty_boot.py` | PTY harness used to drive the pristine upstream `temu` CLI for comparison evidence |
| `guest-scripts/` | timed guest command scripts |

## Local quick start

```sh
cd FloeAgent/Qualification/TinyEMULinux
./run_local_smoke.sh              # Linux host
MACOS=1 ./run_local_smoke.sh      # macOS host (build shims, console-only)
```

SMP host qualification (needs the FLOE-SMP engine patches from job A):

```sh
# build (from this directory; relative paths because the workspace has spaces)
make -f ../../ThirdParty/TinyEMU/adapter/Makefile \
  TINYEMU_SRC=<tinyemu-src> PATCH_DIR=../../ThirdParty/TinyEMU/patches \
  BUILD=<build-dir> HOST_DIR=. -j4 [MACOS=1]
cc -O2 -Wall -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -D_GNU_SOURCE \
  -DCONFIG_VERSION='"2019-12-21"' -DCONFIG_SLIRP -DCONFIG_RISCV_MAX_XLEN=64 \
  -I<build-dir> -I<tinyemu-src> -I../../ThirdParty/TinyEMU/adapter \
  -c -o <build-dir>/smp_host_test.o smp_host_test.c
cc -o <build-dir>/smp_host_test <build-dir>/smp_host_test.o <build-dir>/libfloevm.a -lm -lpthread

# 1 vs 2 hart host boots with stats
<build-dir>/floe_vm_host --bios <img>/bbl64.bin --kernel <img>/kernel-riscv64.bin \
  --disk <img>/root-riscv64.bin --ram 128 --vcpu 2 --script <cmds> \
  --transcript out.txt --stats-file out.jsonl --until MARKER --max-s 120
# full SMP test (marker/9p checks fail honestly while the dual-hart guest
# bring-up is unresolved; the summary JSON records exactly which checks failed)
<build-dir>/smp_host_test --bios <img>/bbl64.bin --kernel <img>/kernel-riscv64.bin \
  --disk <img>/root-riscv64.bin --share floe=<dir> --ram 128 \
  --summary smp.json --transcript smp-transcript.txt
```

## FLOE-SMP qualification status (2026-09-23, host: Apple Silicon macOS, interpreter)

Exact fixture/pins used for these measurements:

- engine: TinyEMU `2019-12-21` (sha256
  `be8351f2121819b3172fcedce5cb1826fa12c87da1b7ed98f269d3e802a05555`) with
  patches `0001`–`0010` from `ThirdParty/TinyEMU/patches/`; patch `0010-smp-dual-hart.patch`
  was job A's in-flight (uncommitted) WIP at the time of measurement.
- guest: the bellard.org demo archive `diskimage-linux-riscv-2018-09-23.tar.gz`
  (sha256 `808ecc1b32efdd76103172129b77b46002a616dff2270664207c291e4fde9e14`):
  `bbl64.bin` sha256 `293610cea7af6c75e4a8337e16c0d62834becbf31ffd9cca35e0c211602349db`
  (53786 bytes), `kernel-riscv64.bin` sha256
  `293aef345c8e996320de4ca7fc87ff48155a183b3dde00d2f269c8e461b067c5` (3946740 bytes,
  ident `Linux 4.15.0-00049-ga3b1e7a-dirty`, `CONFIG_SMP` unset), 128 MB RAM,
  `console=hvc0 root=/dev/vda rw`. This is a UP smoke fixture, not the target
  userland and never shipped as one.

Results:

- `--vcpu 0/1` keeps the legacy single-hart path: `host_threads=0`, only hart 0
  retires instructions, the demo guest boots to its runtime-assembled marker
  (verified locally; see the stats lines `host_threads:0`).
- `--vcpu 2` really spawns two host threads and BOTH harts retire instructions
  (local run: ~5.4e9 insns per hart in 90 s, `hart_powered_down` never set).
  But the **guest produced a 0-byte console transcript in 90 s**. This failure
  is **unresolved and not localized by K**: with a UP kernel/bbl the second
  hart is not exercised by Linux at all, so engine SMP bring-up, the 2018
  bbl firmware's secondary-hart path, and FDT/boot plumbing remain equally
  plausible causes. What K's evidence does rule out is the host side: the API
  create/stats/thread contract and the single-hart control both work on the
  same fixture. Root-cause attribution requires A's Linux SMP boot work plus a
  cloud re-run; K's gates surface the failure rather than mask it.
- `smp_host_test` on that same tree: 18 checks, 2 failures — both are the
  dual-hart guest symptom (no marker, no 9p write). Host-side checks pass:
  capability probes, `vcpu_count=3` rejected, continuous concurrent stats
  sampling from a second host thread with `host_threads=2`, 3/3 stop+flush
  destroy cycles, and the full single-hart control. The parked-hart WFI state
  is recorded as informational evidence, not asserted (it depends on the
  guest firmware park loop).
- The pinned demo kernel is UP (`CONFIG_SMP` is not set), so even a working
  dual-hart bring-up cannot show workload speedup on it; the cloud baseline
  records repeats for both hart counts and explicitly claims no speedup until
  an SMP guest kernel lands (job A guest-image scope).
- **Release state: production/default dual-core (and any SIX-tier enablement)
  stays OFF until a real SMP guest kernel image passes the `run_smp` S1–S5
  gates in cloud.** As of run 36004192418 the real SMP boot path is green
  through S4; S5's completion/timing methodology was corrected here (see the
  stage contract below) and still needs a green cloud rerun. Nothing in this
  document enables dual-core, and the cloud gates must not be weakened to
  change that.

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
boot/memory/time measurements, and (opt-in `run_smp=true`) the FLOE-SMP
stages S1–S5 described below. iPad performance: **pending** — no device
measurements exist yet; never extrapolate from the above.

### Cloud SMP stage contract (`run_smp=true`)

- **S1** boots the demo guest with `floe_vm_host --vcpu 1` and `--vcpu 2`
  and hard-fails unless: `vcpu=1` uses inline interpretation
  (`host_threads=0`), `vcpu=2` spawns two host threads with hart 1 actually
  retiring instructions, and BOTH guests reach a runtime-assembled marker.
  A missing dual-hart marker is kept as a real failure (transcript + stats
  uploaded per stage) — never downgraded to a skip.
- **S2** runs `smp_host_test` (capability probes, concurrent stats sampling,
  9p IO, repeated stop+flush destroys, single-hart control) and uploads its
  summary/transcript immediately.
- **S3** runs a repeated (3×) `--vcpu 1` vs `--vcpu 2` performance baseline
  with per-hart instruction counters and writes `smp-perf-baseline.json`;
  the recorded `speedup_claim` stays `null` for the UP demo kernel. Host
  `nproc` is never used as evidence of dual-hart execution.
- **S4** boots the freshly built `CONFIG_SMP=y NR_CPUS=2` pair with
  `--vcpu 1`/`2` and requires the guest's own `/proc/cpuinfo` hart count, the
  boot pair's kernel ident, both harts retiring instructions and parallel 9p
  I/O; vcpu=1 is the control.
- **S5** repeats an equal-work two-worker `dd` workload 3× per hart count
  plus a stopped run. DONE is assembled at runtime by the same guest shell
  command that runs the workers and only after `wait`, so it means real
  completion (the earlier fixed `@50` timer was a measured method error: it
  made every wall time 50.0 s). The work window is measured in the guest from
  `/proc/uptime` around the workload, isolating boot/console delay. The gate
  (`smp_workload_check.py`) requires real per-worker completion, bounded
  equal work, `host_threads=2` with a non-empty hart 1 (and the inline
  vcpu=1 control), the stopped-run evidence, and a real median work-window
  speedup — no speedup is a real failure. Per-hart retired instruction counts
  are recorded evidence only; equal work retiring roughly equal totals is
  expected, so a total-instruction ratio is never a success criterion (the
  retired 1.5× rule failed a run at 393.8 M vs 537.1 M).

## Cloud results (2026-09-20, ubuntu-latest, raw transcripts kept as artifacts)

Honest status, including what does **not** work:

- **Modern Debian 13 (kernel 6.12.107) does not boot on the 2018 bbl.**
  Stage B produced a 0-byte console transcript (rc=2 timeout): Linux removed
  the legacy SBI v0.1 interface that bbl implements in 5.9, so the kernel
  never reaches the virtio console. A modern guest needs FDT generation +
  OpenSBI in the engine — future work, not a configuration tweak. The 2018
  demo image is a smoke fixture, **not** a complete Linux.
- **Debian 13 userland on the 2018 4.15 kernel now really runs** (run
  35500083112, apt_probe): `apt-get update` over the default **HTTPS**
  sources with normal signature verification fetched 28.1 MB in 1m36s
  (rc=0), `apt-get install -y --no-install-recommends python3-numpy nodejs`
  succeeded (rc=0), `import numpy` reported 2.2.4, `node -e` reported
  v20.19.2, and Python HTTPS returned 200. Multi-process/fork/pipe/signal/
  PTY, 9p sharing and write-through persistence (reboot readback) pass in
  the same image. Two fixes were required: `patches/0005-fence-hints.patch`
  (upstream trapped `FENCE.TSO`, which Debian's libapt-pkg executes — apt's
  http and https methods died with SIGILL before any network work) and
  setting the guest clock (a 1970 clock made TLS report "certificate is not
  yet valid").
- **The 4.15 fallback kernel cannot use the Debian GPT cloud image.** It
  has no EFI/GPT parser, so the ext4 partition is extracted and booted as a
  partitionless image (`root=/dev/vda`); the guest disk read path itself was
  verified byte-exact.
- **Lean push run (build + lifecycle + Stage A): passing.** Lifecycle covers
  repeatable create/destroy, hostfwd bind/remove/destroy by real TCP
  connect, oversized BIOS/kernel recoverable failures and the RAM-OOM
  negative case on Linux (2 GB guest under a 1 GB `RLIMIT_AS` fails create
  cleanly through the `floe_ram_oom` path instead of exiting the host).
- **Guest runner verified in the real engine**: static riscv64 cross-build,
  injection into the rootfs image, PID1 startup and one real
  `\x1eFLOE-EXEC` frame returning `FLOE-BEGIN`/`FLOE-END … 0`.
- A separate `apt_probe=true` dispatch exists for targeted re-checks; it
  skips Stage A/B/C/E and drives one real sequential guest script from the
  9p share. The first such run's instruction probe printed an
  `IndentationError` (a harness `sed` stripped the Python indentation), so
  no `FLOE_INSN_*` evidence came from that run even though APT itself
  passed; the probe is fixed and its `fence_tso=OK` marker is now part of
  the required evidence, to be re-confirmed in the final image smoke.

## Phase 2 adapter results (2026-09-21, host: Apple Silicon macOS 27, interpreter)

Run after patches 0006/0007/0008 landed (per-VM slirp, fd-based 9p
containment, recoverable guest-fault paths). All four native tests pass on
this host; the commands are the ones `run_local_smoke.sh` now runs:

- `lifecycle_test <bios> <kernel> <disk> <share>` → `LIFECYCLE_OK
  (0 failures)`: 5x create/slice/destroy with networking, failed-create
  cleanup, hostfwd bind/remove/destroy-auto-cleanup, recoverable
  oversized-BIOS/kernel; the RAM-OOM rlimit case is skipped on Darwin
  (Linux CI covers it).
- `containment_test` → `CONTAINMENT_OK` (65 checks): walking `..`, `/`,
  `dir1/../../outside` returns 0 components; a symlink fid is returned as
  `P9_QTSYMLINK` with its target verbatim but walking through it (relative,
  absolute or directory link, host- or guest-created) walks 0 components
  and `open` fails; create/mkdir/symlink/mknod/link/rename/unlink reject
  `..`/`/` names; legitimate in-share create/write/rename/unlink still
  work; a file fid cannot resolve a sibling; a host FIFO under the share is
  metadata-only and `open`/`setattr(size)` return `EOPNOTSUPP` in <1 s
  (never blocking the caller).
- `two_vm_test` → `TWO_VM_OK` (23 checks): two networked VMs exist at the
  same time, run 200 slices each on two threads, keep independent
  forwarding tables, and destroying one closes only its own listeners
  (the other even re-uses the freed host port).
- `two_vm_test <bios> <kernel> <disk>` → `TWO_VM_OK` (32 checks, ~9 s wall):
  two REAL guests boot concurrently on two threads, each mounts its own 9p
  share, writes a distinct file and prints a distinct console marker; each
  marker appears only on its own VM's console and each file only in its own
  share directory. The same run under `-fsanitize=thread` completes with
  **zero ThreadSanitizer warnings**.
- Single-VM smoke (`floe_vm_host … --share /dev/root=… --net`) still boots
  the 2018 demo guest, mounts the 9p share, writes `two_vm_a.txt` and exits
  on the assembled marker (`FLOE_TWOVM_A_OK`).

Limits: both phases run the demo buildroot guest, not Debian; no iPad or
physical-device measurement was made here; the Linux RAM-OOM case is only
covered by the CI workflow. See `docs/PHASE2_adapter.md` for the
fatal-path audit (what is recoverable vs. which upstream invariants
remain) and the integration contract.



## Evidence rules for this qualification

Guest markers are only ever emitted by commands that build them at runtime
(`echo X_$((6*7))`, `printf 'X_%s' OK`) and `--until` uses the same form, so
`grep`/`--until` cannot match the console echo of the input line. Command
exit codes are captured from the command itself (`cmd >log 2>&1; printf
'RC=%d\n' $?`), never from the tail of a pipeline, and raw apt/dpkg logs are
exported to the host through the 9p share. Debian stages are opt-in
(`workflow_dispatch` input `run_debian`), so a push stays a few-minute check.

Focused static/parse checks (no guest run, no build):

```sh
python3 FloeAgent/Qualification/TinyEMULinux/tests/test_smp_workload_check.py
```

They run the S5 gate helper against synthetic pass/fail work directories
(including the exact 393.8 M vs 537.1 M false-failure shape) and parse the
S5 step of the workflow YAML as the runner executes it (no fixed-timer DONE,
marker never verbatim in the console input, real `wait` before the
runtime-assembled marker, bounded equal work, no 1.5× instruction rule).

## Notes for app integration (phase 2B handoff)

The engine is ready to be driven by the shell/localPython backend work:
one `FloeVM` per environment, console bytes bridged to the shell UI, 9p
share per environment workspace, `run_slice` on a dedicated thread. The
shared `LocalShellBackend` (6 methods today) will still need: byte-oriented
I/O (not line-only), real signal delivery (guest `kill` via console input
is only shell-level), capability reporting, and backend/environment
routing. Those are phase 2B concerns — this task intentionally does not
change app defaults or remove existing fallbacks.

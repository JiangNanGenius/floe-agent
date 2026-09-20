# TinyEMU phase 2 — native adapter isolation (contract, audit, evidence)

Status: implemented and committed on `codex/tinyemu-phase2-adapter` (baseline
`46422286`). Scope: `FloeAgent/ThirdParty/TinyEMU` (adapter + patches +
vendored/generated engine) and `FloeAgent/Qualification/TinyEMULinux`
focused native tests. No app build, no release, no push.

## What changed

| Item | Change |
| --- | --- |
| `patches/0006-slirp-per-instance-state.patch` | slirp's wall-clock cache, timer flags, DNS cache and `select()` scratch fd_sets moved from process-wide globals into `struct Slirp`; `get_dns_addr(Slirp *, …)` is explicit (no thread-local "current instance"); the one remaining constant global (`loopback_addr`) is initialised with `pthread_once` (`InterlockedCompareExchange` on Windows). Connection lists, mbufs, TFTP/BootP state were already per-instance upstream. |
| `patches/0007-9p-export-root-containment.patch` | `fs_disk.c` containment rewritten to be fd-based (root pinned as `root_fd`, one fid = contained dirfd + one single component, every syscall `*at()` + `O_NOFOLLOW`/`AT_SYMLINK_NOFOLLOW`); special files (FIFO/socket/device) are metadata-only and never opened (`EOPNOTSUPP`). |
| `patches/0008-recoverable-guest-fault-paths.patch` | guest-reachable fatal/UB paths in `virtio.c` become device errors (details below). |
| `adapter/floe_vm.{c,h}` | singleton slirp guard removed; per-VM `Slirp *`; per-VM `api_lock` serializing `run_slice`/`hostfwd_*`/`destroy`; `destroy` waits for an in-flight slice; lock-free `floe_vm_poweroff_requested` cache; `run_slice` returns `<0` on a recoverable host-side fault (e.g. `select()` failure other than `EINTR`). API is source-compatible: no signature changed. |
| `adapter/Makefile` | compiles the patched `fs_disk.c`/`virtio.c`/slirp copies from `$(BUILD)` (static pattern rules, so the pristine sources can never win); builds the new tests. |
| `vendor_swift_sources.sh`, `PROVENANCE.json`, `LICENSE-INVENTORY.md`, `README.md` | 0006/0007/0008 added to the patch series and the vendored tree regenerated (`--check` passes). `VENDORED-SHA256SUMS.txt` still records pristine hashes only (patch verification is the `--check` rebuild). |
| `Qualification/TinyEMULinux/{containment_test,two_vm_test}.c`, `run_local_smoke.sh` | new focused native tests and driver wiring. |

## Lifecycle and thread contract (engine worker handoff)

The C ABI is unchanged (`floe_vm.h`); only semantics were tightened:

- `floe_vm_create()` may run on any thread. It captures no thread id and
  stores no thread-local state. `floe_vm_run_slice()` may run on a different
  worker thread afterwards.
- Per VM, `run_slice` / `hostfwd_add` / `hostfwd_remove` / `destroy` are
  serialized by an internal mutex; different VMs have different mutexes and
  truly run concurrently. `destroy` blocks until an in-flight slice returns.
- One VM must not be driven by two threads at once (the mutex makes that
  safe but sequential, not parallel); one worker thread per VM is the
  intended model.
- `floe_vm_console_input()` may be called from any thread (own lock).
- Do not call `floe_vm_destroy()` from the console output callback: it runs
  inside `run_slice` on the same thread and the lock is not recursive. Stop
  the worker, then destroy.
- `run_slice` returns `1` on guest poweroff, `0` normally, `-1`/`<0` for a
  recoverable host-side fault — destroy and recreate that VM.
- Networking is per VM: each `net_enable=1` VM has its own slirp instance
  (10.0.2.0/24, DHCP, DNS cache, timers, forwarding table). Two networked
  VMs can run on two threads; host TCP/UDP ports stay a single host
  namespace (two VMs cannot bind the same `127.0.0.1:port`).
- `floe_vm_hostfwd_add/remove` are per VM and their listening sockets are
  closed on `floe_vm_destroy` (upstream `slirp_cleanup` does not close
  them), without touching other VMs.
- The engine still executes one virtual CPU with a single interpreter
  thread; two host threads mean two VMs, not multicore guest performance.

## Fatal-path audit

Fixed (guest-reachable, now recoverable per instance):

| Path | Before | After |
| --- | --- | --- |
| Guest RAM allocation failure (`iomem.c`) | `exit(1)` | create returns `NULL` (`floe_ram_oom`) — patch 0002 |
| BIOS/kernel/initrd larger than guest RAM (`riscv_machine.c copy_bios`) | `exit(1)` (and `memcpy` before the size check) | create returns `NULL` — patch 0002 |
| Guest poweroff (`riscv_machine.c`) | `exit(0)` | observable flag — patch 0001 |
| Unknown `virtio-blk` request type (`virtio_block_req_end`, `VIRTIO_BLK_T_GET_ID`-style) | `abort()` | completes with `VIRTIO_BLK_S_UNSUPP`; `virtio_block_recv_request` consumes the descriptor instead of stalling the queue — patch 0008 |
| `assert(write_size >= 1)` on a malformed guest block descriptor | host `abort()` | request size range-checked, no abort — patch 0008 |
| `read_size < header` / negative `len` in block & net receive paths | `malloc((size_t)negative)` → NULL, then `memcpy_from_queue(NULL, …)` | range check, return device error — patch 0008 |
| Guest-controlled `malloc()` results in block/net/console/9p (`walk`, `read`, `write`, `readdir`, `send_reply`, unmarshall `s`) | unchecked (NULL deref / write through NULL) | checked; 9p answers a 9p error, other paths drop the request — patch 0008 |
| 9p reply with empty payload (`Tclunk`, `Tflush`, `Tfsync`) | sent (7-byte header) | still sent; patch 0008 initially dropped them, which froze the guest's mount — fixed before commit and covered by the real-guest test |
| 9p export path escape through `..`/`/`/symlinks/renames | path-string only, `open()`/`stat()` followed links | structured fd containment — patch 0007 |
| Host FIFO/device under a share opened from the run thread (potential unkillable block) | `open()` could block the slice forever | `EOPNOTSUPP`, metadata still visible; never opened — patch 0007 |

Remaining upstream fatal paths (inspected, **not** guest-reachable in this
configuration — kept as invariants):

- `virtio_config_read()` / `pci.c pci_config_read/write` `default: abort()`
  on `size_log2`: both transports are registered with
  `DEVIO_SIZE8|DEVIO_SIZE16|DEVIO_SIZE32` only, and `riscv_cpu.c` emulates a
  64-bit guest access as two 32-bit device accesses, so a device callback can
  only ever see `size_log2` 0–2. The RISC-V virt machine uses virtio-MMIO;
  no PCI host bridge is instantiated (the PCI code paths are dead here).
- `riscv_cpu.c` `target_read_slow/target_write_slow` `default: abort()` on
  `size_log2`: the interpreter emits only 0–3 (0–4 with 128-bit, gated by
  `MLEN >= 128`), and those switches are keyed on the same width.
- `virtio.c` input-device `default: abort()`s: the adapter never sets
  `p->input_device`, so no virtio input device exists in an app VM.
- `marshall()/unmarshall()` `default: abort()` on a format character: the
  format strings are compile-time constants at each call site; guest data
  cannot change them. The fixed 1 KB reply buffers keep the layout
  `assert()`s (byte counts and `len <= 65535` for host-side strings ≤ 1023
  bytes) within bounds.
- `virtio_init()` `default: abort()` on an unknown device id: the adapter
  only registers block/console/net/9p ids.
- `machine.c` `exit(1)` in `load_file()`/`config_file_loaded()`: only
  reachable through `virt_machine_load_config_file()`, which the adapter
  never calls (it loads BIOS/kernel/initrd itself and fails cleanly).
- `riscv_machine.c` `exit(1)` for unsupported `display_device`/
  `input_device` strings: config-time only; the adapter leaves both `NULL`.
  A future embedder passing a bad string would exit the process; treat the
  machine params as adapter-owned.

No `abort()` remains on a path a valid or malicious guest can reach through
the virtio-MMIO devices used by the app (console, block, net, 9p).

## 9p containment design (patch 0007)

- `FSDeviceDisk.root_fd` pins the export root (`O_RDONLY|O_DIRECTORY|O_NOFOLLOW`).
- A fid is either a contained directory fd (`name == NULL`) or a contained
  directory fd plus one single component (`name`). Walk resolves each
  component with `fstatat(…, AT_SYMLINK_NOFOLLOW)` and opens directories
  with `openat(…, O_DIRECTORY|O_NOFOLLOW)`; a symlink/file fid has no
  children (upstream stopped at `ENOTDIR`; symlinks must not be traversed
  server-side in 9p2000.L).
- `open`/`create`/`mkdir`/`symlink`/`mknod`/`link`/`rename`/`unlink`/
  `readlink`/`setattr` all use `*at()` on contained fds, reject names with
  `/` or `..`, and never follow a final symlink (`O_NOFOLLOW`); symlink
  targets are stored and returned verbatim but are inert because no later
  resolution can leave the root.
- The diagnostic `path` string is never passed to an authority-granting
  syscall.
- Special files: `open` returns `-P9_ENOTSUP` (524) unless the fid is a
  regular file/directory/symlink; `create`/`setattr(size)` refuse to open an
  existing FIFO/device. This is deliberately narrow: it prevents a blocking
  host FIFO from freezing `run_slice`, without adding a general security
  layer.
- Legitimate workspace sharing is unchanged: readdir, read/write, chunked
  I/O, locking and persistence were verified by the guest smoke test and the
  lifecycle test.

## Evidence (2026-09-21, Apple Silicon macOS 27.0, interpreter)

Source: this worktree; pristine TinyEMU 2019-12-21 (SHA256
`be8351f2…5555`); vendor `--check` passes after regeneration; every vendored
engine source compiles with the SwiftPM target's flags (`-fno-modules`,
shims) and every patched source compiles in the qualification build.

Commands (from `FloeAgent/Qualification/TinyEMULinux`, `BUILD` on a
nanosecond-timestamp volume; the exFAT worktree volume has 2-second mtimes,
which makes make's timestamp comparisons unreliable):

```sh
make -f ../../ThirdParty/TinyEMU/adapter/Makefile \
     TINYEMU_SRC=<pristine>/tinyemu-2019-12-21 \
     PATCH_DIR=../../ThirdParty/TinyEMU/patches BUILD=<build> HOST_DIR=. MACOS=1 -j4
<build>/containment_test                       # CONTAINMENT_OK, 65 checks
<build>/two_vm_test                            # TWO_VM_OK, 23 checks
<build>/two_vm_test <IMG>/bbl64.bin <IMG>/kernel-riscv64.bin <IMG>/root-riscv64.bin
                                               # TWO_VM_OK, 32 checks, ~9 s
<build>/lifecycle_test <same fixtures> <share> # LIFECYCLE_OK (0 failures)
```

Observed results:

- `containment_test`: all escape shapes refused, legitimate in-share
  create/write/rename/unlink works, file fids cannot resolve siblings, FIFO
  open/setattr return `EOPNOTSUPP` in < 1 s.
- `two_vm_test` (synthetic BIOS): two networked VMs exist simultaneously,
  200 slices each on two threads, independent forwarding tables, destroying
  one closes only its listeners and the survivor can re-use the freed port.
- `two_vm_test` (real 2018 demo guest, Linux 4.15 + buildroot): two guests
  boot concurrently on two threads; each mounts its own 9p share, writes
  `two_vm_a.txt`/`two_vm_b.txt` and prints `FLOE_TWOVM_A_OK`/`_B_OK`;
  markers appear only on their own console and files only in their own share
  directory.
- The same real-guest run under `-fsanitize=thread` completes with **zero
  ThreadSanitizer warnings** (concurrent create, `slirp_init`, two
  `slirp_select_fill/poll` loops, console input/output, teardown).
- `lifecycle_test`: `LIFECYCLE_OK (0 failures)` (5 create/slice/destroy
  cycles with net, failed-create cleanup, hostfwd lifecycle, recoverable
  oversized BIOS/kernel; RAM-OOM case skipped on Darwin, covered by the
  Linux CI workflow).
- Single-VM smoke: real guest boots, mounts the 9p share, writes the file
  and exits on the assembled marker.

Limits / not done here: no Debian boot or package matrix (cloud CI owns
that), no iPad/device measurement, no app build, no release/push. The
ThreadSanitizer run is a host check, not a production-device result. The
RAM-OOM negative case was skipped on macOS because `setrlimit(RLIMIT_AS)` is
rejected there.

## Integration instructions

1. The app worker (`Sources/FloeExecution/Linux` + LinuxGuest runner, owned
   by the engine continuation job) should treat the API above as stable and
   additive: one `FloeVM` per environment, `run_slice` on a dedicated
   thread, console bytes bridged through the callback, one 9p share per
   environment workspace. `floe_vm_create` may stay on the caller's thread;
   `run_slice` may move to a worker thread.
2. Stop the worker thread before `floe_vm_destroy` (or call destroy from a
   different thread, which now waits). Never destroy from the console
   callback.
3. `run_slice < 0` is a recoverable fault: destroy the VM, surface a
   runtime error, recreate. Guest poweroff is `1`.
4. Per-VM forwarding: register with `floe_vm_hostfwd_add`, and expect
   cleanup on destroy; host ports are still one namespace, so allocate them
   per environment.
5. Migration owns `Package.swift`/`project.yml`: no manifest change is
   needed here (no new engine source file; `fs_disk.c`/`virtio.c`/slirp
   files are the same set). To regenerate the vendored tree:
   `bash FloeAgent/ThirdParty/TinyEMU/vendor_swift_sources.sh <pristine>` and
   `… --check <pristine>`.
6. SwiftPM builds the vendored engine with `-fno-modules`; the new patches
   add plain POSIX header use (`<pthread.h>`, `<sys/stat.h>`, `*at()`
   syscalls) available on iOS/iPadOS/macOS and Linux, and no new files.

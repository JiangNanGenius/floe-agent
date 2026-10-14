# Floe Linux guest kernel upgrade (4.15 → modern LTS)

Status 2026-10-15 (lane job-22a7dfde5f83467f, post-reboot continuation):
**complete and native-qualified.** Patches 0012–0019 are canonical
(`vendor_swift_sources.sh --check` clean); the 6.18.56 + OpenSBI 1.9 pair
passes the full native TinyEMU qualification matrix on the canonical
engine with no workaround flags: uname/SMP, stat ABI matrix, ping, DNS,
TLS, apt update, gcc install (persistent across reboot), guest C
compile+run, faulttest 32 MiB, 9p read/write/exec and directory
enumeration (342-entry listing), stop/restart persistence, 1/2/3 harts,
and 4.15-pair rollback on the same engine. Known non-kernel limitation:
the engine RTC reports time-since-boot, so the guest clock needs one
`date -s @<epoch>` at qualification time (pre-existing; the 4.15 guest
behaves identically); the synthetic rootfs' gcc driver computes a
relative exec-prefix so cc1/ld need explicit `-B` paths (rootfs image
defect, kernel-independent).

## 1. Why upgrade

The shipped guest kernel is the 2018 demo build
(`Linux 4.15.0-ga3b1e7acc-dirty`, TinyEMU `diskimage-linux-riscv-2018-09-23`,
`riscv-linux` `a3b1e7acc`, `riscv-pk` `ac2c910b`). It predates upstream
RISC-V and its SBI/console/ISA surface:

- Linux 5.9 removed legacy SBI v0.1, so the 2018 `bbl` cannot boot any
  modern kernel (the previous Debian 6.12 attempt produced no console for
  exactly this reason).
- The kernel is unmaintained (4.15 left support in 2019) and carries no
  modern VFS/syscall/allocator hardening.

User-reported apt failures on the guest were investigated first (§5); the
"kernel fstat ABI bug" claim did **not** reproduce on either the 4.15 UP demo
kernel or the exact `#1 SMP` kernel with correctly-declared raw syscalls, on
both buildroot and the full Debian trixie userland. The user-visible errno
was shown to be the classic ctypes pitfall (`CDLL(...)` without
`use_errno=True` fabricates a stale errno). The kernel upgrade is therefore
justified on supportability/compatibility grounds, not as a confirmed bug
fix — and it must be a real upgrade, not a version-string change.

## 2. Chosen versions (verified)

| Component | Version | Source | Verification |
| --- | --- | --- | --- |
| Kernel (primary) | `6.18.56` (latest LTS, 2026-10-11) | cdn.kernel.org | sha256 `4633bbda…` matches kernel.org `sha256sums.asc`, GPG "Good signature" from Kernel.org checksum autosigner (key `B8868C80…589DA6B1` via keyserver.ubuntu.com) |
| Kernel (fallback) | `6.12.112` (LTS, 2026-10-03) | cdn.kernel.org | sha256 `164dc9d1…` matches the same signed sums |
| Firmware | OpenSBI `v1.9` (2026-07-01) | GitHub releases | `FW_JUMP`, generic platform; defconfig already sets `CONFIG_FDT_SERIAL_HTIF=y` |
| Engine | TinyEMU 2019-12-21 + patches 0001–0019 | this repo | `vendor_swift_sources.sh --check` clean |

## 3. TinyEMU engine changes (patches 0012–0019, landed)

All five are required to boot a modern kernel and are applied by the
canonical vendoring script; `vendor_swift_sources.sh --check` passes.

- **0012 htif-fdt-reg** — expose the tohost/fromhost MMIO window in the FDT
  `htif` node (`reg` = fromhost@+8, tohost@+0; order matches OpenSBI
  `fdt_serial_htif` parsing) so OpenSBI's HTIF console driver works. The 2018
  bbl reached the same registers via linker-script symbols (`tohost =
  0x40008000`).
- **0013 mid-csrs** — implement `mvendorid/marchid/mimpid` (0xf11–0xf13),
  which the spec makes mandatory (return 0 if unimplemented). OpenSBI reads
  `mvendorid` at hart init and died on the illegal-instruction trap.
- **0014 canonical-isa-string** — emit `riscv,isa = "rv64imafdc"` in canonical
  order and skip the MISA privilege bits `s`/`u` (not ISA extensions). The old
  alphabetical form `"rv64acdfimsu"` failed the modern kernel's
  `strncasecmp(isa, "rv64ima")` fallback check, dropping the boot CPU.
- **0015 time-csr** — implement the read-only `time`/`timeh` CSRs (shadow of
  the CLINT mtime counter, machine-provided `get_time` hook) and fix
  `COUNTEREN_MASK` to include the TM bit so OpenSBI's counteren writes are not
  stripped. Without it the kernel panics in `extract_entropy` (`rdtime`).
- **0016 htif-console-getc** — implement the HTIF GETC handshake (deliver one
  pending host input byte through `fromhost`). Upstream stubbed it, so no SBI
  firmware console input ever reached the guest.

The kernel config
([`config_linux_riscv64_6.18.56`](../FloeAgent/ThirdParty/TinyEMU/guest-image/config_linux_riscv64_6.18.56),
§4) additionally disables
every ISA extension beyond rv64gc that the interpreter cannot execute
(SVPBMT/SUPM/SVNAPOT, Zba/b/c/bk, Zicbom/boz/bop, Zawrs/abha/acas, V,
vendor extensions) and selects the console on virtio-console (the path the
4.15 kernel already used on TinyEMU), `earlycon=sbi` for early messages.

## 4. Reproducible build

Build host: Ubuntu 24.04 container (gcc 13.3.0, binutils 2.42), 6 jobs.
The retained build and qualification records bind the Image, matching symbols,
configuration and upstream sources by hash. The exact source configuration is
tracked at `FloeAgent/ThirdParty/TinyEMU/guest-image/config_linux_riscv64_6.18.56`.

```sh
# In the verified Linux 6.18.56 source tree, supply the absolute path to
# the tracked config_linux_riscv64_6.18.56 via FLOE_KERNEL_CONFIG.
: "${FLOE_KERNEL_CONFIG:?set to the tracked exact kernel configuration}"
cp "$FLOE_KERNEL_CONFIG" .config
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- olddefconfig
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j6
# -> arch/riscv/boot/Image

# OpenSBI
make PLATFORM=generic FW_JUMP=y FW_JUMP_ADDR=0x80200000 \
     CROSS_COMPILE=riscv64-linux-gnu-     # defconfig has CONFIG_FDT_SERIAL_HTIF=y
# -> build/platform/generic/firmware/fw_jump.bin
```

## 5. User-evidence re-check (apt / fstat)

The user's transcript claimed `fstatat(fd,"",…,AT_EMPTY_PATH)` returns ENOENT
for pipes/sockets on the 4.15 guest, breaking `apt-get update`. Measured with
correctly-declared raw syscalls (riscv64 asm-generic nr 79/80/291) on the real
guests:

| fd type | `fstat` (80) | `fstatat` "" AT_EMPTY_PATH (79) | `statx` AT_EMPTY_PATH (291) |
| --- | --- | --- | --- |
| pipe | 0 | 0 | 0 |
| socketpair | 0 | 0 | 0 |
| regular file | 0 | 0 | 0 |
| invalid fd 999 | EBADF | EBADF | EBADF |

- 4.15 UP demo kernel (buildroot): all pass.
- 4.15 `#1 SMP` kernel + Debian 13 trixie userland (the user's exact image
  kernel): all pass.
- 6.18.56 + OpenSBI + same Debian userland: all pass.

The user's python probe reported `rc=0 errno=2`. Reproduced: with
`ctypes.CDLL("libc.so.6")` **without** `use_errno=True`, `ctypes.get_errno()`
returns a stale value (2 = ENOENT left over from an earlier failed call)
while the syscall itself returns 0 — exactly the reported artifact. The apt
failure in this lane's live boot was DNS (`Temporary failure resolving
'deb.debian.org'`), not the fstat error, and has a different root cause.
Conclusion: the claimed kernel fstat ABI bug is **not confirmed**; the errno
was a ctypes artifact. The upgrade stands on supportability, not this bug.

## 6. The three engine fixes that unblocked the modern kernel (2026-10-15)

The §6 "anonymous-memory deadlock" is **root-caused and fixed**, together
with two further kernel-6.x compatibility gaps found during qualification.
All three are canonical patches (0017–0019) on top of 0012–0016:

- **0017 fw-reserved-memory** — the FDT handed to the kernel had no
  `reserved-memory` node, so the buddy allocator handed OpenSBI's
  firmware pages (0x80000000-0x801fffff) to guests; writes zeroed the
  M-mode trap handler (observed raw: `word@0x800003c8` `34021273` → `0`
  / ASCII) and the next trap stormed illegal-instruction fetches
  (pc=0x800003c8, mcause=2). The patch emits
  `/reserved-memory/opensbi@80000000` covering `[RAM_BASE, kernel_start)`.
  After it, `faulttest` 8192 pages (32 MiB) completes where 256-512 pages
  wedged the VM. The earlier no4lvl/Sv48/THP/PTE-AD/SFENCE hypotheses
  were refuted and are not the cause.
- **0018 virtio-queue-num-max** — TinyEMU advertised a 16-entry virtqueue
  ring. Linux ≥ 6.12 `virtio_net` suspends the TX queue below
  `MAX_SKB_FRAGS + 2` (=19) free descriptors and resumes only at ≥ 19, so
  a 16-entry ring never restarted after the very first frame: exactly one
  packet transmitted, then NETDEV TX watchdog timeouts forever (the 4.15
  image wakes at a lower threshold, which is why only the modern kernel
  stalled). `MAX_QUEUE_NUM` is now 256 (QEMU's default). Discriminated by
  booting once with `virtio_net.napi_tx=0` (ping restored on the unpatched
  engine); no NAPI workaround is shipped.
- **0019 fs-open-dir-detect** — the Linux ≥ 6.18 9p client masks Tlopen
  mode with `P9L_MODE_MASK` (0x1fff) before sending, so the O_DIRECTORY
  bit (0x10000) never reaches the engine; TinyEMU keyed its directory
  handling on that flag alone, opened directories as regular files, and
  `fs_readdir` answered `-P9_EPROTO` (guest-visible
  `ls: reading directory ... Protocol error`) while read/write/exec on
  known paths worked. `fs_open` now decides from the fid's real
  `S_ISDIR` type; an explicit O_DIRECTORY on a non-directory is still
  honored as ENOTDIR.

Two probe/toolchain artifacts of the qualification are retained, not
causes: the "console/netlink livelock" was a stale `stat_probe` binary
missing its exit syscall spinning in a userspace write loop (fresh probe
+ retained disassembly evidence); and the gcc
driver on the synthetic rootfs resolves cc1/ld through a relative
exec-prefix (fix: pass explicit `-B` paths; rootfs image fix queued for
the next image build, kernel-independent).

## 7. Rollback

The 4.15 boot pair (`bbl64.bin` + `kernel-riscv64.bin`) is preserved
byte-identical in the image directory and in
`ThirdParty/TinyEMU/guest-image/pinned-inputs.json`; patches 0001–0011 are
unchanged and the 4.15 pair still boots under the patched engine (the new
patches only add CSRs/FDT properties/HTIF behavior the old firmware ignores
or uses identically). An explicit rollback selects the preserved pair through the versioned boot-asset
sidecar at the next stopped start, without rebuilding or rewriting user disks.

## 8. Native qualification matrix (2026-10-15, canonical engine)

Command shape (from `FloeAgent/Qualification/TinyEMULinux`, with verified
pair files staged in a caller-supplied `boot-assets` directory):

```
floe_vm_host --bios boot-assets/opensbi_fw_jump.bin \
  --kernel boot-assets/kernel-6.18.56-riscv64.bin \
  --disk debian-rootfs.img --rw --share floe=smoke/probe-share --net \
  --ram 1024 --vcpu N --cmdline "console=hvc0 root=/dev/vda rw init=/bin/sh earlycon=sbi" \
  --script <script> --transcript evidence/<name>.txt --until MARKER_42 --max-s <budget>
```

| Check | Result | Evidence |
| --- | --- | --- |
| uname 6.18.56 SMP (build #7) | PASS | qual3-core/hart2/hart3 transcripts |
| stat ABI matrix (fresh probe) | PASS (fstat/fstatat-empty/statx rc=0 fifo/sock/reg; EBADF badfd) | qual3-core-transcript |
| ping 10.0.2.2 | PASS | qual3-core-transcript |
| DNS getent deb.debian.org | PASS | qual3-dns2-transcript |
| TLS https://deb.debian.org/debian/ | PASS (HTTP 200; guest clock set from host epoch first) | qual3b-apt-transcript |
| apt-get update | PASS (28.2 MB fetched) | qual3b-apt-transcript |
| apt-get install gcc | PASS (gcc-14 + toolchain; persists across reboot) | qual3b-apt + qual3-cc1c |
| guest gcc compile + run | PASS with `-B` discriminator (rootfs driver layout defect, kernel-independent; default driver path recorded as image-build fix) | qual3-gccfull/gcrun/final transcripts, `GUEST_GCC_OK_42` |
| faulttest 8192 pages / 32 MiB | PASS (reserved-memory fix) | qual3-final-transcript |
| 9p read/write/exec | PASS | qual3-core/b-apt |
| 9p directory enumeration | PASS (`ls`, `ls -la`, 342-entry listing) | qual3-9p/final |
| stop/restart persistence | PASS (/root file + installed packages survive) | qual3-cc1 + core |
| 1 / 2 / 3 harts | PASS (nproc = 1/2/3; stat probe on 2 and 3 harts) | qual3-core/hart2/hart3 |
| 4.15 pair rollback, same engine | PASS (Linux version 4.15.0 boot, ping rc=0) | qual2-oldnet-transcript |

The mutable synthetic Debian disk
(`debian-rootfs.img`, 2.88 GiB) survived the whole matrix; no rootfs
replace/format/hotswap was ever performed.

## 9. App 采用策略与匹配符号导出（2026-10-15 收口 / adoption closure）

- 匹配的 build #7 符号和校验清单 `SHA256SUMS-6.18.56-b7` 已留存：
  `vmlinux-6.18.56-b7`（`c3bc5b31…c777`）、`System.map-6.18.56-b7`（`f5bb06b5…e627`）、
  `config-6.18.56-b7`（`e7058fe4…7cb5`，与 `config_linux_riscv64_6.18.56-effective` 及
  vmlinux 内嵌配置逐字节一致）、`kernel-build-6.18.56-b7.log`（`5f8efd19…ba3f`）。
  全部与当时保留的构建树原始输出校验（构建容器现已停止），
  与出货 Image（`kernel-6.18.56-riscv64.bin`，`6bb99c01…b1ca`，#7 SMP）同源，未重新构建。
- 先前保留的 `vmlinux-6.18.56`（`60898ba3…d747e`，build #1）不匹配出货 Image，
  已标记为陈旧（`STALE-vmlinux-6.18.56-build1.md`），保留至主负责人确认无引用后再清理。
- 启动采用策略（自动采用 vs 显式重放、独占段内重校验、故障原子性）记录在
  `FLOE_LINUX_GUEST_BACKEND.md` 的 2026-10-15 段。

## 10. Bundled pair distribution metadata (2026-10-15)

The app now ships the verified boot pair as separate **data resources** (the
`bundled-boot-pair/` resource folder, staged by
`ThirdParty/TinyEMU/guest-image/stage-boot-pair.sh` and pinned by
`boot-pair-v2.manifest.json`). This section records the corresponding license
and source metadata that ships with it; it states facts and does not certify
the distribution as legally complete.

- Licenses: the kernel Image is unmodified upstream Linux under GPL-2.0 (its
  `COPYING` adds the `GPL-2.0 WITH Linux-syscall-note` clarification); the
  OpenSBI `fw_jump` firmware is BSD-2-Clause ("Copyright (c) 2019 Western
  Digital Corporation or its affiliates and other contributors"). Neither
  file is linked into the app binary or the MIT/BSD TinyEMU engine; the
  engine licensing conclusion in `ThirdParty/TinyEMU/LICENSE-INVENTORY.md` is
  unchanged.
- Corresponding source: the kernel is built from the unmodified
  `https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.56.tar.xz` tarball
  (sha256 `4633bbda2ab95eaf2a7af4041236451d6759c72e6946265531af4b3aacefbf89`,
  re-verified against the signed kernel.org `sha256sums.asc`); its exact build
  configuration is tracked in-tree as
  `ThirdParty/TinyEMU/guest-image/config_linux_riscv64_6.18.56` (sha256
  `e7058fe40e27e8d56ca10ec5e7a1bf2969bc6de07078fe2d95f5ebd3098f7cb5`,
  byte-identical to the shipped Image's build `.config`), with the build
  commands in §4. The firmware source is the unmodified OpenSBI v1.9 release
  (`PLATFORM=generic FW_JUMP=y FW_JUMP_ADDR=0x80200000`).
- Shipping notices: the complete GPL-2.0 text, the kernel `COPYING` statement,
  the Linux syscall note and the OpenSBI BSD-2-Clause text ship in the app as
  `Licenses/LinuxBootPair-LICENSES.txt`; the inventory in
  `scripts/license_inventory.py` declares the kernel and firmware as separate
  components and this record as a required bundled notice. The tracked audit
  record is `ThirdParty/TinyEMU/guest-image/BOOT-PAIR-LICENSES.md`.
- The separately downloaded Debian rootfs image keeps its original 4.15
  kernel/bbl pair as rollback and its own manifest
  (`docs/FLOE_LINUX_GUEST_IMAGE_MANIFEST.md`); the open source-offer items
  recorded there are unchanged by this section.

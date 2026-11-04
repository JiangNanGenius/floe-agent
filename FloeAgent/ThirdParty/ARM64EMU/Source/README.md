# arm64emu — an AArch64 system emulator (pure interpreter)

A from-scratch **ARMv8-A (AArch64) system emulator** written in C11 with **no
external dependencies** (libc/POSIX only). It is a **pure interpreter** — no JIT,
no dynamic translation. It runs the **real EDK2 `ArmVirtQemu` UEFI firmware** and
**boots Linux to a userspace shell**, with the **serial console on your terminal**.

The emulated platform is the QEMU `virt` machine (GICv2), the standard,
well-documented target for EDK2 and Linux on AArch64.

## What it does

- Loads and runs the **actual** `/usr/share/qemu-efi-aarch64/QEMU_EFI.fd`
  firmware and runs it through SEC/PEI/DXE/BDS to the **UEFI Interactive Shell**
  (`Shell>`), including the 5→1s boot-countdown driven by the generic timer.
- **Boots a Linux kernel** supplied over fw_cfg: the EDK2 EFI-stub decompresses
  the kernel, exits boot services, and Linux comes up — detecting the CPU, GICv2,
  generic timer, PL011 console, PL031 RTC, PSCI and the PCIe host bridge — then
  mounts the initramfs and runs **`/init` in userspace (EL0)**, reaching an
  interactive **BusyBox shell**.

```sh
make                       # builds ./arm64emu  (C11, libc only)
make test                  # runs the assembly self-tests

# Boot the EDK2 firmware to the UEFI shell (serial -> your terminal):
./arm64emu --bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd

# Boot Linux via fw_cfg (the EDK2 --kernel path, no disk needed):
./arm64emu --bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
           --kernel Image --initrd initramfs \
           --append "console=ttyAMA0 earlycon=pl011,0x9000000"

# Share host directories into the guest over virtio-9p (repeatable):
./arm64emu --bios .../QEMU_EFI.fd --kernel Image --initrd initramfs \
           --virtfs /path/to/project,tag=proj \
           --virtfs /srv/data,tag=data,ro

# virtio-console on hvc0, so the guest terminal size tracks the host window:
./arm64emu --bios .../QEMU_EFI.fd --kernel Image --initrd initramfs \
           --console virtio \
           --append "console=hvc0 earlycon=pl011,0x9000000"
```

Useful flags: `-m/--memory MB` RAM size, `--dtb FILE` supply a device tree,
`--drive IMG[,ro]` attach a virtio-blk disk (repeatable; `ro` opens the image
read-only and advertises VIRTIO_BLK_F_RO), `--net` user-mode networking
(`--netfwd tcp|udp:HOST_PORT:GUEST_PORT` forwards host ports to the guest),
`--virtfs DIR[,tag=TAG][,ro]` share a host directory over virtio-9p
(repeatable), `--console pl011|virtio[,count=N]` pick the console device
(default `pl011`) and create N virtio-consoles (`hvc0`..`hvcN-1`), each a
separate guest terminal, `--console-fd DEV=RFD[:WFD]` bind `ttyAMA0`/`hvcN` to
inherited descriptors instead of the terminal (with `--ctrl-fd FD` carrying
their window sizes — see `tests/scripts/console_mux.c`),
`--bin FILE[@ADDR]` load a flat binary (bare-metal tests), `-d/--trace`
per-instruction trace, `--reg-trace` register trace, `--max-insn N` stop after N
instructions. `arm64emu --help` is the full reference, reflowed to your
terminal; options are GNU-style (`--long`, `--opt=VAL`, short `-h -v -m -d -j`).

> **Breaking change (CLI).** Options used to be QEMU-style single-dash words.
> Every option is now spelled `--word`; besides the extra dash, `-maxinsn` is
> now `--max-insn`, `-m` is `--memory` (the `-m` short form still works),
> `-d` is `--trace` (short `-d` still works), and `-rt` is `--reg-trace`.

**Several guest terminals (`--console ,count=N`, `--console-fd`).** Each
virtio-console device is one more guest tty — `hvc0`, `hvc1`, … — and each can
speak through a host channel of its own instead of the shared terminal. Bind
them with `--console-fd hvc0=<fd>` (and `--console-fd ttyAMA0=<fd>` for the
UART) to descriptors the process inherited: a socketpair per terminal, plus
`--ctrl-fd` carrying their window sizes, since a socketpair has no
`TIOCGWINSZ`. Run a `getty` on each inside the guest and every terminal is an
independent login. `tests/scripts/console_mux.c` is a working host driver.

**Embedding.** Built with `-DANDROID_JNI`, `main()` becomes `arm64emu_main()`
and fatal paths leave through `_exit()`, so a host process can link the
emulator in and enter it in a `fork()`ed child — no `exec`, which is what
Android's W^X rule requires. `make test-embed` builds that configuration and
runs the suite against it.

Build it as its own shared object with `-fvisibility=hidden`: `arm64emu_main`
is the only symbol marked visible, and it is the whole interface. That matters
when the host also carries this emulator's user-mode sibling
([arm64chroot](https://github.com/sylirre/arm64emu-user)) — the two share an
ancestor and so share around sixty global names (`cpu_step`, `exec_a64`,
`g_jit`, …), which linked into one object collide, and left visible across two
objects would let the dynamic linker bind one engine's calls into the other's
code.

**Host directory sharing (`--virtfs`).** Each `--virtfs DIR` exports a host
directory to the guest as a 9P2000.L filesystem on its own virtio-mmio slot.
`tag=` names the mount (default: the directory's basename); `ro` makes it
read-only (default is read-write, changes pass straight through to the host).
Repeat `--virtfs` for multiple independent shares. Mount inside the guest with:

```sh
mount -t 9p -o trans=virtio,version=9p2000.L proj /mnt/proj
```

The guest kernel needs 9p-over-virtio support (`CONFIG_NET_9P`,
`CONFIG_NET_9P_VIRTIO`, `CONFIG_9P_FS`, plus `virtio_mmio`) built in or as
loadable modules. `..` is confined to the share root; symlinks inside a share
are followed by the host, so a share is a convenience, not a security boundary.

**Console (`--console pl011|virtio`).** The default `pl011` is the PL011 UART
(`ttyAMA0`): a byte-pipe serial line, unchanged and fully deterministic.
`--console virtio` additionally attaches a **virtio-console** on its own
virtio-mmio slot, exposed to the guest as `hvc0`. It advertises
`VIRTIO_CONSOLE_F_SIZE`, so the guest terminal size follows the host window
automatically — the initial columns/rows and every later host resize (SIGWINCH)
are propagated, and full-screen programs (`vi`, `less`, `top`) redraw without a
manual `resize`. The guest kernel needs `CONFIG_VIRTIO_CONSOLE` (with
`CONFIG_HVC_DRIVER`) built in or in the initramfs.

For the resize feature to reach your shell, the guest's **interactive console must
be `hvc0`** — i.e. the kernel must boot with `console=hvc0`. There are two host
consoles sharing one terminal (the PL011 for firmware/GRUB/`earlycon`, and hvc0
for the OS), so host keystrokes are routed to **whichever console last produced
output** ("input follows output"): firmware and GRUB menus stay on the PL011, and
once the guest writes its console to hvc0 your typing (and the window size) follow
there. This means `--console virtio` never leaves you unable to type, wherever the
guest's login ends up.

Getting the login onto hvc0 depends on how you boot:

- **`--kernel` path**: the emulator adds `console=hvc0` to the kernel cmdline for you
  when `--console virtio` is set, so the login lands on hvc0 with no extra flags
  (keep `earlycon=pl011,0x9000000` for early output before the driver probes). This
  works for a guest that has its own root filesystem (an installed disk image, or a
  kernel+initramfs that mounts a real root).
- **`--drive` ISO / GRUB boot** (e.g. the stock Alpine live ISO): the kernel cmdline
  comes from the ISO's bootloader, not from `--append`, and the emulator can't
  override a `console=` baked into it. The Alpine ISO uses
  `console=tty0 console=ttyAMA0`, so its login is on `ttyAMA0` — you can still type
  (input follows it). To move the login to hvc0, edit the GRUB entry at the menu:
  press `e`, go to the `linux` line, and **append** ` console=hvc0` at the end
  (last `console=` wins), then `Ctrl-X` to boot. Keep the existing
  `console=ttyAMA0` — *append*, don't replace it: the live ISO's boot-media
  discovery relies on it, and dropping it makes early init fail (`switch_root:
  can't execute '/sbin/init'`). For the same reason, booting a live ISO's kernel
  directly via `--kernel` won't work — its root overlay is assembled only under its
  own GRUB boot. (An installed system with a normal root filesystem has neither
  restriction: just use the `--kernel` path, where `console=hvc0` is auto-added.)

Note that host resize events make `virtio` mode as non-deterministic as any
keyboard input; the default `pl011` path is untouched.

Debug/bring-up env vars (all off by default, no runtime cost when unset):
`AEDBG=N` device/IRQ + fw_cfg/flash logging, `AEPROF=1` hot-PC profiler,
`AERING=1` recent-instruction ring buffer, `AETPC=0xADDR` dump CPU state at a PC,
`AEWATCH=0xADDR` watch writes to an address, `AEIABORT=1` log instruction aborts,
`AECOV=file` coverage-divergence finder (see below).

The generic timer and PL031 RTC follow the host wall clock by default. Set
`AE_RTCLOCK=0` to switch both to a deterministic instruction-count clock and a
fixed RTC epoch, giving a bit-for-bit reproducible boot — the mode the test gates
(`make test`, `test-pd`, `test-jit`, `fuzz-engines`) pin for cross-engine
comparison.

## Architecture

```
src/
  main.c        CLI, image loading, the run loop, signal-flush of diagnostics
  cpu.{h,c}     CPU state, fetch/decode/execute driver, condition codes, dump,
                hot-PC profiler / ring buffer / coverage-divergence finder
  decode.c      A64 decoder: integer/branch/load-store, CRC32, AdvSIMD ld/st
  exec_fpsimd.c FP/Advanced-SIMD execution (scalar FP + vector integer)
  sysreg.c      MSR/MRS, ID registers, generic-timer registers, DC ZVA, TLBI
  mmu.c         AArch64 stage-1 walk (4 KB granule) + software TLB + fetch cache
  exception.c   exception entry/return (VBAR vectors, ESR/FAR/ELR/SPSR, ERET)
  memory.c      physical bus: RAM + NOR-flash CFI command set + MMIO dispatch
  tty.c         raw-terminal serial console via termios
  console.c     host endpoints the console devices speak through: the shared
                process terminal, or an inherited fd pair
  platform.c    device instantiation, DTB placement, kernel load, tick/WFI
  devices/      gicv2, timer, pl011, pl031, psci, fwcfg, virtio_blk (--drive),
                virtio_net (--net), virtio_9p (--virtfs), virtio_console (--console)
  fdt/          device tree: virt.dts (QEMU virt tree; compiled to virt_dtb.h,
                embedded) + fdt.c, which sizes its /memory node to --memory
  jit/          accelerated engines: predecode.{h,c} (the default direct-threaded
                tier + the JIT's classifier), jit.c runtime, ir.h, frontend.c,
                backend_x86_64.c, backend_a64.c
  net/          usernet, the built-in user-mode NAT stack behind virtio-net
                (core/udp/tcp; no TAP, TUN, privileges or external libraries)
docs/           jit.md, pd.md, parity.md, todo/
tests/          self-checking assembly tests + QEMU differential helpers
```

### What is implemented

- **Integer ISA**: data-processing (immediate & register), shifts/bitfields,
  conditional select/compare, mul/div/madd/smulh/umulh, rev/rbit/clz/cls,
  **CRC32/CRC32C**, branches, the full load/store family incl. LDP/STP,
  pre/post/unscaled/register-offset, **STTR/LDTR** (true unprivileged
  semantics), **STNP/LDNP** (non-temporal pair), exclusives, acquire/release,
  **FEAT_LSE** atomics (LDADD/…/SWP/CAS/CASP/LDAPR), **FEAT_LRCPC2**
  LDAPUR/STLUR, the **FEAT_FLAGM/FLAGM2** flag-manipulation set
  (CFINV/RMIF/SETF8/SETF16/AXFLAG/XAFLAG), and **FEAT_MOPS** memory
  copy/set (CPYx/CPYFx/SETx, Option A, incl. the unprivileged forms and
  the EC 0x27 mismatch exception).
- **System level**: EL0/EL1, MSR/MRS with a large system-register file, ID
  registers matched to QEMU's cortex-a57 plus the advertised extensions, MMU
  (48-bit VA, 4 KB granule, blocks & pages, AP/XN/AF) with a software TLB and
  an instruction-fetch fast path, exception entry/return (incl. CPACR_EL1.FPEN
  traps), SVC/HVC/SMC/BRK, barriers/CLREX/WFI/WFE, TLBI, DC ZVA, AT
  S1E1R/W→PAR_EL1.
- **FP/SIMD**: scalar floating-point (convert int↔fp, FMOV, FADD/FSUB/FMUL/FDIV,
  FABS/FNEG/FSQRT, FCMP/FCCMP, FCSEL, FCVT, FRINT, FMADD/FMSUB/FNMADD/FNMSUB);
  the comprehensive Advanced-SIMD surface (loads/stores, modified immediate,
  copy, three-same, three-different, across-lanes, two-register misc,
  by-element, shift-by-immediate) with **FEAT_FP16** half-precision arithmetic;
  ARMv8 **crypto** (AES/PMULL/SHA1/SHA256 + **SHA512/SHA3**); and the v8.1–8.4
  ecosystem extensions **FEAT_RDM** (SQRDMLAH/SQRDMLSH), **FEAT_DotProd**
  (SDOT/UDOT), **FEAT_FCMA** (FCMLA/FCADD), **FEAT_FHM** (FMLAL/FMLSL) and
  **FEAT_JSCVT** (FJCVTZS) — each differential-tested against qemu-aarch64
  before its ID nibble was advertised. **FPSR is live**: the cumulative
  exception flags (IOC/DZC/OFC/UFC/IXC), the sticky QC saturation bit, and
  the quiet-vs-signaling FCMP/FCMPE IOC split all accumulate architecturally
  across all three engines.
- **Platform devices**: GICv2, generic timer (periodic IRQs), PL011 serial,
  PL031 RTC, PSCI (HVC/SMC), fw_cfg (data port + DMA, legacy kernel keys),
  **Intel CFI (pflash_cfi01) NOR flash** so EDK2's UEFI variable store works,
  and empty virtio-mmio / PCIe / GICv2m / GPIO transports so probing behaves.

## Differential testing against QEMU (development only)

QEMU is used purely as a *development oracle* — never linked or required to run
`arm64emu`. Two techniques made deep bring-up tractable:

1. **Same-run DTB + coverage.** Boot the same firmware in QEMU, dump its runtime
   device tree from guest memory, and capture `-d in_asm` coverage from the *same
   run* (so the DTB, including its random seed, matches). Reconstruct the full
   set of executed instruction addresses from the `OBJD-T` bytes.
2. **Coverage-divergence finder** (`AECOV=qemu_cov.txt`): run `arm64emu` with the
   identical DTB and stop at the first PC it executes that QEMU never does — i.e.
   the exact point where control flow first leaves QEMU's path. This pinpointed
   each bug (a missing device register, a wrong DTB node, an unimplemented
   instruction) instead of debugging a silent hang.

This located, among others: the virtio-mmio magic value, a too-small device
tree (missing the `cfi-flash`/PCIe/virtio nodes), the CFI flash command set, and
an exception-return bug (instruction-abort ELR pointing at the wrong PC).

## Current state and remaining work

- **Firmware**: boots SEC→PEI→DXE→BDS to the **UEFI Interactive Shell**, with a
  working CFI-flash variable store.
- **Linux**: the EFI-stub kernel boots to **userspace** — kernel init completes,
  `/init` runs, and a **BusyBox shell** is reached over the serial console.
- **Remaining work**: the advertised instruction surface (baseline + FP16 +
  crypto + the v8.1–8.4 ecosystem extensions) is complete and
  differential-tested; what remains unimplemented is deliberately unadvertised
  (PAuth/BTI/MTE/SVE — see `docs/todo/TODO_OPCODES.md`). Engine
  **performance** is ~90 MIPS by default (the predecoded interpreter tier),
  ~40 with `--no-pd` (the plain interpreter), and ~370 with `--jit`, so a full
  distro boot is slow (see *Performance notes* below for why a
  decoded-instruction cache did **not** help).
- **Devices**: **virtio-blk** (`--drive`, disk-backed rootfs), **virtio-net**
  (`--net`, user-mode NAT via the built-in usernet stack in `src/net/`: DHCP,
  DNS redirect, TCP/UDP proxying and `--netfwd` port forwarding over plain
  host sockets — IPv4 only, no TAP/TUN, no external libraries), **virtio-9p**
  (`--virtfs`, host directory sharing), and **virtio-console** (`--console
  virtio`, host-tracking `hvc0` terminal size) are implemented over
  virtio-mmio, alongside the fw_cfg initramfs rootfs.

These are incremental extensions along the path already established. The hard
parts — a correct CPU/MMU/exception core, the device model, the CFI flash and
firmware↔platform contract (DTB, fw_cfg, PSCI), and the full firmware→kernel→
userspace hand-off — are done and validated against QEMU.

## Performance notes

The interpreter runs at **~40 MIPS** (firmware boot prefix, `-O2`, single core).
A pure interpreter spends its time on the per-instruction work itself — fetch,
operand extraction, the ALU/memory operation — not on classifying the opcode.

### JIT (`--jit`, off by default)

An opt-in basic-block JIT (ported from the arm64chroot sibling project)
translates guest code to host x86-64 (an AArch64 backend is included,
validated under qemu-user emulation but untested on real hardware):
**~370 MIPS (≈10×)** on the Linux-boot workload, >99.9% of instructions
native in steady state. The interpreter stays the
default and the reference — `make test-jit` requires byte-identical CPU
state between the modes on a deterministic-clock boot (`AE_RTCLOCK=0`, which the
gate pins). Design, full-system
coherence (SMC store-tracking, block/context keying, IRQ safepoints) and
debug knobs: [docs/jit.md](docs/jit.md).

### Decoded-instruction cache — evaluated, not adopted

A **decoded-instruction cache** (the classic "memoize the decode" interpreter
optimization, *not* a JIT) was implemented and benchmarked, then reverted. It was
a direct-mapped table keyed by PC that cached the resolved group-handler function
pointer for each instruction word, re-validated against the live word on every
hit (so it stayed correct for self-modifying / decompressed code with no flush).

It was **correct** — full CPU state stayed byte-for-byte identical to the plain
interpreter over 50M firmware instructions, at a ~99.99% hit rate — but it **did
not improve throughput; it was ~5–6% slower**. Findings, kept here so the
experiment isn't blindly repeated:

- This decode tree is **shallow and branch-predictable** (a 4-bit top-level
  `switch`, then short per-group chains). The classification a cache hit skips is
  only a handful of correctly-predicted branches — cheaper than what the cache
  adds: an **indirect call** through the cached pointer (mispredicts) plus the
  **data-cache pressure** of a ~1 MB table.
- At ~90 cycles/instruction the hot loop is extremely sensitive: merely *defining*
  the function-pointer classifier inside `decode.c` (taking the handlers'
  addresses) perturbed that translation unit's codegen by ~6%, even when the cache
  was disabled.
- The real lever for a pure interpreter is **operand pre-decode** — caching a
  fully decoded form (opcode id + pre-extracted operands) dispatched via a dense
  `switch`, so a hit skips operand extraction too, not just classification. That
  is exactly the **predecoded tier**, now the default engine (`--no-pd` opts out
  to the plain interpreter): a direct-threaded executor over such a cache,
  ~2.46× the plain interpreter. See [docs/pd.md](docs/pd.md). A function-pointer
  decode cache, by contrast, is not the path forward.

## License

**Apache License 2.0** — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

arm64emu is original, clean-room code (C11, libc/POSIX only) and shares no
source with QEMU, EDK2, or the Linux kernel; it interoperates with them purely
through their public hardware/software interfaces. EDK2 firmware and Linux
kernel/initramfs images are supplied by you at runtime and are neither bundled
nor distributed here. Apache-2.0 was chosen for its permissive terms plus an
explicit patent grant. Each source file carries an `SPDX-License-Identifier:
Apache-2.0` tag; `src/fdt/virt.dts` is QEMU-generated device-tree data and is
exempt (see NOTICE).

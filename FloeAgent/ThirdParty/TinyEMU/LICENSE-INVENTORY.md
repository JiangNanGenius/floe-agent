# TinyEMU 2019-12-21 — per-file license inventory

Verified 2026-09-20 against the pinned tarball
`tinyemu-2019-12-21.tar.gz` (SHA256
`be8351f2121819b3172fcedce5cb1826fa12c87da1b7ed98f269d3e802a05555`).

Upstream rule (`readme.txt` §5): *"TinyEMU is released under the MIT
license. If there is no explicit license in a file, the license from
MIT-LICENSE.txt applies. The SLIRP library has its own license (two clause
BSD license)."*

## Files actually linked into the Floe embeddable build

| File(s) | License | Evidence |
| --- | --- | --- |
| `virtio.c`, `pci.c`, `fs.c`, `cutils.c`, `iomem.c`, `simplefb.c`, `json.c`, `machine.c`, `fs_disk.c`, `riscv_machine.c`, `riscv_cpu.c`, `softfp.c` (+ their headers, `list.h`, `iomem.h`, `virtio.h`, `machine.h`, `fs.h`, `fs_utils.h`*, `riscv_cpu*.h`) | MIT (Fabrice Bellard) | explicit MIT header in each `.c`; headers covered by readme default rule |
| `slirp/*.c` `slirp/*.h` used: `bootp cksum if ip_icmp ip_input ip_output mbuf misc sbuf slirp socket tcp_input tcp_output tcp_subr tcp_timer udp` + headers | 2-clause BSD (per upstream readme); individual files carry UC Regents BSD and/or Danny Gasparovski copyright headers | `slirp/tcp_input.c` UC Regents BSD header; `slirp/socket.c`, `slirp/if.c` "Copyright (c) 1995 Danny Gasparovski … see COPYRIGHT" |

*`fs_utils.h` is only referenced on the disabled HTTP-FS path; inventory kept for completeness.

## Files present in the tarball but EXCLUDED from the Floe build

| File(s) | License | Why excluded |
| --- | --- | --- |
| `sdl.c` | MIT | no SDL dependency (console-only embedding) |
| `x86_cpu.c`, `x86_machine.c`, `ide.c`, `ps2.c`, `vmmouse.c`, `pckbd.c`, `vga.c`, `fbuf.h`, `ps2.h` | MIT | x86 emulator off (RV64 only) |
| `fs_net.c`, `fs_wget.c`, `fs_utils.c`, `block_net.c`, `fs_wget.h` | MIT | HTTP network filesystem off — drops libcurl + OpenSSL |
| `aes.c` | public domain (Rijndael reference implementation, Rijmen/Bosselaers/Barreto) | only used by HTTP-FS |
| `sha256.c` | public domain (LibTomCrypt, Tom St Denis — "free for all purposes") | only used by HTTP-FS |
| `jsemu.c`, `js/`, `Makefile.js` | MIT (readme default) | browser/WebAssembly host, unused |
| `temu.c` | MIT | CLI main(); its block-device + slirp glue is re-hosted with attribution in `adapter/floe_vm.c` |
| `build_filelist.c`, `splitimg.c` | MIT | HTTP-FS tooling |
| `netinit.sh`, `Changelog`, `VERSION`, `readme.txt`, `MIT-LICENSE.txt` | MIT (readme default) | docs/meta |

## Engine-level conclusion

Every object linked into `libfloevm.a` is MIT or 2-clause BSD. **No
GPL/LGPL source is used by the engine**, and no code was taken from QEMU
(GPL) or iSH (GPL); TinyEMU is an independent MIT implementation by
Fabrice Bellard.

## Guest-side GPL separation (host gate invariant)

The *guest* images used for qualification (TinyEMU buildroot demo, Debian
13 riscv64) contain GPL-licensed software (Linux kernel, busybox, GNU
userland). They run **inside** the emulator, are never linked into or
shipped by the host app, and carry their own license/source-availability
obligations, which must be inventoried separately before any user-facing
distribution of a guest image. The MIT engine license does **not** cover
guest contents. The existing Floe host GPL gate continues to apply to all
host-linked code.

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

## Complete license/copyright texts on record (added 2026-09-20)

The pinned tarball ships only `MIT-LICENSE.txt`; the slirp files reference a
`COPYRIGHT` file it does not contain. Both applicable texts are now kept
next to the engine so review does not depend on re-deriving them:

| File | sha256 | Origin |
| --- | --- | --- |
| `MIT-LICENSE.txt` | `a75690160a50d8085bcd25acf34faa5b1c484e15ffd0bd662e5f4d7a289da080` | verbatim copy from the pinned tarball |
| `licenses/SLIRP-COPYRIGHT.txt` | `6aa542ccb77b884dbb8e8c4620f3471111e5648fe341147befcf933ea30d764f` | restored verbatim from `raw.githubusercontent.com/qemu/qemu/v3.1.0/slirp/COPYRIGHT` (identical at v2.5.0/v2.12.0); the later v4.0.0 variant adds a third clause (sha256 `b28aecf4796a6a22054167f0a976de13d9db335669d37afd2dc7ea4c335e1e13`). See `licenses/README.md` |

Consequently the slirp rows above are **BSD-2-clause** terms for the
Gasparovski-only files (`mbuf.c`, `socket.c`, `if.c`, `misc.c`, `sbuf.c`,
`bootp.c`, ...) and the **full 3-clause BSD notice inline** for the
FreeBSD-derived files (`tcp_input.c`, `tcp_output.c`, `tcp_subr.c`,
`tcp_timer.c`, `udp.c`, `cksum.c`, `ip_input.c`, `ip_output.c`,
`ip_icmp.c`). The conclusion does not change: no GPL/LGPL in the host
engine build.

## Engine patch set (core)

| Patch | Applies to | Purpose |
| --- | --- | --- |
| `patches/0001-htif-poweroff-callback.patch` | `riscv_machine.c` | guest poweroff becomes an observable flag instead of `exit(0)` |
| `patches/0002-embeddable-error-propagation.patch` | `riscv_machine.c` (after 0001), `iomem.c` | recoverable create failures: RAM OOM returns NULL, `copy_bios` returns 0/-1 with bounds checks before `memcpy` |
| `patches/0003-fs_disk-apple-stat-timestamps.patch` | `fs_disk.c` | Apple SDK stat-timestamp member names for the vendored/SwiftPM copy |
| `patches/0004-slirp-bootp-debug-typo.patch` | `slirp/bootp.c` | upstream typo that only compiles with DEBUG undefined |
| `patches/0005-fence-hints.patch` | `riscv_cpu_template.h` | treat FENCE/FENCE.TSO and reserved fm encodings as the no-op hints the base ISA defines, and ignore fence.i's unused fields (Zifencei). Upstream trapped FENCE.TSO, which Debian 13's libapt-pkg executes — apt's http/https methods died with SIGILL |
| `patches/0006-slirp-per-instance-state.patch` | `slirp/slirp.{c,h}`, `slirp/{socket,udp,ip_icmp,tcp_subr}.c`, `slirp/{main,libslirp}.h` | move the process-wide slirp timers, DNS cache and select scratch into `struct Slirp`, make `get_dns_addr` take its instance explicitly and initialise the remaining constant global (`loopback_addr`) with `pthread_once`; lets two networked VMs run on two host threads (no TLS) |
| `patches/0007-9p-export-root-containment.patch` | `fs_disk.c` (after 0003) | fd-based 9p export-root containment: root pinned as `root_fd`, every fid is a contained dir fd + single component, all authority via `*at()` syscalls with `O_NOFOLLOW`; "..", "/", absolute/relative symlink targets and renames cannot escape; FIFOs/device nodes are metadata-only (`EOPNOTSUPP`, never opened) |
| `patches/0008-recoverable-guest-fault-paths.patch` | `virtio.c` | replace the remaining guest-reachable `abort()`/unchecked allocations with device errors: unknown virtio-blk request types answer `VIRTIO_BLK_S_UNSUPP`, guest-controlled descriptor sizes/allocation failures return an error instead of aborting or writing through NULL, and empty 9p replies (Tclunk/Tfsync) are still sent |

The integrated app vendor tree (`FloeAgent/ThirdParty/TinyEMU/Sources/`,
SwiftPM target `FloeTinyEMU`) carries the same `0001`-`0008` set; the
qualification build and the vendored tree must both apply them in numeric
order. `0002` must be applied after `0001` to the same `riscv_machine.c`
copy, and `0007` after `0003` to the same `fs_disk.c` copy; the vendoring
script has to keep that order. `0005` patches `riscv_cpu_template.h`, so any
tree that compiles `riscv_cpu.c` must compile it where the patched header is
visible (the qualification Makefile copies `riscv_cpu.c` plus the header into
`$(BUILD)` for that reason). `0006`/`0007`/`0008` are Floe-authored
MIT-compatible modifications of MIT/BSD files: no new upstream code, no
GPL/LGPL.

## Guest image licensing

See [GUEST-IMAGE-MANIFEST.md](../../../docs/FLOE_LINUX_GUEST_IMAGE_MANIFEST.md)
for the exact boot loader/kernel revisions, the kernel config, the Debian
userland obligations and the concrete gaps that currently make the candidate
image **not distributable as a bundled artifact**.

## Guest-side GPL separation (host gate invariant)

The *guest* images used for qualification (TinyEMU buildroot demo, Debian
13 riscv64) contain GPL-licensed software (Linux kernel, busybox, GNU
userland). They run **inside** the emulator, are never linked into or
shipped by the host app, and carry their own license/source-availability
obligations, which must be inventoried separately before any user-facing
distribution of a guest image. The MIT engine license does **not** cover
guest contents. The existing Floe host GPL gate continues to apply to all
host-linked code.

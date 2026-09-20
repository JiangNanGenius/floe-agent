# Third-party license texts restored from upstream archives

The pinned TinyEMU tarball (`tinyemu-2019-12-21.tar.gz`, sha256
`be8351f2121819b3172fcedce5cb1826fa12c87da1b7ed98f269d3e802a05555`)
ships only `MIT-LICENSE.txt`. Several files in `slirp/` carry the classic
slirp header

```
 * Copyright (c) 1995 Danny Gasparovski.
 *
 * Please read the file COPYRIGHT for the
 * terms and conditions of the copyright.
```

but the tarball contains **no COPYRIGHT file**. Because the engine build
compiles those files (`slirp/mbuf.c`, `socket.c`, `if.c`, `misc.c`,
`sbuf.c`, `bootp.c`, ...), the applicable terms must be on record. The text
below was restored verbatim from an upstream archive that still ships it.

| File | Source | sha256 |
| --- | --- | --- |
| `MIT-LICENSE.txt` | pinned tarball (verbatim copy) | `a75690160a50d8085bcd25acf34faa5b1c484e15ffd0bd662e5f4d7a289da080` |
| `licenses/SLIRP-COPYRIGHT.txt` | `https://raw.githubusercontent.com/qemu/qemu/v3.1.0/slirp/COPYRIGHT` (identical at v2.5.0/v2.12.0; BSD-2-clause text) | `6aa542ccb77b884dbb8e8c4620f3471111e5648fe341147befcf933ea30d764f` |

Notes for review:

- The restored slirp text is the classic BSD-2-clause grant from
  Danny Gasparovski (1995,1996). QEMU v4.0.0 carries a later variant of the
  same file that adds a third clause ("neither the name of the copyright
  holder nor the names of its contributors..."), sha256
  `b28aecf4796a6a22054167f0a976de13d9db335669d37afd2dc7ea4c335e1e13`,
  also from `raw.githubusercontent.com/qemu/qemu/v4.0.0/slirp/COPYRIGHT`.
  TinyEMU's slirp is a 2016-2017 snapshot of the classic tree, so the
  BSD-2 text is the one recorded as applicable; both variants are
  permissive and compatible with the MIT terms of Bellard's own changes.
- Files derived from FreeBSD (e.g. `slirp/tcp_input.c`, `slirp/cksum.c`,
  `slirp/ip_icmp.c`) already carry the full 3-clause BSD notice from the
  Regents of the University of California inline; nothing was restored for
  them.
- Nothing in the compiled subset is GPL/LGPL; the host-side GPL gate
  (`license_check.sh`) is unchanged. Guest-side components (Linux kernel,
  bbl, Debian packages, the static runner's glibc) are tracked separately in
  [`docs/FLOE_LINUX_GUEST_IMAGE_MANIFEST.md`](../../../docs/FLOE_LINUX_GUEST_IMAGE_MANIFEST.md).

This directory is documentation only; it changes no build input.

# Qualification guest build record (from the pinned 2018 demo archive)

Verbatim copies of the build material shipped inside the pinned demo archive
`diskimage-linux-riscv-2018-09-23.tar.gz`
(sha256 `808ecc1b32efdd76103172129b77b46002a616dff2270664207c291e4fde9e14`,
`https://bellard.org/tinyemu/diskimage-linux-riscv-2018-09-23.tar.gz`,
`patches/` subdirectory). They are kept in-tree so the corresponding-source
audit in [`docs/FLOE_LINUX_GUEST_IMAGE_MANIFEST.md`](../../../../docs/FLOE_LINUX_GUEST_IMAGE_MANIFEST.md)
is reviewable without re-downloading the archive.

| File | sha256 | Upstream revision it applies to |
| --- | --- | --- |
| `readme.txt` | `a05f71a1ac4661bae2e772f2982dd9f6d0ef5ce944f304b49ffd93272a3dd832` | names the exact revisions below |
| `riscv-pk.diff` | `ee5c9335ff9f7501d04b1f50dbf95c66ce7d22aaaf5bcc102eeae51f2b825fcf` | riscv-pk `ac2c910b18c3e36cfd85080472e78ad2fe484325` (BSD-3-Clause) |
| `riscv-linux.diff` | `48999c3aca770205b6cd01546e429f431a4d01f3d28c5317568a06849804409d` | riscv-linux `a3b1e7acc6a181e04e9a943942084395df4498dd` (GPL-2.0) |
| `config_linux_riscv64` | `442e3380b626a19eeed01f2142284fc7ba58e2829f5f7162e9e3f44bce65d2af` | exact kernel `.config` for `kernel-riscv64.bin` |

These are third-party files kept for provenance/audit; they are not compiled
by the Floe host build. The corresponding full source trees are still hosted
upstream at the revisions above (verified reachable 2026-09-20) and would
have to be mirrored together with these files, their license texts and the
build toolchain before any guest image is distributed — see the manifest for
the open gaps.

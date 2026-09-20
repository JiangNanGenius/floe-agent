# Floe Linux guest image — source and license manifest (candidate)

Status: **the current guest image is NOT yet distributable as a bundled
artifact.** This document records exactly which sources and licenses are
identified, which corresponding-source material is already on hand, and
which gaps remain. It complements `LICENSE-INVENTORY.md` (host engine only)
and is intentionally separate: the MIT host engine and the guest components
keep their own licenses; nothing here requires relicensing the Floe host.

Pinned demo archive: `diskimage-linux-riscv-2018-09-23.tar.gz`
(sha256 `808ecc1b32efdd76103172129b77b46002a616dff2270664207c291e4fde9e14`,
`https://bellard.org/tinyemu/diskimage-linux-riscv-2018-09-23.tar.gz`).
Its `patches/readme.txt` names the exact upstream revisions that built the
boot loader and kernel:

```
riscv-pk    ac2c910b18c3e36cfd85080472e78ad2fe484325
riscv-linux a3b1e7acc6a181e04e9a943942084395df4498dd
```

| Component | Artifact | Exact source | License | Material on hand | Remaining gap |
| --- | --- | --- | --- | --- | --- |
| Boot loader | `bbl64.bin` | riscv-pk `ac2c910b18c3e36cfd85080472e78ad2fe484325` (verified reachable 2026-09-20) | BSD-3-Clause (Regents of the University of California, 2013; `LICENSE` verified) | `FloeAgent/ThirdParty/TinyEMU/guest-image/riscv-pk.diff` + `readme.txt` (in-tree) | Toolchain/build recipe beyond the archive's configs is not pinned; no source tarball mirrored by us |
| Kernel | `kernel-riscv64.bin` (`Linux 4.15.0-00049-ga3b1e7a-dirty`) | riscv-linux `a3b1e7acc6a181e04e9a943942084395df4498dd` (verified reachable; `COPYING` GPL-2.0 available) | GPL-2.0 | `guest-image/riscv-linux.diff` + exact `guest-image/config_linux_riscv64` (in-tree) | No source mirror held by us; no rebuild attempted (no local kernel builds by policy) |
| 2018 demo rootfs | `root-riscv64.bin` | buildroot (busybox + kernel) | GPL-2.0 and others | buildroot/root configs inside the demo archive (not vendored) | **Qualification-only, never distributed** — unchanged conclusion |
| Candidate userland | Debian 13 (trixie) riscv64 nocloud cloud image | fetched at run time from `cdimage.debian.org` (daily; resolved SHA512 recorded per run, e.g. `6e417af7e77963ea…`) | per-package (Debian `copyright` files) | fetched image, `dpkg -l` listing, apt logs in the qualification evidence | **No package→copyright/source manifest generated; daily image is not digest-pinned.** Bundling requires mirroring corresponding sources or distributing only as an on-device download from Debian with their source availability |
| Floe guest runner (source) | `/usr/local/bin/floe-exec` (injected) | this repository (`FloeAgent/LinuxGuest/`) | MPL-2.0 (repository license) | source in-tree; CI builds a static riscv64 binary and records its sha256 | none |
| Floe guest runner (static runtime) | same binary embeds a **static glibc** | cross toolchain `gcc-riscv64-linux-gnu` on ubuntu-latest (glibc from that toolchain) | LGPL-2.1 (glibc) | none yet | A statically linked glibc is redistributed inside the image, so the image must carry glibc's license text and the corresponding source (or object files/relinkable material per LGPL §6, plus the exact toolchain/version record). Recorded now; nothing is distributed yet. |

Modifications Floe applies to the candidate image (documentation of changes,
not source obligations): clear `orphan_file` / `metadata_csum_seed` on the
ext4 rootfs so the 4.15 fallback kernel can mount it, and extract the ext4
partition into a partitionless image (the pinned 2018 kernel has no GPT
parser). No package content is modified.

### Who distributes what (download-on-demand is not a general exemption)

Three different situations must stay separate, because the obligations are
not the same:

1. **Device downloads the unmodified stock image directly from Debian.**
   Floe hosts and modifies nothing; Debian's archive is the distribution and
   carries its own source availability. Floe must still describe the content
   honestly and keep its notices accurate.
2. **Floe hosts, mirrors, rebuilds or modifies an image** (what the current
   candidate is: ext4 features cleared, partition layout replaced, runner
   injected, app-facing download entry). Then Floe is a distributor of that
   artifact and owes the corresponding source/offers for every GPL/LGPL
   component in it — including glibc if it is statically linked into the
   runner — regardless of where the original came from.
3. **Qualification-only artifacts** (demo image, CI-prepared rootfs): never
   shipped to users; kept with their build record only.

So "the user downloads it from Debian" only helps in case 1. A Floe-hosted
or Floe-modified image is case 2 and stays **not distributable** until the
checklist below is complete.

Runtime facts that bound this candidate: the modern Debian 13 kernel (6.12)
does not boot under the 2018 bbl (no console output at all), so this
candidate runs the Debian userland on the pinned 2018 4.15 kernel; package
installation over **HTTPS** currently dies inside apt's https method with
SIGILL (signal 4) and is under investigation (evidence in the qualification
run artifacts). Do not advertise the candidate as a complete, fully working
Linux.

## Distribution checklist (required before any bundled image ships)

1. Package the corresponding source for the kernel and boot loader from the
   exact revisions above together with `FloeAgent/ThirdParty/TinyEMU/guest-image/riscv-linux.diff`,
   `.../riscv-pk.diff` and `.../config_linux_riscv64`, plus the
   applicable license texts (GPL-2.0 `COPYING`, riscv-pk BSD-3 `LICENSE`) —
   or provide a valid written offer. Mirroring is required if the upstream
   repositories are not guaranteed to remain reachable.
2. Pin the Debian image by digest instead of the rotating daily build, and
   generate a per-package copyright/source manifest for the installed set
   (`dpkg-query` + `/usr/share/doc/*/copyright`, sources.debian.org), or
   keep distribution download-on-demand from Debian.
3. Feed the notices into the app's open-source acknowledgements path
   (host engine MIT/BSD/PD + restored slirp COPYRIGHT + any guest notices
   actually shipped).
4. Include the statically linked glibc from the guest runner (LGPL-2.1):
   glibc license text plus corresponding source or relinkable object files
   and the exact cross-toolchain record.
5. Re-verify this manifest against the exact artifact that ships; a
   download list entry does not by itself satisfy license obligations, and
   neither does pointing at Debian once Floe hosts or modifies the image.

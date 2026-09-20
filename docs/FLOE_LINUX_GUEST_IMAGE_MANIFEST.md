# Floe Linux guest image — source and license manifest (candidate)

Status: **the current guest image is NOT yet distributable as a bundled
artifact.** This document records exactly which sources and licenses are
identified, which corresponding-source material is already on hand, and
which gaps remain. It complements `LICENSE-INVENTORY.md` (host engine only)
and is intentionally separate: the MIT host engine and the guest components
keep their own licenses; nothing here requires relicensing the Floe host.

The component pipeline that builds, boot-verifies and source-packages a
candidate (inputs pinned in
[`pinned-inputs.json`](../FloeAgent/ThirdParty/TinyEMU/guest-image/pinned-inputs.json))
is documented in [the build guide](FLOE_LINUX_GUEST_IMAGE_BUILD.md). Its
artifacts are GitHub component artifacts with recorded digests; they are not a
public release, and the source bundle they contain is not yet a published
source offer.

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
| Boot loader | `bbl64.bin` | riscv-pk `ac2c910b18c3e36cfd85080472e78ad2fe484325` (verified reachable 2026-09-20) | BSD-3-Clause (Regents of the University of California, 2013; `LICENSE` verified) | diff + `readme.txt` in-tree; `build-kernel-bbl.sh` fetches the revision, applies the diff and packages `upstream/riscv-pk-<rev>-src.tar.gz` + LICENSE in the component artifact | No rebuild was run (`compile_verified: false` in the pins); the bundle is not yet published as a source offer |
| Kernel | `kernel-riscv64.bin` (`Linux 4.15.0-00049-ga3b1e7a-dirty`) | riscv-linux `a3b1e7acc6a181e04e9a943942084395df4498dd` (verified reachable; `COPYING` GPL-2.0 available) | GPL-2.0 | diff + exact `config_linux_riscv64` in-tree; same script packages `upstream/riscv-linux-<rev>-src.tar.gz` (diff applied), config and COPYING with SHA-512 digests | No rebuild was run in CI (`--rebuild` exists and is documented); the bundle is not yet published as a source offer |
| 2018 demo rootfs | `root-riscv64.bin` | buildroot (busybox + kernel) | GPL-2.0 and others | buildroot/root configs inside the demo archive (not vendored) | **Qualification-only, never distributed** — unchanged conclusion |
| Candidate userland | Debian 13 (trixie) riscv64 nocloud cloud image | dated daily build `20260920-2607`, sha512 `7106e0d8…`, sha256 `bd477108…` (digest-pinned; build fails closed if the dated URL rotates or bytes change) | per-package (Debian `copyright` files) | fetched image + apt logs + `dpkg-query` inventory (657 packages) + `/usr/share/doc/*/copyright` bundle in the evidence artifact; binary→source→file→sha256 mapping and the verified `.dsc`/orig/debian downloads in the source artifact | Corresponding sources exist as component artifacts but are **not published as a source offer**; unmapped packages (if any) are listed in `debian-source-gaps.tsv` and must be resolved first |
| Floe guest runner (source) | `/usr/local/bin/floe-exec` (injected) | this repository (`FloeAgent/LinuxGuest/`) | MPL-2.0 (repository license) | source in-tree; CI builds a static riscv64 binary and records its sha256 (`360fede9…` for the run recorded in the qualification log) plus the relink object | none |
| Floe guest runner (static runtime) | same binary embeds a **static glibc** | cross toolchain `gcc-riscv64-linux-gnu` on ubuntu-latest (`libc6-dev-riscv64-cross` 2.39, gcc 13.3.0) | LGPL-2.1 (glibc) | `runner-relink/` carries `floe_exec.c`, `floe_clock.h`, the compiled `.o`, the exact link command, the toolchain versions and `RELINK.md`; `toolchain-source/` holds the distribution source packages when the fetch succeeds | The bundle is not published; the glibc source fetch is best-effort and reported as a gap when the distribution source is unavailable |

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
candidate runs the Debian userland on the pinned 2018 4.15 kernel.
Package installation died inside apt's http/https methods with SIGILL
(signal 4) because the engine trapped `FENCE.TSO` (0x8330000f) as illegal;
`libapt-pkg.so.7.0.0` executes it at exactly the faulting offset, and
`patches/0005-fence-hints.patch` implements the stronger ordinary-fence
ordering already provided by this single-hart interpreter. Run 35500083112
then passed real HTTPS APT update/install, NumPy, Node and Python HTTPS.
Build 207 has no Linux backend; cancelled build 208 predates this fix.
These results do not yet qualify a downloadable image: final runner clock,
package ownership and the corresponding-source artifacts must be completed.

Two further runtime facts. The guest kernel has no RTC (`CONFIG_RTC_CLASS`
off), so the host appends `floe.epoch=<unix seconds>` to the kernel command
line on every boot and the guest runner consumes it as PID 1
(`FloeAgent/LinuxGuest/runner/floe_clock.h`, host `LinuxGuestBootArguments`);
every image boot is verified with that parameter, never with a `date -s`
workaround. And the direct FENCE instruction probe from run 35500083112
emitted **no** markers because of a harness indentation bug, not an engine
result; the probe code is fixed and the candidate build re-runs it while
recording the actual status. Until that corrected output exists, the probe is
neither claimed as passing nor as failing — the APT/NumPy/Node/HTTPS
capability stands on its own independent evidence.

## Concrete follow-up artifacts (planned, none published yet)

| Artifact | How to produce it | Why |
| --- | --- | --- |
| `image-manifest.json` | by the image build/qualification job: image digest, kernel/bbl revisions + patch hashes, rootfs size, `dpkg-query -W` hash, runner sha256, toolchain versions | one reviewable record per released image |
| `guest-package-manifest.txt` + `guest-copyrights.tar` | in the guest: `dpkg-query -W -f='${Package} ${Version} ${Architecture}\n'` plus `/usr/share/doc/*/copyright` | per-package license/source mapping for the installed set |
| `source/` mirror | fetch riscv-linux @ `a3b1e7a…` and riscv-pk @ `ac2c910b…` plus the two diffs and the kernel config (already in `FloeAgent/ThirdParty/TinyEMU/guest-image/`) and host them next to the image | GPL-2.0/BSD-3 corresponding source without depending on upstream availability |
| `glibc/` record | glibc version of the cross toolchain plus its source or relinkable objects for the static runner | LGPL-2.1 §6 for the statically linked runner |
| notices bundle | host engine MIT/BSD texts (`MIT-LICENSE.txt`, `licenses/SLIRP-COPYRIGHT.txt`, inline Regents BSD) + guest notices | app open-source acknowledgements path |

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

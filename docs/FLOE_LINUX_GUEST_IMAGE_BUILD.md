# Floe Linux guest image — build and verification guide

Status: the component pipeline in
[`.github/workflows/component-image-ci.yml`](../../.github/workflows/component-image-ci.yml)
builds and boot-verifies a **candidate** image and its corresponding-source
bundle as GitHub component artifacts. Nothing here is published, no app
version/tag changes, and the image stays `distributionAllowed: false` until the
primary release decision pins the archive digest in
`LinuxGuestImageDistributionCatalog` **and** publishes the source offer.

Companion documents:
[source/license manifest](FLOE_LINUX_GUEST_IMAGE_MANIFEST.md) ·
[guest backend contract](FLOE_LINUX_GUEST_BACKEND.md) ·
[guest runner README](../../FloeAgent/LinuxGuest/README.md).

## Pinned inputs

Every value is in
[`pinned-inputs.json`](../../FloeAgent/ThirdParty/TinyEMU/guest-image/pinned-inputs.json)
and is verified by the build, not trusted:

| Input | Pin |
| --- | --- |
| TinyEMU engine | `tinyemu-2019-12-21.tar.gz`, sha256 `be8351f2…`, patches 0001/0002/0005 (FENCE family) |
| Boot loader | `riscv-pk` `ac2c910b18c3e36cfd85080472e78ad2fe484325` + `riscv-pk.diff` |
| Kernel | `riscv-linux` `a3b1e7acc6a181e04e9a943942084395df4498dd` + `riscv-linux.diff` + `config_linux_riscv64` |
| Demo archive | `diskimage-linux-riscv-2018-09-23.tar.gz`, sha256 `808ecc1b…` (only `bbl64.bin` + `kernel-riscv64.bin` are used; the buildroot rootfs is never shipped) |
| Debian userland | trixie nocloud riscv64 daily build `20260920-2607` from its dated URL, sha512 `7106e0d8…`, sha256 `bd477108…`, 410 189 824 bytes |
| Guest runner | `FloeAgent/LinuxGuest/runner`, static riscv64, `floe.epoch=` PID1 contract |

The daily directory is digest-pinned: if Debian rotates it or the bytes
change, the build fails instead of silently using another daily image.

## What the build does (and why each step exists)

`build-guest-image.sh` (Linux, root) runs the whole pipeline; the workflow
just installs host tools and calls it.

1. fetch + SHA-256 the engine and demo archive
   (`FloeAgent/ThirdParty/TinyEMU/fetch_source.sh`);
2. build `libfloevm.a` + `floe_vm_host` with the pinned patches; the build
   fails unless the FENCE patch marker is in the compiled header (upstream
   TinyEMU trapped `FENCE.TSO`, which killed Debian's `libapt-pkg` with SIGILL);
3. download the dated Debian qcow2 and verify size + SHA-512 + SHA-256;
4. convert to raw, clear the two ext4 features the 4.15 fallback kernel cannot
   mount (`orphan_file`, `metadata_csum_seed`), and `dd` the ext4 partition
   out as a partitionless whole-disk image — the 2018 bbl has no EFI/GPT
   parser, so the guest boots `root=/dev/vda`, not a partition;
5. cross-build the static riscv64 runner (plus the relink object used for the
   LGPL glibc obligation);
6. inject `/usr/local/bin/floe-exec` (and the optional
   `/usr/local/lib/floe/floe-guest-init`) with `install-into-image.sh`;
7. **boot A** — the runner is PID 1, reads `floe.epoch=<unix seconds>` from the
   kernel command line and sets `CLOCK_REALTIME` before accepting any frame.
   Stage 1 then brings up slirp networking, runs a real signed-HTTPS
   `apt-get update`, installs the capability packages, and exports the
   `dpkg-query` inventory used for the source mapping;
8. **boot B** — a fresh `floe.epoch`; stage 2 re-checks the clock against the
   host value, repeats signed HTTPS `apt-get update`, runs a Python HTTPS
   request with the default CA store, and exercises the 13 commands from the
   user feedback report: 11 as real operations, `ssh` as a version/presence
   check and `scp` as a negative client attempt (no sshd in the image);
9. `e2fsck` the disk, collect evidence (dpkg inventory, copyright files,
   common licenses, ext4 features, apt logs, transcripts), write
   `manifest.json` in the `LinuxGuestImage` schema, and package the zip.

## Verification gates (the run fails, keeping transcripts, if any is missing)

| Marker | Proves |
| --- | --- |
| `floe-exec: clock set from floe.epoch=` | the runner consumed the host bootstrap clock as PID 1 |
| `FLOE_STAGE{1,2}_CLOCK_OK` | guest `date +%s` is within 300 s (boot A) / 120 s (boot B) of the host value |
| `FLOE_STAGE1_APT_UPDATE_RC_0`, `FLOE_STAGE{1,2}_APT_INSTALL_RC_0` | signed HTTPS APT update/install with normal verification |
| `FLOE_STAGE2_PY_HTTPS_200` | Python `urllib` with the default CA store reached `deb.debian.org` |
| `FLOE_CMD_{ps,setsid,nohup,bash,zsh,zip,unzip,7z,xz,bzip2,sqlite3}_OK` | those 11 commands performed real work |
| `FLOE_CMD_ssh_OK`, `FLOE_CMD_scp_OK` | client presence/version and a negative client attempt only; no transfer is claimed |
| `FLOE-END boot{A,B} 0` | the runner returned exit 0 for the whole guest script |

Not proven by these gates, and intentionally not claimed: iPad/device
performance, interactive use, or that the guest userland is complete. The
`FLOE_INSN_*` lines are the FENCE/instruction probe (diagnostic): the run
records their actual status and never reports a probe as passing unless the
line says `OK`.

## Corresponding-source bundle

`collect-corresponding-sources.sh` assembles four parts (see
`SOURCES-MANIFEST.md` in the artifact):

1. `upstream/` — kernel and bbl source trees at the exact revisions with the
   demo diffs applied, plus `SOURCE-MANIFEST.md` and the config;
2. `runner-relink/` — `floe_exec.c`, `floe_clock.h`, the compiled
   `floe-exec-riscv64.o`, the exact link command/toolchain record and
   `RELINK.md` for the LGPL-2.1 §6 relink path;
3. `toolchain-source/` — the distribution source packages for the cross
   compiler/glibc used for the static runner (recorded; fetch failure is
   reported as a gap, never silently skipped);
4. `debian-sources/shard-N/` — every installed binary package mapped to its
   exact source package version and `.dsc`/orig/debian files, downloaded with
   SHA-256 verification. Shards keep each upload below the per-artifact size
   limit; `SOURCES.sha256` holds paths relative to `debian-sources/`, so
   `sha256sum -c SOURCES.sha256` works once all shards are unpacked together.

Unmapped packages (if any) land in `debian-source-gaps.tsv` and must be
resolved before public distribution; the run reports them instead of hiding
them.

## Reproducing locally (Linux)

```sh
sudo apt-get install qemu-utils parted e2fsprogs gcc-riscv64-linux-gnu zip unzip
sudo bash FloeAgent/LinuxGuest/image/build-guest-image.sh \
    --work /tmp/floe-image-work \
    --run-url https://github.com/<owner>/<repo>/actions/runs/<id>

# corresponding sources (needs ~5 GB scratch and a fast mirror)
sudo bash FloeAgent/LinuxGuest/image/collect-corresponding-sources.sh \
    --out /tmp/floe-sources \
    --packages /tmp/floe-image-work/evidence/guest-packages.tsv \
    --image-evidence /tmp/floe-image-work/evidence
```

`--skip-fetch`/`--skip-engine` reuse a previous run's downloads and engine
build so a retry does not rebuild already-qualified components. The workflow
keeps `image` and `sources` as separate jobs for the same reason.

## Honest limits of the candidate

- **Not distributable yet.** The manifest records
  `provenance.distributionAllowed: false` and the app catalog stays empty, so
  the official download entry keeps reporting "no distributable image".
  Distribution needs the source offer published at a stable URL plus the
  archive SHA-512 pinned in `LinuxGuestImageDistributionCatalog`.
- **`ssh`/`scp` checks are client-side.** The image ships `openssh-client`; it
  has no `sshd`. `ssh` is verified by its version output only, and `scp` by a
  negative attempt (`localhost:1`, rc 255, first line `socket: Address family
  not supported by protocol`). A real connection or transfer was **not**
  tested and is left to user testing.
- **Networking is not automatic.** The runner mounts the filesystems; the
  guest still needs `ip link/addr/route` plus `nameserver 10.0.2.3` (exactly
  what the build scripts do) before APT/HTTPS works. The app currently starts
  Linux environments with networking disabled.
- **Image size.** The extracted rootfs is ~3.1 GB raw; the zip is compressed
  and bounded by the app's import limits (≤2 GiB archive, ≤4 GiB extracted,
  ≤128 entries). A shrunk rootfs is an optimization, not implemented here.
- **No device run exists.** iPad performance under the interpreter is
  unmeasured; do not extrapolate from CI.
- **Debian daily builds rotate.** The dated URL is the pin; when it
  disappears, the build fails closed and the pins must be updated in a
  reviewed commit (with a fresh qualification run for the new userland bytes).

## Updating the pins

Change `pinned-inputs.json` only as a deliberate upgrade: a new Debian daily
build needs its SHA-512/SHA-256/size and a fresh image run; a new kernel/bbl
revision needs the matching diff/config and a fresh capability run. Never edit
a digest to make a check pass.

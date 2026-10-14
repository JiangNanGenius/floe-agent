# Bundled Linux guest boot pair — license and corresponding-source record

Audit record for the two boot files the app bundles as data resources
(Linux 6.18.56 Image + OpenSBI 1.9 `fw_jump`, adopted with the kernel upgrade,
2026-10-15). It records verifiable facts and open items; it is **not** a legal
certification. The canonical byte pin is
[`boot-pair-v2.manifest.json`](boot-pair-v2.manifest.json) in this directory.

## 1. Bundled files

| App bundle resource | Size | sha256 | License |
| --- | --- | --- | --- |
| `bundled-boot-pair/kernel-6.18.56-riscv64.bin` | 25,267,712 B | `6bb99c015997491bb381148f4a28ed7daa17cb95e26329a8b6715af0bc0db1ca` | GPL-2.0 (Linux kernel, `GPL-2.0 WITH Linux-syscall-note` per its `COPYING`) |
| `bundled-boot-pair/opensbi_fw_jump.bin` | 277,840 B | `7120e57cb8e97e40af5f3a9602c757e281f444d3c0c8673f2923a4530ec0d336` | BSD-2-Clause (OpenSBI) |

`stage-boot-pair.sh` copies only bytes matching the manifest and fails closed on
any size/hash mismatch; `stage-boot-pair.sh --check` re-verifies the staged
resource read-only (wired as an app pre-build step in `project.yml`). The
binaries are distribution resources, not Git blobs.

The complete notice texts ship in the app bundle as
`Licenses/LinuxBootPair-LICENSES.txt` (24,582 B, sha256
`c11f1ebb51af96f85d809a8133d529a8005c0fe8d787112b7e104b248487b5f8`): the kernel
`COPYING` statement, the Linux syscall note, the full GPL-2.0 text, and the
OpenSBI BSD-2-Clause text, all copied verbatim from the verified sources below.

## 2. How the files are used

Both files are **separate data resources**: the virtual machine (TinyEMU) loads
them at guest start. They are not linked into the app binary and not compiled
into the engine objects; the engine licensing conclusion (MIT / BSD-2-Clause,
see [`../LICENSE-INVENTORY.md`](../LICENSE-INVENTORY.md)) is unchanged by this
pair. On the first quiet start the app adopts the bundled pair for the guest;
the separately downloaded Debian root filesystem image keeps its original
4.15 kernel/bbl pair as the recorded rollback (that image and its manifests are
documented in `docs/FLOE_LINUX_GUEST_IMAGE_MANIFEST.md`).

## 3. Corresponding source and rebuild references

### Linux kernel 6.18.56 (GPL-2.0)

- Upstream source (unmodified): `https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.56.tar.xz`
- Tarball sha256: `4633bbda2ab95eaf2a7af4041236451d6759c72e6946265531af4b3aacefbf89`
  — matches the `linux-6.18.56.tar.xz` entry of kernel.org `sha256sums.asc`, and
  that file carries a **Good signature** from the Kernel.org checksum
  autosigner key `B8868C80BA62A1FFFAF5FDA9632D3A06589DA6B1` (re-verified
  2026-10-15; the key is not on a locally trusted chain).
- No kernel source changes: the bundled Image is built from the unmodified
  upstream tree; the only input that differs from `defconfig` is the tracked
  configuration below.
- Exact build configuration (tracked in this directory):
  [`config_linux_riscv64_6.18.56`](config_linux_riscv64_6.18.56), sha256
  `e7058fe40e27e8d56ca10ec5e7a1bf2969bc6de07078fe2d95f5ebd3098f7cb5`
  (byte-identical to the `.config` of the build tree that produced the shipped
  Image — re-checked against the matching `vmlinux` embedded IKCONFIG payload;
  the legacy 2018 pair's config stays
  [`config_linux_riscv64`](config_linux_riscv64)).
- Build recipe, toolchain (riscv64-linux-gnu-gcc 13.3.0 / binutils 2.42) and
  full qualification record: `docs/FLOE_LINUX_KERNEL_UPGRADE.md`.
- License note: the kernel `COPYING` declares
  `SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note`; the syscall note
  only clarifies that user programs calling normal syscalls are not derived
  works. It does not relax the GPL-2.0 obligations for the kernel Image itself.

### OpenSBI v1.9 (BSD-2-Clause)

- Upstream release: `https://github.com/riscv-software-src/opensbi/releases/tag/v1.9`
- Retained release source tarball used for the build:
  `opensbi-1.9.tar.gz`, sha256
  `f6c4985843d6d878b5b511d7d7a930b6b541d3d9305371f2d9780765428f66f4`
  (measured from the retained build input; no upstream checksum was recorded
  for this asset).
- License text read from that tarball's `COPYING.BSD` (sha256
  `82d13fb1bf6bb162629deeea9eb9c117e74548d3b707e478967691fe79a68e21`,
  "Copyright (c) 2019 Western Digital Corporation or its affiliates and other
  contributors.") and shipped verbatim in the bundled notice.
- No firmware source changes; built with
  `PLATFORM=generic FW_JUMP=y FW_JUMP_ADDR=0x80200000` (the generic defconfig
  already sets `CONFIG_FDT_SERIAL_HTIF=y`).

## 4. Open items / limits (not certified)

- This record states facts; it does not certify the distribution as legally
  complete. Source-offer mechanics for the shipped app remain the release
  owner's decision.
- The modern pair relies on the public upstream source URLs above plus the
  tracked exact configuration and build recipe; Floe does not mirror them.
- The separate downloaded guest image's source-offer items (mirror/publish)
  remain open exactly as recorded in
  `docs/FLOE_LINUX_GUEST_IMAGE_MANIFEST.md`; nothing here closes them.
- No claim that a rebuild has been reproduced from this record after the fact;
  the record binds the retained build outputs to the pinned inputs and hashes.

## 5. Read-only verification

From `FloeAgent/`:

```sh
bash ThirdParty/TinyEMU/guest-image/stage-boot-pair.sh --check   # staged bytes vs manifest
shasum -a 256 ThirdParty/TinyEMU/guest-image/config_linux_riscv64_6.18.56
python3 scripts/license_inventory.py --check                     # inventory + notices + localization
```

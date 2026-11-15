# Upstream provenance and licenses

## chromeos/virtio-media (guest kernel driver + protocol)

- Repository: https://github.com/chromeos/virtio-media
- Revision: `ed3a56fd39a74bd8117a3cc9c5b8ec8803df19cd`
  ("simple_device: Revert back to RGB888 pixel format", 2026-09-18)
- Vendored files: `driver/protocol.h`, `driver/scatterlist_builder.{c,h}`,
  `driver/session.h`, `driver/virtio_media.h`,
  `driver/virtio_media_driver.c`, `driver/virtio_media_ioctls.c`,
  `driver/Kbuild`, `driver/Makefile` — copied byte-identical (sha256 in
  `GUEST_STAGE_330_MOVE.json` manifest + re-verifiable against the upstream
  blob at the pinned revision).
- License: SPDX `BSD-3-Clause OR GPL-2.0+` per file; upstream `LICENSE`
  (BSD-3-Clause) and `LICENSE.GPL-2.0` are included at the package root.
  As a Linux kernel module loaded into the GPL kernel, the effective license
  for the loaded module is GPL-2.0-or-later (MODULE_LICENSE "Dual BSD/GPL").
- Local patches: **none**.

## Not vendored (deliberately)

- `device/` (Rust host-side devices) — the primary implements the host device
  natively against `abi/HOST_ABI.json`; the Rust helpers would pull in an
  unrelated toolchain without adding authority.
- `extras/ffmpeg-decoder` — same reason; also documented gaps in the 2026-11-11
  assessment (VA-API decode absent, no strict-hardware enforcement).

## Pinned kernel inputs (Debian trixie arm64)

See `config/build-inputs.json` for URLs + sha256:
- `linux-source-6.12_6.12.107-1_all.deb` (GPL-2.0, Linux kernel)
- `linux-headers-6.12.107+deb13-arm64_6.12.107-1_arm64.deb` (GPL-2.0)
- `linux-image-6.12.107+deb13-arm64_6.12.107-1_arm64.deb` (reference; reused
  from the GPU lane's pinned cache, read-only)

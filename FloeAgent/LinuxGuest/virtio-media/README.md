# Floe virtio-media guest package

Standard Linux V4L2 media virtualization for the Floe interpreted ARM64 Linux
guest: vendored ChromeOS virtio-media guest kernel driver (virtio device ID 48)
plus build/install recipes, a wire-ABI contract for the primary's
VideoToolbox-backed host device, V4L2 qualification tools, and protocol
fixtures for host/device glue validation.

> Placement: this is the mergeable guest package at
> `FloeAgent/LinuxGuest/virtio-media`. It was developed in a private stage
> while the live App source was frozen; the primary integrates it as source,
> not as an in-place mutation of a boot image.

## Contents

| Path | What |
| --- | --- |
| `driver/` | Vendored virtio-media guest kernel module (chromeos/virtio-media @ ed3a56fd39a74bd8117a3cc9c5b8ec8803df19cd), dual BSD-3-Clause OR GPL-2.0+; unmodified |
| `abi/HOST_ABI.json` | Host-consumable wire ABI: config space, commands, events, per-ioctl descriptor ordering, exact ARM64 sizes/offsets, error/event sequencing |
| `config/build-inputs.json` | Pinned kernel source/headers inputs with sha256 and expected vermagic |
| `docs/kernel-prerequisites.md` | CONFIG_MEDIA_SUPPORT/VIDEO_DEV/videobuf2/virtio diagnosis from the real 6.12.107+deb13-arm64 config; smallest changed boundary = +1 module |
| `docs/driver-probe-plan.md` | Phased interpreted-Linux probe plan (no VM without a compatible device) |
| `docs/ffmpeg-commands.md` | Stock v4l2-ctl / FFmpeg qualification commands |
| `docs/codec-mapping.md` | Truthful codec↔UAPI↔FFmpeg mapping; ProRes gap stated honestly |
| `tools/fvm_qual.c` | Self-contained stock-V4L2 qualification client (enum / m2m-decode / m2m-encode) |
| `tools/proto_harness.c` | User-space unit harness validating the wire fixtures (host/device glue) |
| `fixtures/` | Deterministic wire fixtures (bin + json + C header) |
| `scripts/build_module.py` | Reproducible module build against pinned 6.12.107 inputs (native window) |
| `boot_overlay/install_recipe.py` | Initrd module overlay assembly (post-build) |
| `scripts/abi_probe.c` | UAPI size/offset probe used to generate the ABI evidence |
| `scripts/gen_fixtures.py` | Fixture generator |
| `boot_overlay/` | Module overlay assembly + image metadata gate (receipts are written to the caller's output directory) |

## Quick status

- Driver vendored + 6.12.107 compatibility assessed from real source: **no patch required** (driver has a 6.11+ virtio_find_vqs branch; all consumed symbols verified exported).
- Native stage 2: scripts repaired after real failures
  (the original failure is retained in the primary's private evidence; Darwin host
  tool fixes are injected headers under the internal-SSD scratch
  `module-build/host-include/`, the pinned kernel tree stays read-only).
- Fixtures: **regenerated from the real `driver/protocol.h` structs** by
  `scripts/gen_fixtures_c.c` (the old Python model had wrong sizes/offsets,
  e.g. cmd_close 12→16); pre-repair bytes preserved in `fixtures/original-ledger/`.
- `tools/fvm_qual.c`: rewritten as a single-planar NV12 M2M client per primary
  review; `tools/proto_harness.c` validates the exact C structs.
- Runtime `/dev/video*` claims: **none made** — compile/link only; insmod and
  codec runtime belong to the primary's guest bring-up.

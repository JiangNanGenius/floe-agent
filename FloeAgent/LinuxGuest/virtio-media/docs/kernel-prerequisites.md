# Kernel 6.12.107+deb13-arm64 — virtio-media prerequisites diagnosis

All facts below are read from the exact pinned inputs
(`config/build-inputs.json`, sha256-verified Debian linux-source-6.12.107-1,
linux-headers-6.12.107+deb13-arm64, linux-image-6.12.107+deb13-arm64).

## Guest kernel facts

- Release: `6.12.107+deb13-arm64`, Debian package `linux 6.12.107-1` (trixie).
- vermagic (from `videodev.ko` / `virtio_mmio.ko` in the linux-image deb):
  `6.12.107+deb13-arm64 SMP mod_unload modversions aarch64`
  - **No compiler component** — modules built with any aarch64 gcc/clang pass
    the vermagic check. MODVERSIONS CRCs come from the shipped
    `Module.symvers` (26,760 symbols) at build time.
- `CONFIG_MODULE_SIG=y`, `CONFIG_MODULE_SIG_ALL=y`, but `CONFIG_MODULE_SIG_FORCE`
  is **not set** → unsigned out-of-tree modules load (with the usual taint).
- Config file: `downloads/config-6.12.107+deb13-arm64` (sha256 in build-inputs.json).

## CONFIG prerequisites (all present in the stock Debian config)

| Config | Value | Why it matters |
| --- | --- | --- |
| CONFIG_MODULES | y | module loading |
| CONFIG_MODULE_UNLOAD | y | rmmod support for iteration |
| CONFIG_MODVERSIONS | y | symbol CRC checks; build must use the shipped Module.symvers |
| CONFIG_MEDIA_SUPPORT | m | videodev core module |
| CONFIG_VIDEO_DEV | m | `videodev.ko` — module depends on it |
| CONFIG_VIDEOBUF2_CORE | m (`videobuf2-common.ko`) | vb2 core |
| CONFIG_VIDEOBUF2_V4L2 | m | vb2 v4l2 glue |
| CONFIG_VIDEOBUF2_MEMOPS | m | `vb2_vmarea_handler` etc. |
| CONFIG_VIDEOBUF2_VMALLOC | m | not used by this driver (MMAP goes via SHM region) |
| CONFIG_V4L2_MEM2MEM_DEV | m | only needed for in-kernel M2M helpers; the virtio-media driver does **not** use v4l2-mem2mem (it is a pure V4L2-device pass-through), listed for completeness |
| CONFIG_MEDIA_CONTROLLER | y | compiled-in; harmless |
| CONFIG_VIRTIO | y / CONFIG_VIRTIO_MMIO | m (`virtio_mmio.ko`) — guest uses virtio-mmio, already in the boot initrd |
| CONFIG_SYNC_FILE | y | vb2 dependency |

**Smallest required changed boundary:** none in the kernel image. The stock
Debian kernel already provides every prerequisite as built-in or module. The
change boundary is exactly: +1 new out-of-tree module `virtio-media.ko`, plus
its existing in-tree dependency modules copied into the initrd if not already
present (they ship in the linux-image deb but the current boot initrd only
carries the GPU-focused subset — see install recipe).

## Symbols the driver consumes (verified exported in 6.12.107 source)

- v4l2 core: `video_ioctl2`, `video_device_release_empty`,
  `v4l2_device_register`, `v4l2_fh_init/add/del/exit`,
  `v4l2_event_queue_fh`, `v4l2_event_pending`, `v4l2_event_subscribe`,
  `v4l2_event_unsubscribe` (+ `_all`), `video_unregister_device`,
  `video_register_device`, `v4l2_subdev...` (not used).
- vb2: `vb2_queue_init`, `vb2_queue_release`, `vb2_poll`, `vb2_streamon`,
  `vb2_streamoff`, `vb2_ioctl_reqbufs`, `vb2_ioctl_create_bufs`,
  `vb2_ioctl_querybuf`, `vb2_ops_wait_prepare/finish`,
  `vb2_create_framevec`, `vb2_destroy_framevec`, `vb2_vmalloc_memops`.
- virtio: `virtio_find_vqs` (6.11+ `virtqueue_info` path taken on 6.12.107),
  `virtio_get_shm_region`, `virtio_device_ready`, `virtio_cread32`,
  `virtio_break_device`, `virtio_reset_device`.
- mm: `io_remap_pfn_range`, `remap_pfn_range` semantics via SHM region.

Driver compatibility note: the vendored driver already carries a
`LINUX_VERSION_CODE >= KERNEL_VERSION(6, 11, 0)` branch for the new
`virtio_find_vqs` signature, so no patch is required for 6.12.107. All other
APIs match 6.12 headers unchanged (assessed 2026-11-11; real compile
verification is queued behind coord/guest-native-grant.json).

## Module load order (initrd/install)

```
virtio_mmio.ko        (already in boot initrd)
videobuf2-common.ko   (VIDEOBUF2_CORE)
videobuf2-memops.ko
videobuf2-v4l2.ko
videodev.ko
virtio-media.ko
```

`modules.dep` entry for virtio-media:
`virtio-media.ko: videodev.ko videobuf2-v4l2.ko videobuf2-common.ko videobuf2-memops.ko`
(the driver also links `frame_vector.o` helpers built from videobuf2-memops;
no additional dependency beyond the list above).

## Toolchain

- Default: `aarch64-linux-musl-gcc` 15.2.0 (Homebrew `aarch64-unknown-linux-musl`).
- Alternative: `clang --target=aarch64-linux-gnu` + `ld.lld` (Xcode toolchain).
- Kernel modules are freestanding; the musl tuple does not leak into the module.
- Host-side `make`/`modpost`/`genksyms` build from the linux-source tree with
  the macOS host compiler — no Linux VM/container needed for the build.
  (A Debian container build also works if preferred; not required.)

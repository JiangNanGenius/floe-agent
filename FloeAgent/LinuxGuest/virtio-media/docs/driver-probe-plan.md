# Interpreted-Linux driver probe plan (real guest, real device)

Status of each step is honest: `PENDING-NATIVE-GRANT`, `PENDING-PRIMARY-DEVICE`,
or `READY`. No VM will be booted without a compatible host device present —
boot-only proof was already established by the GPU work and is not repeated.

## Phase A — module build sanity (grant only, no device needed)

READY — run after coord/guest-native-grant.json:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
python3 -B <shared-native-window>/with_native_window.py \
  --label guest-video-module-build -- \
  python3 <repo>/FloeAgent/LinuxGuest/virtio-media/scripts/build_module.py \
  --jobs 6
```

Accept: `virtio-media.ko` produced on the internal-SSD module tree (scratch `modsrc/virtio-media/`, exported to `guest/artifacts/`); receipt shows vermagic
`6.12.107+deb13-arm64 SMP mod_unload modversions aarch64`; undefined symbol
list resolves entirely within Module.symvers.

## Phase B — module load in interpreted guest (needs initrd overlay; no device yet)

PENDING-PRIMARY-DEVICE (initrd assembly is image-owner work; the overlay
itself is READY via scripts/install_recipe.py).

Accept: `insmod 89-virtio-media.ko` succeeds on the booted guest; `lsmod`
shows it; **no** /dev/videoX node appears because no virtio-media device is
present yet (negative probe — proves clean absence behavior); rmmod clean.
Do NOT treat absence-of-node as failure: it is the expected state until the
emulator publishes device ID 48 on MMIO slots 28/29.

## Phase C — driver probe against the primary device

PENDING-PRIMARY-DEVICE. Preconditions:
- Emulator exposes virtio-media ID 48 with config `device_caps=0xC000`,
  `device_type=0`, card set, SHM region 0 present, on MMIO slots 28/29.
- Initrd carries the whole computed closure overlay (install_recipe.py output; stock deps first, virtio-media last).

Accept sequence (each step evidenced):
1. Boot log: virtio_media probe success; `dmesg | grep virtio` clean.
2. `/dev/videoX` nodes exist; `fvm_qual enum /dev/videoX` prints caps from
   config and the format list served by the device.
3. M2M decode H264 (native-02 clip): `fvm_qual m2m-decode` frame count ==
   source frame count; NV12 sha256 == golden (native-02 set).
4. M2M decode HEVC likewise.
5. M2M encode H264/HEVC: `fvm_qual m2m-encode` produces an ES that
   `ffprobe` parses with correct codec and frame count.
6. Stock FFmpeg one-liners from docs/ffmpeg-commands.md §1–§5 pass.
7. Drain: DECODER_CMD STOP returns all buffers + EOS event; encoder flush
   drains bitstream.
8. Backpressure: queue depth bounded (REQ_BUF_COUNT=8 client-side; device
   must apply its own `max_inflight_per_session` bound and report FLV_LIMIT
   style refusals as -EAGAIN/-ENOSPC on QBUF).
9. Isolation: `timeout -s INT` mid-encode; next open() has a fresh session;
   other sessions (decode while encode killed) unaffected; VM destroy while
   streaming leaves the next boot clean.
10. Multiformat: `v4l2-ctl --list-formats-ext` advertises exactly the
    intersection documented in docs/codec-mapping.md (no enum-only claims).

## Failure handling

Preserve original dmesg/ioctl error output per step; repair within this
package (driver patch or recipe fix) and rerun only the failed phase; never
silently weaken an assertion.

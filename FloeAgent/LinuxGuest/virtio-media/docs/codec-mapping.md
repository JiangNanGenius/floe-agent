# Codec mapping: Linux UAPI / stock FFmpeg ↔ Floe host capability

Rule (from CONTRACT): Linux advertisement = implemented native path ∩ actual
hardware/session probe ∩ a supported Linux format mapping. A codec that fails
any leg is reported as unsupported/probe-only, never as working acceleration.

Legend: **Fmt** = V4L2_PIX_FMT_* fourcc; **FF dec/enc** = FFmpeg v4l2m2m
decoder/encoder module name in stock FFmpeg (7.x); **HW (M5 Pro)** = Apple
VideoToolbox hardware presence is expected per native-02 evidence (H264/HEVC
verified strict-hardware; others = probe required, unverified).

| Codec | V4L2 fourcc | Fmt value | Stock FF decoder | Stock FF encoder | Host VT support expectation | Advertise now? |
| --- | --- | --- | --- | --- | --- | --- |
| H.264 | `H264` | 0x34363248 | h264_v4l2m2m | h264_v4l2m2m | strict HW verified (native-02) | **Yes (decode+encode)** |
| HEVC | `HEVC` | 0x43564548 | hevc_v4l2m2m | hevc_v4l2m2m | strict HW verified (native-02) | **Yes (decode+encode)** |
| VP9 | `VP90` | 0x30395056 | vp9_v4l2m2m | — (no stock FF v4l2m2m VP9 encoder) | HW decode on M-series very likely; encode unlikely | Probe first; advertise decode only if probe passes |
| AV1 | `AV01` | 0x31305641 | av1_v4l2m2m | — | M5 Pro has AV1 decode HW; encode unlikely | Probe first; decode only |
| MJPEG | `MJPG` | 0x47504a4d | mjpeg_v4l2m2m | mjpeg_v4l2m2m | VideoToolbox JPEG encode/decode exists | Probe; likely both |
| MPEG-2 | `MPG2` | 0x3247504d | mpeg2_v4l2m2m | — | HW decode very likely (no SW-allowed target here; VT MPEG2 is decode-only historically) | Probe; decode only |
| MPEG-4 part 2 | `MPG4` | 0x3447504d | mpeg4_v4l2m2m | mpeg4_v4l2m2m | HW decode likely; encode unlikely on Apple | Probe; decode likely only |
| H.263 | `H263` | 0x33363248 | h263_v4l2m2m | h263_v4l2m2m | HW decode likely; encode unlikely | Probe; decode likely only |
| VP8 | `VP80` | 0x30385056 | vp8_v4l2m2m | vp8_v4l2m2m | HW decode likely; encode unlikely | Probe; decode likely only |
| ProRes 422 | — none in Linux UAPI | — | — (FFmpeg decodes ProRes in software only) | — | VT decodes ProRes; encodes ProRes | **No standard mapping** |

## Honest gaps and the exact minimum extension where one exists

1. **ProRes (422/4444)**: Linux videodev2.h has **no** ProRes fourcc and
   stock FFmpeg has **no** v4l2m2m ProRes path. An unmodified stock FFmpeg
   therefore can never use a ProRes V4L2 node. Minimum extension IF ProRes
   acceleration is required later: define a private experiment fourcc (e.g.
   `V4L2_PIX_FMT_FLOE_PRORES = v4l2_fourcc('F','P','R','S')`) plus a patched
   FFmpeg codec — that is a *non-stock* extension and must NOT be presented as
   working in unmodified stock FFmpeg. Recommendation: keep ProRes host-side
   only; guest gets it via the ordinary FFmpeg software decoder.
2. **VP9/AV1 encode**: no stock FFmpeg v4l2m2m encoder exists. Advertising a
   V4L2 VP9/AV1 encode queue is still valid V4L2 (v4l2-ctl can drive it), but
   stock FFmpeg cannot; document as "V4L2-native only, no stock FFmpeg
   encoder mapping".
3. **MPEG2/MPEG4/H263/VP8 encode**: same situation as VP9 — stock FFmpeg
   lacks those encoders except mpeg4/h263/vp8 (which exist per table).
4. **10-bit / P010**: V4L2_PIX_FMT_P010 exists and FFmpeg v4l2m2m can carry
   it; advertise only after the host verifies a 10-bit VT session. Not part
   of the first data plane (NV12 8-bit first per native-02).
5. **Bitstream format**: H264/HEVC queues must accept Annex B (`H264`/`HEVC`
   fourcc imply Annex B in V4L2 stateful M2M). avcC/hvcC length-prefixed
   variants (`AVC1`/`HVC1`) are optional; stock FFmpeg v4l2m2m feeds Annex B.

## Raw pixel formats for CAPTURE/OUTPUT queues

- First data plane: NV12 (`NV12`) both directions (matches native-02 golden).
- Optional later: P010 (10-bit), YUYV/UYVY only if a host converter path is
  implemented (VT native I/O is NV12/P010/BGRA-ish; YUYV needs conversion —
  do not advertise unimplemented conversions).

## What this package guarantees vs. what stays with the primary

Guaranteed here: guest driver, wire ABI doc, tools, build/install recipes,
synthetic fixtures, probe plans. NOT claimed here: any `/dev/video*` runtime
behavior — that requires the primary's device on MMIO slots 28/29 and is
explicitly gated by coord/guest-native-grant.json + primary integration.

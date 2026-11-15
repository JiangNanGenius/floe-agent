# floe-codec — installed Linux video client

`floe-codec` is the single Linux entry point for the Floe video service. It
talks to two backends and never invents availability:

- **v4l2** — the standard single-planar V4L2 M2M nodes exposed by the
  virtio-media guest driver. Existing applications can use `/dev/video*`
  directly; this client uses the same nodes for H.264/HEVC decode/encode.
- **native** — the typed app-owned broker for formats with no standard
  stateful V4L2 mapping (AV1 decode, ProRes 422/4444, and an explicit generic
  path for every host-supported codec). It sends bytes and numeric parameters
  only; the host never opens a model-supplied path.

## Build (source stage; primary-owned native window)

```sh
cd FloeAgent/LinuxGuest/acceleration/video
make CC=aarch64-linux-musl-gcc
file floe-codec   # ELF 64-bit LSB executable, ARM aarch64, statically linked
```

The guest image install recipe copies the verified binary to
`/usr/local/bin/floe-codec` and records its SHA-256 in the overlay receipt.
No application source change is needed for the standard V4L2 path.

## Commands

```
floe-codec list [--json] [--device /dev/videoN] [--endpoint HOST:PORT:TOKEN]
floe-codec decode --codec NAME --input FILE --output FILE
                  [--width N --height N] [--backend auto|v4l2|native]
                  [--device PATH] [--frame-bytes N] [--limit N]
                  [--config RECORD] [--require-hardware] [--json]
floe-codec encode --codec NAME --input RAW --output FILE --width N --height N
                  [--backend auto|v4l2|native] [--bitrate N] [--limit N]
                  [--require-hardware] [--json]
```

Codec names: `h264 hevc vp9 av1 mjpeg mpeg2 mpeg4 prores422 prores4444 h263 vp8`.

`list --json` is the machine-readable discovery surface for the dispatcher and
Terminal UI. It reports, per codec and direction: `v4l2`, `native`,
`hardware`, `native_software`, `native_software_allowed`, `usable`, `flags`.
A codec is only `usable` when a real path exists *and* the live policy admits
it; hardware and native software stay distinct.

## Input framing

- `decode`: FVMP manifest (`"FVMP"`, version 1, count, per-frame length +
  bytes), IVF (AV1/VP9), Annex-B with AUD access-unit delimiters (H.264/HEVC),
  or `--frame-bytes N` for fixed-size raw coded frames.
- `encode`: raw contiguous NV12 frames (frame size `width*height*3/2`); the
  native broker currently accepts NV12 only. ProRes/JPEG alpha and 10-bit
  input are not claimed here.
- `--config RECORD` supplies an explicit codec configuration record for the
  native broker when a format needs one (for example a vpcC/av1C record).

## Endpoint discovery

The guest learns the broker endpoint without a host file share:

1. `--endpoint HOST:PORT:TOKEN` (highest priority),
2. `FLOE_CODEC_ENDPOINT` environment variable,
3. `floe.video.broker=HOST:PORT:TOKEN` on `/proc/cmdline`,
4. a V4L2 `VIDIOC_QUERYCAP` `bus_info` of the form
   `floe:v1:<port>:<16-hex-token>` (default host `10.0.2.2`).

The endpoint is a loopback TCP listener created by the App/engine for the
lifetime of the machine; guest access uses libslirp's existing 10.0.2.2 host
alias. No NAT rule, host share or shell exec is added.

## Failure semantics

- A codec with no public host path or no measured path is never `usable`.
- A `REQUIRE_HARDWARE` request on a software-only format fails at session
  creation (v4l2 or native), never falls back silently.
- Native software output is counted as native software, never hardware.
- `--json` summaries are written to stderr so `--output -` can remain a clean
  binary stream.

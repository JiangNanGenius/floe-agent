# FloeLinuxVideo — native host package

Multi-codec host backend for the Floe Linux video driver, built exclusively on
public Apple VideoToolbox / CoreMedia / CoreVideo. Implements the frozen C ABI
`floe_linux_video.h` (ABI 1) that the virtio-media/V4L2 device emulator
consumes in-process. The package is built as a local SwiftPM dependency of the
engine target; the primary integrates it through the guarded package fragment.

## Layout

```
Sources/FloeLinuxVideoNative/include/floe_linux_video.h   Frozen shared ABI (do not edit)
Sources/FloeLinuxVideoHost/
  FLVInternal.h          Shared internals, bounds, pixel geometry
  FLVPixelFormats.m      Pixel-format plane layout + dimension validation
  FLVBitstream.h/.m      Annex B <-> length-prefixed NAL, avcC/hvcC parse+build,
                         vpcC/av1C build, H.264/HEVC SPS dimension parsing (RBSP)
  FLVProbeSamples.h      Probe-sample record format
  FLVCodecRegistry.h/.m  Codec table (11 codecs) + truthful hardware probe
  FLVFormatDescription.m CMFormatDescription construction from config records
  FLVQueue.h             Host-owned output queue
  FLVHostContext.h/.m    Host: session registry, memory budget, stats, notify
  FLVSessionContext.h/.m Async VT encode/decode sessions (the data plane)
  FLVHostPublic.m        Exported C ABI functions
  FLVImageIOFallback.m   Bounded public-ImageIO JPEG encode/decode fallback
Sources/FloeLinuxVideoBroker/
  include/floe_linux_video_broker.h      Additive typed broker API
  include/floe_linux_video_broker_wire.h Shared guest/server wire contract
  FLVBrokerServer.c                      Single-client loopback service
tests/                   Component tests + build/run scripts; FLVProbeSamples_empty.m is a diagnostic fallback only and is never part of the production target
```

## Design invariants

- **Truthful capabilities**: a codec/direction is only advertised with
  `FLV_CAP_HW_REPORTED | FLV_CAP_SESSION_PROBED` after a real hardware-required
  probe on this machine (encode one frame and read
  `kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder`, or decode
  one real coded frame created with
  `kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder` and
  read `kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder`).
  Software fallbacks are never counted as hardware, and hardware flags are
  never granted by a software session. When the hardware probe fails but a
  real session without the hardware requirement completes the same work and
  reports `UsingHardware == false`, the slot advertises
  `FLV_CAP_IMPLEMENTED | FLV_CAP_NATIVE_SOFTWARE_PROBED` (2|8): a native
  software path proven on this machine. Flag 8 is an implementation-level
  value (the frozen public header is unchanged); old hardware-only consumers
  filter flags 1|4, so they keep strict behavior. `FLV_REQUIRE_HARDWARE`
  sessions still fail on software and never increment `hardware_used`.
  Codecs with no public VideoToolbox path (VP8) advertise `flags == 0`.
  `max_width/max_height` report the largest square dimension at which a
  hardware-required session could be created (hardware) or the measured
  software probe dimensions (software); `0` means unknown, never invented.
- **Bounded**: `max_sessions`, `max_inflight_per_session`,
  `max_packet_bytes`, `max_frame_bytes`, `max_owned_bytes` are all enforced.
  `flv_session_submit_*` returns `FLV_AGAIN` on per-session backpressure and
  `FLV_LIMIT` on memory/session budget exhaustion, with no ownership transfer.
- **Owned memory only**: inputs are copied into host buffers before VT sees
  them; per-work records carry a generation so `cancel`/`discard`/`close`
  fence late callbacks deterministically. Outputs are host-owned until
  `flv_session_release_output`; the release token is never guest-visible.
- **No lock inversions**: one session mutex, one host mutex, ordered
  session→host; VT `Invalidate` is always called without holding the session
  mutex (Invalidate joins callbacks, which take the mutex).
- **Annex-B first for V4L2**: H.264/HEVC decode accepts Annex B and derives
  dimensions from in-band SPS (sessions may start with width=height=0);
  `FLV_OUTPUT_FORMAT` (avcC/hvcC) is emitted before frames. Encoders emit
  Annex B with SPS/PPS/VPS injected on keyframes when the session is Annex-B.
- **Decoder lifecycle**: H.264/HEVC length-prefixed sessions require avcC/hvcC
  at create; other codecs accept raw coded frames (jpeg/ProRes/MPEG) or
  vpcC/av1C records (VP9/AV1). Non-native decoder output pixel formats fall
  back through a public `VTPixelTransferSession` into NV12.

## Codec data-plane status

Measured on M5 Pro (Xcode 27.2 SDK), capability probes with
`RequireHardware` + `UsingHardware` readback; flags 1=HW 2=IMPLEMENTED
4=PROBED. Dated matrices are retained in the private native evidence, not in the mergeable package.

| Codec | Encode | Decode | Notes |
|---|---|---|---|
| H.264 | **hw-verified (flags7, ≤4096²)** | **hw-verified (flags7, ≤4096²)** | Annex B + length-prefixed |
| HEVC | **hw-verified (flags7, ≤8192²)** | **hw-verified (flags7, ≤8192²)** | Annex B + length-prefixed |
| VP9 | none (no public VT encode) | vpcC corrected to the 12-byte VT record; re-probe at runtime | previous 11-byte record (dims packed in) was rejected |
| AV1 | none (no public VT encode) | **hw-verified (flags7, ≤8192²)** | supplemental registration |
| MJPEG | **native software via public ImageIO** (`CGImageDestination` JPEG, explicit `FLV_ALLOW_NATIVE_SOFTWARE` policy only; `hardware_used=0`) | **native software via public ImageIO** (`CGImageSource`, NV12 output) | no hardware on this machine; VT path remains unprobed |
| MPEG-2 | none (no VT path) | no hardware on this machine | truthful hw-absent |
| MPEG-4 Part 2 | no hardware on this machine | no hardware on this machine | esds needed for decode sessions |
| ProRes 422 | implemented: public `VTCompressionSession` (`kCMVideoCodecType_AppleProRes422`), NV12/P010 opaque input; capability probe decides hardware vs proven native software | **hw-verified (flags7, ≤8192²)** | raw coded frames; no avcC/hvcC format record |
| ProRes 4444 | implemented: public `VTCompressionSession` (`kCMVideoCodecType_AppleProRes4444`), NV12/P010 opaque input; no alpha claim | **hw-verified (flags7, ≤8192²)** | raw coded frames; no avcC/hvcC format record |
| H.263 | none | no hardware on this machine | truthful hw-absent |
| VP8 | none | none | no public VideoToolbox support at all |

B-frame/presentation-order (PTS vs DTS) behavior is **unverified**: the
golden clips are no-B-frame streams; a tiny libx264/libx265 B-frame fixture
is required before claiming general stream correctness.

## Tests

- `flv_test_capabilities` — 22 slots, truthfulness rules, no false HW claims.
- `flv_test_malformed_limits` — bad ABI/config/dims/strides, finite budgets,
  backpressure `FLV_AGAIN` (retry-loop; strict assertion, timing-robust),
  memory `FLV_LIMIT`.
- `flv_test_cancel_ownership` — mid-stream cancel fencing, EOS drain, double
  close safety, cancelled stats, host-destroy-with-live-session, 32-cycle
  C-caller ownership check. Optional arg: Annex-B clip path.
- `flv_test_roundtrip <fixtures> <out>` — native-02 golden pixel compares for
  H.264/HEVC decode; encode->own-decode round-trips; multi-codec fixture
  decode (VP9/AV1/MJPEG/ProRes/MPEG2/H.263) with hardware-required sessions,
  falling back to proven native software sessions (then asserting
  `hw_frames == 0`); VP9 first-frame pixel compare against the independent
  ffmpeg software decode (`vp9-ref.nv12`); MJPEG encode.
- `flv_test_software_fallback` — capability flag-8 invariants; pinned 12-byte
  vpcC layout; strict `FLV_REQUIRE_HARDWARE` rejection on software-only
  codecs (real `FLV_UNSUPPORTED` at create, never a software session);
  real software decode/encode of shipped probe data with `hardware_used == 0`;
  cancel/close fencing and host stats return to zero; hardware sanity check.

Scripts: `build_macos.sh` (one test), `build_macos_archive.sh` (standalone
static library), `build_ios_objects.sh` (arm64 device + simulator objects,
triples `arm64-apple-ios26.0{,-simulator}`, vtool evidence),
`gen_fixtures.sh` (ffmpeg fixtures with AUD insertion + generated probe
samples), `run_bounded.sh` (hard-deadline subprocess runner),
`run_tests.sh` (fail-closed master runner; writes evidence + RESULT.json).

## Licensing

MPL-2.0 for this package. No upstream source is vendored; design references
(public Apple SDK headers; ideas cross-checked against MIT-licensed
omacoma/try-omarchy PR168 and LGPL videotoolbox_remote) are documented in
the private native evidence notes. No FFmpeg code is linked or executed by the
library itself.

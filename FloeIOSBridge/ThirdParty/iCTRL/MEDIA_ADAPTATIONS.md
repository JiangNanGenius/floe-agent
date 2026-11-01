# iCTRL media adaptation (host H.264/fMP4 service)

Upstream: **OpenMinis/iCTRL**, commit
`c1e4268859ba858d1579f7b846a56cb40641b7f6` (v1.98.16), Apache-2.0.
`LICENSE` and `NOTICE.md` in this directory are retained. The upstream files
were fetched directly from that immutable revision (no `main` drift):

| Upstream file | SHA-256 |
| --- | --- |
| [`iCTRLUITests/FMP4Muxer.swift`](https://raw.githubusercontent.com/OpenMinis/iCTRL/c1e4268859ba858d1579f7b846a56cb40641b7f6/iCTRLUITests/FMP4Muxer.swift) | `e5ada5a81089e7b52feb9781bb8945f0d702198c35ce394fd0ce4651e2a56b49` |
| [`iCTRLUITests/VideoStreamer.swift`](https://raw.githubusercontent.com/OpenMinis/iCTRL/c1e4268859ba858d1579f7b846a56cb40641b7f6/iCTRLUITests/VideoStreamer.swift) | `314a6b1acf7be6346b05da29612bab10b9438225aa83fba545f7299e042b2d6a` |

The exact fetched copies and their hash manifest are retained in this task's
private media evidence directory (not tracked or published).

## Adapted

- **`FMP4Muxer.swift` → `Sources/BridgeCore/Media/BridgeFMP4Muxer.swift`.**
  Retained the ISO BMFF/CMAF-compatible layout (`ftyp` + `moov`/`avc1`/`avcC`,
  then one `moof` + `mdat` per encoded access unit), 90 kHz timescale,
  monotonic `mfhd` sequence, `tfhd` default-base-is-moof, `tfdt` v1,
  one-sample `trun` with data offset, per-sample keyframe flags and the
  `avc1.PPCCLL` codec string. Retained the `H264LowDelaySPS` VUI rewrite that
  declares `max_num_reorder_frames = 0`; the encoder also sets
  `AllowFrameReordering = false`.
Upstream's top-of-file "H.264-in-MPEG-TS" description is stale: the actual
`VideoStreamer` response code around lines 710-715 sends
`Content-Type: video/mp4` (fMP4) and `X-Codec`. This adaptation follows the
actual fMP4 behavior for both Bridge `/stream` aliases. The Bridge RPC
transport does not expose `X-Codec`, so the browser parses `avcC` instead.

- **`VideoStreamer.swift` → architecture only**, in
  `Sources/BridgeHost/Media/BridgeVideoService.swift` and
  `BridgeVideoEncoder.swift`. Retained: a single shared encoder/muxer with
  per-consumer fan-out, start on the first consumer, stop on the last,
  keyframe-aware late join, capture-time-driven fragment durations, pixel
  buffer pool reuse, real-time H.264 properties (Baseline, no frame
  reordering, 2 s keyframe interval, bounded average bitrate/data rate),
  capture/encode timing diagnostics and parameter-set extraction from the
  actual `CMFormatDescription`.

## Deliberately changed

- Swift 6 / strict-concurrency and Foundation-only `BridgeCore` muxer. No
  UIKit, XCTest, `XCUIScreen`, `NWConnection` or an HTTP server is imported or
  reimplemented.
- The host consumes the typed `BridgeScreenFrame` values from
  `BridgeRuntime.screenFrames`; decoding uses ImageIO/CoreGraphics and
  encoding uses VideoToolbox. The test bundle never appears in this package.
- `trun.data_offset` is found by a bounded box scan instead of the upstream
  fixed byte 84, and malformed/oversized samples throw instead of
  preconditioning.
- `fragment(...)` accepts an optional `presentationTicks` to pin `tfdt` to the
  encoder presentation clock while still enforcing monotonicity.
- One serial media queue owns all mutable encoder/service state. The
  VideoToolbox C callback copies the compressed sample into a `Sendable`
  value and dispatches it back to that queue; the callback context is retained
  through `VTCompressionSessionCompleteFrames` + `Invalidate` and is fenced by
  a generation/deactivate flag.
- The RPC channel is bounded by `BridgeRPCStreamChannel`. Fragments are split
  into bounded chunks; a full channel or finished channel removes that
  subscriber and, when it was the last one, stops the encoder. No frame or
  fragment is written to a file or log by production code.
- Rotation/resolution changes close all consumers and require a fresh
  `openStream`/init segment; one MSE SourceBuffer never receives two
  geometries.
- No upstream XCTest capture, `VideoStreamer` `NWConnection` subscriber,
  `broadcaster` singleton, `UIImage` source, UI, DDI or network server code was
  imported.

## Verification

See the private media evidence directory and the task handoff:

- 12/12 macOS media tests (plain Swift harness, generated offscreen fixtures,
  no XCTest link in the host media module).
- Real VideoToolbox H.264 encode, fMP4 box parse, `ffprobe` stream
  `h264/Baseline/320x240/yuv420p`, `ffmpeg` full decode, and AVFoundation
  `AVAssetImageGenerator` decode of the produced stream.
- Swift 6 `arm64-apple-ios26.0` objects for the separate `BridgeCore` module
  (including `BridgeScreenFrameRegistry` and `BridgeFMP4Muxer`) and
  `BridgeHostMedia` (including the real callback code), plus SIL verification.
  No App build, Simulator, device, signing or publication was performed.

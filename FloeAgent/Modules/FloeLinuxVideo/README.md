# FloeLinuxVideo

Local SwiftPM package for the app-owned video host backend used by the
interpreted ARM64 Linux `virtio-media` device:

- `FloeLinuxVideoNative` — frozen ABI1 C header (`floe_linux_video.h`).
- `FloeLinuxVideoHost` — public VideoToolbox/CoreMedia/CoreVideo implementation,
  capability probing and bounded ImageIO JPEG fallback.
- `FloeLinuxVideoBroker` — additive typed loopback broker for formats without a
  standard stateful V4L2 mapping.

The engine consumes the three products through the guarded package fragment in
`FloeAgent/Package.swift`; the App target does not link them directly. Hardware
is advertised only after a real hardware-required session probe. Software
sessions and the ImageIO fallback are counted separately and never as
hardware. `FLV_PROBE` sample data is synthetic.

The package is source-only in this intake: no new host archive, iOS object,
module load, codec session or pixel result is included. See
`README-host.md` for layout and invariants, and
`FloeAgent/LinuxGuest/acceleration/video/INTEGRATION.md` for guest/image
installation. Floe code is MPL-2.0 (`LICENSE`); Apple frameworks are used
through their public APIs.

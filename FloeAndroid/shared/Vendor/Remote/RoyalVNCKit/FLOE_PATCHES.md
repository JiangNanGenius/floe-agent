# Floe Android RoyalVNCKit slice

Upstream: https://github.com/royalapplications/royalvnc/tree/92d4427c73817d8f849bb289ff190aa4b40c44ea
License: MIT, retained verbatim in `LICENSE`.

This is a source slice, not upstream demos, binaries, build trees or native
runtime packages. The upstream `Package.swift` is replaced with a static
library that links into the single `libFloeAndroidCore.so`; demos, Windows
bundled zlib, `RoyalVNCKitC`/ObjC SDK and the Swift-JPEG/PNG dependencies are
not shipped.

## Omitted Apple-only sources (not compiled, not rewritten)

* `SDK/UI/**` (AppKit/UIKit framebuffer views, scroll views, display link)
* `SDK/CSDK/**` (Objective-C bridge; `RoyalVNCKitC` target omitted)
* `SDK/Input/macOS/**`, `SDK/Input/NSEvent.ModifierFlags+Right.swift`,
  `SDK/Input/VNCKeyCode+ObjC.swift`
* `SDK/Cursor/macOS/**`
* `SDK/VNCAccessibilityUtils.swift`

All remaining sources are compiled in Swift 5 language mode. Android uses
`canImport(Android)` branches already present upstream.

## Floe Android port patches (only non-upstream behavior)

1. `Network/Socket.swift`
   * bounded non-blocking connect (`poll` + `SO_ERROR`, 15 s) so a
     black-holed LAN endpoint returns `timedOut` instead of the OS connect
     timeout;
   * import full Foundation for the lifecycle lock on Android;
   * one-shot `shutdown()`/`closeSocket()` used by cancel, avoiding a double
     close and interrupting a blocked `recv()`.
2. `Network/SocketNetworkConnection.swift`
   * exact-byte read accumulation with a retained excess buffer (TCP may
     split one RFB field);
   * full-write loop (partial `send()` is legal; upstream treated any
     non-negative count as complete);
   * real `cancel()` that marks cancelled, shuts down the socket and posts
     `.cancelled`;
   * lock-protected status/handler and checked socket lifetime;
   * import full Foundation because FoundationEssentials does not export NSLock;
   * full-duplex lanes (2026-11-08): blocking reads run on a private serial
     read queue that solely owns the retained buffer, and blocking full
     writes run on a private serial write queue. Upstream funneled both into
     the caller-supplied queue, so a serial embedder deadlocked when a
     pending `recv()` starved a queued client write, and a concurrent
     embedder let reads race on the retained buffer. Status/connect stay on
     the caller's queue; exact accumulation, write order and one-shot
     shutdown/close are unchanged.
3. `SDK/Connection/VNCConnection+Handshake.swift`
   * security-type preference is `.none` → `.vnc` → `.tight` →
     `.diffieHellman` → `.ultraVNCMSLogonII`. Apple Remote Desktop asks for
     a username that a VNC-only profile does not have, so standard RFB
     password auth is chosen when both are offered.
4. `Framebuffer/VNCFramebuffer.swift`
   * public `floeCopyBGRA32()`: immutable copy under the framebuffer read
     lock. FloeVNC converts BGRA→RGBA with a tested converter before the
     Android Bitmap copy.
5. `Package.swift`
   * static product, no unsafe flags, no Apple JPEG/PNG dependency, exact
     CryptoSwift pin `a59b4d91ebb22011656c830f874fe7152e183a57`.

`Queue.swift` retains the donor's locked reference queue patch (simultaneous
producers/consumer/clear stress coverage). No other upstream behavior is
changed.

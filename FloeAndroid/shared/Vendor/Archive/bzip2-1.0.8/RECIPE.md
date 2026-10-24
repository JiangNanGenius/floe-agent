# bzip2 1.0.8 — pinned vendored library (FloeAndroid, lane job-bf610b6f22fe42ab)

Purpose: Android has no system `libbz2` (Apple platforms ship
`usr/lib/libbz2.tbd`, which the original `CFloeArchive` shim links). The
identical upstream library objects are compiled into this package graph and
`floe_bzip2.c` (byte-equal to public 3fd597b5) runs against them, so
`ArchiveBzip2.swift` stays byte-equal and keeps its bounded streaming
decode/encode contract on both platforms.

Pin: `https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz`
SHA-256 `ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269`
(verified 2026-10-24; matches the widely published 1.0.8 digest).
License: bzip2 BSD-style (`LICENSE` retained verbatim).

Vendored: the 7 library objects (`blocksort.c bzlib.c compress.c crctable.c
decompress.c huffman.c randtable.c`) + `bzlib.h` + `bzlib_private.h`. CLI,
recover tool, tests, XML docs excluded. Upstream 1.0.8 compiles warning-free
on NDK r30 arm64-v8a android-28 and Apple host clang (verified via the lane's
CFloeArchive driver build; same objects link the host functional test that
round-trips against Python `bz2`).

SwiftPM target proposal (Main):
```swift
.target(
    name: "CBZip2",
    path: "Vendor/Archive/bzip2-1.0.8",
    sources: ["blocksort.c", "bzlib.c", "compress.c", "crctable.c",
              "decompress.c", "huffman.c", "randtable.c"],
    publicHeadersPath: "."
)
```
`CFloeArchive` (Sources/CFloeArchive: floe_bzip2.c + floe_xz.c + include/)
depends on `CBZip2` and `CLzma`; no `linkedLibrary("bz2")` remains anywhere
in the Android graph.

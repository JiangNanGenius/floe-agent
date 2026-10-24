# SWCompression 4.9.1 (+ BitByteData 2.1.0) — pinned vendored Swift sources

Purpose: read-only 7z container decoding for `Tools/ArchiveTool.swift`
(byte-equal original, which `import SWCompression`), exactly as the public
`FloeAgent/Package.swift` pins `https://github.com/tsolomko/SWCompression.git`
`exact: "4.9.1"`. Vendored path instead of a floating checkout because the
Android cross-build graph follows the ZIPFoundation-mirror precedent
(deterministic, hash-pinned, no network at build).

- tag tarball SHA-256 4ac7268a8198e58cf4e2f70c9690292475ea1c9234d1a9ad26309bac955a608a
  (https://github.com/tsolomko/SWCompression/archive/refs/tags/4.9.1.tar.gz, verified 2026-10-24)
- MIT license retained (`LICENSE`).
- Vendored scope: `Sources/{Common,7-Zip,BZip2,Deflate,GZip,LZ4,LZMA,LZMA2,TAR,XZ,ZIP,Zlib}`
  byte-unmodified (verified: zero `import Compression/Network/Darwin`
  references — pure Foundation, compiles for Android). `swcomp` CLI,
  `Tests`, xcodeproj, `PrivacyInfo.xcprivacy` excluded (Apple distribution
  metadata only).
- Dependency: BitByteData 2.1.0 (upstream requirement `from: "2.1.0"`),
  tag tarball SHA-256 0d2f5556bd3e3db952e87abc10d05a65c29664116c8b197f48cf94f045336c42,
  MIT, unmodified, same exclusion rules (`Vendor/Archive/BitByteData-2.1.0`).

SwiftPM targets proposed for Main:
```swift
.target(name: "BitByteData", path: "Vendor/Archive/BitByteData-2.1.0/Sources",
        exclude: ["PrivacyInfo.xcprivacy"],
        swiftSettings: [.swiftLanguageMode(.v5)]),   // upstream tool-version 5.x semantics
.target(name: "SWCompression", dependencies: ["BitByteData"],
        path: "Vendor/Archive/SWCompression-4.9.1/Sources",
        exclude: ["PrivacyInfo.xcprivacy", "swcomp"],
        sources: ["Common", "7-Zip", "BZip2", "Deflate", "GZip", "LZ4", "LZMA", "LZMA2", "TAR", "XZ", "ZIP", "Zlib"],
        swiftSettings: [.swiftLanguageMode(.v5)])
```
`FloeWorkspace` gains a `SWCompression` dependency. 7z stays read-only;
archive creation remains zip/tar family exactly like the original promise.
The `XZ` module here is one-shot `Data` decode only and is NOT used by the
streaming engine path (that uses CFloeArchive/liblzma) — SWCompression's
role is 7z list/extract only, matching ArchiveTool's code.

# C05 VNC source and licence lineage

Pinned donor and package graph used by `FloeAndroidCore`/`FloeVNC`:

| Component | Pin | Licence |
| --- | --- | --- |
| RoyalVNCKit slice | `92d4427c73817d8f849bb289ff190aa4b40c44ea` (upstream `royalapplications/royalvnc`), ported in `shared/Vendor/Remote/RoyalVNCKit` | MIT (`LICENSE-RoyalVNCKit.txt`) |
| CryptoSwift | `a59b4d91ebb22011656c830f874fe7152e183a57` | MIT (`LICENSE-CryptoSwift.txt`) |
| d3des | bundled in the RoyalVNCKit slice | Public-domain notice (`NOTICE-d3des.txt`) |
| zlib | Android platform `libz`; header shim only | zlib notice (`NOTICE-zlib.txt`) |

The iOS donor is commit
`a59b4d4005f616c611df67fab7620e9853c525b9` (`FloeAgent/ThirdParty/RoyalVNCKit`
and `FloeAgent/Sources/FloeVNC`). The Android port keeps the RFB
protocol/encoding/auth implementation and replaces only the platform socket
lifetime/partial-I/O behavior documented in
`shared/Vendor/Remote/RoyalVNCKit/FLOE_PATCHES.md`.

No SwiftTerm, RDP, Apple CoreGraphics/UIKit framebuffer fallback or
screenshot-refresh substitute is shipped. Main must include these notices in
the App's aggregate NOTICE/licence inventory; this file is public-safe and
contains no private path, server or credential.

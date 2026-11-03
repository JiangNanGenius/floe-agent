# C05 SSH dependency license handoff

The Android C05 SSH transport reuses the fixed iOS Citadel/SwiftNIO source graph.
No dependency source is vendored into this repository; these notices travel
with the App's licence inventory. Revisions match `FloeAgent/Package.resolved`
at the fixed donor `a59b4d4005f616c611df67fab7620e9853c525b9` and the Android
`shared/Package.swift` and `shared/Package.resolved` declarations.

| Product | Upstream | Revision | Version | Licence |
| --- | --- | --- | --- | --- |
| Citadel | https://github.com/orlandos-nl/Citadel.git | `ae8562f895de06ccb86fdb1cbb65fd99c8976e12` | 0.12.1 (main) | MIT |
| swift-nio | https://github.com/apple/swift-nio.git | `a24771a4c228ff116df343c85fcf3dcfae31a06c` | 2.88.0 | Apache-2.0 |
| swift-nio-ssh (Wellz26 fork) | https://github.com/Wellz26/swift-nio-ssh.git | `a05e6bbe6b141ee68da3030e00275504c0595d4d` | 0.3.6 | Apache-2.0 |
| BigInt | https://github.com/attaswift/BigInt.git | `e07e00fa1fd435143a2dcf8b7eec9a7710b2fdfe` | 5.7.0 | MIT |
| swift-log | https://github.com/apple/swift-log.git | `3ffafb9722d5d918c614feb496c8789a3b59d222` | 1.15.0 | Apache-2.0 |
| swift-crypto | https://github.com/apple/swift-crypto.git | `95ba0316a9b733e92bb6b071255ff46263bbe7dc` | 3.15.1 | Apache-2.0 |
| swift-atomics | https://github.com/apple/swift-atomics.git | `0442cb5a3f98ab802acb777929fdb446bda11a34` | 1.3.1 | Apache-2.0 |
| swift-collections | https://github.com/apple/swift-collections.git | `a0cb0954ecb21e4e31b0070e6ed5674e8556685a` | 1.6.0 | Apache-2.0 |
| swift-system | https://github.com/apple/swift-system.git | `704705c5c51156ede21172a38654d522ce487074` | 1.8.0 | Apache-2.0 |

Notes:

* `swift-nio-ssh` is the API-compatible Wellz26 fork required by the pinned
  Citadel revision; Citadel's own `Package.resolved` entry names it.
* `swift-crypto` already has an exact revision pin in the Android package;
  the Citadel/NIOSSH ranges accept 3.15.1. `swift-asn1` remains at the
  Android package's existing resolved revision.
* The C05 port does **not** include SwiftTerm, RoyalVNCKit or any Apple UI
  framework. The Android terminal renderer is the existing `:feature:terminal`
  Termux-emulator subset.
* `libssh2`, OpenSSH and the host `ssh` CLI are not linked or executed. The
  transport is in-process Citadel/NIO.

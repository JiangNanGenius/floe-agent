# Android dependency notices

Floe-owned source remains MPL-2.0 under the repository license. The shared
`TaskPolicy.swift` source link retains the original implementation and license.

The Android application uses the following upstream runtime components. Exact resolved
versions and checksums belong to the Gradle locks, verification metadata and
`toolchains.lock.json`; this file is an inventory, not a replacement for upstream
license texts or the final distribution source/notice obligations.

| Component | Source | License |
| --- | --- | --- |
| Kotlin standard library | https://github.com/JetBrains/kotlin | Apache-2.0 |
| AndroidX Activity/Core/Compose/Material/icons and transitive AndroidX runtime | https://android.googlesource.com/platform/frameworks/support/ | Apache-2.0; preserve individual file notices |
| AndroidX Ink 1.0.0 (`ink-authoring`, `ink-brush`, `ink-geometry`, `ink-nativeloader`, `ink-rendering`, `ink-storage`, `ink-strokes`), graphics-core 1.0.4 and espresso-idling-resource 3.5.0 (upstream runtime dependency) | https://android.googlesource.com/platform/frameworks/support/ | Apache-2.0; license and pinned provenance in `core/notesmedia/licenses/ink/` |
| kotlinx.coroutines | https://github.com/Kotlin/kotlinx.coroutines | Apache-2.0 |
| Compose Cupertino 3.3.1 (selected for the G01 UI foundation) | https://github.com/RobinPcrd/compose-cupertino/tree/3.3.1 | Apache-2.0; retain upstream NOTICE and contributor lineage |
| Haze 1.7.3 (`dev.chrisbanes.haze:haze`, Android AAR) — real backdrop blur for shared chrome | https://github.com/chrisbanes/haze/tree/1.7.3 | Apache-2.0, copyright Christopher Banes and the Haze project contributors; full text at `licenses/haze/LICENSE` and `assets/legal/haze/LICENSE`; pins/hashes in `licenses/haze/PROVENANCE.json` |
| Cupertino Icons font 2.0.0 — source-derived vector glyph data only (generated ImageVector paths; the font binary is not shipped and is not a runtime dependency) | https://github.com/flutter/packages/tree/main/third_party/packages/cupertino_icons | MIT; copyright per the shipped license ("Copyright (c) 2016 Vladimir Kharlampidi"), full text bundled at `assets/legal/cupertino-icons/LICENSE`; pinned inputs and hashes in `FloeAndroid/licenses/cupertino-icons/PROVENANCE.json` |
| commonmark-java 0.30.1 (`org.commonmark:commonmark`, `commonmark-ext-gfm-tables`, `commonmark-ext-gfm-strikethrough`) — pure-JVM Markdown parse adapter for the conversation rich-body projection | https://github.com/atlassian/commonmark-java | BSD-2-Clause; copyright per the shipped license ("Copyright (c) 2015, Atlassian Pty Ltd"), full text preserved at `FloeAndroid/licenses/commonmark/LICENSE.txt` (extracted from the pinned jar's `META-INF/LICENSE.txt`) |
| Sora Editor 0.24.4 (`io.github.rosemoe:editor`) | https://github.com/Rosemoe/sora-editor/tree/0.24.4 | LGPL-2.1; retain per-file version notices. Exact text and source provenance are preserved at `FloeAndroid/licenses/sora-editor/`. |
| Swift standard libraries and Foundation | https://github.com/swiftlang/swift and https://github.com/swiftlang/swift-foundation | Apache-2.0 with Runtime Library Exception where specified; preserve bundled ICU/third-party notices |
| NDK libc++ shared runtime | https://github.com/llvm/llvm-project | Apache-2.0 with LLVM exceptions |

The commonmark-java artifacts are UI rendering infrastructure for the conversation
rich-body projection only (typed block mapping behind the async parse seam; no
HTML/JS rendering, no network, no execution). Their authoritative license is the
BSD-2-Clause text shipped inside each pinned jar (`META-INF/LICENSE.txt`,
copyright "Atlassian Pty Ltd"); the earlier lane handoff's attribution naming is
superseded by the shipped notice preserved verbatim at
`FloeAndroid/licenses/commonmark/LICENSE.txt`.

JUnit/AndroidX Test and the Android instrumentation runner are test dependencies,
not product functionality. Gradle, the JDK, SDK tools, NDK compilers and the
cross-compilation Swift host toolchain are development tools and are not copied
into the APK. G01 does not bundle Termux, LibreOffice, CAD kernels, root managers
or any local LLM. Future goals must add the corresponding exact upstream notices
and source obligations when they integrate those components.

### Haze backdrop material

Haze 1.7.3 is pinned to tag `1.7.3` / commit
`671eda90f5b8e6e72ebc4fce7455353f581c77d9`. It supplies the real
source/effect blur used by `FloeMaterial.kt`; no translucent-alpha substitute
is presented as blur. The Apache-2.0 text is retained at
`licenses/haze/LICENSE` and bundled at `assets/legal/haze/LICENSE`, with the
artifact hashes and API readback recorded in `licenses/haze/PROVENANCE.json`.
SDK 31 and older keep the opaque readable fallback.

The Cupertino selection excludes `cupertino-icons-extended`: its original README
separately identifies the SF Symbols artwork as copyrighted. Floe ships none of that
artwork: the shared icon family is generated from the MIT-licensed Cupertino
Icons font below (plus a few Floe-owned hand-drawn roles), and the selected
widget code is distinct from that optional icon collection. See the upstream `LICENSE.txt` and
`NOTICE.txt` at the pinned revision; final distribution notices must also cover
the exact resolved transitive graph.

### Shared icon family (Cupertino Icons derived vectors)

The `FloeGlyphs.kt` outlines are generated at development time from
`CupertinoIcons.ttf` in the pinned Flutter third_party package
`cupertino_icons` 2.0.0, which is handcrafted to preserve the SF Symbols
style. Converter: `FloeAndroid/tools/icons/generate_floe_glyphs.py` with
`roles.json` (input hashes enforced by the script itself). Only the
resulting path strings are compiled into the app; the font binary, Flutter
engine and Flutter SDK are not shipped and no Gradle dependency was added.
Roles with no glyph in the licensed family keep Floe-owned hand-drawn
geometry. MIT text bundled at `assets/legal/cupertino-icons/LICENSE`;
archive/font/codepoint-source hashes, the transform constants and the
per-glyph map are recorded in `licenses/cupertino-icons/PROVENANCE.json`.
The pinned codepoint-name table (`licenses/cupertino-icons/upstream/flutter-3.35.0-icons.dart`)
is a separate upstream artifact under BSD-3-Clause (The Flutter Authors); its
license text is bundled next to it at `licenses/cupertino-icons/upstream/Flutter-BSD-LICENSE`.

### G04 native archive, network and source-control components

The native graph now includes the pinned source dependencies below. Their full
license texts are retained in `licenses/native-g04/` and bundled under
`assets/legal/native-g04/`. Exact upstream pins and patch manifests remain in
`shared/Vendor/` and `planning/SHARED_SOURCE_PINS.json`; individual file notices
remain controlling.

| Component | License |
| --- | --- |
| bzip2 1.0.8 | bzip2 BSD-style license |
| xz/liblzma 5.8.1 (selected library sources) | 0BSD; retain individual file notices |
| libarchive 3.8.9 | BSD-2-Clause plus per-file terms recorded in COPYING |
| BitByteData 2.1.0 and SWCompression 4.9.1 | MIT |
| SMBClient 0.2.1 | MIT; documented Android transport/crypto patches retained |
| SwiftGitX 0.4.0 | MIT |
| libgit2 1.9.2 | GPL-2.0-only with the upstream linking exception |
| Mbed TLS 3.6.7 | Apache-2.0 selected from the upstream dual license |

ZIPFoundation 0.9.20 remains MIT; its full existing license is preserved under
`shared/licenses/ZIPFoundation-LICENSE.txt`. Source-control and archive services
use these source-built libraries; this inventory does not claim App or device
qualification. Release packaging must retain the exact source, patch and build
materials required by the applicable licenses.

## Embedded terminal

The selected terminal-emulator sources and TerminalRenderer from termux/termux-app v0.118.3 (5b657c6adf4304e5198951ce815fe0205dcac29c) use the upstream terminal-library Apache-2.0 exception. Full license texts and lineage are in `licenses/terminal` and packaged under `assets/legal/terminal`. Only the documented parser/buffer/renderer subset is reused; Floe owns the execution lifecycle. Source hashes and the two documented patches are recorded in `feature/terminal/PROVENANCE-TERMUX.md`.

## C03 image encoding and C04 offline viewing

AndroidX HeifWriter 1.1.0 (`androidx.heifwriter:heifwriter`) is Apache-2.0.
The exact upstream license and pinned provenance are bundled at
`assets/legal/heifwriter/` and retained in `licenses/heifwriter/`.

The read-only CAD viewer retains its pinned CAD/OCCT source notices, license
texts and source locations under `assets/cad_viewer/` and
`licenses/cad_viewer/`. MiSans font license and provenance are also bundled
under `assets/legal/cad-viewer/`. Android-specific adapters do not change
those upstream terms. Component source availability and final package
contents remain part of release qualification.

## C05 native SSH

The Android SSH port reuses the fixed FloeSSH source and exact Citadel,
SwiftNIO, NIOSSH, Crypto, BigInt and support-package revisions recorded in
`licenses/ssh/`. Full upstream license/source notices are retained there and
bundled under `assets/legal/ssh/`. No SwiftTerm or host ssh executable is
used. Android-specific transport changes retain their source lineage.

## C06 pinned NetBare forwarding and root capture helper

C06 vendors only the reviewed IPv4 TCP/UDP forwarding subset of
`MegatronKing/NetBare-Android` at commit
`df5b417ea663763932cabf1ef52f15b09ddc2e16`. The repository `LICENSE` is MIT
(Copyright © 2019 Megatron King), while upstream source file headers still
carry GPLv3 text. Both notices are retained and the exact vendored source,
paths, hashes and local compatibility patch lineage are recorded in
`FloeAndroid/vendor/netbare/UPSTREAM.json` and
`FloeAndroid/licenses/netbare/`. No NetBare HTTP/SSL injection, UID dumper,
sample app, prebuilt JNI or Maven/JCenter artifact is linked.

The Full-only root capture helper is **not** distributed by this App and is
never downloaded by it. The App accepts only a pinned helper at a fixed
root-owned path and records the source binding in the C06 private handoff for
Main's later build/install qualification. Play contains no root adapter.

## C05 VNC

RoyalVNCKit is pinned to 92d4427c73817d8f849bb289ff190aa4b40c44ea, with the documented Android socket and lifetime port. CryptoSwift is pinned to a59b4d91ebb22011656c830f874fe7152e183a57. MIT, d3des public-domain and platform zlib notices are retained under licenses/vnc and packaged under assets/legal/vnc. The vendored source and local port notes are under shared/Vendor/Remote/RoyalVNCKit.

## C05 device communication

USB serial uses usb-serial-for-android3.11.0, fixed upstream8e694372dee4531d140766df7af3189d3d9531c5 and the pinned JitPack artifact. The MIT license and artifact/source hashes are retained under licenses/devicecommunication and packaged under assets/legal/devicecommunication. BLE GATT uses Android platform APIs; TCP/Telnet uses the JDK socket implementation.

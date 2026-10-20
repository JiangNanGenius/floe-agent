# Android dependency notices

Floe-owned source remains MPL-2.0 under the repository license. The shared
`TaskPolicy.swift` source link retains the original implementation and license.

The G01 application uses the following upstream runtime components. Exact resolved
versions and checksums belong to the Gradle locks, verification metadata and
`toolchains.lock.json`; this file is an inventory, not a replacement for upstream
license texts or the final distribution source/notice obligations.

| Component | Source | License |
| --- | --- | --- |
| Kotlin standard library | https://github.com/JetBrains/kotlin | Apache-2.0 |
| AndroidX Activity/Core/Compose/Material/icons and transitive AndroidX runtime | https://android.googlesource.com/platform/frameworks/support/ | Apache-2.0; preserve individual file notices |
| kotlinx.coroutines | https://github.com/Kotlin/kotlinx.coroutines | Apache-2.0 |
| Compose Cupertino 3.3.1 (selected for the G01 UI foundation) | https://github.com/RobinPcrd/compose-cupertino/tree/3.3.1 | Apache-2.0; retain upstream NOTICE and contributor lineage |
| commonmark-java 0.30.1 (`org.commonmark:commonmark`, `commonmark-ext-gfm-tables`, `commonmark-ext-gfm-strikethrough`) — pure-JVM Markdown parse adapter for the conversation rich-body projection | https://github.com/atlassian/commonmark-java | BSD-2-Clause; copyright per the shipped license ("Copyright (c) 2015, Atlassian Pty Ltd"), full text preserved at `FloeAndroid/licenses/commonmark/LICENSE.txt` (extracted from the pinned jar's `META-INF/LICENSE.txt`) |
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

The Cupertino selection excludes `cupertino-icons-extended`: its original README
separately identifies the SF Symbols artwork as copyrighted. Floe uses its own
permitted assets and geometric outline icons. The selected widget code is
distinct from that optional icon collection. See the upstream `LICENSE.txt` and
`NOTICE.txt` at the pinned revision; final distribution notices must also cover
the exact resolved transitive graph.

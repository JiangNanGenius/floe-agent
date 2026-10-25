# Sora Editor 0.24.4

- Maven coordinate: `io.github.rosemoe:editor:0.24.4`.
- Upstream: https://github.com/Rosemoe/sora-editor
- Tag: `0.24.4`; commit: `1e199e11dcbf9e6526cdcbdf1bdb25b74140496a`.
- License text: `LICENSE` in this directory, preserved byte-for-byte from the tag. Retain the version notices in individual upstream source files.
- License SHA-256: `7ffe1954587c77dfba1cf8eb9b2ea743671fa6e63f9e7a2f258119d42e14eefe`.
- AAR SHA-256: `ee0ff49a899dc2fa7ab5dd7388e733f0c606333d54864c599644be640095a428`.
- Sources JAR SHA-256: `71dc680e5b5aeeecb8fa32fbb6cd354dce19deb97b7ea7e70ece845bfb705156`.

This dependency supplies the native editor widget. Floe's presentation module uses its public APIs; document ownership, revisions and saves remain in the shared workspace services. Exact resolved artifacts still require the Gradle lock and checksum verification step. Distribution must retain the corresponding source and rebuild information for the actual shipped graph.

## Floe completion surface adaptation

`feature/ide/src/main/kotlin/com/floe/android/feature/ide/sora/FloeCompletionSurface.kt`
adapts the pinned editor's default completion layout chrome and popup placement. It
retains the upstream copyright and LGPL-2.1-or-later notice. The layout uses bounded
list positioning and places candidates above the caret when space below is too
small; it uses public editor APIs and leaves the published upstream AAR unchanged.
The adaptation source and build configuration are distributed in the Floe source
repository at the exact release commit.

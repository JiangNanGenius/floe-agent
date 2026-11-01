# AndroidX HeifWriter 1.1.0

Pinned implementation dependency for the C03 real HEIC export path.

- Coordinate: `androidx.heifwriter:heifwriter:1.1.0`
- License: Apache License 2.0 (`LICENSE.txt`, SHA-256
  `809fa1ed21450f59827d1e9aec720bbc4b687434fa22283c6cb5dd82a47ab9c0`)
- Upstream release page: https://developer.android.com/jetpack/androidx/releases/heifwriter
- Primary public API used: `androidx.heifwriter.HeifWriter` with
  `INPUT_MODE_BITMAP`, `Builder.setQuality`, `Builder.setMaxImages(1)`,
  `start()`, `addBitmap(Bitmap)`, `stop(timeoutMs)` and `close()`.

The Gradle/dependency-lock edits are Main-owned and are delivered as an exact
private patch in the C03 image handoff. This directory retains the license and
provenance only; it does not add a second dependency mechanism.

AndroidX HeifWriter 1.1.0 does not expose high-bit-depth output
(`highBitDepthEnabled=false` in its constructor). The Floe export boundary
therefore treats HEIC as 8-bit SDR and refuses HDR sources unless the user
explicitly creates an SDR copy first.

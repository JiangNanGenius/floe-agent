# Floe Visual Novel Runtime — Third-Party Binaries

This directory carries the frozen KiriKiri slices embedded in the App, their
license and provenance, and the standalone macOS ONS build record. Native engine
binaries come from pinned upstream sources. Game content, assets and scripts
are excluded.

## ShioriKrkr.xcframework (Kirikiri / 吉里吉里)

- **Engine**: Shiori's own KiriKiri 2/Z engine (`OWCramer/KiriKit` 0.1.3,
  krkr2 core by 2468785842 at `3ac366c439a142f1712ed3059cb80184cb102dbf`).
- **Slices**: `ios-arm64` (iphoneos, minos 17.0, generic build, unsigned) and
  `ios-arm64-simulator` (minos 17.0). Both export exactly the 13 C symbols of
  `shiorikrkr.h`; every krkr2/TJS2/dependency symbol is internalized so the
  framework coexists with other engines in one process.
- **Verified SHA-256** (frozen record `Local/Artifacts/floe-visual-novels-20261122/kirikiri-runtime-sha256.txt`):
  - device `2dddb86e5c95a8de6ba85b0a6ffea6befb39be818a8d27f44fe99379b5b0fa69`
  - simulator `71778e33f2a2f8701d0bf3ce44bba66f2457b9864e1c7f67262347ed44db4cfd`
- **Load model**: the App embeds this framework **without linking** and
  `dlopen`s it when a Kirikiri game starts (never at App launch — the engine's
  SDL3 must not bind OpenGLES ahead of MetalANGLE). Xcode signs it on copy.
- **Licenses**: MPL-2.0 (KiriKit + shiori), BSD-style KiriKiri license
  (krkr2 core + plugins), LGPL-2.1-or-later for the statically linked FFmpeg
  n8.0.3 (no GPL/nonfree components; `--disable-network`). See `LICENSES/`.
- **Corresponding source**: the matching App source tag contains the KiriKit
  and FFmpeg source archives, the pinned engine and plug-in patches, and the
  build and relink instructions. [Rebuild and relink](Relink/README.md)

## ONS (onslaught) — license/relink record only

- `ONS/ONSlaught-Licence.txt`, `ONS/onslaught-macos-arm64.patch` and
  `ONS/build-ons-macos.sh` are the pinned license and build record for the
  ONScripter-family engine (`Helios-vmg/ONSlaught` at
  `b1d671976f57fb9ed2218f849c8b66a3637f15cc`, BSD-style license, mpg123 LGPL-2.1
  dynamically linked on the Mac build, MIDI/tracker disabled).
- **No iOS binary ships in this checkout.** The verified slice is the macOS
  arm64 probe (`FloeONSRuntime`); an iOS slice requires an iOS dependency build
  (SDL2/sdl12-compat, FreeType, libpng, libjpeg-turbo, FLAC, Vorbis, Ogg,
  mpg123) that is not part of this delivery. The App reports ONS projects
  honestly through the run-route prerequisite instead of faking a run.
- Upstream source retained at
  `Local/Scratch/floe-ons-runtime-20261122/upstream/ONSlaught`.

## Apple guideline 2.5.2 note

The KiriKiri engine is compiled into the bundled framework and interprets TJS.
The loader uses the signed App framework, the engine confines file access to
the game root and engine temporary directory, and the host exposes only its
startup, frame, input, logging and shutdown interfaces. App Review acceptance
is a separate qualification step.

# Ren'Py 8.5.3 Web (Beta) — component notice addendum

This addendum supplements the official `RENPY-LICENSE.txt`. It records the
components actually linked or embedded in the official Web build, their exact
source pins, and the LGPL-2.1 §6(a) source/relink materials. It is not legal
advice and does not claim App Store approval.

## Exact runtime provenance

- Official runtime: `renpy-8.5.3-web.zip`, SHA-256
  `954db897e65f51ea63cb2fb7b203d02be0447f4e22069514020bbe6c6691fdfc`.
- Official arm64 SDK used for the launcher: `renpy-8.5.3-sdkarm.tar.bz2`,
  SHA-256
  `0579782517f203ba3535dcc2dab54e34bfc318f2f2a7510a5130b6f809f901f6`,
  version `8.5.3.26051504`.
- Ren'Py source tag `8.5.3.26051504`, commit
  `39895c1e017f0b36ffea2447d97eccd69d76ee1c`; archive SHA-256
  `706daeeeb8dfe5e441d2697fbbb8bfc530dc2999ebda2bc81d15a5a2b3393448`.
- Build repository tag `renpy-8.5.3.26051504`, commit
  `7bfab40c1174f622f644b24669afd5fb167fbb79`; archive SHA-256
  `15f15bc524f6b8b173ba8671d1992140051c7d9455ac81a24338a433a5127446`.
- `runtime/web/renpy-pre.js`, `manifest.json` and `service-worker.js` in the
  official Web zip are **byte-identical** to the build tag. `index.html` is
  generated from the build tag's `shell.html`.
- Build toolchain: Emscripten **3.1.67** (`tasks/toolchain.py`), Python
  **3.12.8**, `-sASYNCIFY=1`, `-sFILESYSTEM=1`, IDBFS preloaded. The official
  build directory embedded in `renpy.wasm` is
  `/home/tom/ab/renpy-build-fix/...`, consistent with the official builder.
- The build was not byte-reproduced here. The source tags, the byte-identical
  web glue files, and the exact dependency tarballs are recorded so the release
  owner can reproduce or provide the corresponding source.

## Components actually linked/embedded

| Component | Version | Role | License | Notice | Evidence |
| --- | --- | --- | --- | --- | --- |
| Ren'Py | 8.5.3.26051504 | engine | MIT (most); LGPL-derived portions as listed | `RENPY-LICENSE.txt` | source tag/commit; web zip |
| Python | 3.12.8 | CPython runtime | PSF | `PYTHON-3.12.8-LICENSE.txt` | `link_web -l3.12`; `renpy.data` `/lib/python3.12/` |
| FFmpeg (libavcodec/avformat/swscale/swresample/avutil) | 4.3.1 | media | **LGPL-2.1-or-later** | `FFMPEG-4.3.1-COPYING.LGPLv2.1.txt` | `link_web` `-lavcodec/-lavformat/-lswscale/-lswresample/-lavutil`; `libavcodec/*.c` paths and `avcodec_open2` in `renpy.wasm` |
| FriBidi | 1.0.7 | bidirectional text | **LGPL-2.1-or-later** | `FRIBIDI-1.0.7-COPYING.txt` | `link_web -lfribidi`; `renpy/text/bidi.pyx` includes `fribidi/fribidi.h`; `renpy.text.bidi` in `renpy.wasm` |
| chardet | 5.2.0 | charset detection (pure Python) | **LGPL-2.1** | `CHARDET-5.2.0-LICENSE.txt` | `renpy.data` contains `lib/python3.12/chardet/*.pyc`; SDK `chardet/version.pyc` = 5.2.0 |
| SDL_gfxPrimitives (vendored in Ren'Py `src/pygame`) | Ren'Py 8.5.3 source | drawing primitives (`renpy.pygame.gfxdraw`) | **LGPL-2.1** | `LGPL-2.1.txt` | `src/pygame/SDL_gfxPrimitives.c` header "LGPL (c) A. Schiffler"; `src/Setup` maps `renpy.pygame.gfxdraw` to that file |
| pygame `alphablit.c` / `surface.h` (vendored) | Ren'Py 8.5.3 source | alpha blitting / surface (`renpy.pygame.surface`) | **LGPL-2.0-or-later** | `LGPL-2.0.txt` | headers say GNU Library GPL v2 or later; `src/Setup` maps `renpy.pygame.surface` to `alphablit.c` |
| SDL2 | 2.0.20 | platform layer | zlib | `SDL2-2.0.20-COPYING.txt` | `link_web -lSDL2`; source tarball |
| SDL2_image | 2.6.2 | image loading | zlib | `SDL2_IMAGE-2.6.2-LICENSE.txt` | `link_web -lSDL2_image` |
| FreeType | 2.13.3 | fonts | FTL | `FREETYPE-2.13.3-FTL.txt` | `link_web -lfreetype` |
| HarfBuzz | 8.0.1 | shaping | MIT | `HARFBUZZ-8.0.1-COPYING.txt` | `link_web -lharfbuzz` |
| brotli | 1.1.0 | compression | MIT | `BROTLI-1.1.0-LICENSE.txt` | `link_web -lbrotlidec/-lbrotlicommon` |
| libpng | 1.6.43 | PNG | libpng-2.0 | `LIBPNG-1.6.43-LICENSE.txt` | `link_web -lpng` |
| libjpeg-turbo | 1.5.3 | JPEG | IJG / BSD-3 / zlib | `LIBJPEG-TURBO-1.5.3-LICENSE.md` | `link_web -ljpeg` |
| libwebp | 1.3.2 | WebP | BSD-3-Clause | `LIBWEBP-1.3.2-COPYING.txt` | `link_web -lwebp` |
| libavif | 0.11.1 | AVIF | BSD-2-Clause | `LIBAVIF-0.11.1-LICENSE.txt` | `link_web -lavif` |
| aom | 3.5.0 | AV1 | BSD-3-Clause + AOM patent license | `AOM-3.5.0-LICENSE.txt` | `link_web -laom` |
| libyuv | commit `331c361581896292fb46c8c6905e41262b7ca95f` | YUV | BSD-3-Clause | `LIBYUV-LICENSE.txt` | `link_web -lyuv`; `tasks/libyuv.py` |
| assimp | 5.4.3 | 3D model import | BSD-3-Clause | `ASSIMP-5.4.3-LICENSE.txt` | `link_web -lassimp` |
| xz/liblzma | 5.4.2 | LZMA | liblzma: public domain (xz CLI/scripts not linked) | `XZ-5.4.2-COPYING.txt` | `link_web -llzma` |
| bzip2 | 1.0.8 | bzip2 | BSD-like | `BZIP2-1.0.8-LICENSE.txt` | `link_web -lbz2` |
| zlib | 1.3.1 | zlib | zlib | `ZLIB-1.3.1-LICENSE.txt` | `link_web -lz` |
| Emscripten | 3.1.67 | generated JS/WASM runtime, IDBFS | MIT / NCSA | `EMSCRIPTEN-3.1.67-LICENSE.txt` | `tasks/toolchain.py`; `-lidbfs.js` |

`libusb` is named in `RENPY-LICENSE.txt` but is **not** linked in the Web
build (`link_web` has no `-lusb`; the Web runtime has no USB access). It is not
a component of this distribution.

## LGPL-2.1 §6(a) source and relink path

Floe chooses §6(a) for every LGPL component:

- **FFmpeg**: exact source `ffmpeg-4.3.1.tar.gz` (SHA-256
  `45035f15d6f192772de2309c846e1d60472694f479679354a39c699719e53772`),
  built by `tasks/ffmpeg.py` with two pinned patches. The full source is
  included in `source-packages/renpy/`.
- **FriBidi**: exact source `fribidi-1.0.7.tar.bz2` (SHA-256
  `5ab5f21e9f2fc57b4b40f8ea8f14dba78a5cc46d9cf94bc5e00a58e6886a935d`),
  built by `tasks/fribidi.py`.
- **chardet**: exact sdist `chardet-5.2.0.tar.gz` (SHA-256
  `1b3b6ff479a8c414bc3fa2c0852995695c4a026dcd6d0633b2dd092ca39c1cf7`).
  The engine loads the compiled `.pyc` from `renpy.data`; replacing the
  chardet module and rebuilding the data is the relink/replace path.
- **SDL_gfxPrimitives / pygame LGPL portions**: exact files are included in
  `renpy-39895c1.tar.gz` and in the convenience archive
  `renpy-lgpl-src.tar.gz` (SHA-256
  `5f9c584a2779492c12b6e0037aacbc204376ea43c4f9687ce24f4131c77b8822`),
  compiled by `src/Setup` and `tasks/librenpy.py`. Replacing those files and
  rebuilding `librenpy`/the Web runtime is the relink path.

The work that uses the libraries is Ren'Py
`39895c1e017f0b36ffea2447d97eccd69d76ee1c` plus the build repository
`7bfab40c1174f622f644b24669afd5fb167fbb79`; both are included in
`source-packages/renpy/`. Rebuild route:
`build.sh web` in the official `renpy-build` tag (requires the pinned Emscripten
3.1.67 and the dependency sources in `source/`). No reverse-engineering
restriction is added by Floe. See `source-packages/renpy/RELINK.md`.

## Persistence (IDBFS), stated precisely

- `renpy-pre.js` mounts IDBFS at `/home/web_user/.renpy` and calls
  `FS.syncfs(true)` before the engine starts.
- Ren'Py's save path calls `FS.syncfs(false)` (the string is present in
  `renpy.wasm` and the Python save code); saves are engine-internal, not host
  snapshots.
- A persistent WKWebsiteDataStore and a stable per-project origin are required
  for durability across player instances. This is the Core storage owner's
  work; this package does not change it and does not claim durability from
  generic IndexedDB success.

## Source/notice hashes

All hashes are recorded in `../../Scripts/Distribution/distribution-lock.json`
and checked by `../../Scripts/check_distribution.py`.

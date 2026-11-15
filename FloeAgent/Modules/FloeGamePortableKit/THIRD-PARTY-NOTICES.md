# Third-party notices — FloeGamePortableKit

Component source is MPL-2.0 (`LICENSE`). Original starter templates are also
MIT (`LICENSE-FLOE-STARTER-MIT.txt` in each template). Runtime resources are
prepared on demand and are **not** embedded in the native package.

The machine-readable receipt is
`Scripts/Distribution/distribution-lock.json`; the read-only preflight is
`Scripts/Distribution/check_distribution.py`. The receipt records exact source
pins, notice hashes, source-package hashes, LGPL components, relink paths,
eligibility and limitations. This file is a summary, not legal advice, and does
not claim App Store approval.

## RPG Maker MV CoreScript

- https://github.com/rpgtkoolmv/corescript
- Pin `182e31449707ba7e406db0485c44c2a9d11e2dcd` (community v1.3b), MIT,
  Copyright (c) 2015 KADOKAWA CORPORATION./YOJI OJIMA.
- Prepared files: six concatenated `js/rpg_*.js`, reviewed MIT web libraries
  (PIXI 4.5.4, pixi-tilemap, pixi-picture, FPSMeter, lz-string,
  iphone-inline-video) and their notices under `licenses/`.
- No RTP, editor asset, sample game, MZ runtime or commercial plugin is
  included. The starter map, data and procedural artwork are original Floe
  content under MIT.
- MIT-only path; no LGPL component and no change to the prepared runtime.

## love.js / LÖVE

- love.js: https://github.com/Davidobot/love.js, npm `love.js@11.4.1`,
  tarball SHA-256 `9eb2db1f789254faed8e5cf7eeeded46a7e56ecbc931c88be809526c448d25fb`,
  source commit `8f9a7b85da9149b6d4d0af46442ead1e71f76477` (npm `gitHead`,
  2022-08-25). The shipped WASM files are byte-identical to that commit; text
  files are CRLF-normalized copies. The later `c4f04e18...` commit is LÖVE 11.5
  work and is not this runtime.
- LÖVE: 11.4 (zlib). The compatibility runtime reports LÖVE 11.4.0.
- Build: `build_lovejs.sh`, emsdk 2.0.0, `-DLOVE_JIT=0`,
  `-DCMAKE_BUILD_TYPE=Release`, `-DLOVEJS_COMPAT=1` (compat). Publish-time
  source pins: `Davidobot/love` `a79ab87...`, `Davidobot/megasource`
  `b1faef45...`.
- `licenses/LOVE-11.4-LICENSE.txt` is the exact LÖVE 11.4 umbrella notice.
  The retained `LOVE-11.5-LICENSE.txt` is **not** used for this binary; it is
  preserved only in private research as evidence of the earlier mismatch.
- Actual components in the binary: LÖVE, love.js, Emscripten 2.0.0, SDL2
  2.0.10, mpg123 1.25.6, FreeType 2.8.1, libogg 1.3.2, libvorbis 1.3.5,
  libtheora 1.1.1, libmodplug 0.8.8.4, zlib 1.2.11, Lua 5.1.5, ENet and other
  permissive LÖVE-bundled libraries. **mpg123 1.25.6 is LGPL-2.1**; complete
  corresponding source, vendor delta and relink route are in
  `licenses/LOVE-11.4-COMPONENT-ADDENDUM.md` and the source package.
- OpenAL Soft 1.19.1 and LuaJIT 2.1.0 are named by LÖVE but are **not linked**
  in this Emscripten build: OpenAL is Emscripten's `library_openal.js`
  (MIT/NCSA) and the build uses `LOVE_JIT=0` with Lua 5.1.5. Their notices are
  retained for completeness only; see the addendum.
- Emscripten 2.0.0 license is retained. Generated JS/WASM retains its upstream
  nature.
- Persistence: IDBFS at `/home/web_user/love`; the **unpatched** loader flushes
  only on `beforeunload` and failed a real new-player save test. Root's
  authoritative `Module.floePrepareToStop` patch/candidate passed actual native
  WebKit cross-player save with unchanged `love.wasm`/`game.data`; the
  candidate's current 11.5 notice folder must be replaced with this package's
  11.4 bundle before distribution. See `licenses/LOVE-11.4-COMPONENT-ADDENDUM.md`.
- No proprietary LÖVE game asset, RTP, native executable or signed iOS binary
  is bundled.

## Ren'Py

- Official Web support:
  https://www.renpy.org/dl/8.5.3/renpy-8.5.3-web.zip, SHA-256
  `954db897e65f51ea63cb2fb7b203d02be0447f4e22069514020bbe6c6691fdfc`.
- SDK: `renpy-8.5.3-sdkarm.tar.bz2`, SHA-256
  `0579782517f203ba3535dcc2dab54e34bfc318f2f2a7510a5130b6f809f901f6`,
  version `8.5.3.26051504`.
- Source pins: Ren'Py `39895c1e...` (tag `8.5.3.26051504`), build repository
  `7bfab40c...` (tag `renpy-8.5.3.26051504`). Web glue files are byte-identical
  to the build tag; the WASM/data are official outputs, not byte-reproduced
  here.
- Most of Ren'Py is MIT. The Web binary actually links/embeds **LGPL-2.1**
  FFmpeg 4.3.1, FriBidi 1.0.7, chardet 5.2.0, SDL_gfxPrimitives and pygame
  LGPL portions. Exact source and relink route are in
  `licenses/RENPY-8.5.3-COMPONENT-ADDENDUM.md` and the source package.
  `libusb` is named in the upstream license but is not linked in the Web build.
- `RENPY-LICENSE.txt` is the exact upstream SDK license. The component
  addendum supplies the per-component notices and source pins.
- The starter `.rpy` content is original Floe MIT content; no tutorial, demo or
  premium Ren'Py asset is copied.

## Distribution, source and relink

- self-authored Swift remains MPL-2.0; starter content is MPL-2.0 + MIT;
  third-party files retain their original licenses. No whole-App GPL
  relicensing, no additional use restrictions and no Exhibit B notice is added
  to third-party files.
- LÖVE's LGPL component is mpg123; Ren'Py's are FFmpeg, FriBidi, chardet,
  SDL_gfxPrimitives and pygame LGPL portions. The profile uses LGPL-2.1 §6(a):
  complete corresponding source plus the work that uses the Library in source
  form, so a user can modify the library and relink. Source packages are in the
  private release source depot; the release owner must publish them with the
  binary or provide the §6(c) written offer.
- Exact source hashes, notice hashes, prepared-manifest hashes and the
  read-only preflight command are in
  `Scripts/Distribution/distribution-lock.json`.
- User-imported game files are user-supplied data. They are preserved wholesale
  regardless of engine/license recognition and are not relicensed by Floe; no
  new user-facing approval gate is introduced.
- The profile does not claim App Store review/approval, signing, archive,
  Simulator, device or publication. Apple WebKit is an OS framework; the WASM
  executes inside WebKit and is not statically linked into the signed native
  App binary, but LGPL obligations attach to the WASM distribution itself.

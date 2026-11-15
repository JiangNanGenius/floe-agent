# LÖVE 11.4 / love.js 11.4.1 — component notice addendum

This addendum is part of the Floe distribution profile for the **compatibility
(single-threaded) love.js runtime** and its **release (pthread) sibling**.
It supplements, and does not replace, `LOVE-11.4-LICENSE.txt`. It records the
actual components identified in the published binaries, including components
that are absent from LÖVE's own umbrella notice.

## Exact runtime provenance

- npm tarball: `love.js@11.4.1`, SHA-256
  `9eb2db1f789254faed8e5cf7eeeded46a7e56ecbc931c88be809526c448d25fb`.
- npm registry `gitHead`: `8f9a7b85da9149b6d4d0af46442ead1e71f76477`
  (2022-08-25), not the later `c4f04e18...` commit used by LÖVE 11.5.
- The npm tarball's `src/compat/love.wasm` and `src/release/love.wasm` are
  **byte-identical** to the public source tree at `8f9a7b85...`. Text files
  (`love.js`, `index.html`, theme, `package.json`, `LICENSE`) are the same
  bytes after CRLF→LF normalization. Thus the shipped runtime is tied to the
  public commit, not merely to a version string.
- Build recipe at that commit: `build_lovejs.sh`/`.bat`, emsdk **2.0.0**
  (`README` requires 2.0.0 because newer Emscripten removed `getMemory`).
- At the 2022-08-25 publish timestamp the build recipe's mutable branches
  pointed at:
  - `Davidobot/love` `emscripten`: `a79ab87d82f1105e8badd39ff22cfad02882ddc1`
  - `Davidobot/megasource` `emscripten`: `b1faef45bd5ec10b9b5a78ffea57401188790283`
  These are the source pins used by this profile. The upstream recipe does not
  record the commits immutably; a clean byte-identical rebuild was **not**
  performed here. The runtime identity is proven by the committed binary
  equality above, and the dependency identities below are proven by the
  binary's embedded source paths and the pinned dependency tree.
- Compatibility flags:

  ```
  emcmake cmake <megasource> -DLOVE_JIT=0 -DCMAKE_BUILD_TYPE=Release \
    -DLOVEJS_COMPAT=1 -DSEXPORT_ALL=1 -DSMAIN_MODULE=1 \
    -DSERROR_ON_UNDEFINED_SYMBOLS=0
  ```

  The release variant is the same source with `-DLOVEJS_COMPAT=1` removed and
  pthreads enabled.

## Components actually in the binaries

| Component | Version | Role | License | Notice | Evidence |
| --- | --- | --- | --- | --- | --- |
| LÖVE | 11.4 | engine | zlib | `LOVE-11.4-LICENSE.txt` | `src/common/version.h` `LOVE_VERSION_STRING "11.4"`; binary `11.4` |
| love.js | 11.4.1 | Emscripten wrapper / CLI | MIT | `LOVE.JS-MIT.txt` | `package.json`, npm tarball |
| Emscripten | 2.0.0 | generated JS/WASM runtime, IDBFS, OpenAL Web Audio shim | MIT / NCSA | `EMSCRIPTEN-2.0.0-LICENSE.txt` | `README` pins 2.0.0; `library_openal.js` implements `al*`/`alc*`; `SDL2-version_22` port path in `love.wasm` |
| SDL2 | 2.0.10 | window, input, audio | zlib | `SDL2-2.0.10-COPYING.txt` | Emscripten `sdl2` port `version_22` (`SDL_version.h`); `SDL2-version_22` path in `love.wasm` |
| mpg123 | 1.25.6 | MP3 decoding | **LGPL-2.1** | `MPG123-1.25.6-COPYING.txt` | `mpg123-1.25.6/src/libmpg123/*.c` paths in `love.wasm`; megasource `MEGA_MPG123_VER 1.25.6` |
| FreeType | 2.8.1 | font rasterizer | FTL | `FREETYPE-2.8.1-FTL.txt` | `FT_Init_FreeType` / `love.font.freetype` in `love.wasm`; megasource `MEGA_FREETYPE_VER 2.8.1` |
| libogg | 1.3.2 | Ogg container | BSD-3-Clause | `LIBOGG-1.3.2-COPYING.txt` | megasource dependency; LÖVE audio/video |
| libvorbis | 1.3.5 | Vorbis audio | BSD-3-Clause | `LIBVORBIS-1.3.5-COPYING.txt` | `VorbisDecoder` in `love.wasm`; megasource |
| libtheora | 1.1.1 | Theora video | BSD-3-Clause | `LIBTHEORA-1.1.1-COPYING.txt` | `TheoraVideoStream` in `love.wasm`; megasource |
| libmodplug | 0.8.8.4 | MOD audio | public domain | `LIBMODPLUG-0.8.8.4-COPYING.txt` | `ModPlugDecoder` in `love.wasm`; megasource |
| zlib | 1.2.11 | compression | zlib | `ZLIB-1.2.11-LICENSE.txt` | `1.2.11` in `love.wasm`; megasource |
| Lua | 5.1.5 | scripting runtime | MIT | `LUA-5.1.5-COPYRIGHT.txt` | `Lua 5.1` in `love.wasm`; `-DLOVE_JIT=0` selects `lua51` |
| ENet | LÖVE-bundled 1.3.x | networking | MIT | `ENET-MIT.txt` | `src/libraries/enet/libenet`; `LOVE-11.4-LICENSE.txt` |
| Other LÖVE-bundled libraries | as listed in LÖVE 11.4 | GLAD, glslang, lua-compat, lua-enet, Lua UTF-8, LuaSocket, LZ4, LodePNG, TinyEXR, UTF8-CPP, xxHash, dr_flac, stb_image | as listed in LÖVE 11.4 | `LOVE-11.4-LICENSE.txt` | upstream umbrella notice; all permissive |

## Components named by LÖVE but **not linked** in this build

- **OpenAL Soft 1.19.1** — not compiled into these WASM binaries. The
  `al*`/`alc*` imports are satisfied by Emscripten 2.0.0's
  `src/library_openal.js` (MIT/NCSA), and the megasource `EMSCRIPTEN` branch
  excludes the native OpenAL build. `OPENAL-SOFT-1.19.1-COPYING.txt` is
  retained for completeness; it does not describe code in this binary.
- **LuaJIT 2.1.0-0bee44c** — not linked. The build uses `-DLOVE_JIT=0`; the
  Lua runtime is 5.1.5. `LUAJIT-2.1.0-COPYRIGHT.txt` is retained because the
  LÖVE 11.4 notice mentions LuaJIT; it does not describe code in this binary.
  The `LuaJIT` strings inside the WASM are comments from LÖVE's Lua bootstrap,
  not a linked LuaJIT.

## Why this addendum exists

The upstream `LOVE-11.4-LICENSE.txt` (SHA-256
`4605993b18eb43800ca12ac7fe904c040f9ab39c5e5616dd02eb1ed4ed47deac`)
does not list FreeType, SDL2, libogg, libvorbis, libtheora, libmodplug, zlib or
Lua 5.1.5, even though those components are present in the Emscripten build.
The retained 11.5 notice is **not** used: the binary reports 11.4, and the 11.5
notice differs (it adds FreeType and changes the LÖVE copyright year). Using
11.5 would be a false provenance claim. This addendum supplies the missing
notices and explicitly identifies the non-linked entries.

## LGPL-2.1 obligation and relink path

`mpg123` is the only LGPL library compiled into the LÖVE/love.js WASM. Floe
chooses LGPL-2.1 §6(a): it supplies the complete corresponding source for
mpg123 (the exact megasource tree, plus the upstream reference and the
megasource delta) and the complete source of the work that uses it (LÖVE
`a79ab87...`, love.js `8f9a7b85...`, megasource `b1faef45...`), together with
the exact build recipe. A user can modify mpg123, rebuild the WASM with emsdk
2.0.0, and run the modified runtime. See `../../source-packages/love/RELINK.md`.

No reverse-engineering restriction is added by Floe. The native App code stays
MPL-2.0; the WASM is a separate distribution item.

## Persistence (IDBFS), stated precisely

- The LÖVE fork's `src/scripts/EmscriptenPersistence.js` (SHA-256
  `2176225739b95988edef11554233e6d6eb7a2a4ff78375b9021c5a482f4227de`)
  mounts Emscripten **IDBFS** at `/home/web_user/love`, calls
  `FS.syncfs(true)` before the game starts, and calls `FS.syncfs(false)` on
  `window.beforeunload`.
- LÖVE's save directory is the identity subdirectory (for the starter,
  `floe-tidepool` → `/home/web_user/love/floe-tidepool`). The IDBFS mount
  therefore covers engine saves.
- The runtime does **not** call `syncfs` after every `love.filesystem.write`,
  has no `saveFS` symbol, and does not expose `FS` or a flush method on the
  `Love` object. A generic browser IndexedDB success or a durable
  WKWebsiteDataStore alone is **not** proof that a LÖVE save survives a new
  player.
- Initial real lifecycle evidence failed: S/write -> stop -> **new** GameWebPlayer
  -> L/read produced `Could not open file floe-save.txt. Does not exist.`,
  confirming the beforeunload-only gap.
- Root prepared the authoritative generated-loader source patch:
  `Scripts/Distribution/patches/love/EmscriptenPersistence.js.patch`
  (SHA-256 `e678aa5191f9ed39591c27fedd11e7e3242e638dfa2afbb519653e6cd78ef2ef`)
  and `LOVE-PERSISTENCE-SOURCE-PATCH.json` (SHA-256
  `32f50673919173a951a7b86439cd4f8313c9c1c133b37a137cd1759abb55454b`).
  It adds `Module.floePrepareToStop`, queues `FS.syncfs(false)`, pauses the
  main loop, and changes no WASM or user content. Root owns those files; do not
  overwrite them during integration.
- Root's actual native WebKit follow-up then **PASSED**:
  `web-storage-final/native-close-1/record.json` (SHA-256 `c6066331...`),
  with `crossPlayerBuiltInSavePersistenceVerified: true`; the original Lua game
  saved x=641.04, stopped with `.saved`, a **new** GameWebPlayer started at
  x=480, and L read x=641.04 from the original file. The candidate receipt is
  `mpl-compat/love-close-candidate-1-receipt.json` (SHA-256 `e6d98d33...`);
  the patched loader is `a9fec128...`, while `love.wasm` (`ecc9e098...`) and
  `game.data` (`51fcbc69...`) are unchanged. Root ran the test; this task did
  not repeat it.
- The unpatched upstream loader (`12db012a...`) is **not** durable by itself.
  The distribution candidate must use Root's patched loader or an equivalent,
  plus the Core storage lifecycle. The candidate's current `LOVE-11.5-LICENSE.txt`
  in its private license folder is not the final 11.4 notice bundle; replace
  that bundle with this package's `LOVE-11.4-*` notices before publication.
- A synthetic `beforeunload` dispatch timing pass is **not** evidence of
  durability. The optional
  `../../Scripts/Distribution/patches/love/floe-persist.js` overlay only calls
  `floePrepareToStop` (or a synthetic event as a stopgap) and is not proof.
  Core WebKit persistence remains the Core owner's work.

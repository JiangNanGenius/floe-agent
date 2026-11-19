# TIC-80 v1.4.1 and blip_buf — source / relink offer

This file accompanies the Floe-prepared TIC-80 v1.4.1 Web player. It is an
engineering source/relink record, not a legal clearance or an App Store claim.

## Actual binary provenance

- Player loader `tic80.js`: SHA-256 `f5f940a807dfdcbc81425cb4c49cfbc42526056e5160ba0db60b32489ac37f62`
- Player engine `tic80js.wasm`: SHA-256 `7ae37e4deff0e9e633aa407a60f6f2a23a5c3f45a33e34506d1032e9ba443cbc`
- Runtime banner: `version 1.4.1 (b3dbd59)`
- TIC-80 tag `v1.4.1` resolves to commit `b3dbd597eecfe6742f64001c2fe5ba6c1afe55d9`
  (the banner's `b3dbd59` prefix matches the tag commit).

## TIC-80 source

- Repository: https://github.com/nesbox/TIC-80
- Tag/commit: `v1.4.1` / `b3dbd597eecfe6742f64001c2fe5ba6c1afe55d9`
- Archive included: `TIC-80-b3dbd59-source.tar.gz`
- Archive SHA-256: `d5d95c1e591602ce9574d363fadaab60cc5433e368c07a1745a288040c21e569`
- Exact submodule URLs and commits: `TIC80-SUBMODULE-PINS.json`
- Upstream third-party notice list: `../files/THIRD-PARTY-NOTICES.md`
- License texts: `../files/LICENSES/`

## blip_buf (the LGPL component actually linked into the Web engine)

- Repository: https://github.com/nesbox/blip-buf
- Submodule commit at TIC-80 v1.4.1: `330226d9b55ecbeea644e17b5e0f096a165ca07e`
- Archive included: `blip-buf-330226d-source.tar.gz`
- Archive SHA-256: `e86870ecb4b7c3feac6afbf5ddd0aff809e14b2d16d9bde251b712fd4ecd6d99`
- License text: `../files/LICENSES/LGPL-2.1-or-later-blip_buf.txt`
  (SHA-256 `319daefe38ebeead3df178e5937898a52d67c0c795f54f1c0bb10ac3b9cffb63`)
- TIC-80 CMake links `blipbuf` into `tic80core` (`cmake/blipbuf.cmake`,
  `cmake/core.cmake`), and `src/core/sound.c` calls `blip_new`,
  `blip_add_delta`, `blip_end_frame` and `blip_read_samples`. The universal
  `BUILD_WITH_ALL=ON` player therefore contains blip_buf code.

## Build / relink route

The upstream HTML job builds the universal player with Emscripten:

```sh
cd build
emcmake cmake -G Ninja -DBUILD_TOUCH_INPUT=ON -DCMAKE_BUILD_TYPE=Release -DBUILD_WITH_ALL=ON .. --fresh
cmake --build . --parallel
# produces build/bin/tic80.js and build/bin/tic80.wasm
```

A recipient can replace or modify `vendor/blip-buf` with the included source
(or edit `blip_buf.c`), rebuild with the same command, and use the resulting
`tic80.js` / `tic80.wasm` in place of the shipped pair. No Floe code or
reverse-engineering restriction is added. The rest of the engine is TIC-80
MIT and the other permissive components listed in `THIRD-PARTY-NOTICES.md`.

## Demonstrable remaining gap

- No object files, byte-identical rebuild, or executed relink proof were
  produced for this profile. The current work is under NATIVE-HOLD and the
  shipped binary was not rebuilt.
- The upstream workflow uses `emscripten-core/setup-emsdk@v15` without an exact
  emsdk version pin. A strict LGPL-2.1 section 6(a) relink kit should also pin
  the exact Emscripten version used to produce the shipped pair, or provide
  relinkable objects/archives. This gap is recorded rather than hidden.
- The TIC-80 source archive alone does not contain submodule contents; the
  recipient must fetch the exact submodule commits in `TIC80-SUBMODULE-PINS.json`
  (blip_buf is included here).

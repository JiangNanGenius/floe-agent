# Bundled scene-decoder license sources

These files are copied into `FloeAgent/FloeApp/Resources/EngineeringViewers/` by
`build.mjs` and are part of the hashed viewer inventory.

| Bundled component | Source | Version / commit | License |
| --- | --- | --- | --- |
| three.js core, GLTFLoader, OrbitControls, RoomEnvironment | npm `three` (pinned in `package-lock.json`) | 0.176.0 / r176 | MIT (`LICENSE.three.txt`) |
| Draco glTF decoder JS/WASM | files in `three@0.176.0/examples/jsm/libs/draco/gltf/`; upstream google/draco | glTF branch shipped by r176 | Apache-2.0 (`LICENSE.draco.txt`), NOTICE preserved upstream |
| Basis Universal transcoder JS/WASM | files in `three@0.176.0/examples/jsm/libs/basis/`; upstream BinomialLLC/basis_universal | version shipped by r176 | Apache-2.0 (`LICENSE.basis-transcoder.txt`) |
| meshopt decoder | `three@0.176.0/examples/jsm/libs/meshopt_decoder.module.js`; upstream zeux/meshoptimizer v1.3 | MIT header (`LICENSE.meshopt.txt`) |
| ktx-parse | `three@0.176.0/examples/jsm/libs/ktx-parse.module.js`; upstream donmccurdy/ktx-parse | MIT (`LICENSE.ktx-parse.txt`) |
| zstddec + embedded Zstandard WASM | `three@0.176.0/examples/jsm/libs/zstddec.module.js`; upstream donmccurdy/zstddec 0.3.4 | MIT AND BSD-3-Clause (`LICENSE.zstddec.txt`) |

`DECODER_BOM.json` (generated into the resource folder) records the exact bytes
and SHA-256 of every bundled decoder file. No decoder is fetched from a CDN at
runtime; the local preview server rejects external URLs. `GLTFKit2` and its
prebuilt `libktx` are intentionally NOT used because the optional
`lib/etcdec.cxx` terms are unresolved.

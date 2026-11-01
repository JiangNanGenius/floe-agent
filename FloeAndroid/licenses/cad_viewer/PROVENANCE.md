# C04A offline CAD / general-3D viewer provenance

Source of truth: fixed iOS donor commit `a59b4d4005f616c611df67fab7620e9853c525b9`,
`FloeAgent/FloeApp/Resources/EngineeringViewers/` (read with `git show`/`git ls-tree`
only; the old root checkout was not used).

## Ported bytes

`PINS.json` records the donor git blob, donor bytes/SHA-256 and the bundled
bytes/SHA-256 for every asset. `ASSETS.json` is the APK-facing inventory.
`dxf.js`, `mesh.js`, `occt-import-js.js/.wasm`,
`MiSans-Regular.ttf`, the source/license notices and `asset-hashes.json` are
byte-identical to the donor. `occt-worker.js` is a C04A read-only derivation
(local `importScripts`, bounded STL output, no editor surface). `index.html`,
`viewer.css`, `viewer.js` and `cad-worker.js` are C04A read-only additions;
`viewer.js` keeps only the read-only load/fit/capture paths from the donor
`viewer.js`.

## Verified routing (source, not a marketing list)

| Format | Reader | Source proof |
| --- | --- | --- |
| DXF | dxf-viewer 1.0.48 | `dxf.js` exports `DxfViewer`; `dxf-worker.js` calls `DxfViewer.SetupWorker()` |
| DWG | Floe CADEngine over acadrust 0.5.5 | `ThirdParty/CADEngine/src/lib.rs::read()` matches `"dwg"`; `display_dxf()` returns the render projection |
| STEP/STP | occt-import-js 0.0.23 | `occt-worker.js` method map `step/stp -> ReadStepFile` |
| IGES/IGS | occt-import-js 0.0.23 | method map `iges/igs -> ReadIgesFile` |
| BREP | occt-import-js 0.0.23 | method map `brep -> ReadBrepFile` |
| GLB/glTF/OBJ/STL/3MF | online-3d-viewer 0.18.0 | `mesh.js` `CanImportExtension` checks exactly `glb`, `gltf`, `obj`, `stl`, `3mf` for these routes |

`mesh.js` also contains an OCCT/FBX/Draco loader that resolves third-party
libraries from `cdn.jsdelivr.net`; C04A never routes STEP/IGES/BREP to it and
preflights GLB/glTF `extensionsRequired` for Draco/meshopt/basisu. The WebView
interceptor returns 403 for every non-local URL, so a remaining CDN attempt
fails closed instead of fetching.

## Licenses

`CAD_NOTICES.txt` (Rust crate notices incl. MPL-2.0), `third-party notices`
(`THIRD_PARTY_NOTICES.txt`), `license.occt-import-js.txt`,
`license.occt.txt`, `OCCT_LGPL_EXCEPTION.txt`, `dxf.js.LEGAL.txt`,
`mesh.js.LEGAL.txt`, `CAD_SOURCES.json`, `OCCT_SOURCES.json`.
MiSans is retained from the existing Floe font inventory with
`MiSans-PROVENANCE.json` and the upstream license page preserved as
`MiSans-LICENSE.html`; the font license name is “MiSans 字体许可（全社会免费商用）”.
`occt-import-js.wasm` is the reviewed memory-capped build whose
`bundledWASMSHA256` is recorded in `OCCT_SOURCES.json`.

## Boundary

The App stages source bytes only through the existing G04 native workspace
egress; the WebView origin is `https://cad.floe.invalid` and every request is
answered by `C04CadWebAssetServer` from an exact allowlist or an exact session
resource token. File/content/universal access is off, external navigation is
blocked, and no file path is converted into a host path.

`.floecad` is not a C04A format. `C04CadPackageValidator` hands C04B a
`floe.cad-package/1` contract with mesh v1/v2, transforms, images, resource
digests and source units; C04A does not pretend to render that package.

## Current Android package adapter (C04C)

The Android-authored `index.html`, `loader.js` and `floecad.js` now route real
`.floecad` directories, normalize millimetre geometry to glTF metres and append
derived B-Rep surfaces using the unchanged pinned offline OCCT worker. Their
current byte counts and hashes are recorded in `PINS.json` / `ASSETS.json`;
the earlier Android index hash is retained as `previousAndroidSha256`. No
upstream donor blob, dependency revision, license, WASM or renderer bundle was
changed by this inventory update.

The copied `asset-hashes.json` is the original iOS donor's inventory, including
editor resources not bundled on Android. It remains byte-identical evidence
of that donor; use `ASSETS.json` for the actual Android asset subset and
Android-authored adapters.

## Rust reader build-path remapping

The original Rust DWG reader asset contains absolute build-machine paths in
its data section. Android rebuilds `FloeAgent/ThirdParty/CADEngine` from the
same fixed source commit using Rust 1.98.1, wasm-bindgen 0.2.126 and the exact
original Cargo.lock, with remapped source/build-user paths and the unchanged
384 MiB memory maximum. `ANDROID_DERIVATION.json` retains original donor asset
hashes, new paired JS/WASM hashes, inputs, commands and the component-only
DWG-to-DXF check. Original donor blobs/pins, license/source notices and
`asset-hashes.json` remain preserved. This is an explicit source rebuild, not
a binary substitution or a claim of Android WebView acceptance.

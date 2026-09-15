# Floe engineering viewers and editing bridge

Native entry: `FilePreviewView` → `EngineeringPreviewPackage` → `EngineeringFilePreview`. The IDE reuses the same file-preview surface. User files never go to a hosted conversion service.

Pinned implementations:

| Component | Version | License | Bundled use |
| --- | --- | --- | --- |
| [dxf-viewer](https://github.com/vagran/dxf-viewer) | 1.0.48 | MPL-2.0 | 2D DXF geometry, text, layer visibility, worker parsing |
| [Online 3D Viewer](https://github.com/kovacsv/Online3DViewer) | 0.18.0 | MIT | Mesh imports and orbit/pan/zoom |
| [gerber-to-svg / tracespace](https://github.com/tracespace/tracespace) | 4.2.8 | MIT | Individual Gerber and Excellon layers in a worker |
| [occt-import-js](https://github.com/kovacsv/occt-import-js) | 0.0.23 | LGPL-2.1; OCCT exception retained | Read-only STEP/IGES/BREP surface conversion in a 384 MiB worker |
| MiSans Regular | Existing Floe bundled revision | MiSans license | Latin/Chinese DXF text; existing font provenance retained under Resources/Fonts/Bundled/misans |

`package-lock.json` pins every npm source URL and integrity digest. `THIRD_PARTY_NOTICES.txt` in the resource folder includes the dependency notices. Engine source is available in the exact lockfile tarballs; the integration entrypoints, build script and fixtures are kept here. Do not treat the full Online 3D Viewer upstream format list as this App's compatibility list: extra CDN decoders are blocked and unbundled.

Rebuild from this directory with Node and an existing npm cache with sufficient space:

```sh
npm ci --ignore-scripts --no-audit --no-fund
node build.mjs
python3 ../../scripts/check_engineering_viewer_assets.py
```

`check_engineering_viewer_assets.py` is read-only; it does not regenerate the manifest. `build.mjs` is an intentional maintainer action and regenerates distributions, notices and hashes. The asset folder is a folder resource in `project.yml`.

Integration changes: separate sized DXF surface prevents upstream `autoResize` from changing the native viewport layout; explicit local Chinese font; no external scripts/fonts/uploads; SVG output displayed in an image context; native and web timeouts, scoped read-only bridge and dismantle cleanup. DXF parser workers run outside the UI JavaScript thread. The frame inspector can expand to a full-screen native container.

Current limits: 20 MiB total preview input, 32 referenced files, and the existing workspace per-file read cap. Only explicit OBJ/MTL/glTF dependencies under the selected folder are read. Remote previews currently contain the selected file only. Some MTL options, texture formats, DXF dimension/line-style/layout features and compressed model decoders are unavailable. Imports do not establish dimensionally exact engineering validation or CAD editing. See `docs/FLOE_ENGINEERING_VIEWERS.md` for the evidence and pending decoder work.

## Open CASCADE source and replacement

This application makes use of facilities provided by Open CASCADE Technology. The OCCT JS/WASM library remains a distinct file behind a message interface; it is not linked into Floe's native executable. `OCCT_SOURCES.json` fixes the wrapper source and full OCCT source commits, plus upstream and modified WASM hashes. Full sources and build scripts are available at those immutable public repository links; `tools/` and CMakeLists.txt describe rebuilding the library. The full LGPL texts and OCCT exception accompany the App resource.

The only WASM modification lowers its single memory maximum from 2 GiB to 384 MiB. Reproduce it with `python3 bound_occt_memory.py upstream.wasm output.wasm`. The script verifies both hashes. `build.mjs` runs this on the pinned npm distribution. The JS is unchanged; npm/tag differences are CRLF only. To replace the library, rebuild it from the referenced source, place its JS/WASM at the same resource names, regenerate asset hashes and build Floe from source. No production signing identity is needed to modify the library or build your own development copy.

The local worker emits a bounded display mesh (200,000 triangles / 600,000 vertices / 1,000 parts maximum), retains limited part names and face counts for AI evidence, and is terminated on completion/failure/45-second timeout. Source files remain read only. Display meshes omit colors/materials and exact analytic surfaces; no dimensional or design-rule acceptance is claimed.

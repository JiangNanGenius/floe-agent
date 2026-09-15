# Floe read-only engineering viewers

Native entry: `FilePreviewView` → `EngineeringPreviewPackage` → `EngineeringFilePreview`. The IDE reuses the same file-preview surface. User files never go to a hosted conversion service.

Pinned implementations:

| Component | Version | License | Bundled use |
| --- | --- | --- | --- |
| [dxf-viewer](https://github.com/vagran/dxf-viewer) | 1.0.48 | MPL-2.0 | 2D DXF geometry, text, layer visibility, worker parsing |
| [Online 3D Viewer](https://github.com/kovacsv/Online3DViewer) | 0.18.0 | MIT | Mesh imports and orbit/pan/zoom |
| [gerber-to-svg / tracespace](https://github.com/tracespace/tracespace) | 4.2.8 | MIT | Individual Gerber and Excellon layers in a worker |
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

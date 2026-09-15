# Engineering viewers — implementation and qualification

2026-09-15 working candidate. These changes have **not** been uploaded to TestFlight. Build 172 remains the last confirmed internal delivery. This document separates a bundled renderer from a verified sample and from full-App/device acceptance.

## User flow

Open an engineering file from workspace files or the IDE → read-only inline preview → full-screen button → zoom/pan, rotate a 3D model, or toggle DXF layers → Done returns to the file. Original data is never edited. Chinese/English controls and light/dark shell styling share the application conventions. Assets and parsing are local; no third-party conversion account or upload is used.

## Compatibility matrix

| Files | Current integration | Evidence / limitation |
| --- | --- | --- |
| DXF | dxf-viewer 1.0.48, bundled | Synthetic plate: outline, circles, Latin/Chinese text and three layers rendered; wide/compact browser checks passed. Not all dimensions, linetypes, hatches, paper-space layouts or encodings are faithful. |
| STL | Online 3D Viewer 0.18.0, bundled | Four-face tetrahedron rendered; wide/compact browser checks passed. |
| OBJ/MTL, PLY, OFF, 3DS, DAE, FBX, 3MF, AMF, glTF/GLB, WRL, BIM | Routed to the bundled mesh importer | Format-specific real samples still pending; unsupported compression and absent external references can prevent or reduce rendering. Do not call every format validated. |
| Gerber / Excellon | gerber-to-svg 4.2.8, bundled | Synthetic copper and drill files rendered in both browser sizes. Single layer only; a multilayer board stack is not yet implemented. |
| USDZ and existing system formats | Existing native Quick Look route | Not requalified by this patch. |
| KiCad PCB / schematic | Candidate reviewed; not yet bundled | KiCanvas `b031159eb74aaa7eef2b026fd85d35bc05ff2095`: top-level MIT but generated Newstroke file has GPL header conflicting with the top-level font attribution. Resolve provenance; remove remote fonts and test touch/real schematic hierarchy before distribution. |
| STEP / IGES / BREP / FreeCAD | Candidate reviewed; not yet bundled | `occt-import-js` 0.0.23 WASM is LGPL-2.1; exact corresponding OCCT source/build/license distribution and bounded real-file qualification remain. No remote CDN fallback. |
| DWG / DWT / DGN, IFC, Rhino 3DM | Decoder not bundled | A native unavailable-format message suggests DXF/PDF or GLB/STL export. DWG candidates include GPL LibreDWG or separately licensed commercial parsers; no commercial key, GPL relicense, or server upload has been introduced. |

Primary sources: [DXF viewer](https://github.com/vagran/dxf-viewer), [Online 3D Viewer](https://github.com/kovacsv/Online3DViewer), [tracespace](https://github.com/tracespace/tracespace), [KiCanvas license](https://github.com/theacodes/kicanvas/blob/b031159eb74aaa7eef2b026fd85d35bc05ff2095/LICENSE.md), [KiCanvas generated font](https://github.com/theacodes/kicanvas/blob/b031159eb74aaa7eef2b026fd85d35bc05ff2095/src/kicad/text/newstroke-glyphs.ts), [OCCT importer](https://github.com/kovacsv/occt-import-js), [CAD viewer DWG opt-in](https://github.com/mlightcad/cad-viewer).

## Data and lifecycle

`EngineeringPreviewPackage` reads immutable bytes through `WorkspacePathGuard`. Aggregate input is limited to 20 MiB/32 files, also respecting the existing workspace per-file cap. It follows only explicit OBJ/MTL/glTF dependencies; remote URLs, traversal, secrets, unsupported paths and missing files are not silently fetched. Missing references remain visible. Remote workspace previews carry a single downloaded file and report missing companions.

The nonpersistent WKWebView receives one immutable package after checking the main-frame origin. Its bridge has no write, tool, Agent, credential or arbitrary-file capability. The token-protected loopback server serves only bundled viewer assets. CSP blocks remote connections and navigation. DXF/Gerber parsers use workers; native timeout and WebKit termination errors preserve the source file and offer retry. Closing/replacing the view cancels startup/watchdog and stops its own server. Large compressed input can still exhaust the WebKit process; device memory qualification remains required.

## Evidence

[Machine-readable browser results](evidence/floe-1.7/engineering-viewers/result.json): Playwright 1.62.1 + installed Edge 153, 1194×834 and 390×844. Browser plugin unavailable, so existing Playwright was used. Four synthetic fixtures × two viewports rendered, no relevant console errors or external requests observed; fit and DXF layer interaction exercised. These are **desktop browser component checks**, not iPad/iPhone App acceptance. Screenshots were visually inspected; the original zero-height DXF result was rejected and corrected, not counted as a pass.

Local Swift 6.4/Xcode 27: source parsing and preview package + three test bodies typechecking passed against the existing compiled FloeWorkspace module. Direct test typechecking initially omitted TestingMacros; it passed after using the installed plugin path. This did not execute the tests. Added cloud qualification tests cover referenced-file restrictions, symlinks/secrets/traversal, missing materials, limits and decoder routing. Added full-App UI test covers workspace DXF → inline render → full-screen → layers → return on both device jobs; its outcome is pending.

![Wide browser DXF with Chinese text](evidence/floe-1.7/engineering-viewers/dxf-wide.png)
![Compact browser DXF layer selection](evidence/floe-1.7/engineering-viewers/dxf-compact-layers.png)

## Remaining before release acceptance

Complete native two-device checks, corrupted/missing/compressed inputs and memory/cancellation evidence; integrate and verify the outstanding KiCad/CAD decoders and multilayer PCB view; broaden mesh-format fixtures. Publish only the capabilities actually verified. Retain previous runtime/language/package/assistant/concurrent-edit work and its own evidence. TestFlight, GitHub prerelease, Feather, review materials and main merge remain separate unfinished delivery steps.

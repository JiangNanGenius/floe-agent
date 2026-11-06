# Offline chemistry interoperability

`ChemistryStructureProcessor` provides serialized, bounded Indigo conversion, layout and molecular properties to the native chemistry editor. It loads the pinned Ketcher/Indigo standalone distribution entirely from the package. The offscreen WKWebView never enters the editor's interactive view hierarchy. Native Core Graphics/UIKit owns Pencil input and the visible structure drawing.

`UPSTREAM.json` pins Ketcher 3.18.0, the release archive URL/SHA256 and each bundled file. Unused alternate app entrypoints were omitted; the main runtime and lazy chunks are unchanged. Preserve `LICENSE.Ketcher`, the bundled JavaScript license notices and all dependency notices when integrating the package. The distribution contains offline Indigo WebAssembly; no paid chemistry server is required for these operations.

Requests call fixed JavaScript APIs with structured arguments. Imported chemical strings cannot select JavaScript, paths, project ownership or tool permissions. Only the bundled origin can communicate with the native bridge. Scheme loading checks path containment, symlinks, MIME type and navigation. A restrictive content policy blocks external network access, subframes and plugins; WebAssembly compilation is allowed for the pinned runtime. A nonpersistent website data store is used.

The earlier public `ChemistrySketchView` is retained as a research/comparison editor. **The current main editor is `ChemistryDrawing` in FloeChemistryUI, a native view.** Do not wire the reference editor into production in place of the native Pencil surface.

Verification is read-only:

```sh
python3 FloeAgent/Modules/FloeChemistrySketch/Scripts/verify_assets.py --check
```

The iPad qualification uses the real offline processor while drawing, undoing and reopening a native benzene diagram and asserts that no WebView is present in the visible UI. Real Pencil hardware behavior needs separate acceptance.

# Native drawing editing and recovery qualification

E20 and E22 meet their original criteria. Qualified App source: `83429fc78ff94f31ee07008a6b19bc95e1f693e7`, Xcode 27.1 / 27A9275, arm64 on the existing canonical iPad Simulator. Invocation numbers App304/305 are private build checks, not distribution build numbers.

The original App304 run passed five checks and failed two: native dimension Save refused a layer mismatch, and a texture-menu UI operation failed. The layer defect was real: a newly created layer without an explicit colour incorrectly inherited ByLayer, while the native writer resolved it to white. The constructor default is now used for the layer itself; entity colour inheritance is unchanged. The original refusal and assertions remain preserved.

The exact repaired source passed full App and test object compilation in 78.119 seconds. The next App run passed all **seven drawing checks**, including:

- Native LINE/DIMENSION/DIMASSOC identities and measured geometry survive text/position edits, undo/redo, strict original-format Save, fresh reopen and another geometry edit.
- Both Linear and Aligned dimensions render through the actual bundled WebKit/DxfViewer/worker/font path. The source line is hidden as a control; actual dimension text changes its image region, disappears on undo and reappears after reopening. Eight original PNGs and their source/image hashes were retained.
- Mixed block/Xref/Spline/Hatch records remain unchanged while a supported model-space line is edited and saved. The shipping visible editor shows their read-only labels, status and absence of edit fields.
- The shipping recovery action presents an actual native document-export picker containing a valid exact-source JSON journal. Session teardown removes staging and resolves the original page reply exactly once. This does not claim a particular external Files provider saved a copy.

That run still failed its separate texture-menu case; it is not reported as an all-green eight-case run. Relevant texture recovery continues separately. Root visually reviewed these unchanged synthetic screenshots:

![Native dimension after save and reopen](dimension-reopened.png)

![Actual read-only editor controls](readonly-editor.png)

The repaired engine also passed 64 Rust checks; one explicitly external-corpus probe remains separately qualified rather than being counted as part of that run. Actual bundled-WASM command checks passed 58/58, and native-association/recovery replay checks passed. The 52-package notices, exact wrapper/vendor hashes and all 49 bundled asset hashes remain recorded.

Editing scope remains explicit: existing Linear/Aligned dimension updates and unattached leaders are supported; unsupported dimensions, attached annotations and block/layout/Xref/Spline/Hatch edits remain read only. No universal DWG compatibility or external-reference resolution is claimed.

E23 additionally has private real DWG, font/layout/object/Xref corpus evidence and independent LibreDWG 0.14 reads. Its real-corpus App refusal/export/import boundary is still being checked. Proprietary tutorial files are not redistributed here. Whole-App release, Mac suspension and the remaining original CAD criteria are still open.

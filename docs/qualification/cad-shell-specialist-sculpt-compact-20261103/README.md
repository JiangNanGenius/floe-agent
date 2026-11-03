# CAD shell, specialist controls, sculpt and compact acceptance

Source-bound App333 qualification: `39fd6da44fbd875037350e9f6feae3e283cd1437`, Xcode 27.1, Swift 6, arm64 iPad Simulator. The complete App/test object build passed in 312.755 seconds with no source drift. Runtime checks used the existing canonical iPad and shut it down afterward. This is not physical-device or publication evidence.

## Actual results

| Run | Relevant outcome | Whole selected run |
| --- | --- | --- |
| `native316-guide-sphere-moonshot` | `CADShellRegionTests`: 8 passed; Moonshot/video contracts: 16 passed | 28 passed, 2 guided-loft failures, 0 skipped |
| `ui317-sculpture-texture` | Original sculpt draw/smooth/mask/subdivide/undo/save/cold-reopen flow passed | 1 passed, 1 texture UI failure, 0 skipped |
| `native318-guided-contact-diagnostic` | Additional diagnostics preserve the original guide assertions | 4 passed, 2 failed, 0 skipped |

The guide failures remain M16 work. The texture failure remains X10 work. Neither selected run is reported as wholly passing.

## Accepted original criteria

**M22 — curved openings and multiple wall thicknesses.** The original eight App-host shell tests pass, including the original quarter-sphere input and independent volume integration at 1 mm and 2 mm wall thickness. Native tolerance, closure, Boolean health, ancestry and exact source BRep byte-preservation assertions remain unchanged. Multiwall tests retain the independent 5856/6360 mm³ checks, stable face/region identities, updates, undo/redo and saved rebuild. Earlier cylindrical opening evidence is reused. This does not claim arbitrary open-surface offset support.

**M29 — the selected specialist scope.** Reuse `native303-loft-gear-shell-scene`: seven mechanical and seven spur-gear tests passed. Reuse the actual `ui313-scoped-native-specialist-controls` gear creation, 2.5-module edit, apply, save and cold-reopen flow. The dedicated production and test sources were compared through App333. The implemented scope remains single-bend formed/unfolded parts, straight profiles/cut lists and bounded external spur gears. Involute geometry is approximated BRep; arbitrary imported unfolding, undercut roots and a full manufacturing engine are not claimed.

**X04 — sculpt and multiresolution.** Reuse the twelve passing `native312-scoped-sculpt-material-fixes` sculpt tests and unchanged passing pressure-routing test from native310. The original ui317 touch flow now passes: real draw, smooth and mask strokes, level 1, undo to 0, redo to 1, level 2, save and fresh-process reopen. Pressure magnitudes and routing are App-host evidence; XCUITest touch is not a physical Pencil-force measurement.

**X37 — current device acceptance policy.** The user explicitly assigns functional validation to the canonical iPad Simulator and limits iPhone acceptance to compact layout. Reuse ui268 (6/6), ui271 (8/8) and ui276 (2/2), together with current per-feature iPad controls and save/reopen results. The original criterion remains recorded, with the device-policy exception separate. Compact fixtures are not described as physical iPhone, physical Pencil or actual operating-system split-screen tests.

## Guided-loft recovery

App334 (`024c5216c2b76076871a444d8089fd4bf05381bb`) passed the complete Swift 6 App/test object build in 134.95 seconds without source drift. The original six `CADGuidedLoftWorkflowTests` all passed in `native319-guided-machining-moonshot`, including the unchanged three-section/guide-contact cases, same-feature updates, undo/save/reopen and atomic refusal checks. The formal two-slice native derivation retained the original tolerances and fixtures. M16 is accepted within its existing bounded exact line/conic section scope; finite independent residual samples are not a universal whole-curve certificate.

The whole native319 run remains **19 passed, 3 basic-machining failures, 0 skipped**. Two fixture failures used a retired Simulator container path; the third found an unwanted saved-revision change during snapshot capture. Those failures remain recorded and require their own recovery. They are not guided-loft failures.

Original failures, run records, screenshots and videos remain retained. The original 106 criterion texts and their hashes are unchanged. The reconciled original-criterion count is **102/106**; M30, E38, X10 and X34 remain open. Full E38 professional manufacturing is separately deferred by the user and does not block unrelated delivery.

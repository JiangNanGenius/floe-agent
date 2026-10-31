# FloeCADKit modification record

Upstream files are copied into `Sources/FloeCAD/**` (OpenShape3D commit
`30b3c7c…`, MIT). This file lists every intentional deviation so the next
upstream sync can rebase instead of re-deriving the patches.

## Build/module plumbing

1. **Module identity.** Upstream compiles as one app target with a bridging
   header. FloeCADKit is a Swift package:
   - `Sources/FloeCAD/**` = module `FloeCAD`;
   - `Sources/OCCTShim/**` = ObjC++ module (OCCTBridge.mm, OS3DLinearAlgebra.c,
     public headers OCCTBridge.h / OS3DLinearAlgebra.h / ShaderTypes.h).
   - Every vendored Swift file that used the bridging header gained
     `import OCCTShim` (11 files: `Editor/ViewportBridge`, `Editor/EditorViewModel`,
     `Kernel/ConstraintSolver/LinearAlgebra`,
     `Kernel/OCCT/{KernelCapture,KernelCaptureReplay,OCCTKernel,ShapeAncestry,ShapeHealth}`,
     `Model/FeatureGraph`, `Rendering/{GizmoRenderer,OrientationCube,Renderer}`).
   - `Model/Commands.swift` gained `import simd`.
   - Header search path is pinned to `Vendor/OCCT.xcframework/ios-arm64/Headers`
     (platform-independent headers; both slices use it).
   - Language mode Swift 5 with `defaultIsolation(MainActor.self)`, mirroring
     the upstream Xcode project.
2. **Metal library.** Upstream uses the app's `default.metallib`.
   `Rendering/RenderContext.makeLibrary` compiles the bundled
   `Shaders/Shaders.metal` source via `Bundle.module` when no default library
   exists, and caches the result.
3. **Module-qualified typealias.** `FaceTopology.PlanarFace` referred to
   `openshape3d.PlanarFace`; renamed to `FloeCAD.PlanarFace`.

## Configuration / small utilities

4. **`AppSettings` → `CADPreferences`.** The app-shell preference singleton is
   replaced by `Floe/CADPreferences.swift` (same fields, UserDefaults-backed,
   plus `DisplayUnit.binding`). `OpenTiming` is a no-op unless
   `FLOE_CAD_OPEN_TIMING=1`. `NumericKeypad.trailingUnit` (pure parsing half)
   became `Floe/NumericParsing.swift`; the on-screen keypad itself is Floe UI.
5. **Shell extracts not copied:** `Agent/**` (transport), `App/**` (gallery,
   account, bug reporting, SwiftData), `UI/EditorView.swift` shell navigation,
   `UI/ProjectGalleryView.swift`, `UI/SettingsView.swift`, `UI/WelcomeView.swift`,
   `UI/BugReportSheet.swift`, `UI/ARQuickLookView.swift`,
   `UI/AIAssistantSettingsSection.swift`, `Demos/`, `Assets.xcassets/`.
   `WorkbenchUI/**` keeps the viewport chrome/overlays (32 files) and adds
   `FloeCADEditorView.swift` (the adapted `EditorView`: SwiftData project and
   modelContext replaced by `FloeCADDocument`; settings/bug/AR sheets replaced
   or removed; Save Project button committed through the FloeCAD facade).
   `UI/MacWindowTitle.swift` is re-created unchanged in effect.
6. **Command vocabulary.** `Agent/AgentExec.swift` is vendored as the typed
   operation model (`Sources/FloeCAD/Floe/CommandService/AgentExec.swift`).
   The execution half of `Agent/AgentBridge.swift` became
   `Floe/CommandService/CADCommandExecutor.swift` (class `CADCommandExecutor`,
   injected `EditorViewModel`; transport/screenshot/capture/archive routes
   removed; `platformName`/`modeName` retained). The MCP/HTTP server and
   agent registration are not copied.

## Persistence/transaction (Floe-owned replacements)

7. **SwiftData → FloeCAD package.** `Model/PersistenceModels.swift` keeps the
   same record columns but as plain classes owned by `CADModelContext`;
   `DocumentSession.load/save` keep upstream's diff/preserve semantics.
   `Floe/FileCADDocumentStore.swift` implements the versioned `.floecad`
   package: `manifest.json` + `document.json` + separate binary
   `blobs/<id>.{mesh,brep}` (and images), staged commit with verification, a
   `previous/` recoverable snapshot, revision-guarded `performWrite`, and
   `create(overwrite:)` staging the new package before moving the old one
   aside. JSON/hash/file I/O run off-main; B-rep serialization is cached per
   body/revision and pre-warmed detached. Fault-injection hooks exist for
   regression tests only.
8. **Public facade + contracts.** `Floe/FloeCADDocument.swift` (open/create/
   save/execute/snapshot/measure), `Floe/CADAssembly.swift`,
   `Floe/CADDrawing.swift` (persisted models; no service wired yet),
   `Floe/CADProposalService.swift` (geometry transaction primitives: propose on
   a flushed throwaway copy, authorized apply). App-level authority stays in
   `CadDocumentCenter` + the existing `CadProposalGrantStore`; the package's
   in-package grant path is test-only.
9. **Workbench view.** `Floe/CADWorkbenchView.swift` exposes
   `FloeCADWorkbenchView(document:)` and the compact settings sheet.
10. **`DocumentSession` additions:** `flushPendingAutosave`, `saveAsync`,
    `prewarmBrepSerialization`, `buildSavePayload`; autosave now runs
    off-main. `ModelContext.save()` remains for tests/explicit close.

## Native read-only observation (2026-10-31)

11. **`Rendering/Camera.swift` — explicit pole up vector.** `TurntableCamera`
    gained an additive `upVector` (default +Y) consumed by `viewMatrix`. Every
    existing orbit/pick/standard-view result is bit-identical; the App's native
    `cad.document observe` path supplies the horizontal limit direction for an
    exact ±90° plan view, so `Matrices.lookAt` never degenerates and a real
    pole frame is never reported as an undisclosed 89° approximation.
12. **`Floe/FloeCADDocument+Observation.swift` (new).** Bounded read-only
    multi-view capture for the App's native observe path: a detached `Renderer`
    over a value-copy `viewModel().scene`, a local `TurntableCamera.fit` pose,
    committed-revision/content-SHA + live-change-count fencing, exact PNG
    dimension/digest/per-frame/total budget checks, cancellation checks and
    honest `renderer: engineering` metadata. No new camera engine, no second
    scene authority, no package/model/undo/camera mutation.

## Original extraction gaps (historical)

The first two items below describe the original extraction, not the current
integration; the dated updates supersede them. The missing Catalyst slice remains.

- Upstream UI strings are English; Floe bilingual resources for the workbench
  have not been added yet (acceptance gap, see docs page).
- Assembly/drawing service operations, ShapeScript interpretation and the
  Canvas creation path are not wired (models persist; `three_d_assembly` /
  `three_d_drawing` answer `not_implemented`).
- The Catalyst OCCT slice is not vendored (see UPSTREAM.md).


## 2026-10-30: continuous editing, materials and presentation

Floe extends the existing document/session and undo history with typed parameter edits,
query-generation fences, failed-edit checkpoints, reusable PBR materials, per-face
appearance bindings and additive package fields. Canvas and task hosts resolve the
same native package and independently enforce ownership. The Metal editor consumes
the same applied material snapshot as the non-AR RealityKit presentation. Shader ABI
extensions are mirrored in the shim and bundled shader headers. GLB export carries
actual PBR factors, embedded image resources and a millimetre-to-metre root transform;
PNG uses the active renderer. Legacy geometry remains readable when optional
appearance resources cannot be used. Upstream licenses and the OCCT relink route
remain unchanged. Validation and release status belong to the build-specific records.

Presentation uses an explicit non-AR camera, metre-space placed-instance bounds
and viewport-aware fitting. The shared inline title survives Edit/Present changes.
Texture cache identities use the complete content digest with bounded exact-byte
reuse; stale metadata and small image edits cannot alias another texture. GLB PNG
packing preserves straight-alpha RGB without a lossy premultiplication round trip.

## 2026-10-31: preserve clean-save model identity

Clean saves reuse the committed opaque record and BRep bytes rather than
re-encoding unchanged geometry. Content revisions still advance for metadata
and preview commits, while model identity remains stable. Saves pin the
change generation before suspension so a later edit remains dirty, and closed
or newer-format documents remain protected. The staged commit and digest
calculation run outside the main actor.

## 2026-10-31: associative datum transactions and exact primitive identity

Offset datum definitions and sketch supports retain their source body version,
actual writer and existing topological face name. Replay resolves these through
OCCT and the existing feature graph; derived coordinates remain caches. Session
preflight, variable fanout, checkpoints and undo use the same document authority.
Format 2 preserves these definitions; unknown semantics remain opaque and read-only.
Project merging preserves or explicitly refuses associations rather than dropping
relationships or rebinding them to host identities.

The OCCT bridge exposes box construction faces from `BRepPrimAPI_MakeBox` and
follows their identities through the existing transform builder. Euclid render
indices and geometric similarity are not kernel identities. Unsupported baked
primitive rotations refuse named association until render-side roles can preserve
local construction identities. This extends the existing OCCT adapter; the pinned
OCCT version, licenses and relinking route are unchanged. Qualification results and
remaining UI/live-drag boundaries are recorded in the implementation progress docs.


Associated sketch drags use a Session-owned transient token over the existing
checkpoint and command stack. Committing performs one guarded rebuild; cancellation
restores the baseline. Save results are per call, with ownership checked after
serialization awaits. Persistence markers remain separate from query generations.
UIKit cancellation is routed explicitly through the public SwiftUI gesture-recognizer
adapter; no custom gesture recognizer or geometry engine is introduced. Ordinary
non-associated and model-mode previews retain their earlier paths. Component and
actual App/touch qualification remain separate in the progress record.

## 2026-10-31: durable identity, host selection and volume integration

The existing Session publishes one observable successful `CADSaveOutcome`. Native
autosave, synchronous save and the public facade use the same receipt; facade and
scene identity are projections rather than separate cached revisions. File-store
receipts bind revision and both digests under the original commit lock. Older
deliveries cannot downgrade the published identity or dirty acknowledgement, while
each save still returns its own outcome. The generic store tuple API is unchanged.

A shared Edit/Present wrapper publishes the live editor selection to the host.
Its identity includes complete face/edge picks and the live document object; the
wrapped Editor publisher is disabled to avoid duplicate events. Standalone Editor
publication remains available, and no polling or secondary selection store is added.

Certified elementary surfaces and boundary curves use OCCT's existing adaptive
Gauss exact-surface volume overload at relative `1e-7`. Spline, Bezier and unknown
geometry retain the original knot-span Gauss-Kronrod path and precision. The change
avoids the observed rotated analytic-cutter integration hot path without replacing
OCCT, changing its pin, using mesh volume or adding a custom integrator. Historical
upstream spline acceptance is relative `1e-6`; new regression tests check relative
`1e-7`. Runtime qualification and original failed assumptions remain in the progress
and private evidence records.

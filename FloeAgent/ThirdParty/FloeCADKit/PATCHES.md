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

## Known deviations / open items

- Upstream UI strings are English; Floe bilingual resources for the workbench
  have not been added yet (acceptance gap, see docs page).
- Assembly/drawing service operations, ShapeScript interpretation and the
  Canvas creation path are not wired (models persist; `three_d_assembly` /
  `three_d_drawing` answer `not_implemented`).
- The Catalyst OCCT slice is not vendored (see UPSTREAM.md).

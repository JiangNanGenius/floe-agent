//
//  EditorViewModel.swift
//  openshape3d
//
//  The mode state machine bridging SwiftUI chrome, the geometry kernel, and
//  the Metal viewport. All mutations funnel through here; the viewport only
//  reports events.
//

import OCCTShim
import Foundation
import SwiftData
import Observation
import os
import simd
import Euclid
import ImageIO

enum ViewportEvent {
    case tap(ray: Ray)
    case doubleTap(ray: Ray)
}

/// Camera operations the view model can request from the viewport.
@MainActor
protocol ViewportCameraControl: AnyObject {
    func fitScene()
    /// Animate to look head-on at a sketch plane.
    func moveCameraHeadOn(to plane: SketchPlane)
    /// Animate to a standard view (Views popover, spec §7.3).
    func animateToStandardView(_ view: StandardView)
    /// Switch between perspective and orthographic projection.
    func setProjection(orthographic: Bool)
    /// Animate to frame a world-space AABB (Items Manager "Zoom to").
    func fitTo(bounds: (min: SIMD3<Float>, max: SIMD3<Float>))
    /// World units per screen point at the camera target depth — converts
    /// screen-space pick tolerances into sketch-plane distances.
    var worldUnitsPerPoint: Double { get }
    /// Project a world-space point to viewport screen points (top-left origin),
    /// or nil when it is behind the camera. Used to place SwiftUI overlays such
    /// as dimension labels (plan §C2).
    func worldToScreenPoint(_ world: SIMD3<Double>) -> CGPoint?
    /// Degrees between the camera eye-line and a plane's normal, 0 = head-on,
    /// 90 = edge-on. Entering a sketch reads this to decide whether the current
    /// view is usable to draw in.
    func offAxisDegrees(to plane: SketchPlane) -> Double
    /// Standard-view names for the orientation-cube faces currently turned
    /// toward the camera, in screen points (spec §7.2).
    func orientationCubeLabels() -> [OrientationCube.FaceLabel]
    /// World-units-per-gizmo-unit at `origin` (constant on-screen gizmo size).
    /// The 2D move/rotate overlay uses it to project gizmo-local part anchors.
    func gizmoWorldScale(at origin: SIMD3<Float>) -> Float
}

@MainActor
@Observable
final class EditorViewModel {
    let session: DocumentSession
    var mode: EditorMode = .idle {
        didSet {
            if !mode.isSketching || mode.sketchTool != nil { sketchTransformActive = false }
            // An Items plane selection lives only while idle.
            if mode != .idle { selectedPlaneID = nil }
        }
    }
    var selection: Set<BodyID> = []

    /// Multi-select chip (plan §B13, spec §8.1): while on, viewport taps
    /// toggle whole bodies in and out of `selection` instead of replacing
    /// it, and area selects add instead of replace. Boolean tool picking
    /// has its own always-additive tap flow and is unaffected.
    var selectionAdditive = false

    weak var cameraControl: (any ViewportCameraControl)?

    /// Bumped by the viewport coordinator whenever the camera moves; SwiftUI
    /// overlays that reproject world points (dimension labels, plan §C2) read
    /// it to re-run their layout as the camera orbits/animates.
    var cameraEpoch = 0

    init(project: Project, modelContext: CADModelContext) {
        self.session = DocumentSession(project: project, modelContext: modelContext)
        loadAutoConstrainSettings()
        // Data-safety warnings from load (newer-format store opens read-only,
        // or rows this build couldn't read) surface once as the alert.
        errorMessage = session.loadWarning
    }

    /// FloeCAD: attach to an existing session so the document facade, the
    /// headless command executor and the workbench UI share ONE document.
    init(session: DocumentSession) {
        self.session = session
        loadAutoConstrainSettings()
        errorMessage = session.loadWarning
    }

    // MARK: - Scene for the viewport

    /// Highlighted gizmo part during hover/drag (set by the coordinator).
    var gizmoHighlight: GizmoPart?

    /// The part the gizmo overlay draws lit: the one being dragged or
    /// hovered, else the one whose typed entry is open — a tapped arrow or
    /// ring stayed white while its field waited for a value (iPad,
    /// 2026-09-14).
    var litGizmoPart: GizmoPart? { gizmoHighlight ?? axisEntryPart ?? angleEntryPart }

    /// Set once an Apple Pencil has drawn this session. After that, a FINGER
    /// drag in sketch mode navigates (orbits) instead of drawing — the Shapr3D
    /// split where the Pencil creates and the finger manipulates the view. It
    /// stays false for finger-only users, who keep drawing with a finger.
    var sawApplePencil = false

    /// True while the Move tool is armed on a SELECTED FACE: the move gizmo is
    /// shown and dragging it shears the solid (moves the face). A face selection
    /// on its own shows only the extrude arrow; picking Move flips this on.
    private(set) var faceMoveActive = false

    /// True while the Scale tool is armed on a SELECTED FACE: the gizmo is shown
    /// as scale grips and dragging it scales the face about its centre, tapering
    /// the solid. Mutually exclusive with `faceMoveActive`.
    private(set) var faceScaleActive = false

    /// True while the Rotate tool is armed on a SELECTED FACE: the gizmo shows its
    /// rotation rings and dragging one rotates the face about that axis through
    /// its centre (an in-plane ring tilts the solid, the normal ring twists it).
    /// Mutually exclusive with `faceMoveActive` / `faceScaleActive`.
    private(set) var faceRotateActive = false

    /// The face gizmo is in SCALE mode (grips) rather than move (arrows).
    var gizmoIsScale: Bool { faceScaleActive }

    /// Whether the move gizmo offers its rotation rings. A body/image rotates; a
    /// selected FACE normally only translates/scales, but the Rotate tool arms
    /// the rings so a ring drag rotates the face (tilt/twist the solid).
    var gizmoAllowsRotation: Bool {
        if case .faceSelected = mode { return faceRotateActive }
        return true
    }

    /// User-facing error surfaced as an alert.
    var errorMessage: String?

    /// Short, non-blocking explanation shown as a pill — e.g. why a tool is
    /// unavailable for the current selection. An alert would be too heavy for
    /// something the user can simply retry differently. Clears itself.
    private(set) var notice: String?
    private var noticeToken = 0

    func showNotice(_ text: String) {
        notice = text
        noticeToken &+= 1
        let token = noticeToken
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.noticeToken == token else { return }
            self.notice = nil
        }
    }

    /// The selection is a curved face, so the planar-only tools (push/pull, and
    /// the Move/Scale/Rotate face transforms) can't act on it.
    var selectionIsCurvedFace: Bool {
        if case .faceSelected = mode { return toolContext?.curvedRegion == true }
        return false
    }

    /// Set by the viewport coordinator: renders the current scene offscreen.
    var thumbnailProvider: (() -> Data?)?

    /// Set by the viewport coordinator: offscreen render with screenshot
    /// options (width, height, transparent background, show grid).
    var screenshotProvider: ((Int, Int, Bool, Bool) -> Data?)?

    /// All solid bodies, or nil (with a user-facing error) when empty.
    private func exportableBodies() -> [Body]? {
        let bodies = session.document.bodies
        guard !bodies.isEmpty else {
            errorMessage = "Nothing to export — the design has no solid bodies."
            return nil
        }
        return bodies
    }

    /// STL of the whole document, or nil when empty.
    func exportSTL() -> Data? {
        exportableBodies().map { STLExporter.binarySTL(bodies: $0) }
    }

    /// OBJ of the whole document, or nil when empty.
    func exportOBJ() -> Data? {
        exportableBodies().map { Data(OBJExporter.obj(bodies: $0).utf8) }
    }

    /// 3MF of the whole document, or nil when empty.
    func exportThreeMF() -> Data? {
        exportableBodies().map { ThreeMFExporter.threeMF(bodies: $0) }
    }

    /// GLB of the whole document, or nil when empty.
    func exportGLB() -> Data? {
        exportableBodies().map { GLBExporter.glb(bodies: $0) }
    }

    /// USDZ of the whole document (plan §B14); nil when the design is empty
    /// or ModelIO on this platform cannot write USDZ (the UI hides the
    /// entries via `USDZExporter.isSupported`, so this error is a fallback).
    func exportUSDZ() -> Data? {
        guard let bodies = exportableBodies() else { return nil }
        guard let data = USDZExporter.usdz(bodies: bodies) else {
            errorMessage = "Couldn't export USDZ on this device."
            return nil
        }
        return data
    }

    /// Per-body OBJ payloads for the "Separate File per Body" export option
    /// (plan §B14); nil (with a user-facing error) when the design is empty.
    func exportOBJPerBody() -> [(name: String, data: Data)]? {
        exportableBodies().map { bodies in
            bodies.map { ($0.name, Data(OBJExporter.obj(bodies: [$0]).utf8)) }
        }
    }

    /// Per-body GLB payloads, mirroring `exportOBJPerBody`.
    func exportGLBPerBody() -> [(name: String, data: Data)]? {
        exportableBodies().map { bodies in
            bodies.map { ($0.name, GLBExporter.glb(bodies: [$0])) }
        }
    }

    /// STEP AP214 of every ANALYTIC body (spec §12.2), or nil with a
    /// user-facing error. Unlike the mesh formats above this one carries the
    /// exact B-rep, so a cylinder arrives in the other CAD tool as a cylinder
    /// — which is also why mesh-only bodies can't ride along: they are named
    /// in a notice instead of being quietly triangulated.
    func exportSTEP() -> Data? {
        guard let bodies = exportableBodies() else { return nil }
        switch STEPKit.export(bodies: bodies) {
        case let .success(data, skipped):
            if !skipped.isEmpty {
                showNotice(skippedNotice(skipped))
            }
            return data
        case let .nothingAnalytic(skipped):
            errorMessage = skipped.count == 1
                ? "“\(skipped[0])” has no analytic B-rep, so there is nothing to write "
                  + "to STEP. Bodies imported as meshes can be exported as STL, OBJ, GLB or 3MF."
                : "None of these \(skipped.count) bodies has an analytic B-rep, so there is "
                  + "nothing to write to STEP. Mesh bodies can be exported as STL, OBJ, GLB or 3MF."
            return nil
        case .failed:
            errorMessage = "Couldn't write the STEP file — please try again."
            return nil
        }
    }

    /// "2 mesh-only bodies were skipped (Imported, Imported 2)" — the names
    /// matter, because a partial export otherwise looks like a complete one.
    private func skippedNotice(_ skipped: [String]) -> String {
        let names = skipped.prefix(3).joined(separator: ", ")
        let more = skipped.count > 3 ? ", +\(skipped.count - 3) more" : ""
        let noun = skipped.count == 1 ? "body" : "bodies"
        return "STEP skipped \(skipped.count) mesh-only \(noun) (\(names)\(more))."
    }

    /// DXF of the active sketch while sketching, else of the ground-plane
    /// sketch (plan §B14, spec §12); nil (with a user-facing error) when
    /// neither has entities.
    func exportDXF() -> Data? {
        let sketch = activeSketch
            ?? session.document.sketches.first { $0.plane.isCoincident(with: .ground) }
        guard let sketch, !sketch.entities.isEmpty else {
            errorMessage = "Nothing to export — draw a sketch on the ground plane first."
            return nil
        }
        return Data(DXFKit.exportSketch(entities: sketch.entities, plane: sketch.plane).utf8)
    }

    /// DXF import (plan §B14, spec §12.1): parsed entities land in the
    /// ground-plane sketch — reused when one exists (unhiding it if an
    /// extrude auto-hid it), created otherwise — as ONE CompositeCommand so
    /// a single undo removes everything the import added.
    func importDXF(data: Data, fileName: String) {
        let entities = DXFKit.importDXF(data)
        guard !entities.isEmpty else {
            errorMessage = "Couldn't import “\(fileName)” — no supported DXF entities found."
            return
        }
        cancelTransientPicks()
        if case .sketching = mode { finishSketch() }
        var commands: [DocumentCommand] = []
        let sketch: Sketch
        if let existing = session.document.sketches.first(where: {
            $0.plane.isCoincident(with: .ground)
        }) {
            sketch = existing
            if existing.isHidden {
                commands.append(SetItemVisibilityCommand(
                    item: .sketch(existing.id), isHidden: false
                ))
            }
        } else {
            sketch = Sketch(name: session.document.uniqueSketchName(), plane: .ground)
            commands.append(AddSketchCommand(sketch: sketch))
        }
        commands.append(AddSketchEntitiesCommand(
            sketchID: sketch.id, entities: entities, title: "Import DXF"
        ))
        session.perform(CompositeCommand(title: "Import DXF", commands: commands))
        mode = .idle
        cameraControl?.moveCameraHeadOn(to: sketch.plane)
    }

    /// Screenshot PNG at the requested size, or nil (with a user-facing
    /// error) when the viewport is not ready.
    func captureScreenshot(
        width: Int, height: Int, transparentBackground: Bool, showGrid: Bool
    ) -> Data? {
        guard let data = screenshotProvider?(width, height, transparentBackground, showGrid) else {
            errorMessage = "Couldn't capture a screenshot — please try again."
            return nil
        }
        return data
    }

    /// STL import (spec §12.1): parsed mesh becomes a body named after the
    /// file, with its pivot at the mesh AABB center.
    func importSTL(data: Data, fileName: String) {
        let mesh: RenderMesh
        do {
            mesh = try STLImporter.importSTL(data)
        } catch {
            errorMessage = "Couldn't import “\(fileName)” — not a valid STL file."
            return
        }
        // Recenter local coordinates so the gizmo pivot sits at the AABB
        // center instead of wherever the file's origin happened to be.
        var recentered = mesh
        let aabb = mesh.localAABB
        let center = (aabb.min + aabb.max) * 0.5
        for i in recentered.positions.indices {
            recentered.positions[i] -= center
        }
        var transform = Transform3D.identity
        transform.translation = SIMD3<Double>(center)

        let stem = (fileName as NSString).deletingPathExtension
        let base = stem.isEmpty ? "Imported" : stem
        var document = session.document
        let body = Body(
            id: BodyID(),
            name: document.uniqueBodyName(base: base),
            transform: transform,
            primitive: nil,
            render: recentered,
            revision: document.nextRevision()
        )
        cancelTransientPicks()
        session.perform(AddBodyCommand(body: body, title: "Import \(body.name)"))
        selection = [body.id]
        mode = .idle
        cameraControl?.fitScene()
    }

    /// STEP import (spec §12.1): every solid in the file becomes its own body,
    /// carrying its analytic `brep` — so an imported part can be filleted,
    /// shelled and booleaned on the OCCT path exactly like one modelled here.
    /// All of them land as ONE undo step.
    func importSTEP(data: Data, fileName: String) {
        let solids = STEPKit.solids(from: data)
        guard !solids.isEmpty else {
            errorMessage = "Couldn't import “\(fileName)” — no solids found in the STEP file."
            return
        }
        let stem = (fileName as NSString).deletingPathExtension
        let base = stem.isEmpty ? "Imported" : stem
        // A local COPY of the document, grown as we go: `uniqueBodyName` reads
        // the bodies it can see, and a multi-solid file has to number its own
        // parts before any of them reach the real document.
        var document = session.document
        var bodies: [Body] = []
        for handle in solids {
            let name = document.uniqueBodyName(base: base)
            guard let body = STEPKit.body(
                from: handle, name: name, revision: document.nextRevision()) else { continue }
            document.bodies.append(body)
            bodies.append(body)
        }
        guard !bodies.isEmpty else {
            errorMessage = "Couldn't import “\(fileName)” — its solids could not be meshed."
            return
        }
        cancelTransientPicks()
        session.perform(CompositeCommand(
            title: "Import STEP",
            commands: bodies.map { AddBodyCommand(body: $0, title: "Import \($0.name)") }))
        selection = Set(bodies.map(\.id))
        mode = .idle
        cameraControl?.fitScene()
        if bodies.count < solids.count {
            showNotice("Imported \(bodies.count) of \(solids.count) solids — "
                       + "the rest could not be meshed.")
        }
    }

    /// Mesh import for glTF/GLB, USDZ and OBJ (+MTL/textures, alone or in a
    /// zip). Every part becomes its own body — texture coordinates and the
    /// albedo image ride along on the mesh and material — and all of them
    /// land as ONE undo step, like STEP.
    /// Parse a mesh file without applying units, for the import prompt.
    /// Sets `errorMessage` and returns nil when the file can't be read.
    func probeMesh(data: Data, fileName: String, siblings: [String: Data] = [:]) -> MeshImportProbe? {
        do {
            return try MeshImportKit.probe(data: data, fileName: fileName, siblings: siblings)
        } catch MeshImportError.unsupportedFormat(let what) {
            errorMessage = "Couldn't import “\(fileName)” — \(what.isEmpty ? "unknown" : what) files aren't supported."
        } catch MeshImportError.empty {
            errorMessage = "Couldn't import “\(fileName)” — no triangle meshes found."
        } catch MeshImportError.malformed(let what) {
            errorMessage = "Couldn't import “\(fileName)” — \(what)."
        } catch {
            errorMessage = "Couldn't import “\(fileName)” — \(error)."
        }
        return nil
    }

    /// Import with the detected unit, or `unitScale` mm per file unit (the
    /// bridge's `units`). The UI goes through `probeMesh` + the prompt +
    /// `importParts` instead so the user chooses.
    func importMesh(data: Data, fileName: String, siblings: [String: Data] = [:],
                    unitScale: Double? = nil) {
        guard let probe = probeMesh(data: data, fileName: fileName, siblings: siblings) else { return }
        importParts(MeshImportKit.scaled(probe.parts, by: unitScale ?? probe.detectedScale),
                    fileName: fileName)
    }

    /// Parts (already in millimetres) become mesh bodies, one undo step.
    func importParts(_ parts: [ImportedPart], fileName: String) {
        let stem = (fileName as NSString).deletingPathExtension
        let fallback = stem.isEmpty ? "Imported" : stem
        var document = session.document
        var bodies: [Body] = []
        for part in parts where part.mesh.indices.count >= 3 {
            // Pivot at the part's AABB centre, like STL; the file's placement
            // survives in the transform.
            var mesh = part.mesh
            let aabb = mesh.localAABB
            let center = (aabb.min + aabb.max) * 0.5
            for i in mesh.positions.indices { mesh.positions[i] -= center }
            var transform = Transform3D.identity
            transform.translation = SIMD3<Double>(center)
            // A part the file never named ("Part", "Part (material)") takes
            // the file's own name instead.
            var base = part.name.trimmingCharacters(in: .whitespaces)
            if base.isEmpty || base == "Part" { base = fallback }
            else if base.hasPrefix("Part (") { base = fallback + base.dropFirst(4) }
            var body = Body(
                id: BodyID(),
                name: document.uniqueBodyName(base: base),
                transform: transform,
                primitive: nil,
                render: mesh,
                revision: document.nextRevision())
            body.material = part.material?.clamped
            document.bodies.append(body)
            bodies.append(body)
        }
        guard !bodies.isEmpty else {
            errorMessage = "Couldn't import “\(fileName)” — no triangle meshes found."
            return
        }
        cancelTransientPicks()
        session.perform(CompositeCommand(
            title: "Import \(fallback)",
            commands: bodies.map { AddBodyCommand(body: $0, title: "Import \($0.name)") }))
        selection = Set(bodies.map(\.id))
        mode = .idle
        cameraControl?.fitScene()
        let textured = bodies.filter { $0.material?.baseColorTexture != nil }.count
        if bodies.count > 1 || textured > 0 {
            showNotice("Imported \(bodies.count) part\(bodies.count == 1 ? "" : "s")"
                       + (textured > 0 ? ", \(textured) textured" : "") + ".")
        }
    }

    func saveThumbnail() {
        if let data = thumbnailProvider?() {
            session.project.thumbnail = data
        }
    }

    /// The pull-arrow handle, computed WITHOUT assembling the full scene.
    /// `ExtrudeGizmoOverlay` re-reads it on every camera move (`cameraEpoch`)
    /// and the viewport per drag tick — reading it off `scene` made plain
    /// orbiting rebuild every drawable each frame (2026-08-25 review, S2).
    /// Priority mirrors the scene builder's old last-write-wins order: an
    /// armed profile tool wins; the section arrow appears only with no tool
    /// armed; the blend-edge arrow comes last.
    var pullArrowState: PullArrowState? {
        // Armed profile tool (extrude / revolve / offset plane). Suppressed
        // while a face Move/Scale/Rotate tool is armed: then only that gizmo
        // shows, and drags reach it (shear/taper) instead of the arrow.
        if let context = toolContext, !context.curvedRegion,
           !faceMoveActive, !faceScaleActive, !faceRotateActive {
            let centroid = context.plane.toWorld(context.profile.centroid)
            switch context.kind {
            case .extrude(let distance):
                let n = context.plane.normal
                let tip = centroid + n * distance
                return PullArrowState(
                    origin: SIMD3(Float(tip.x), Float(tip.y), Float(tip.z)),
                    direction: SIMD3(Float(n.x), Float(n.y), Float(n.z)),
                    isValid: context.isPendingValid
                )
            case .revolve:
                let t = context.plane.xAxis
                return PullArrowState(
                    origin: SIMD3(Float(centroid.x), Float(centroid.y), Float(centroid.z)),
                    direction: SIMD3(Float(t.x), Float(t.y), Float(t.z))
                )
            case .offsetPlane(let distance):
                let n = context.plane.normal
                let tip = centroid + n * distance
                return PullArrowState(
                    origin: SIMD3(Float(tip.x), Float(tip.y), Float(tip.z)),
                    direction: SIMD3(Float(n.x), Float(n.y), Float(n.z))
                )
            case .sweep, .loft:
                break // no drag-editable parameter → no arrow
            }
        }
        // Section plane drag (offset-plane pattern); defers to a profile tool.
        if let section = sectionState, toolContext == nil {
            let plane = section.plane
            let n = simd_normalize(section.basePlane.normal)
            return PullArrowState(
                origin: SIMD3(Float(plane.origin.x), Float(plane.origin.y), Float(plane.origin.z)),
                direction: SIMD3(Float(n.x), Float(n.y), Float(n.z))
            )
        }
        // Drag-to-size handle (spec §4.3 edge arrows): rides the LAST picked
        // blend edge's midpoint, pointing INTO the body along the inward
        // bisector — dragging the way it points carves a bigger blend.
        if case .pickingBlendEdges = mode, let bodyID = blendBodyID,
           let body = session.document.body(with: bodyID),
           let last = blendSelectedEdges.last {
            var bis = last.normalA + last.normalB
            let bl = simd_length(bis)
            if bl > 1e-5 {
                bis /= bl
                let matrix = body.transform.matrixFloat
                let mid4 = matrix * SIMD4(last.midpoint, 1)
                let dir4 = matrix * SIMD4(-bis, 0)   // inward, world space
                let dir = simd_normalize(SIMD3(dir4.x, dir4.y, dir4.z))
                return PullArrowState(
                    origin: SIMD3(mid4.x, mid4.y, mid4.z),
                    direction: dir,
                    isValid: blendPreview != nil || blendValue <= 1e-6
                )
            }
        }
        return nil
    }

    var scene: ViewportScene {
        _ = session.changeCount // establish observation dependency
        var drawables: [BodyDrawable] = []
        // During a face push/pull, the preview IS the modified source body, so
        // hide the original to avoid it poking through the preview.
        let facePreviewSource: BodyID? =
            (toolContext?.previewReplacesSource == true && toolContext?.preview != nil)
            ? toolContext?.sourceBody : nil
        // A live chamfer/fillet preview also replaces its source body.
        let blendPreviewSource: BodyID? = blendPreview != nil ? blendBodyID : nil
        // …and so does a live shell preview.
        let shellPreviewSource: BodyID? = shellPreview != nil ? shellBodyID : nil
        // …and a live delete-face heal.
        let deleteFacePreviewSource: BodyID? =
            deleteFacePreview != nil ? deleteFaceBodyID : nil
        // …and a live replace-face result.
        let replaceFacePreviewSource: BodyID? =
            replaceFacePreview != nil ? replaceFaceBodyID : nil

        // A preview that replaces its source body IS that body mid-edit, so it
        // wears the source's material — without this, a blue part turned the
        // default grey for the whole push/pull, blend, shell or face edit.
        func sourceMaterial(_ sourceID: BodyID?, on preview: Body) -> BodyMaterial? {
            guard let sourceID, let spec = session.document.body(with: sourceID)?.material else { return nil }
            return BodyMaterial(spec: spec, meshHasTexcoords: preview.render.texcoords != nil,
                                revision: preview.meshRevision)
        }

        // Isolate (spec §16.2): a transient override hides everything outside
        // the isolated set without touching persisted visibility.
        for body in session.document.bodies
        where !body.isHidden
            && body.id != facePreviewSource
            && body.id != blendPreviewSource
            && body.id != shellPreviewSource
            && body.id != deleteFacePreviewSource
            && body.id != replaceFacePreviewSource
            && (isolatedBodyIDs?.contains(body.id) ?? true) {
            var selectionState = SelectionStateNone.rawValue
            if selection.contains(body.id) {
                selectionState = SelectionStateSelected.rawValue
            }
            // A face selection highlights just the face (bright blue overlay
            // below), not the whole body — Shapr3D keeps the body neutral.
            if case .faceSelected(let faceBodyID) = mode, faceBodyID == body.id {
                selectionState = SelectionStateNone.rawValue
            }
            drawables.append(BodyDrawable(
                id: body.id,
                renderMesh: body.render,
                edges: body.edges,
                meshRevision: body.meshRevision,
                modelMatrix: body.transform.matrixFloat,
                baseColor: SIMD4(0.72, 0.74, 0.78, 1),
                selectionState: selectionState,
                material: body.material.map {
                    BodyMaterial(spec: $0, meshHasTexcoords: body.render.texcoords != nil,
                                 revision: body.meshRevision)
                }
            ))
        }
        var scene = ViewportScene(bodies: drawables)
        scene.gridPlane = activeSketch?.plane

        // Tool preview (extrude/revolve): translucent accent body — except a
        // face push/pull preview replaces the source body, so it renders as a
        // solid selected body (the real edited result).
        if let preview = toolContext?.preview {
            let replacesSource = facePreviewSource != nil
            scene.bodies.append(BodyDrawable(
                id: preview.id,
                renderMesh: preview.render,
                edges: preview.edges,
                meshRevision: preview.meshRevision,
                modelMatrix: preview.transform.matrixFloat,
                baseColor: SIMD4(0.72, 0.74, 0.78, 1),
                // The face push/pull result renders as a neutral body (like the
                // committed result), not an orange "selected" body.
                selectionState: replacesSource
                    ? SelectionStateNone.rawValue : SelectionStatePreview.rawValue,
                isTranslucent: !replacesSource,
                // A fresh sketch extrude's accent ghost stays uncoloured.
                material: replacesSource ? sourceMaterial(facePreviewSource, on: preview) : nil
            ))
        }

        // Live shell preview: the hollowed source body rendered neutrally in
        // place of the original (spec §4.4 live feedback).
        if let preview = shellPreview {
            scene.bodies.append(BodyDrawable(
                id: preview.id,
                renderMesh: preview.render,
                edges: preview.edges,
                meshRevision: preview.meshRevision,
                modelMatrix: preview.transform.matrixFloat,
                baseColor: SIMD4(0.72, 0.74, 0.78, 1),
                selectionState: SelectionStateNone.rawValue,
                material: sourceMaterial(shellBodyID, on: preview)
            ))
        }

        // Live delete-face preview: the healed body in place of the original.
        if let preview = deleteFacePreview {
            scene.bodies.append(BodyDrawable(
                id: preview.id,
                renderMesh: preview.render,
                edges: preview.edges,
                meshRevision: preview.meshRevision,
                modelMatrix: preview.transform.matrixFloat,
                baseColor: SIMD4(0.72, 0.74, 0.78, 1),
                selectionState: SelectionStateNone.rawValue,
                material: sourceMaterial(deleteFaceBodyID, on: preview)
            ))
        }

        // Live replace-face preview: the extended/trimmed body in place of the
        // original.
        if let preview = replaceFacePreview {
            scene.bodies.append(BodyDrawable(
                id: preview.id,
                renderMesh: preview.render,
                edges: preview.edges,
                meshRevision: preview.meshRevision,
                modelMatrix: preview.transform.matrixFloat,
                baseColor: SIMD4(0.72, 0.74, 0.78, 1),
                selectionState: SelectionStateNone.rawValue,
                material: sourceMaterial(replaceFaceBodyID, on: preview)
            ))
        }

        // Replace Face picks: the face being MOVED in blue, drawn from the
        // original mesh (the preview has already moved it). The target face is
        // not filled — it is not being changed, and colouring it the same way
        // would suggest it is.
        if case .pickingReplaceFace = mode, let bodyID = replaceFaceBodyID,
           let body = session.document.body(with: bodyID),
           let face = replaceSourceFace {
            let matrix = body.transform.matrixFloat
            var triangles: [SIMD3<Float>] = []
            for t in face.triangles where t < body.render.triangleCount {
                for k in 0..<3 {
                    let index = Int(body.render.indices[t * 3 + k])
                    let world = matrix * SIMD4(body.render.positions[index], 1)
                    triangles.append(SIMD3(world.x, world.y, world.z))
                }
            }
            if !triangles.isEmpty {
                scene.profileFills.append(SketchFillBatch(
                    triangles: triangles,
                    color: SIMD4(0.16, 0.55, 1.0, 0.72)
                ))
            }
        }

        // Picked faces (Delete Face): red fills over what Apply will remove,
        // drawn from the ORIGINAL mesh — the preview has already healed them
        // away, so this is the only thing showing what is selected. Red, not
        // the shell pick's blue: this one destroys geometry.
        if case .pickingDeleteFaces = mode, let bodyID = deleteFaceBodyID,
           let body = session.document.body(with: bodyID) {
            let matrix = body.transform.matrixFloat
            var triangles: [SIMD3<Float>] = []
            for target in deleteFaceTargets {
                for t in target.triangles where t < body.render.triangleCount {
                    for k in 0..<3 {
                        let index = Int(body.render.indices[t * 3 + k])
                        let world = matrix * SIMD4(body.render.positions[index], 1)
                        triangles.append(SIMD3(world.x, world.y, world.z))
                    }
                }
            }
            if !triangles.isEmpty {
                scene.profileFills.append(SketchFillBatch(
                    triangles: triangles,
                    color: SIMD4(0.95, 0.26, 0.21, 0.65)
                ))
            }
        }

        // Picked open faces (Shell): vivid-blue fills over the faces the shell
        // will cut open, drawn from the ORIGINAL body's mesh so the user sees
        // the selection even after the preview removes those faces.
        if case .pickingShellFaces = mode, let bodyID = shellBodyID,
           let body = session.document.body(with: bodyID) {
            let matrix = body.transform.matrixFloat
            var triangles: [SIMD3<Float>] = []
            for face in shellSelectedFaces {
                for t in face.triangles where t < body.render.triangleCount {
                    for k in 0..<3 {
                        let index = Int(body.render.indices[t * 3 + k])
                        let world = matrix * SIMD4(body.render.positions[index], 1)
                        triangles.append(SIMD3(world.x, world.y, world.z))
                    }
                }
            }
            if !triangles.isEmpty {
                scene.profileFills.append(SketchFillBatch(
                    triangles: triangles,
                    color: SIMD4(0.16, 0.55, 1.0, 0.72)
                ))
            }
        }

        // Live chamfer/fillet preview: the blended source body rendered
        // neutrally in place of the original (spec §4.3 live feedback).
        if let preview = blendPreview {
            scene.bodies.append(BodyDrawable(
                id: preview.id,
                renderMesh: preview.render,
                edges: preview.edges,
                meshRevision: preview.meshRevision,
                modelMatrix: preview.transform.matrixFloat,
                baseColor: SIMD4(0.72, 0.74, 0.78, 1),
                selectionState: SelectionStateNone.rawValue,
                material: sourceMaterial(blendBodyID, on: preview)
            ))
        }

        // Selected-face highlight (Shapr3D: tap selects a face). While a flat
        // face is pushed/pulled, the highlight RIDES the cap along the pull
        // normal so the selected face stays coloured through the whole drag
        // (Shapr3D keeps it lit). Radial cylinder-wall pushes reshape the wall,
        // so those keep the highlight only at rest.
        if case .faceSelected(let bodyID) = mode,
           let context = toolContext,
           let body = session.document.body(with: bodyID) {
            var offset = SIMD3<Float>(repeating: 0)
            var showHighlight = true
            if case .extrude(let distance) = context.kind, context.cylinderFace == nil {
                let n = context.plane.normal
                offset = SIMD3(Float(n.x * distance), Float(n.y * distance), Float(n.z * distance))
            } else {
                showHighlight = (facePreviewSource == nil)
            }
            let matrix = body.transform.matrixFloat
            var triangles: [SIMD3<Float>] = []
            if showHighlight {
                for t in context.faceTriangles where t < body.render.triangleCount {
                    for k in 0..<3 {
                        let index = Int(body.render.indices[t * 3 + k])
                        let world = matrix * SIMD4(body.render.positions[index], 1)
                        triangles.append(SIMD3(world.x, world.y, world.z) + offset)
                    }
                }
            }
            if !triangles.isEmpty {
                // Vivid blue, mostly opaque — the selected face reads clearly
                // against the neutral body (Shapr3D-style face selection).
                scene.profileFills.append(SketchFillBatch(
                    triangles: triangles,
                    color: SIMD4(0.16, 0.55, 1.0, 0.72)
                ))
            }
        }

        // Selected blend edges (Chamfer/Fillet): draw the picked edges as thick
        // vivid-blue world lines so the user sees the selection set.
        if case .pickingBlendEdges = mode, let bodyID = blendBodyID,
           let body = session.document.body(with: bodyID) {
            let matrix = body.transform.matrixFloat
            var segs: [SIMD3<Float>] = []
            for edge in blendSelectedEdges {
                for p in [edge.start, edge.end] {
                    let w = matrix * SIMD4(p, 1)
                    segs.append(SIMD3(w.x, w.y, w.z))
                }
            }
            if !segs.isEmpty {
                scene.sketchLines.append(SketchLineBatch(
                    segments: segs, color: SIMD4(0.16, 0.55, 1.0, 1)))
            }
        }

        // Pull arrow — computed by `pullArrowState` (NOT inline here) so the
        // gizmo overlay and drag hit-tests can re-read it per camera move
        // without re-assembling this entire scene (2026-08-25 review, S2).
        scene.pullArrow = pullArrowState

        // The move/rotate gizmo is drawn by the 2D `MoveGizmoOverlay` (flat
        // arrows like the extrude handle, curved double-headed rotate arrows),
        // NOT the Metal mesh — so `scene.gizmo` stays nil. Hit-testing still
        // runs off `gizmoOrigin` in the viewport, so drags are unaffected.

        // Sketch overlay: committed entities dark, in-progress accent blue,
        // selected entities accent orange. The sketch BEING EDITED renders its
        // committed entities by definition state (plan §C4): GREEN when fully
        // defined, BLUE when under-defined.
        let committedColor = SIMD4<Float>(0.15, 0.17, 0.20, 1)
        let pendingColor = SIMD4<Float>(0.20, 0.48, 0.95, 1)
        // Paired native line/arc selections are orange; under-defined geometry
        // stays blue. Do not conflate selected edges with construction previews
        // or the separate manipulation control.
        let selectedColor = mode.sketchTool == nil
            ? SIMD4<Float>(1.0, 0.60, 0.0, 1) : pendingColor
        let manipulationColor = SIMD4<Float>(0.0, 0.60, 1.0, 1)
        let definedColor = Self.definedSketchColor
        let underDefinedColor = Self.underDefinedSketchColor
        // Hidden sketches are skipped — except the one being edited.
        let activeSketchID: SketchID? = {
            if case .sketching(let id, _) = mode { return id }
            return nil
        }()
        for sketch in session.document.sketches
        where !sketch.isHidden || sketch.id == activeSketchID {
            // Construction (reference) entities render dashed (spec §3.3).
            let construction = sketch.constructionEntityIDs
            let unselected = sketch.entities.filter { !selectedSketchEntityIDs.contains($0.id) }
            // Per-entity definition state, only for the sketch being edited —
            // from the memo; a miss solves in the background, never here.
            let definition = (sketch.id == activeSketchID)
                ? sketchDefinitionReport(for: sketch) : nil
            let states = definition?.states
            func committedColorFor(_ id: UUID) -> SIMD4<Float> {
                guard let states else { return committedColor }
                return (states[id] ?? false) ? definedColor : underDefinedColor
            }
            func appendRectangleEdges(_ entity: SketchEntity) {
                for index in 0..<4 {
                    guard let edge = RectangleConstruction.axisEdge(entity, index: index) else { continue }
                    let color = definition?.rectangleEdges[entity.id].map {
                        $0[index] ? definedColor : underDefinedColor
                    } ?? committedColorFor(entity.id)
                    let line = SketchEntity.line(id: entity.id, a: edge.a, b: edge.b)
                    let segments = construction.contains(entity.id)
                        ? SketchTessellator.dashedSegments(for: [line], on: sketch.plane, worldUnitsPerPoint: worldPerPoint)
                        : SketchTessellator.segments(for: [line], on: sketch.plane)
                    scene.sketchLines.append(SketchLineBatch(segments: segments, color: color))
                }
            }
            let axisRectangles = unselected.filter { definition?.rectangleEdges[$0.id] != nil }
            for entity in axisRectangles { appendRectangleEdges(entity) }
            // Solid committed entities, grouped by state color.
            let regularUnselected = unselected.filter { !construction.contains($0.id) && !axisRectangles.contains($0) }
            for (color, group) in Dictionary(grouping: regularUnselected, by: { committedColorFor($0.id) }) {
                let segs = SketchTessellator.segments(for: group, on: sketch.plane)
                if !segs.isEmpty {
                    scene.sketchLines.append(SketchLineBatch(segments: segs, color: color))
                }
            }
            // Dashed construction entities, grouped by state color.
            let constructionUnselected = unselected.filter { construction.contains($0.id) && !axisRectangles.contains($0) }
            for (color, group) in Dictionary(grouping: constructionUnselected, by: { committedColorFor($0.id) }) {
                let segs = SketchTessellator.dashedSegments(for: group, on: sketch.plane, worldUnitsPerPoint: worldPerPoint)
                if !segs.isEmpty {
                    scene.sketchLines.append(SketchLineBatch(segments: segs, color: color))
                }
            }
            let selected = sketch.entities.filter { selectedSketchEntityIDs.contains($0.id) }
            let edgeSelected = selected.filter { selectedAxisRectangleEdge?.id == $0.id && selectedSketchEntityIDs.count == 1 }
            for entity in edgeSelected {
                guard let pick = selectedAxisRectangleEdge,
                      let edge = RectangleConstruction.axisEdge(entity, index: pick.index) else { continue }
                appendRectangleEdges(entity)
                scene.sketchLines.append(SketchLineBatch(
                    segments: SketchTessellator.segments(for: [.line(id: entity.id, a: edge.a, b: edge.b)], on: sketch.plane),
                    color: selectedColor))
            }
            let regularSelected = selected.filter { !construction.contains($0.id) && !edgeSelected.contains($0) }
            if !regularSelected.isEmpty {
                scene.sketchLines.append(SketchLineBatch(
                    segments: SketchTessellator.segments(for: regularSelected, on: sketch.plane),
                    color: selectedColor
                ))
            }
            let constructionSelected = selected.filter { construction.contains($0.id) }
            if !constructionSelected.isEmpty {
                scene.sketchLines.append(SketchLineBatch(
                    segments: SketchTessellator.dashedSegments(
                        for: constructionSelected, on: sketch.plane, worldUnitsPerPoint: worldPerPoint
                    ),
                    color: selectedColor
                ))
            }
            // Tangent may contact an arc's supporting circle outside its
            // visible span. Native shows the complementary arc as a violet
            // dashed guide, never as selectable/profile-producing geometry.
            if activeSketchID == sketch.id {
                var guided = Set<UUID>()
                for constraint in sketch.constraints where constraint.kind == .tangent {
                    guard annotationIsVisible(refs: constraint.refs,
                        alwaysShow: CADPreferences.shared.alwaysShowConstraints,
                        explicitlySelected: selectedConstraintID == constraint.id) else { continue }
                    let ids = Set(constraint.refs.map(\.entityID))
                    let operands = sketch.entities.filter { ids.contains($0.id) }
                    guard let arc = operands.first(where: { if case .arc = $0 { return true }; return false }),
                          let circle = operands.first(where: { if case .circle = $0 { return true }; return false }),
                          case let .arc(id, center, radius, start, end) = arc,
                          case let .circle(_, otherCenter, otherRadius) = circle,
                          !guided.contains(id) else { continue }
                    // An internally tangent smaller arc contacts the far side
                    // of its supporting circle, away from the larger center.
                    let reverseRay = constraint.circleTangency == .internalContact && radius < otherRadius
                    let ray = reverseRay ? center - otherCenter : otherCenter - center
                    guard simd_length(ray) > 1e-9 else { continue }
                    let sweep = SketchEntity.arcSweep(startAngle: start, endAngle: end)
                    let offset = SketchEntity.arcSweep(startAngle: start, endAngle: atan2(ray.y, ray.x))
                    guard sweep > 1e-9, offset > sweep + 1e-9 else { continue }
                    guided.insert(id)
                    let extensionArc = SketchEntity.arc(id: id, center: center, radius: radius,
                                                       startAngle: end, endAngle: start)
                    scene.sketchLines.append(SketchLineBatch(
                        segments: SketchTessellator.dashedSegments(for: [extensionArc], on: sketch.plane,
                                                                  worldUnitsPerPoint: worldPerPoint),
                        color: SIMD4<Float>(0.55, 0.30, 0.95, 1)))
                }
            }
            // While sketching, native leaves unselected closed regions clear,
            // including reference profiles belonging to other sketch items.
            // An armed profile tool adds its explicit selection fill below;
            // do not tint every region merely because its boundary is closed.
            if activeSketchID == nil {
                scene.profileFills.append(contentsOf: fillBatches(for: sketch))
            }
        }
        // The regions an armed profile tool is working on read stronger than
        // the rest: the first one and every extra one tapped in afterwards.
        // Without this a second region joined the extrude (its volume proved
        // it) with no visible sign that the tap had landed.
        if let context = toolContext, let sketchID = context.sketchID,
           let sketch = session.document.sketches.first(where: { $0.id == sketchID }) {
            let armedColor = SIMD4<Float>(0.16, 0.55, 1.0, 0.45)
            for entry in [(context.profile, context.holes)] + context.extraProfiles.map({ ($0.profile, $0.holes) }) {
                let triangles = SketchTessellator.fillTriangles(
                    for: entry.0, holes: entry.1, on: sketch.plane)
                if !triangles.isEmpty {
                    scene.profileFills.append(SketchFillBatch(triangles: triangles, color: armedColor))
                }
            }
        }
        if case .sketching(let activeID, _) = mode,
           let sketch = session.document.sketches.first(where: { $0.id == activeID }) {
            let pendings = [pendingEntity, pendingArcEntity].compactMap { $0 } + rectanglePreview
            if !pendings.isEmpty {
                // A released three-point baseline is the active construction
                // edge (native orange), not a new blue stroke or committed edge.
                let releasedRectangleBaseline = rectangleType == .threePoint
                    && rectangleBaseline != nil && rectanglePreview.count == 1
                scene.sketchLines.append(SketchLineBatch(
                    segments: SketchTessellator.segments(for: pendings, on: sketch.plane),
                    color: releasedRectangleBaseline ? SIMD4<Float>(1.0, 0.60, 0.0, 1) : pendingColor
                ))
            }
            // Offset Edge (spec §1.9): the picked source entities read as
            // selected, and the offset result previews in the pending colour
            // so it is legible as not-yet-committed geometry.
            if case .offset = mode.sketchTool {
                let sources = sketchOffsetSourceEntities
                if !sources.isEmpty {
                    scene.sketchLines.append(SketchLineBatch(
                        segments: SketchTessellator.segments(for: sources, on: sketch.plane),
                        color: selectedColor
                    ))
                }
                if !sketchOffsetPreview.isEmpty {
                    scene.sketchLines.append(SketchLineBatch(
                        segments: SketchTessellator.segments(
                            for: sketchOffsetPreview, on: sketch.plane
                        ),
                        color: pendingColor
                    ))
                }
            }
            // Line tool tap-chaining: mark the vertex the next tap extends from,
            // so a first tap (which draws no segment yet) still reads as landed.
            if tapChainActive, let anchor = chainAnchor {
                scene.sketchLines.append(SketchLineBatch(
                    segments: Self.chainAnchorMarkerSegments(at: anchor, on: sketch.plane),
                    color: pendingColor
                ))
                // Closing highlight: when the hover preview is snapped onto the
                // start point, ring it so the user sees the loop will close.
                if lineWillClose, let start = chainStart {
                    scene.sketchLines.append(SketchLineBatch(
                        segments: Self.closeLoopMarkerSegments(at: start, on: sketch.plane),
                        color: pendingColor
                    ))
                }
            }
            // Selection gizmo (plan §B6, spec §1.10): move handle at the
            // selection centroid plus a rotate ring around it.
            if mode.sketchTool == nil, !usesExplicitSketchTransform, !sketchTransformActive,
               let centroid = sketchSelectionCentroid {
                scene.sketchLines.append(SketchLineBatch(
                    segments: sketchGizmoSegments(centroid: centroid, plane: sketch.plane),
                    color: manipulationColor
                ))
            }
            if mode.sketchTool == .rect,
               let anchor = rectangleAnchor ?? rectangleBaseline?.a ?? sketchStrokeStart {
                scene.sketchLines.append(SketchLineBatch(
                    segments: Self.chainAnchorMarkerSegments(at: anchor, on: sketch.plane),
                    color: pendingColor))
            }
            // Live auto-constraint guides (plan §B): violet reference lines for
            // the relationships being inferred for the in-progress stroke.
            if !activeGuides.isEmpty {
                let guideColor = SIMD4<Float>(0.55, 0.30, 0.95, 1)
                var segs: [SIMD3<Float>] = []
                for guide in activeGuides {
                    let a = sketch.plane.toWorld(guide.a)
                    let b = sketch.plane.toWorld(guide.b)
                    segs.append(SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z)))
                    segs.append(SIMD3<Float>(Float(b.x), Float(b.y), Float(b.z)))
                }
                scene.sketchLines.append(SketchLineBatch(segments: segs, color: guideColor))
            }
        }

        // Pattern ghost preview (plan §B5): translucent body instances, or
        // accent-blue entity copies for sketch-profile patterns.
        if case .patterning = mode, let state = patternState {
            if let bodyID = state.bodyID,
               let body = session.document.body(with: bodyID) {
                for transform in patternTransforms(state).dropFirst() {
                    scene.bodies.append(BodyDrawable(
                        id: body.id,
                        renderMesh: body.render,
                        edges: body.edges,
                        meshRevision: body.meshRevision,
                        modelMatrix: Self.composedPatternTransform(
                            transform, base: body.transform
                        ).matrixFloat,
                        baseColor: SIMD4(0.72, 0.74, 0.78, 1),
                        selectionState: SelectionStatePreview.rawValue,
                        isTranslucent: true
                    ))
                }
            } else if let sketchID = state.sketchID,
                      let sketch = session.document.sketches.first(where: { $0.id == sketchID }) {
                let entities = sketch.entities.filter { state.entityIDs.contains($0.id) }
                var ghosts: [SketchEntity] = []
                for transform in sketchPatternTransforms(state).dropFirst() {
                    for entity in entities {
                        ghosts.append(contentsOf: PatternKit.transformed(entity, by: transform))
                    }
                }
                if !ghosts.isEmpty {
                    scene.sketchLines.append(SketchLineBatch(
                        segments: SketchTessellator.segments(for: ghosts, on: sketch.plane),
                        color: pendingColor
                    ))
                }
            }
        }

        // Construction planes: translucent bordered quads (spec §6.1).
        // An Items-selected plane takes the accent colour.
        let selectedPlaneID = selectedPlane?.id
        for plane in session.document.planes where !plane.isHidden {
            let selected = plane.id == selectedPlaneID
            appendPlaneQuad(
                plane.plane, size: plane.size,
                fill: selected ? SIMD4(0.0, 0.52, 1.0, 0.22) : SIMD4(0.45, 0.58, 0.80, 0.16),
                border: selected ? SIMD4(0.0, 0.52, 1.0, 1) : SIMD4(0.45, 0.58, 0.80, 0.85),
                into: &scene
            )
        }
        // Construction axes (spec §6.2): a dashed reference line, drawn in the
        // same muted blue as the plane tiles so construction geometry reads as
        // one family and stays distinct from sketch geometry.
        let axisColor = SIMD4<Float>(0.45, 0.58, 0.80, 0.95)
        for axis in session.document.axes where !axis.isHidden {
            scene.sketchLines.append(SketchLineBatch(
                segments: Self.axisSegments(axis), color: axisColor))
        }
        // Live preview of the axis being defined, in the accent colour.
        if let pending = pendingAxisPreview {
            scene.sketchLines.append(SketchLineBatch(
                segments: Self.axisSegments(pending),
                color: SIMD4(0.0, 0.52, 1.0, 0.95)))
        }

        // Pending offset plane: accent quad tracking the pull.
        if let context = toolContext, case .offsetPlane(let distance) = context.kind {
            let pending = offsetPlanePreview(context, distance: distance)
            appendPlaneQuad(
                pending.plane, size: pending.size,
                fill: SIMD4(0.0, 0.52, 1.0, 0.20),
                border: SIMD4(0.0, 0.52, 1.0, 0.9),
                into: &scene
            )
        }

        // Inserted reference images (plan §B10): textured quads, plus an
        // accent outline around the selected one.
        for image in session.document.images where !image.isHidden {
            let plane = image.plane
            let origin = SIMD3<Float>(
                Float(plane.origin.x), Float(plane.origin.y), Float(plane.origin.z)
            )
            scene.imageQuads.append(ImageQuadDrawable(
                id: image.id.raw,
                origin: origin,
                xAxis: SIMD3(Float(plane.xAxis.x), Float(plane.xAxis.y), Float(plane.xAxis.z)),
                yAxis: SIMD3(Float(plane.yAxis.x), Float(plane.yAxis.y), Float(plane.yAxis.z)),
                width: Float(image.width),
                height: Float(image.height),
                opacity: Float(image.opacity),
                textureData: image.imageData
            ))
            if image.id == selectedImageID {
                let hw = image.width / 2
                let hh = image.height / 2
                let corners = [
                    SIMD2(-hw, -hh), SIMD2(hw, -hh), SIMD2(hw, hh), SIMD2(-hw, hh),
                ].map { (corner: SIMD2<Double>) -> SIMD3<Float> in
                    let world = plane.toWorld(corner)
                    return SIMD3(Float(world.x), Float(world.y), Float(world.z))
                }
                scene.sketchLines.append(SketchLineBatch(
                    segments: [corners[0], corners[1], corners[1], corners[2],
                               corners[2], corners[3], corners[3], corners[0]],
                    color: SIMD4(0.0, 0.52, 1.0, 1)
                ))
            }
        }

        // Plane pickers while a sketch tool waits for its plane, while the
        // Split tool waits for a cutter plane, while Section View waits for
        // its plane, or while Insert Image waits for its target plane.
        switch mode {
        case .pickingSketchPlane, .pickingSplitCutter, .pickingSectionPlane, .pickingImagePlane:
            // Origin tiles go in unscaled: the renderer resolves their size
            // per frame from its camera (see `worldPlaneTiles`).
            scene.planePickers = PlanePicking.originTiles + constructionPlaneTiles
        default:
            break
        }

        // Display mode + Section View (spec §16, plan §B11/§B12).
        scene.displayMode = displayMode
        scene.showHiddenEdges = showHiddenEdges
        scene.groundShadow = groundShadowEnabled
        if let section = sectionState {
            let plane = section.plane
            let n = simd_normalize(section.basePlane.normal)
            let keep = section.flipped ? -n : n
            scene.sectionPlane = SectionPlaneState(
                point: SIMD3(Float(plane.origin.x), Float(plane.origin.y), Float(plane.origin.z)),
                normal: SIMD3(Float(keep.x), Float(keep.y), Float(keep.z))
            )
            // The plane rectangle, nudged a hair to the kept side so its own
            // fill/border survive the clip test in the sketch shaders.
            var quadPlane = plane
            quadPlane.origin += keep * 1e-3
            appendPlaneQuad(
                quadPlane, size: section.size,
                fill: SIMD4(0.0, 0.52, 1.0, 0.10),
                border: SIMD4(0.0, 0.52, 1.0, 0.85),
                into: &scene
            )
            // The section plane's own pull arrow comes from `pullArrowState`.
        }

        // Measure/Translate/Align picks: cross markers at each picked point
        // (+ the span line for a completed measure).
        let markerPoints: [SIMD3<Double>] = {
            switch mode {
            case .measuring: return measurePoints
            case .translating, .aligning: return transformPickPoints
            default: return []
            }
        }()
        if !markerPoints.isEmpty {
            var segments: [SIMD3<Float>] = []
            let r = Float(max(0.12, 8 * worldPerPoint))
            for p in markerPoints {
                let c = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
                segments += [
                    c - SIMD3(r, 0, 0), c + SIMD3(r, 0, 0),
                    c - SIMD3(0, r, 0), c + SIMD3(0, r, 0),
                    c - SIMD3(0, 0, r), c + SIMD3(0, 0, r),
                ]
            }
            if measurePoints.count == 2 {
                let a = measurePoints[0]
                let b = measurePoints[1]
                segments += [
                    SIMD3(Float(a.x), Float(a.y), Float(a.z)),
                    SIMD3(Float(b.x), Float(b.y), Float(b.z)),
                ]
            }
            scene.sketchLines.append(SketchLineBatch(
                segments: segments,
                color: SIMD4(0.0, 0.52, 1.0, 1)
            ))
        }
        return scene
    }

    /// Translucent bordered quad for a plane (construction planes and the
    /// pending offset plane), drawn via the fill/line batches.
    private func appendPlaneQuad(
        _ plane: SketchPlane, size: Double,
        fill: SIMD4<Float>, border: SIMD4<Float>,
        into scene: inout ViewportScene
    ) {
        let h = size / 2
        let corners = [
            SIMD2(-h, -h), SIMD2(h, -h), SIMD2(h, h), SIMD2(-h, h),
        ].map { (corner: SIMD2<Double>) -> SIMD3<Float> in
            let world = plane.toWorld(corner)
            return SIMD3(Float(world.x), Float(world.y), Float(world.z))
        }
        scene.profileFills.append(SketchFillBatch(
            triangles: [corners[0], corners[1], corners[2], corners[0], corners[2], corners[3]],
            color: fill
        ))
        scene.sketchLines.append(SketchLineBatch(
            segments: [corners[0], corners[1], corners[1], corners[2],
                       corners[2], corners[3], corners[3], corners[0]],
            color: border
        ))
    }

    /// Origin plane pickers resolved for hit-testing at the camera's current
    /// scale — the same `gizmoWorldScale(at:)` the renderer applies per frame
    /// (`Renderer.draw`), so what is tapped is what is drawn. Constant on
    /// screen, whatever the zoom (iPad, 2026-09-14); this replaces the
    /// 2026-09-05 rule that sized them to 60 % of the largest body. Without
    /// a viewport (unit tests) they are the 2.3 mm default.
    private var worldPlaneTiles: [PlanePickerTile] {
        guard let camera = cameraControl else { return PlanePicking.worldTiles }
        let scale = PlanePicking.originTileScale(gizmoUnit: Double(camera.gizmoWorldScale(at: .zero)))
        return PlanePicking.originTiles.map { $0.scaled(by: scale) }
    }

    /// Tappable quads for the document's visible construction planes.
    private var constructionPlaneTiles: [PlanePickerTile] {
        session.document.planes.filter { !$0.isHidden }.map { plane in
            let h = plane.size / 2
            return PlanePickerTile(
                planeID: plane.id,
                plane: plane.plane,
                localMin: SIMD2(-h, -h),
                localMax: SIMD2(h, h),
                color: SIMD4(0.45, 0.58, 0.80, 0.30)
            )
        }
    }

    /// Gizmo attach point: a single selected body's pivot, or the shared
    /// centroid of pivots for multi-selections (plan §B13). Whole-body
    /// selections only — face selections use the pull arrow instead. A
    /// selected inserted image (plan §B10) attaches the gizmo at its center.
    var gizmoOrigin: SIMD3<Float>? {
        guard let base = gizmoBaseOrigin else { return nil }
        return base + activeGizmoPivotOffset
    }

    /// Where the gizmo attaches BEFORE the user repositions it (see
    /// `activeGizmoPivotOffset`).
    private var gizmoBaseOrigin: SIMD3<Float>? {
        if let image = selectedImage {
            let center = image.plane.origin
            return SIMD3(Float(center.x), Float(center.y), Float(center.z))
        }
        // A selected face shows only the extrude pull-arrow by DEFAULT. The
        // move/scale gizmo appears only after the user picks Move or Scale from
        // the Transform menu — the Shapr3D flow, where those are explicit tools,
        // not something a face selection auto-shows.
        if case .faceSelected = mode, faceMoveActive || faceScaleActive || faceRotateActive,
           let context = toolContext {
            let c = context.plane.toWorld(context.profile.centroid)
            return SIMD3(Float(c.x), Float(c.y), Float(c.z))
        }
        // Sketch entities selected in model mode (QA-24): Shapr3D puts its
        // Move/Rotate gizmo on them too, at the selection's centre.
        if let centroid = modelSketchSelectionCentroid {
            return SIMD3(Float(centroid.x), Float(centroid.y), Float(centroid.z))
        }
        switch mode {
        case .selected, .editingPrimitive:
            break
        default:
            return nil
        }
        // The centre of the selection's world bounding box (combined for
        // several bodies) — where Shapr3D puts its gizmo, and what a
        // rotation spins about. It used to be each body's local origin, the
        // sketch-plane origin an extruded body was born with: the gizmo sat
        // at the base of a box and a rotation swung the box around its
        // base (Jason, iPad, 2026-09-14).
        var lo = SIMD3<Double>(.infinity, .infinity, .infinity)
        var hi = -lo
        var count = 0
        for id in selection {
            guard let body = session.document.body(with: id) else { continue }
            let b = Self.worldBounds(of: body)
            lo = simd_min(lo, SIMD3(b.min.x, b.min.y, b.min.z))
            hi = simd_max(hi, SIMD3(b.max.x, b.max.y, b.max.z))
            count += 1
        }
        guard count > 0 else { return nil }
        let centre = (lo + hi) / 2
        return SIMD3(Float(centre.x), Float(centre.y), Float(centre.z))
    }

    // MARK: - Gizmo pivot (tap the centre to reposition the control)

    /// What a dropped pivot belongs to. Selecting something else — or the same
    /// body's face instead of the body — starts over rather than inheriting the
    /// last drop, so a stale offset can never strand the gizmo off in space.
    private struct GizmoPivotOwner: Equatable {
        var bodies: Set<BodyID>
        var face: Bool
        var image: Bool
        var sketchEntities: Set<UUID>
    }

    private var currentGizmoPivotOwner: GizmoPivotOwner {
        var face = false
        if case .faceSelected = mode { face = true }
        return GizmoPivotOwner(bodies: selection, face: face, image: selectedImage != nil,
                               sketchEntities: selectedSketchEntityIDs)
    }

    /// Where the user dropped the gizmo, as an offset from `gizmoBaseOrigin`.
    /// Repositioning moves the CONTROL only — the bodies stay where they are —
    /// which is how you line an axis up with a corner before moving.
    private var gizmoPivotOffset: SIMD3<Float> = .zero
    private var gizmoPivotOwner: GizmoPivotOwner?
    private var gizmoPivotArmed = false

    /// True once the pivot has been tapped: the dot becomes a crosshair and a
    /// drag on it repositions the gizmo instead of orbiting the camera.
    var gizmoRepositionArmed: Bool {
        gizmoPivotArmed && gizmoPivotOwner == currentGizmoPivotOwner
    }

    /// The offset in force right now — zero unless it belongs to what is
    /// selected at this moment.
    private var activeGizmoPivotOffset: SIMD3<Float> {
        gizmoPivotOwner == currentGizmoPivotOwner ? gizmoPivotOffset : .zero
    }

    /// True when the gizmo has been dragged off its natural attach point.
    var gizmoPivotIsOffset: Bool { activeGizmoPivotOffset != .zero }

    /// Tap on the pivot: arm (or disarm) repositioning.
    func toggleGizmoReposition() {
        guard gizmoOrigin != nil else { return }
        let armed = gizmoRepositionArmed
        claimGizmoPivot()
        gizmoPivotArmed = !armed
    }

    /// Put the gizmo back at its natural attach point — the centre of the
    /// selection — after it was dropped somewhere else (Recenter badge).
    func recenterGizmoPivot() {
        claimGizmoPivot()
        gizmoPivotOffset = .zero
    }

    /// Drop the gizmo at `world` (the pivot drag; nothing else moves).
    func setGizmoPivot(world: SIMD3<Float>) {
        claimGizmoPivot()
        guard let base = gizmoBaseOrigin else { return }
        gizmoPivotOffset = world - base
    }

    /// Hand the pivot to whatever is selected NOW, dropping a previous
    /// selection's offset instead of adopting it.
    private func claimGizmoPivot() {
        let owner = currentGizmoPivotOwner
        guard gizmoPivotOwner != owner else { return }
        gizmoPivotOwner = owner
        gizmoPivotOffset = .zero
    }

    /// Send the gizmo back to its natural attach point and put the dot back.
    func resetGizmoPivot() {
        gizmoPivotOffset = .zero
        gizmoPivotOwner = nil
        gizmoPivotArmed = false
    }

    // MARK: - Move drags (gizmo)

    private var moveBefore: [BodyID: Transform3D]?
    /// The rotation centre for the move in flight: the gizmo's position when
    /// the move began. Captured once, because the gizmo follows the bounding
    /// box, which itself shifts as an asymmetric body turns.
    private var moveRotationPivot: SIMD3<Double>?

    /// Copy badge (spec §5.1): when on, the next gizmo drag duplicates the
    /// selection and moves the copy. Resets after each drag.
    var copyOnDrag = false

    /// World-space delta of the gizmo drag in flight — what the on-gizmo
    /// distance pill reads. nil when no handle is being dragged.
    private(set) var moveDragDelta: SIMD3<Float>?

    /// Live state for a gizmo drag that MOVES a selected face (deforming the
    /// solid), as opposed to translating a whole body. Everything is captured
    /// in WORLD space at drag start so each frame recomputes from the immutable
    /// source — the gizmo delta is world-space too.
    private struct FaceMoveSession {
        let bodyID: BodyID
        let source: Body
        let context: ToolContext
        let sourceLocalMesh: Euclid.Mesh
        let pivot: SIMD3<Double>
        let worldMesh: Euclid.Mesh
        let worldFace: FaceTopology.PlanarFace
        /// Which vertices the drag moves — `worldMesh` and `worldFace` are
        /// fixed for the whole gesture, so this is resolved once here instead
        /// of on every frame (see `KernelOps.FaceVertexMask`). Used by the
        /// COMMIT, which still deforms through Euclid.
        let faceMask: KernelOps.FaceVertexMask
        /// Preview buffers: the source render mesh already shifted into the
        /// body's local space (world minus pivot), the indices of the vertices
        /// the drag translates, and the edge overlay to reuse. A preview frame
        /// is then a copy of `positions` with `delta` added at those indices —
        /// see `KernelOps.faceVertexIndices`.
        let previewRender: RenderMesh
        let previewMovedVertices: [Int]
        let previewEdges: FeatureEdgeSet
    }
    private var faceMoveSession: FaceMoveSession?
    /// The world delta the face-move drag last applied (drives the commit).
    private var faceMoveLastDelta: SIMD3<Float> = .zero
    /// Bumped every preview frame so the GPU re-uploads the deforming mesh.
    private var faceMovePreviewRevision: UInt64 = 0

    /// Build the world-space `PlanarFace` for the currently selected face from
    /// its tool context (plane basis + profile loops are already world/scaled).
    private func selectedFaceWorld(_ context: ToolContext) -> FaceTopology.PlanarFace {
        FaceTopology.PlanarFace(
            triangles: [],
            normal: SIMD3<Float>(Float(context.plane.normal.x),
                                 Float(context.plane.normal.y),
                                 Float(context.plane.normal.z)),
            origin: context.plane.origin,
            basisX: context.plane.xAxis,
            basisY: context.plane.yAxis,
            outline: context.profile.loop,
            holes: context.holes.map(\.loop)
        )
    }

    /// Build the face-selection `ToolContext` (pull-arrow + gizmo anchor) for a
    /// planar face of `body`, mapping its local basis/outline into world space
    /// (uniform scale + rotation + translation). Shared by the tap-to-select
    /// path and the post-deform re-selection so the two never diverge.
    private func faceContext(body: Body, face: FaceTopology.PlanarFace) -> ToolContext {
        let transform = body.transform
        let originWorld = transform.applying(to: face.origin)
        let xWorld = transform.rotation.act(face.basisX)
        let yWorld = transform.rotation.act(face.basisY)
        let plane = SketchPlane(origin: originWorld, xAxis: xWorld, yAxis: yWorld)
        let scale = transform.scale
        let profile = Profile(
            loop: face.outline.map { $0 * scale }, kind: .polygonal, sourceEntityIDs: [])
        let holes = face.holes.map {
            Profile(loop: $0.map { $0 * scale }, kind: .polygonal, sourceEntityIDs: [])
        }
        return ToolContext(
            profile: profile, holes: holes, plane: plane, sketchID: nil,
            sourceBody: body.id, faceTriangles: face.triangles, kind: .extrude(distance: 0))
    }

    /// Tool context for a CURVED smooth face picked whole (twisted wall, blend).
    /// There is no meaningful profile/plane for it — the plane is a nominal frame
    /// at the tapped triangle, used only so the selection has somewhere to anchor
    /// — so `curvedRegion` marks it and the planar-only affordances stay off.
    private func curvedFaceContext(
        body: Body, triangles: [Int], seedTriangle: Int
    ) -> ToolContext {
        let render = body.render
        let i0 = Int(render.indices[seedTriangle * 3])
        let i1 = Int(render.indices[seedTriangle * 3 + 1])
        let i2 = Int(render.indices[seedTriangle * 3 + 2])
        let a = SIMD3<Double>(render.positions[i0])
        let b = SIMD3<Double>(render.positions[i1])
        let c = SIMD3<Double>(render.positions[i2])
        let transform = body.transform
        let originWorld = transform.applying(to: (a + b + c) / 3)
        var xAxis = simd_normalize(b - a)
        let n = simd_normalize(simd_cross(b - a, c - a))
        if !xAxis.x.isFinite { xAxis = SIMD3(1, 0, 0) }
        let yAxis = simd_normalize(simd_cross(n, xAxis))
        let plane = SketchPlane(origin: originWorld,
                                xAxis: transform.rotation.act(xAxis),
                                yAxis: transform.rotation.act(yAxis))
        return ToolContext(
            profile: Profile(loop: [], kind: .polygonal, sourceEntityIDs: []),
            holes: [], plane: plane, sketchID: nil, sourceBody: body.id,
            faceTriangles: triangles, curvedRegion: true, kind: .extrude(distance: 0))
    }

    /// After a face move/scale reshapes the body, re-select the SAME face on the
    /// rebuilt mesh so the active tool stays on the face (Shapr3D keeps the
    /// transform live for repeated drags) instead of falling back to the whole
    /// body. Finds the planar face whose world normal matches `worldNormal` and
    /// whose centroid is nearest `worldCentroid` (a move shifts the centroid by
    /// the drag; a scale about the centroid leaves it put). Returns false when
    /// no matching planar face survives — the caller then settles on the body.
    private func reselectDeformedFace(
        bodyID: BodyID, worldNormal: SIMD3<Double>, worldCentroid: SIMD3<Double>
    ) -> Bool {
        guard let body = session.document.body(with: bodyID) else { return false }
        let mesh = body.render
        let transform = body.transform
        let targetN = simd_normalize(worldNormal)

        // Nearest triangle (by world centroid) whose world normal aligns with the
        // face we just edited; its index seeds the coplanar flood-fill.
        var bestSeed = -1
        var bestDist = Double.greatestFiniteMagnitude
        for t in 0..<mesh.triangleCount {
            let i0 = Int(mesh.indices[t * 3]), i1 = Int(mesh.indices[t * 3 + 1]), i2 = Int(mesh.indices[t * 3 + 2])
            let a = mesh.positions[i0], b = mesh.positions[i1], c = mesh.positions[i2]
            let cross = simd_cross(b - a, c - a)
            let len = simd_length(cross)
            guard len > 1e-12 else { continue }
            let localN = SIMD3<Double>(cross / len)
            let worldN = simd_normalize(transform.rotation.act(localN))
            guard simd_dot(worldN, targetN) > 0.999 else { continue }
            let localCentroid = SIMD3<Double>((a + b + c) / 3)
            let worldC = transform.applying(to: localCentroid)
            let d = simd_length_squared(worldC - worldCentroid)
            if d < bestDist { bestDist = d; bestSeed = t }
        }
        guard bestSeed >= 0,
              let face = FaceTopology.planarFace(in: mesh, seedTriangle: bestSeed)
        else { return false }

        selection = [bodyID]
        toolContext = faceContext(body: body, face: face)
        mode = .faceSelected(bodyID)
        return true
    }

    /// Begin a face move: snapshot the source body in world space so the drag
    /// deforms the same immutable geometry every frame. Returns false (and
    /// leaves `faceMoveSession` nil) when the selection isn't a movable face.
    private func beginFaceMove() -> Bool {
        guard case .faceSelected(let bodyID) = mode,
              let context = toolContext, context.cylinderFace == nil,
              let source = session.document.body(with: bodyID)
        else { return false }
        let local = source.euclidMesh()
        faceMoveLastDelta = .zero
        let worldMesh = local.transformed(by: source.transform.euclid)
        let worldFace = selectedFaceWorld(context)
        let pivot = source.transform.translation
        // Preview buffers, resolved once for the whole gesture. Classification
        // runs on WORLD positions (the face lives in world space); the stored
        // positions are the same vertices shifted into body-local space, so
        // the indices line up.
        let worldRender = EuclidBridge.renderMesh(from: worldMesh)
        let movedVertices = KernelOps.faceVertexIndices(
            in: worldRender.positions, face: worldFace)
        let pivotF = SIMD3<Float>(Float(pivot.x), Float(pivot.y), Float(pivot.z))
        let previewRender = RenderMesh(
            positions: worldRender.positions.map { $0 - pivotF },
            normals: worldRender.normals,
            indices: worldRender.indices)
        faceMoveSession = FaceMoveSession(
            bodyID: bodyID,
            source: source,
            context: context,
            sourceLocalMesh: local,
            pivot: pivot,
            worldMesh: worldMesh,
            worldFace: worldFace,
            faceMask: KernelOps.faceVertexMask(mesh: worldMesh, face: worldFace),
            previewRender: previewRender,
            previewMovedVertices: movedVertices,
            previewEdges: FeatureEdgeExtractor.edges(from: previewRender)
        )
        return true
    }

    /// Commit a face move as one undoable step. A negligible drag reverts the
    /// live preview and pushes nothing. The reshaped body replaces the source
    /// (mesh baked, pivot preserved) exactly like `commitFaceOperation`; a
    /// `.moveFace` feature node is recorded when the body is feature-produced so
    /// the move replays after upstream edits (parametric, like push/pull).
    private func commitFaceMove(worldDelta: SIMD3<Float>) {
        guard let s = faceMoveSession else { return }
        faceMoveSession = nil
        faceMoveLastDelta = .zero

        var beforeTransform = Transform3D.identity
        beforeTransform.translation = s.pivot
        let before = Body(
            id: s.bodyID, name: session.document.body(with: s.bodyID)?.name ?? "Body",
            transform: beforeTransform, primitive: nil,
            euclidMesh: s.sourceLocalMesh, revision: 0
        )

        // Negligible drag (a tap, or a wobble): restore the source and do
        // nothing undoable.
        guard simd_length(worldDelta) > 1e-4,
              let moved = faceMovedLocalMesh(s, worldDelta: worldDelta) else {
            session.preview { document in
                if let index = document.bodyIndex(of: s.bodyID) {
                    document.bodies[index] = before.keepingAppearance(of: document.bodies[index])
                }
            }
            return
        }

        let after = Body(
            id: s.bodyID, name: before.name, transform: beforeTransform,
            primitive: nil, euclidMesh: moved, revision: 0
        )
        let replace = ReplaceBodyCommand(title: "Move Face", before: before, after: after)

        if let node = moveFaceFeatureNode(session: s, worldDelta: worldDelta) {
            session.perform(CompositeCommand(
                title: "Move Face", commands: [replace, AppendFeatureCommand(node: node)]))
        } else {
            session.perform(replace)
        }
        // Keep the Move tool live on the SAME face (Shapr3D leaves it active for
        // repeated shears): re-resolve the face — shifted by the drag — against
        // the reshaped mesh. If it can't be found, fall back to the whole body.
        let oldCentroid = s.context.plane.toWorld(s.context.profile.centroid)
        let newCentroid = oldCentroid + SIMD3<Double>(worldDelta)
        if reselectDeformedFace(bodyID: s.bodyID,
                                worldNormal: s.context.plane.normal,
                                worldCentroid: newCentroid) {
            faceMoveActive = true
        } else {
            toolContext = nil
            faceMoveActive = false
            selection = [s.bodyID]
            mode = .selected(s.bodyID)
        }
        session.save()
    }

    /// A `.moveFace` feature node for a face move on a feature-produced body, or
    /// nil when the body isn't parametric (import/seed/copy) or the face can't be
    /// pinned — in which case the move commits as a plain mesh replacement.
    ///
    /// The world drag is stored as (u, v, n) in the face's own basis (divided by
    /// the body's scale to land in local units), so the replay reconstructs the
    /// same intrinsic move against the re-resolved face after an upstream edit —
    /// exactly how `pushPull` pins its distance to the face normal.
    private func moveFaceFeatureNode(
        session s: FaceMoveSession, worldDelta: SIMD3<Float>
    ) -> FeatureNode? {
        guard let owner = featureNode(owning: s.bodyID),
              let faceRef = pushPullFaceRef(
                  context: s.context, source: s.source, creator: owner.id)
        else { return nil }
        let world = SIMD3<Double>(Double(worldDelta.x), Double(worldDelta.y), Double(worldDelta.z))
        let scale = max(s.source.transform.scale, 1e-9)
        let n = simd_normalize(s.context.plane.normal)
        let components = SIMD3<Double>(
            simd_dot(world, s.context.plane.xAxis) / scale,
            simd_dot(world, s.context.plane.yAxis) / scale,
            simd_dot(world, n) / scale
        )
        return FeatureNode(
            name: "Move Face",
            kind: .moveFace(face: faceRef, delta: PointWrapper(components)),
            outputBodyIDs: [s.bodyID])
    }

    /// Deform the source by moving the selected face by `worldDelta`, returning
    /// the body-local mesh (pivot re-centred, like `commitFaceOperation`). Takes
    /// the session explicitly so `commitFaceMove` can call it AFTER it has
    /// cleared `faceMoveSession` (else the commit would recompute against a nil
    /// session, fall into the "negligible drag" branch, and revert the shear).
    private func faceMovedLocalMesh(_ s: FaceMoveSession, worldDelta: SIMD3<Float>) -> Euclid.Mesh? {
        let delta = SIMD3<Double>(Double(worldDelta.x), Double(worldDelta.y), Double(worldDelta.z))
        let movedWorld = KernelOps.moveFace(mesh: s.worldMesh, mask: s.faceMask, delta: delta)
        guard !movedWorld.polygons.isEmpty else { return nil }
        return movedWorld.translated(by: Vector(-s.pivot.x, -s.pivot.y, -s.pivot.z))
    }

    // MARK: - Face scale (Scale tool on a selected face → taper the solid)

    /// Live state for a gizmo drag that SCALES a selected face. Mirrors
    /// `FaceMoveSession`; captured in world space at drag start.
    private struct FaceScaleSession {
        let bodyID: BodyID
        let source: Body
        let context: ToolContext
        let sourceLocalMesh: Euclid.Mesh
        let pivot: SIMD3<Double>
        let worldMesh: Euclid.Mesh
        let worldFace: FaceTopology.PlanarFace
        /// Resolved once for the gesture — same reason as `FaceMoveSession`.
        let faceMask: KernelOps.FaceVertexMask
        /// Preview buffers, as in `FaceMoveSession`; `previewCenter` is the
        /// face centroid in the same (pivot-shifted) space as the positions.
        let previewRender: RenderMesh
        let previewMovedVertices: [Int]
        let previewEdges: FeatureEdgeSet
        let previewCenter: SIMD3<Float>
    }
    private var faceScaleSession: FaceScaleSession?
    private var faceScaleLastFactor: Double = 1
    /// Bumped every preview frame so the GPU re-uploads the deforming mesh.
    private var faceScalePreviewRevision: UInt64 = 0

    /// Begin a face scale: snapshot the source body so the drag re-scales the
    /// same immutable geometry every frame. Returns false when the selection
    /// isn't a scalable face.
    func beginFaceScale() -> Bool {
        guard case .faceSelected(let bodyID) = mode,
              let context = toolContext, context.cylinderFace == nil,
              let source = session.document.body(with: bodyID)
        else { return false }
        let local = source.euclidMesh()
        faceScaleLastFactor = 1
        let worldMesh = local.transformed(by: source.transform.euclid)
        let worldFace = selectedFaceWorld(context)
        let pivot = source.transform.translation
        let worldRender = EuclidBridge.renderMesh(from: worldMesh)
        let movedVertices = KernelOps.faceVertexIndices(
            in: worldRender.positions, face: worldFace)
        let pivotF = SIMD3<Float>(Float(pivot.x), Float(pivot.y), Float(pivot.z))
        let previewRender = RenderMesh(
            positions: worldRender.positions.map { $0 - pivotF },
            normals: worldRender.normals,
            indices: worldRender.indices)
        let centre = KernelOps.faceCentroid(worldFace)
        faceScaleSession = FaceScaleSession(
            bodyID: bodyID,
            source: source,
            context: context,
            sourceLocalMesh: local,
            pivot: pivot,
            worldMesh: worldMesh,
            worldFace: worldFace,
            faceMask: KernelOps.faceVertexMask(mesh: worldMesh, face: worldFace),
            previewRender: previewRender,
            previewMovedVertices: movedVertices,
            previewEdges: FeatureEdgeExtractor.edges(from: previewRender),
            previewCenter: SIMD3<Float>(Float(centre.x), Float(centre.y), Float(centre.z)) - pivotF
        )
        return true
    }

    /// Deform the source by scaling the selected face by `factor` (pivot
    /// re-centred). Session passed explicitly so the commit can recompute after
    /// clearing `faceScaleSession`.
    private func faceScaledLocalMesh(_ s: FaceScaleSession, factor: Double) -> Euclid.Mesh? {
        let scaledWorld = KernelOps.scaleFace(mesh: s.worldMesh, mask: s.faceMask, factor: factor)
        guard !scaledWorld.polygons.isEmpty else { return nil }
        return scaledWorld.translated(by: Vector(-s.pivot.x, -s.pivot.y, -s.pivot.z))
    }

    /// Live preview of the face scale (bumping revision so the GPU re-uploads).
    func updateFaceScale(factor: Double) {
        guard let s = faceScaleSession else { return }
        faceScaleLastFactor = factor
        // Render-buffer preview, exactly as in `updateMove` — see the note
        // there for why a face drag must not deform through Euclid per frame.
        var positions = s.previewRender.positions
        let f = Float(factor)
        let c = s.previewCenter
        for i in s.previewMovedVertices { positions[i] = c + (positions[i] - c) * f }
        faceScalePreviewRevision &+= 1
        let revision = (UInt64(1) << 59) | faceScalePreviewRevision
        var transform = Transform3D.identity
        transform.translation = s.pivot
        let render = RenderMesh(positions: positions,
                                normals: s.previewRender.normals,
                                indices: s.previewRender.indices)
        session.preview { document in
            guard let index = document.bodyIndex(of: s.bodyID) else { return }
            var preview = Body(
                id: s.bodyID, name: document.bodies[index].name,
                transform: transform, render: render,
                edges: s.previewEdges, revision: revision)
            preview.material = document.bodies[index].material   // not grey mid-drag
            document.bodies[index] = preview
        }
    }

    /// Commit the face scale (uses the last previewed factor).
    func endFaceScale() {
        guard faceScaleSession != nil else { return }
        commitFaceScale(factor: faceScaleLastFactor)
    }

    private func commitFaceScale(factor: Double) {
        guard let s = faceScaleSession else { return }
        faceScaleSession = nil
        faceScaleLastFactor = 1

        var beforeTransform = Transform3D.identity
        beforeTransform.translation = s.pivot
        let before = Body(
            id: s.bodyID, name: session.document.body(with: s.bodyID)?.name ?? "Body",
            transform: beforeTransform, primitive: nil,
            euclidMesh: s.sourceLocalMesh, revision: 0)

        guard abs(factor - 1) > 1e-4,
              let scaled = faceScaledLocalMesh(s, factor: factor) else {
            session.preview { document in
                if let index = document.bodyIndex(of: s.bodyID) {
                    document.bodies[index] = before.keepingAppearance(of: document.bodies[index])
                }
            }
            return
        }

        let after = Body(
            id: s.bodyID, name: before.name, transform: beforeTransform,
            primitive: nil, euclidMesh: scaled, revision: 0)
        let replace = ReplaceBodyCommand(title: "Scale Face", before: before, after: after)

        if let node = scaleFaceFeatureNode(session: s, factor: factor) {
            session.perform(CompositeCommand(
                title: "Scale Face", commands: [replace, AppendFeatureCommand(node: node)]))
        } else {
            session.perform(replace)
        }
        // Keep the Scale tool live on the SAME face (repeated tapers): scaling
        // about the face centroid leaves that centroid put, so re-resolve there.
        let centroid = s.context.plane.toWorld(s.context.profile.centroid)
        if reselectDeformedFace(bodyID: s.bodyID,
                                worldNormal: s.context.plane.normal,
                                worldCentroid: centroid) {
            faceScaleActive = true
        } else {
            toolContext = nil
            faceScaleActive = false
            selection = [s.bodyID]
            mode = .selected(s.bodyID)
        }
        session.save()
    }

    /// A `.scaleFace` feature node for a scale on a feature-produced body, or nil
    /// when the body isn't parametric — then it commits as a plain mesh replace.
    private func scaleFaceFeatureNode(
        session s: FaceScaleSession, factor: Double
    ) -> FeatureNode? {
        guard let owner = featureNode(owning: s.bodyID),
              let faceRef = pushPullFaceRef(
                  context: s.context, source: s.source, creator: owner.id)
        else { return nil }
        return FeatureNode(
            name: "Scale Face",
            kind: .scaleFace(face: faceRef, factor: Expr(value: factor)),
            outputBodyIDs: [s.bodyID])
    }

    // MARK: - Face rotate (Rotate tool on a selected face → tilt/twist the solid)

    /// Live state for a gizmo ring drag that ROTATES a selected face. Mirrors
    /// `FaceScaleSession`; captured in world space at drag start.
    private struct FaceRotateSession {
        let bodyID: BodyID
        let source: Body
        let context: ToolContext
        let sourceLocalMesh: Euclid.Mesh
        let pivot: SIMD3<Double>
        let worldMesh: Euclid.Mesh
        let worldFace: FaceTopology.PlanarFace
    }
    private var faceRotateSession: FaceRotateSession?
    private var faceRotateLastAngle: Double = 0
    private var faceRotateLastAxis = SIMD3<Double>(0, 0, 1)
    private var faceRotatePreviewRevision: UInt64 = 0

    /// Rodrigues rotation of world unit vector `n` about unit `axis` by `angle`.
    private func rotateVector(_ n: SIMD3<Double>, about axis: SIMD3<Double>, by angle: Double) -> SIMD3<Double> {
        let a = simd_normalize(axis)
        return n * cos(angle) + simd_cross(a, n) * sin(angle) + a * simd_dot(a, n) * (1 - cos(angle))
    }

    /// Begin a face rotate: snapshot the source body so each drag frame rotates
    /// the same immutable geometry. Returns false when the selection isn't a
    /// rotatable planar face.
    func beginFaceRotate() -> Bool {
        guard case .faceSelected(let bodyID) = mode,
              let context = toolContext, context.cylinderFace == nil,
              let source = session.document.body(with: bodyID)
        else { return false }
        let local = source.euclidMesh()
        faceRotateLastAngle = 0
        faceRotateSession = FaceRotateSession(
            bodyID: bodyID,
            source: source,
            context: context,
            sourceLocalMesh: local,
            pivot: source.transform.translation,
            worldMesh: local.transformed(by: source.transform.euclid),
            worldFace: selectedFaceWorld(context))
        return true
    }

    /// Deform the source by rotating the selected face by `angle` about world
    /// `axis` (through the centroid), pivot re-centred. Session passed explicitly
    /// so the commit can recompute after clearing `faceRotateSession`.
    private func faceRotatedLocalMesh(
        _ s: FaceRotateSession, angle: Double, axis: SIMD3<Double>
    ) -> Euclid.Mesh? {
        let rotatedWorld = KernelOps.rotateFace(
            mesh: s.worldMesh, face: s.worldFace, angle: angle, axis: axis)
        guard !rotatedWorld.polygons.isEmpty else { return nil }
        return rotatedWorld.translated(by: Vector(-s.pivot.x, -s.pivot.y, -s.pivot.z))
    }

    /// Live preview of the face rotation (bumping revision so the GPU re-uploads).
    func updateFaceRotate(angle: Double, axis: SIMD3<Double>) {
        guard let s = faceRotateSession else { return }
        setRotationOrbitAngle(radians: angle)
        faceRotateLastAngle = angle
        faceRotateLastAxis = axis
        guard let rotated = faceRotatedLocalMesh(s, angle: angle, axis: axis) else { return }
        faceRotatePreviewRevision &+= 1
        let revision = (UInt64(1) << 58) | faceRotatePreviewRevision
        var transform = Transform3D.identity
        transform.translation = s.pivot
        session.preview { document in
            guard let index = document.bodyIndex(of: s.bodyID) else { return }
            var preview = Body(
                id: s.bodyID, name: document.bodies[index].name,
                transform: transform, primitive: nil,
                euclidMesh: rotated, revision: revision)
            preview.material = document.bodies[index].material   // not grey mid-drag
            document.bodies[index] = preview
        }
    }

    /// Commit the face rotation (uses the last previewed angle/axis).
    func endFaceRotate() {
        endRotationOrbit()
        guard faceRotateSession != nil else { return }
        commitFaceRotate(angle: faceRotateLastAngle, axis: faceRotateLastAxis)
    }

    private func commitFaceRotate(angle: Double, axis: SIMD3<Double>) {
        guard let s = faceRotateSession else { return }
        faceRotateSession = nil
        faceRotateLastAngle = 0

        var beforeTransform = Transform3D.identity
        beforeTransform.translation = s.pivot
        let before = Body(
            id: s.bodyID, name: session.document.body(with: s.bodyID)?.name ?? "Body",
            transform: beforeTransform, primitive: nil,
            euclidMesh: s.sourceLocalMesh, revision: 0)

        guard abs(angle) > 1e-4,
              let rotated = faceRotatedLocalMesh(s, angle: angle, axis: axis) else {
            session.preview { document in
                if let index = document.bodyIndex(of: s.bodyID) {
                    document.bodies[index] = before.keepingAppearance(of: document.bodies[index])
                }
            }
            return
        }

        let after = Body(
            id: s.bodyID, name: before.name, transform: beforeTransform,
            primitive: nil, euclidMesh: rotated, revision: 0)
        let replace = ReplaceBodyCommand(title: "Rotate Face", before: before, after: after)

        if let node = rotateFaceFeatureNode(session: s, angle: angle, axis: axis) {
            session.perform(CompositeCommand(
                title: "Rotate Face", commands: [replace, AppendFeatureCommand(node: node)]))
        } else {
            session.perform(replace)
        }
        // Keep the Rotate tool live on the SAME face (repeated tilts): rotating
        // about the centroid leaves it put, but the face NORMAL rotates with it —
        // re-resolve against the tilted normal.
        let centroid = s.context.plane.toWorld(s.context.profile.centroid)
        let newNormal = rotateVector(s.context.plane.normal, about: axis, by: angle)
        if reselectDeformedFace(bodyID: s.bodyID,
                                worldNormal: newNormal,
                                worldCentroid: centroid) {
            faceRotateActive = true
        } else {
            toolContext = nil
            faceRotateActive = false
            selection = [s.bodyID]
            mode = .selected(s.bodyID)
        }
        session.save()
    }

    /// A `.rotateFace` feature node for a rotate on a feature-produced body, or
    /// nil when the body isn't parametric — then it commits as a plain mesh
    /// replace. The axis is stored in the face's own (u, v, n) basis so the tilt /
    /// twist replays intrinsically after an upstream edit.
    private func rotateFaceFeatureNode(
        session s: FaceRotateSession, angle: Double, axis: SIMD3<Double>
    ) -> FeatureNode? {
        guard let owner = featureNode(owning: s.bodyID),
              let faceRef = pushPullFaceRef(
                  context: s.context, source: s.source, creator: owner.id)
        else { return nil }
        let a = simd_normalize(axis)
        let n = simd_normalize(s.context.plane.normal)
        let components = SIMD3<Double>(
            simd_dot(a, s.context.plane.xAxis),
            simd_dot(a, s.context.plane.yAxis),
            simd_dot(a, n))
        return FeatureNode(
            name: "Rotate Face",
            kind: .rotateFace(face: faceRef, angle: Expr(value: angle),
                              axis: PointWrapper(components)),
            outputBodyIDs: [s.bodyID])
    }

    func beginMove() {
        // Selected inserted image (plan §B10): the gizmo drags it in-plane.
        if selectedImage != nil {
            axisEntryPart = nil
            scaleEntryActive = false
            moveDragDelta = nil
            if copyOnDrag {
                copyOnDrag = false
                duplicateSelectedImageForDrag()
            }
            beginImageInteraction()
            return
        }
        // Selected face: the gizmo deforms the solid by moving the face.
        if case .faceSelected = mode {
            axisEntryPart = nil
            scaleEntryActive = false
            moveDragDelta = nil
            copyOnDrag = false // Copy-on-drag is a whole-body affordance.
            _ = beginFaceMove()
            return
        }
        // Sketch entities selected in model mode: the gizmo moves them
        // (QA-24). Copy-on-drag is a whole-body affordance here too.
        if selection.isEmpty, beginModelSketchMove() {
            axisEntryPart = nil
            scaleEntryActive = false
            moveDragDelta = nil
            copyOnDrag = false
            return
        }
        guard !selection.isEmpty else { return }
        axisEntryPart = nil
        scaleEntryActive = false
        moveDragDelta = nil
        if copyOnDrag {
            copyOnDrag = false
            duplicateSelectionForDrag()
        }
        var before = [BodyID: Transform3D]()
        for id in selection {
            if let body = session.document.body(with: id) {
                before[id] = body.transform
            }
        }
        moveBefore = before
        moveRotationPivot = gizmoOrigin.map { SIMD3(Double($0.x), Double($0.y), Double($0.z)) }
    }

    /// Copy badge: clone each selected body in place (AddBodyCommand, new id,
    /// shared CoW buffers) and switch the selection so the drag moves the copy.
    private func duplicateSelectionForDrag() {
        var copies: Set<BodyID> = []
        for id in selection {
            guard let body = session.document.body(with: id) else { continue }
            var clone = Body(
                id: BodyID(),
                name: session.document.uniqueBodyName(base: body.name),
                transform: body.transform,
                primitive: body.primitive,
                render: body.render,
                revision: body.meshRevision
            )
            clone.euclid = body.euclid
            // Carry the analytic solid: a copy of a smooth cylinder must not
            // degrade to its tessellation (review C4). Handles are shared
            // read-only; downstream ops derive new handles, never mutate.
            clone.brep = body.brep
            session.perform(AddBodyCommand(body: clone, title: "Copy \(body.name)"))
            copies.insert(clone.id)
        }
        guard !copies.isEmpty else { return }
        selection = copies
        if copies.count == 1, let id = copies.first {
            mode = session.document.body(with: id)?.primitive != nil
                ? .editingPrimitive(id)
                : .selected(id)
        }
    }

    func updateMove(delta: SIMD3<Float>) {
        // Feeds the distance pill riding the gizmo (Shapr3D shows the travelled
        // distance on the handle as you drag).
        moveDragDelta = delta
        if imageInteractionBaseline != nil {
            updateImageMove(delta: delta)
            return
        }
        // Face move: deform the source and preview the reshaped body. The
        // revision must CHANGE every frame — the GPU cache re-uploads a mesh only
        // when meshRevision differs (GPUResourceCache), so a constant revision
        // would freeze the preview on the first frame. A high tag bit keeps these
        // transient revisions from colliding with real ones (like blend/shell).
        if let s = faceMoveSession {
            faceMoveLastDelta = delta
            // The preview only has to LOOK right, so it translates the picked
            // vertices of the source's render buffers — 0.5 ms — instead of
            // deforming through Euclid, which rebuilds every polygon, welds the
            // result watertight and copies it again to re-pivot: ~370 ms/frame
            // on a body with a fillet on it (≈3 fps, the reported jank). The
            // commit below still runs the real Euclid deform, so the geometry
            // that lands in the document is unchanged. Vertex NORMALS are
            // carried over untouched, which is exactly what `KernelOps.moveFace`
            // does with them, so the shading matches too.
            var positions = s.previewRender.positions
            let d = SIMD3<Float>(delta)
            for i in s.previewMovedVertices { positions[i] += d }
            faceMovePreviewRevision &+= 1
            let revision = (UInt64(1) << 60) | faceMovePreviewRevision
            var transform = Transform3D.identity
            transform.translation = s.pivot
            let render = RenderMesh(positions: positions,
                                    normals: s.previewRender.normals,
                                    indices: s.previewRender.indices)
            session.preview { document in
                guard let index = document.bodyIndex(of: s.bodyID) else { return }
                var preview = Body(
                    id: s.bodyID,
                    name: document.bodies[index].name,
                    transform: transform,
                    render: render,
                    edges: s.previewEdges,
                    revision: revision
                )
                // The fresh body has no material: carry the source's, or a
                // painted part turns the default grey for the whole drag.
                preview.material = document.bodies[index].material
                document.bodies[index] = preview
            }
            return
        }
        if let move = modelSketchMove {
            let worldDelta = SIMD3<Double>(Double(delta.x), Double(delta.y), Double(delta.z))
            previewModelSketchMotion(
                ModelSketchMotion(translation: worldDelta, pivot: move.pivot), title: "Move")
            return
        }
        guard let moveBefore else { return }
        let worldDelta = SIMD3<Double>(Double(delta.x), Double(delta.y), Double(delta.z))
        session.preview { document in
            for (id, original) in moveBefore {
                if let index = document.bodyIndex(of: id) {
                    var transform = original
                    transform.translation += worldDelta
                    document.bodies[index].transform = transform
                }
            }
        }
    }

    /// Ring drag: rotate about the ring axis through each body's own pivot
    /// (quaternion delta pre-multiplied; translation unchanged). Snaps in
    /// 5° increments while dragging (spec §5.3).
    func updateRotation(part: GizmoPart, deltaRadians: Float) {
        guard part.isRing else { return }
        // Drags snap to 5° (spec §5.3); a TYPED angle goes through
        // `applyRotation` directly and is honoured exactly.
        let degrees = (Double(deltaRadians) * 180 / .pi / 5).rounded() * 5
        rotationOrbit?.degrees = degrees
        applyRotation(part: part, degrees: degrees)
    }

    /// Rotate the captured selection by an exact angle about `part`'s axis.
    private func applyRotation(part: GizmoPart, degrees: Double) {
        guard part.isRing else { return }
        if let move = modelSketchMove {
            let axis = part.axisDirection
            let q = simd_quatd(angle: degrees * .pi / 180,
                               axis: SIMD3(Double(axis.x), Double(axis.y), Double(axis.z)))
            previewModelSketchMotion(
                ModelSketchMotion(rotation: q, pivot: move.pivot), title: "Rotate")
            return
        }
        guard let moveBefore else { return }
        let axis = part.axisDirection
        let q = simd_quatd(
            angle: degrees * .pi / 180,
            axis: SIMD3(Double(axis.x), Double(axis.y), Double(axis.z))
        )
        // The body spins about the gizmo: the centre of its bounding box, or
        // wherever the pivot was dropped (a corner, say). Captured when the
        // move began (`moveRotationPivot`), so the centre does not creep as
        // the box of a turning asymmetric body shifts frame to frame.
        let pivot: SIMD3<Double>? = moveRotationPivot ?? gizmoOrigin.map {
            SIMD3(Double($0.x), Double($0.y), Double($0.z))
        }
        session.preview { document in
            for (id, original) in moveBefore {
                if let index = document.bodyIndex(of: id) {
                    var transform = original
                    transform.rotation = simd_normalize(q * original.rotation)
                    if let pivot {
                        transform.translation = pivot + q.act(original.translation - pivot)
                    }
                    document.bodies[index].transform = transform
                }
            }
        }
    }

    /// Commit a transform tool's result. A body the feature graph produced
    /// gets a `.transform` node (delta = after ∘ before⁻¹), appended and
    /// rebuilt in ONE undo step, so the move survives every later rebuild —
    /// the graph owns the placement now; `RebuildPlanner` deliberately resets
    /// document-level transforms (they used to vanish on the next parameter
    /// edit). A body with no producing feature (an import) keeps the direct
    /// `TransformBodiesCommand`; scale rides in the node too. The live preview
    /// mutated `transform` outside the undo stack; for the node path it is put
    /// back first, so the rebuild's snapshot of "before" is the true before
    /// and undo lands the body where it started.
    private func commitTransforms(title: String,
                                  before: [BodyID: Transform3D],
                                  after: [BodyID: Transform3D]) {
        var nodes: [FeatureNode] = []
        var directBefore: [BodyID: Transform3D] = [:]
        var directAfter: [BodyID: Transform3D] = [:]
        for (id, new) in after {
            guard let old = before[id], old != new else { continue }
            let producer = session.document.features.nodes.last { $0.outputBodyIDs.contains(id) }
            if let producer, new.scale > 1e-12, old.scale > 1e-12 {
                session.preview { document in
                    if let index = document.bodyIndex(of: id) {
                        document.bodies[index].transform = old
                    }
                }
                nodes.append(FeatureNode(
                    name: title,
                    kind: .transform(body: BodyRef(producer: producer.id, bodyID: id),
                                     delta: Transform3D.delta(from: old, to: new)),
                    outputBodyIDs: [BodyID()]))
            } else {
                directBefore[id] = old
                directAfter[id] = new
            }
        }
        if !directAfter.isEmpty {
            session.perform(TransformBodiesCommand(title: title, before: directBefore, after: directAfter))
        }
        if !nodes.isEmpty {
            session.recordAndRebuild(nodes, title: title)
        }
    }

    func endMove() {
        moveDragDelta = nil
        endRotationOrbit()
        if modelSketchMove != nil {
            endModelSketchMove()
            return
        }
        if imageInteractionBaseline != nil {
            endImageInteraction()
            return
        }
        if faceMoveSession != nil {
            commitFaceMove(worldDelta: faceMoveLastDelta)
            return
        }
        guard let before = moveBefore else { return }
        moveBefore = nil
        moveRotationPivot = nil
        var after = [BodyID: Transform3D]()
        var changed = false
        for (id, original) in before {
            if let body = session.document.body(with: id) {
                after[id] = body.transform
                if body.transform != original { changed = true }
            }
        }
        guard changed else { return }
        commitTransforms(title: "Move", before: before, after: after)
    }

    // MARK: - Rotation orbit + exact angle (spec §5.3)

    /// The dashed circle Shapr3D draws around the body while you rotate, plus
    /// the solid arc of how far it has swung. Live during a ring drag, and
    /// also up while an exact angle is being typed.
    struct RotationOrbit: Equatable {
        /// Which ring — its axis is the rotation axis and its basis the plane
        /// the circle is drawn in.
        var part: GizmoPart
        /// Where the drag was grabbed, radians in the ring's basis. The arc is
        /// swept from here, so it starts under the finger.
        var startAngle: Double
        /// Signed degrees swept so far.
        var degrees: Double
        /// True while the angle field is open instead of a drag being in flight.
        var isEditing: Bool
    }

    private(set) var rotationOrbit: RotationOrbit?

    /// Ring tapped (not dragged) → type an exact angle, the rotate twin of
    /// `axisEntryPart`.
    private(set) var angleEntryPart: GizmoPart?

    /// World radius of the orbit circle: outside the selection, so the circle
    /// rings the BODY rather than cutting through it (Shapr3D draws it that
    /// way). Falls back to the gizmo's own size when nothing has bounds.
    var rotationOrbitRadius: Double {
        guard let origin = gizmoOrigin else { return 0 }
        let pivot = SIMD3<Double>(Double(origin.x), Double(origin.y), Double(origin.z))
        var radius: Double = 0
        for id in selection {
            guard let body = session.document.body(with: id) else { continue }
            let bounds = Self.worldBounds(of: body)
            for i in 0..<8 {
                let corner = SIMD3<Double>(
                    (i & 1) == 0 ? bounds.min.x : bounds.max.x,
                    (i & 2) == 0 ? bounds.min.y : bounds.max.y,
                    (i & 4) == 0 ? bounds.min.z : bounds.max.z)
                radius = max(radius, simd_length(corner - pivot))
            }
        }
        for (sketch, ids) in modelSketchSelection {
            for entity in sketch.entities where ids.contains(entity.id) {
                for (_, point) in SketchHitTester.controlPoints(of: entity) {
                    radius = max(radius, simd_length(sketch.plane.toWorld(point) - pivot))
                }
            }
        }
        let gizmoWorld = Double(cameraControl?.gizmoWorldScale(at: origin) ?? 1)
        return max(radius * 1.08, gizmoWorld * 1.35)
    }

    /// A ring drag started: put the orbit up, anchored where it was grabbed.
    func beginRingRotation(part: GizmoPart, startAngle: Double) {
        guard part.isRing else { return }
        angleEntryPart = nil
        rotationOrbit = RotationOrbit(part: part, startAngle: startAngle,
                                      degrees: 0, isEditing: false)
    }

    /// The face-rotate path drives its own angle (unsnapped radians) — keep the
    /// orbit in step with it.
    func setRotationOrbitAngle(radians: Double) {
        rotationOrbit?.degrees = radians * 180 / .pi
    }

    func endRotationOrbit() {
        guard rotationOrbit?.isEditing != true else { return }
        rotationOrbit = nil
    }

    func beginAngleEntry(_ part: GizmoPart) {
        guard part.isRing, gizmoOrigin != nil else { return }
        axisEntryPart = nil
        scaleEntryActive = false
        angleEntryPart = part
        rotationOrbit = RotationOrbit(part: part, startAngle: 0, degrees: 0, isEditing: true)
    }

    func cancelAngleEntry() {
        angleEntryPart = nil
        rotationOrbit = nil
    }

    /// Rotate by exactly `degrees` about the tapped ring's axis. No 5° snap —
    /// a typed angle is meant literally.
    func commitAngleRotate(degrees: Double) {
        guard let part = angleEntryPart else { return }
        angleEntryPart = nil
        rotationOrbit = nil
        guard abs(degrees) > 1e-9 else { return }
        let a = part.axisDirection
        let axis = SIMD3<Double>(Double(a.x), Double(a.y), Double(a.z))
        // Rotate tool armed on a FACE: spin the face, deforming the solid.
        if faceRotateActive {
            guard beginFaceRotate() else { return }
            updateFaceRotate(angle: degrees * .pi / 180, axis: axis)
            endFaceRotate()
            return
        }
        beginMove()                       // captures the pre-rotation transforms
        applyRotation(part: part, degrees: degrees)
        endMove()                         // one undoable TransformBodies step
    }

    /// The pill riding the orbit: the live swept angle, or an empty editable
    /// field once a ring has been tapped.
    struct RotationAngleLabel: Equatable {
        var part: GizmoPart
        var text: String
        var isEditable: Bool
    }

    var rotationAngleLabel: RotationAngleLabel? {
        guard let orbit = rotationOrbit else { return nil }
        if orbit.isEditing {
            return RotationAngleLabel(part: orbit.part, text: "", isEditable: true)
        }
        let rounded = (orbit.degrees * 10).rounded() / 10
        let text = rounded == rounded.rounded()
            ? String(format: "%.0f°", rounded)
            : String(format: "%.1f°", rounded)
        return RotationAngleLabel(part: orbit.part, text: text, isEditable: false)
    }

    /// Commit a typed angle (supports "45/2" like the other inline fields).
    func commitRotationAngle(_ text: String) {
        guard let typed = ExpressionEvaluator.evaluate(text) else {
            cancelAngleEntry()
            return
        }
        commitAngleRotate(degrees: typed)
    }

    // MARK: - Gizmo numeric entry (tap an arrow → exact axis distance)

    /// Arrow awaiting a typed distance (set by tapping, not dragging, a
    /// gizmo arrow; shows the distance field in NumericInputBar).
    var axisEntryPart: GizmoPart?

    func beginAxisDistanceEntry(_ part: GizmoPart) {
        guard part.isArrow, gizmoOrigin != nil else { return }
        scaleEntryActive = false
        axisEntryPart = part
    }

    func cancelAxisDistanceEntry() {
        axisEntryPart = nil
    }

    /// The value pill riding the move gizmo (Shapr3D §5.1): the live distance
    /// while a handle is dragged, or an empty editable field once an arrow has
    /// been TAPPED, so a move can be typed exactly instead of dragged.
    struct MoveDistanceLabel: Equatable {
        var part: GizmoPart
        var text: String
        /// True = show the text field (an arrow was tapped); false = a live
        /// read-out of the drag in flight.
        var isEditable: Bool
    }

    var moveDistanceLabel: MoveDistanceLabel? {
        guard gizmoOrigin != nil else { return nil }
        if let part = axisEntryPart {
            return MoveDistanceLabel(part: part, text: "", isEditable: true)
        }
        guard let delta = moveDragDelta, let part = gizmoHighlight, !part.isRing else {
            return nil
        }
        let d = SIMD3<Double>(Double(delta.x), Double(delta.y), Double(delta.z))
        let a = part.axisDirection
        // An arrow reads its own axis component (signed travel); a plane tile
        // reads how far the body slid in that plane.
        let distance = part.isArrow
            ? simd_dot(d, SIMD3<Double>(Double(a.x), Double(a.y), Double(a.z)))
            : simd_length(d)
        return MoveDistanceLabel(
            part: part,
            text: CADPreferences.shared.unit.compactLengthString(fromMM: abs(distance)),
            isEditable: false)
    }

    /// Commit a distance typed into the pill (supports "25.4/2" like the other
    /// inline fields); the value is in the display unit.
    func commitMoveDistance(_ text: String) {
        guard let typed = ExpressionEvaluator.evaluate(text) else {
            cancelAxisDistanceEntry()
            return
        }
        commitAxisMove(distance: CADPreferences.shared.unit.mm(fromDisplay: typed))
    }

    /// Move the selection by exactly `distance` along the tapped arrow's axis.
    func commitAxisMove(distance: Double) {
        guard let part = axisEntryPart else { return }
        axisEntryPart = nil
        guard abs(distance) > 1e-9 else { return }
        let a = part.axisDirection
        let axis = SIMD3(Double(a.x), Double(a.y), Double(a.z))
        // Selected image (plan §B10): exact in-plane move along the axis.
        // The Copy badge applies to a typed move as it does to a drag
        // (iPad, 2026-09-14): duplicate first, then move the duplicate.
        if selectedImage != nil, copyOnDrag {
            copyOnDrag = false
            duplicateSelectedImageForDrag()
        }
        if let image = selectedImage {
            let plane = image.plane
            let delta = axis * distance
            var after = image
            after.plane.origin = plane.origin
                + plane.xAxis * simd_dot(delta, plane.xAxis)
                + plane.yAxis * simd_dot(delta, plane.yAxis)
            commitImageEdit(after, title: "Move Image")
            return
        }
        // Selected face: move the face by exactly `distance` along the axis,
        // deforming the solid (the typed-distance twin of the gizmo drag).
        if case .faceSelected = mode {
            copyOnDrag = false // Copy is a whole-body affordance (as for drags).
            guard beginFaceMove() else { return }
            let delta = SIMD3<Float>(
                Float(axis.x * distance), Float(axis.y * distance), Float(axis.z * distance))
            commitFaceMove(worldDelta: delta)
            return
        }
        // Sketch entities selected in model mode (QA-24): the typed distance
        // moves them along the arrow, the way the native probe did.
        if selection.isEmpty, let origin = gizmoOrigin {
            let targets = modelSketchSelection
            guard !targets.isEmpty else { return }
            copyOnDrag = false // whole-body affordance, as for drags
            let pivot = SIMD3(Double(origin.x), Double(origin.y), Double(origin.z))
            switch transformedModelSketches(
                ModelSketchMotion(translation: axis * distance, pivot: pivot), baselines: targets) {
            case let .sketches(updated, added):
                commitModelSketchTransform(updated: updated, added: added, baselines: targets, title: "Move")
            case .refused(let reason):
                modelSketchSplitIdentities.removeAll()
                showNotice(reason)
            }
            return
        }
        // Copy badge on: the typed distance moves a duplicate, exactly as
        // a drag would (beginMove) — the original stays put. The badge
        // resets, and the selection is the copy from here on.
        if copyOnDrag {
            copyOnDrag = false
            duplicateSelectionForDrag()
        }
        var before = [BodyID: Transform3D]()
        var after = [BodyID: Transform3D]()
        for id in selection {
            guard let body = session.document.body(with: id) else { continue }
            before[id] = body.transform
            var transform = body.transform
            transform.translation += axis * distance
            after[id] = transform
        }
        guard !after.isEmpty else { return }
        commitTransforms(title: "Move", before: before, after: after)
        session.save()
    }

    // MARK: - Model-mode sketch Move/Rotate (QA-24)
    //
    // Shapr3D offers its Move/Rotate gizmo for sketch edges selected in model
    // mode. Observed 2026-09-13 on sketch24 (six edges, all of the sketch):
    // a distance typed on the up arrow moved the edges along it, the sketch
    // kept its identity and selection, History gained no step, an offset
    // plane built downstream re-evaluated (and failed), and Undo restored
    // everything. This is that path: a whole sketch moves as a rigid frame
    // (plane origin/axes; local geometry, constraints and dimensions are
    // untouched) and dependents rebuild in the same undo step. A subset of a
    // sketch moves within its plane through the constraint solver; taking a
    // subset off its plane is refused — native's behaviour for that case has
    // not been observed, and guessing at a sketch split would be worse than
    // saying so.

    /// Sketch entities selected while idle in model mode, by owning sketch.
    private var modelSketchSelection: [(sketch: Sketch, ids: Set<UUID>)] {
        guard mode == .idle, selection.isEmpty, selectedImage == nil,
              !selectedSketchEntityIDs.isEmpty else { return [] }
        return session.document.sketches.compactMap { sketch in
            let ids = Set(sketch.entities.map(\.id)).intersection(selectedSketchEntityIDs)
            return ids.isEmpty ? nil : (sketch, ids)
        }
    }

    /// True when the Move/Rotate gizmo is up for sketch entities in model mode.
    var hasModelSketchSelection: Bool { !modelSketchSelection.isEmpty }

    /// Where the gizmo attaches: the mean of the selected entities' anchors
    /// (line midpoint, rect centre, the centre of the circular kinds, the
    /// mean of a spline's points), in world.
    var modelSketchSelectionCentroid: SIMD3<Double>? {
        var sum = SIMD3<Double>.zero
        var count = 0
        for (sketch, ids) in modelSketchSelection {
            for entity in sketch.entities where ids.contains(entity.id) {
                sum += sketch.plane.toWorld(Self.entityAnchor(entity))
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : nil
    }

    private static func entityAnchor(_ entity: SketchEntity) -> SIMD2<Double> {
        switch entity {
        case let .line(_, a, b): return (a + b) / 2
        case let .rect(_, lo, hi): return (lo + hi) / 2
        case let .circle(_, c, _), let .arc(_, c, _, _, _),
             let .ellipse(_, c, _, _, _), let .polygon(_, c, _, _, _): return c
        case let .spline(_, points, _):
            guard !points.isEmpty else { return .zero }
            return points.reduce(SIMD2<Double>.zero, +) / Double(points.count)
        }
    }

    /// A rigid motion in world: rotate about `pivot`, then translate.
    private struct ModelSketchMotion {
        var translation: SIMD3<Double> = .zero
        var rotation = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        var pivot: SIMD3<Double>

        func apply(_ p: SIMD3<Double>) -> SIMD3<Double> {
            pivot + rotation.act(p - pivot) + translation
        }
        func applyDirection(_ d: SIMD3<Double>) -> SIMD3<Double> { rotation.act(d) }
    }

    private enum ModelSketchTransformOutcome {
        /// `updated`: sketches whose frame or entities changed, by id.
        /// `added`: sketches split off for a subset taken off its plane —
        /// Shapr3D makes a new sketch for it (observed 2026-09-13: one edge
        /// of sketch24 moved along the normal became "Sketch 14").
        case sketches(updated: [SketchID: Sketch], added: [Sketch])
        case refused(String)
    }

    private func transformedModelSketches(
        _ motion: ModelSketchMotion, baselines: [(sketch: Sketch, ids: Set<UUID>)]
    ) -> ModelSketchTransformOutcome {
        var result: [SketchID: Sketch] = [:]
        var added: [Sketch] = []
        for (sketch, ids) in baselines {
            let plane = sketch.plane
            if ids.count == sketch.entities.count {
                // The whole sketch: move its frame. Local geometry, constraints
                // and dimensions are exactly what they were, somewhere else.
                var moved = sketch
                moved.plane = SketchPlane(origin: motion.apply(plane.origin),
                                          xAxis: motion.applyDirection(plane.xAxis),
                                          yAxis: motion.applyDirection(plane.yAxis))
                result[sketch.id] = moved
                continue
            }
            // A subset taken off its plane (tilted, or moved along the
            // normal) becomes a new sketch on the moved frame, as native does;
            // its constraints and dimensions that stay within the subset
            // travel with it, the rest are dropped with the entities.
            let normal = simd_normalize(plane.normal)
            let tilts = abs(simd_dot(motion.applyDirection(normal), normal)) < 1 - 1e-9
            let leaves = abs(simd_dot(motion.apply(plane.origin) - plane.origin, normal)) > 1e-9
            if tilts || leaves {
                let moved = sketch.entities.filter { ids.contains($0.id) }
                let inside: (ConstraintRef) -> Bool = { ids.contains($0.entityID) }
                let split = Sketch(
                    id: splitSketchID(for: sketch.id),
                    name: splitSketchName(for: sketch.id),
                    plane: SketchPlane(origin: motion.apply(plane.origin),
                                       xAxis: motion.applyDirection(plane.xAxis),
                                       yAxis: motion.applyDirection(plane.yAxis)),
                    entities: moved,
                    constructionEntityIDs: sketch.constructionEntityIDs.intersection(ids),
                    constraints: sketch.constraints.filter { $0.refs.allSatisfy(inside) },
                    dimensions: sketch.dimensions.filter { $0.refs.allSatisfy(inside) },
                    lineDimensionKinds: sketch.lineDimensionKinds.filter { ids.contains($0.key) })
                var remainder = sketch
                RemoveSketchEntitiesCommand(ids: ids, sketch: sketch).apply(toSketch: &remainder)
                result[sketch.id] = remainder
                added.append(split)
                continue
            }
            let xImage = motion.applyDirection(plane.xAxis)
            let angle = atan2(simd_dot(simd_cross(plane.xAxis, xImage), normal),
                              simd_dot(plane.xAxis, xImage))
            let localPivot = plane.toLocal(motion.pivot)
            let localShift = SIMD2(simd_dot(motion.translation, plane.xAxis),
                                   simd_dot(motion.translation, plane.yAxis))
            let originals = sketch.entities.filter { ids.contains($0.id) }
            var targets = abs(angle) > 1e-12
                ? SketchTransform.rotate(entities: originals, about: localPivot, angle: angle)
                : originals
            guard targets.count == originals.count else {
                return .refused("Rotate a rectangle inside its sketch")
            }
            targets = SketchTransform.translate(entities: targets, by: localShift)
            var moved = sketch
            let solvable = originals.allSatisfy {
                switch $0 { case .line, .circle, .arc: return true; default: return false }
            }
            if solvable {
                guard let solved = SketchSolverBridge.solvePointTransform(sketch, targets: targets),
                      solved != sketch.entities || targets == originals else {
                    return .refused("Locked or constrained sketch parts can't be moved.")
                }
                moved.entities = solved
            } else {
                var byID = [UUID: SketchEntity]()
                for entity in targets { byID[entity.id] = entity }
                moved.entities = sketch.entities.map { byID[$0.id] ?? $0 }
            }
            result[sketch.id] = moved
        }
        return .sketches(updated: result, added: added)
    }

    /// A split-off sketch keeps one identity and name for the whole drag, so
    /// the live preview and the committed result are the same sketch.
    private var modelSketchSplitIdentities: [SketchID: (id: SketchID, name: String)] = [:]

    private func splitSketchID(for source: SketchID) -> SketchID {
        if let existing = modelSketchSplitIdentities[source] { return existing.id }
        let identity = (id: SketchID(), name: session.document.uniqueSketchName())
        modelSketchSplitIdentities[source] = identity
        return identity.id
    }

    private func splitSketchName(for source: SketchID) -> String {
        _ = splitSketchID(for: source)
        return modelSketchSplitIdentities[source]!.name
    }

    /// One undo step — the sketch change plus the rebuild of whatever depends
    /// on it (what the native probe showed: dependents re-evaluate).
    private func commitModelSketchTransform(
        updated sketches: [SketchID: Sketch], added: [Sketch],
        baselines: [(sketch: Sketch, ids: Set<UUID>)], title: String
    ) {
        var commands: [DocumentCommand] = []
        var ids = Set<SketchID>()
        for (sketch, selected) in baselines {
            guard let after = sketches[sketch.id], after != sketch else { continue }
            if after.entities.count < sketch.entities.count {
                // The subset left for a new sketch (appended below).
                commands.append(RemoveSketchEntitiesCommand(ids: selected, sketch: sketch))
            } else {
                if after.plane != sketch.plane {
                    commands.append(ChangeSketchPlaneCommand(
                        sketchID: sketch.id, before: sketch.plane, after: after.plane))
                }
                if after.entities != sketch.entities {
                    commands.append(UpdateSketchEntitiesCommand(
                        sketchID: sketch.id, before: sketch.entities, after: after.entities))
                }
            }
            ids.insert(sketch.id)
        }
        for sketch in added {
            commands.append(AddSketchCommand(sketch: sketch, title: title))
        }
        modelSketchSplitIdentities.removeAll()
        guard !commands.isEmpty else { return }
        session.performWithSketchRebuild(
            CompositeCommand(title: title, commands: commands), sketchIDs: ids)
        session.save()
    }

    private struct ModelSketchMove {
        var baselines: [(sketch: Sketch, ids: Set<UUID>)]
        var pivot: SIMD3<Double>
        var result: (updated: [SketchID: Sketch], added: [Sketch])?
        var title = "Move"
        var noticeShown = false
    }
    private var modelSketchMove: ModelSketchMove?

    private func beginModelSketchMove() -> Bool {
        let targets = modelSketchSelection
        guard !targets.isEmpty, let origin = gizmoOrigin else { return false }
        modelSketchMove = ModelSketchMove(
            baselines: targets,
            pivot: SIMD3(Double(origin.x), Double(origin.y), Double(origin.z)))
        return true
    }

    private func restoreModelSketchBaselines(_ baselines: [(sketch: Sketch, ids: Set<UUID>)]) {
        let previewIDs = Set(modelSketchSplitIdentities.values.map(\.id))
        session.preview { document in
            document.sketches.removeAll { previewIDs.contains($0.id) }
            for (sketch, _) in baselines {
                if let index = document.sketches.firstIndex(where: { $0.id == sketch.id }) {
                    document.sketches[index] = sketch
                }
            }
        }
    }

    /// Live drag preview, outside the undo stack like the body gizmo's.
    private func previewModelSketchMotion(_ motion: ModelSketchMotion, title: String) {
        guard var move = modelSketchMove else { return }
        move.title = title
        switch transformedModelSketches(motion, baselines: move.baselines) {
        case let .sketches(updated, added):
            move.result = (updated, added)
            // A split previewed earlier in the drag goes away once the
            // motion is back in the plane.
            let addedIDs = Set(added.map(\.id))
            let stale = Set(modelSketchSplitIdentities.values.map(\.id)).subtracting(addedIDs)
            session.preview { document in
                document.sketches.removeAll { stale.contains($0.id) }
                for (id, sketch) in updated {
                    if let index = document.sketches.firstIndex(where: { $0.id == id }) {
                        document.sketches[index] = sketch
                    }
                }
                for sketch in added {
                    if let index = document.sketches.firstIndex(where: { $0.id == sketch.id }) {
                        document.sketches[index] = sketch
                    } else {
                        document.sketches.append(sketch)
                    }
                }
            }
        case .refused(let reason):
            if !move.noticeShown {
                showNotice(reason)
                move.noticeShown = true
            }
            if move.result != nil {
                restoreModelSketchBaselines(move.baselines)
                move.result = nil
            }
        }
        modelSketchMove = move
    }

    private func endModelSketchMove() {
        guard let move = modelSketchMove else { return }
        modelSketchMove = nil
        // The preview mutated the sketches in place; put the baselines back
        // so the command's before/after are the truth and undo lands home.
        restoreModelSketchBaselines(move.baselines)
        guard let result = move.result else {
            modelSketchSplitIdentities.removeAll()
            return
        }
        commitModelSketchTransform(updated: result.updated, added: result.added,
                                   baselines: move.baselines, title: move.title)
    }

    // MARK: - Scale (uniform, about the body pivot — spec §5.4 v1)

    /// True while the palette's Scale tool shows its factor field.
    var scaleEntryActive = false

    /// Factor typed in the scale bar; an empty-grid tap commits it
    /// (spec §5.4 "commit by tapping empty grid").
    var scalePendingFactor: Double = 1

    /// Copy badge on the scale bar (spec §5.4): committing scales a
    /// duplicate, keeping the original.
    var scaleCopyOnCommit = false

    func beginScaleEntry() {
        guard !selection.isEmpty else { return }
        cancelTransientPicks()
        axisEntryPart = nil
        scalePendingFactor = 1
        scaleCopyOnCommit = false
        scaleEntryActive = true
    }

    func cancelScaleEntry() {
        scaleEntryActive = false
        scaleCopyOnCommit = false
    }

    /// Multiply each selected body's uniform scale by `factor`. Transform3D
    /// scales about the translation point, so this is scale-about-pivot.
    /// With the Copy badge on, scaled duplicates are added instead.
    func commitScale(factor: Double) {
        scaleEntryActive = false
        let copy = scaleCopyOnCommit
        scaleCopyOnCommit = false
        guard factor > 0.001 else {
            errorMessage = "Scale factor must be greater than 0.001."
            return
        }
        if copy {
            commitScaleCopy(factor: factor)
            return
        }
        guard abs(factor - 1) > 1e-9 else { return }
        var before = [BodyID: Transform3D]()
        var after = [BodyID: Transform3D]()
        for id in selection {
            guard let body = session.document.body(with: id) else { continue }
            before[id] = body.transform
            var transform = body.transform
            transform.scale *= factor
            after[id] = transform
        }
        guard !after.isEmpty else { return }
        commitTransforms(title: "Scale", before: before, after: after)
        session.save()
    }

    /// Copy badge: add scaled duplicates in one undo step (originals keep
    /// their size); the copies become the selection.
    private func commitScaleCopy(factor: Double) {
        var document = session.document // local: unique names + revisions
        var commands: [DocumentCommand] = []
        var ids: Set<BodyID> = []
        for id in selection {
            guard let body = session.document.body(with: id) else { continue }
            var transform = body.transform
            transform.scale *= factor
            var clone = Body(
                id: BodyID(),
                name: document.uniqueBodyName(base: body.name),
                transform: transform,
                primitive: body.primitive,
                render: body.render,
                revision: document.nextRevision()
            )
            clone.euclid = body.euclid
            document.bodies.append(clone) // keeps the next name unique
            commands.append(AddBodyCommand(body: clone, title: "Scale Copy"))
            ids.insert(clone.id)
        }
        guard !commands.isEmpty else { return }
        session.perform(commands.count == 1
            ? commands[0]
            : CompositeCommand(title: "Scale Copy", commands: commands))
        selection = ids
        if ids.count == 1, let id = ids.first {
            mode = .selected(id)
        }
        session.save()
    }

    // MARK: - Rotate Around Axis (plan §B6, spec §5.3)

    struct RotateAxisState {
        /// World axis line; nil until picked (sketch line or world-axis
        /// button).
        var axisPoint: SIMD3<Double>?
        var axisDirection: SIMD3<Double>?
        var angleDegrees: Double = 0
        /// Transforms when the tool opened (preview baseline + undo `before`).
        var before: [BodyID: Transform3D]

        var hasAxis: Bool { axisPoint != nil && axisDirection != nil }
    }

    var rotateAxisState: RotateAxisState?
    /// Angle when the current scrub drag began (5°-snapped drags, spec §5.3).
    private var rotateDragStartDegrees: Double = 0

    func beginRotateAxisPick() {
        guard !selection.isEmpty else { return }
        cancelTransientPicks()
        cancelTool()
        axisEntryPart = nil
        scaleEntryActive = false
        var before = [BodyID: Transform3D]()
        for id in selection {
            if let body = session.document.body(with: id) {
                before[id] = body.transform
            }
        }
        guard !before.isEmpty else { return }
        rotateAxisState = RotateAxisState(before: before)
        mode = .rotatingAroundAxis
    }

    func cancelRotateAxis() {
        if let state = rotateAxisState {
            session.preview { document in
                for (id, original) in state.before {
                    if let index = document.bodyIndex(of: id) {
                        document.bodies[index].transform = original
                    }
                }
            }
        }
        rotateAxisState = nil
        if case .rotatingAroundAxis = mode {
            mode = .idle
        }
    }

    /// World-axis button in the pill: the axis runs through the origin.
    func setRotateWorldAxis(_ axis: PatternState.Axis) {
        guard var state = rotateAxisState else { return }
        state.axisPoint = .zero
        state.axisDirection = axis.direction
        rotateAxisState = state
        applyRotateAxisPreview()
    }

    func setRotateAngle(_ degrees: Double) {
        guard var state = rotateAxisState, state.hasAxis else { return }
        state.angleDegrees = degrees
        rotateAxisState = state
        applyRotateAxisPreview()
    }

    private func applyRotateAxisPreview() {
        guard let state = rotateAxisState,
              let point = state.axisPoint,
              let direction = state.axisDirection
        else { return }
        let radians: Double = state.angleDegrees * Double.pi / 180
        session.preview { document in
            for (id, original) in state.before {
                if let index = document.bodyIndex(of: id) {
                    document.bodies[index].transform = original.rotated(
                        byRadians: radians, aboutAxisThrough: point, direction: direction
                    )
                }
            }
        }
    }

    /// Drag while the axis is set scrubs the angle in 5° steps.
    func beginRotateAxisDrag() -> Bool {
        guard let state = rotateAxisState, state.hasAxis else { return false }
        rotateDragStartDegrees = state.angleDegrees
        return true
    }

    func updateRotateAxisDrag(screenDeltaWorld: Double) {
        guard rotateAxisState?.hasAxis == true else { return }
        let raw = rotateDragStartDegrees + screenDeltaWorld * Self.revolveDegreesPerWorldUnit
        setRotateAngle((raw / 5).rounded() * 5)
    }

    func commitRotateAxis() {
        guard let state = rotateAxisState,
              let point = state.axisPoint,
              let direction = state.axisDirection,
              abs(state.angleDegrees) > 1e-9
        else {
            cancelRotateAxis()
            return
        }
        let radians: Double = state.angleDegrees * Double.pi / 180
        var after = [BodyID: Transform3D]()
        for (id, original) in state.before {
            after[id] = original.rotated(
                byRadians: radians, aboutAxisThrough: point, direction: direction
            )
        }
        rotateAxisState = nil
        commitTransforms(title: "Rotate", before: state.before, after: after)
        mode = .idle
        session.save()
    }

    /// Tap while rotating: with no axis yet, a sketch LINE sets it; with the
    /// axis set, tapping empty space commits (the shared grid convention).
    private func handleRotateAxisTap(ray: Ray) {
        guard let state = rotateAxisState else {
            mode = .idle
            return
        }
        if state.hasAxis {
            commitRotateAxis()
            return
        }
        guard let hit = nearestSketchLine(to: ray) else { return }
        let a = hit.plane.toWorld(hit.a)
        let direction = hit.plane.toWorld(hit.b) - a
        guard simd_length(direction) > 1e-9 else { return }
        var updated = state
        updated.axisPoint = a
        updated.axisDirection = simd_normalize(direction)
        rotateAxisState = updated
    }

    /// Nearest LINE entity under the ray across visible sketches.
    private func nearestSketchLine(
        to ray: Ray
    ) -> (a: SIMD2<Double>, b: SIMD2<Double>, plane: SketchPlane)? {
        let tolerance = SketchHitTester.screenPickTolerance(worldUnitsPerPoint: worldPerPoint)
        var best: (a: SIMD2<Double>, b: SIMD2<Double>, plane: SketchPlane, distance: Double)?
        for sketch in session.document.sketches where !sketch.isHidden {
            guard let local = localPoint(of: ray, on: sketch.plane) else { continue }
            for entity in sketch.entities {
                guard case .line(_, let a, let b) = entity else { continue }
                let d = Self.distanceToSegment(local, a: a, b: b)
                if d <= tolerance, best == nil || d < best!.distance {
                    best = (a, b, sketch.plane, d)
                }
            }
        }
        return best.map { ($0.a, $0.b, $0.plane) }
    }

    // MARK: - Translate (spec §5.2) & Align (spec §5.5 v1)

    /// Source point picked so far for Translate/Align (marker + pill state).
    var transformPickPoints: [SIMD3<Double>] = []
    /// Body that moves in an Align (owner of the first tapped snap point).
    private var alignSourceBody: BodyID?

    func beginTranslatePick() {
        guard !selection.isEmpty else { return }
        cancelTransientPicks()
        cancelTool()
        axisEntryPart = nil
        scaleEntryActive = false
        transformPickPoints = []
        mode = .translating
    }

    func cancelTranslate() {
        transformPickPoints = []
        if case .translating = mode {
            mode = .idle
        }
    }

    /// Transform-menu **Move**. On a selected FACE it arms the move gizmo that
    /// shears the solid (keeping the face context — a plain face selection shows
    /// only the extrude arrow until Move is chosen). On any other selection it
    /// falls back to the point-to-point Translate.
    func beginMoveTool() {
        // Sketch entities in model mode already show the Move/Rotate gizmo
        // (QA-24); the menu entry just makes sure nothing else is armed.
        if selection.isEmpty, hasModelSketchSelection {
            axisEntryPart = nil
            scaleEntryActive = false
            return
        }
        // A curved face has no plane to shear along. Say so rather than silently
        // falling through to the whole-BODY translate, which is a different edit
        // than the one the user asked for.
        if selectionIsCurvedFace {
            showNotice("Move needs a flat face — this one is curved")
            return
        }
        if case .faceSelected = mode {
            axisEntryPart = nil
            scaleEntryActive = false
            faceScaleActive = false
            faceRotateActive = false
            faceMoveActive = true
            return
        }
        beginTranslatePick()
    }

    func cancelMoveTool() {
        if faceMoveActive {
            faceMoveActive = false
            return
        }
        cancelTranslate()
    }

    /// True while the Move tool is armed (face-shear gizmo or body translate).
    var isMoveToolActive: Bool {
        if faceMoveActive { return true }
        if case .translating = mode { return true }
        return false
    }

    /// Transform-menu **Scale**. On a selected FACE it arms the scale gizmo that
    /// tapers the solid (scaling the face about its centre); on any other
    /// selection it falls back to the numeric scale-factor entry.
    func beginScaleTool() {
        if selectionIsCurvedFace {
            showNotice("Scale needs a flat face — this one is curved")
            return
        }
        if case .faceSelected = mode {
            axisEntryPart = nil
            scaleEntryActive = false
            faceMoveActive = false
            faceRotateActive = false
            faceScaleActive = true
            return
        }
        beginScaleEntry()
    }

    func cancelScaleTool() {
        if faceScaleActive {
            faceScaleActive = false
            return
        }
        cancelScaleEntry()
    }

    /// True while the Scale tool is armed (face-taper gizmo or body scale entry).
    var isScaleToolActive: Bool { faceScaleActive || scaleEntryActive }

    /// Transform-menu **Rotate**. On a selected FACE it arms the rotation rings
    /// so a ring drag rotates the face about its centre (tilt/twist the solid);
    /// on any other selection it falls back to the axis-pick body rotate.
    func beginRotateTool() {
        if selectionIsCurvedFace {
            showNotice("Rotate needs a flat face — this one is curved")
            return
        }
        if case .faceSelected = mode {
            axisEntryPart = nil
            scaleEntryActive = false
            faceMoveActive = false
            faceScaleActive = false
            faceRotateActive = true
            return
        }
        beginRotateAxisPick()
    }

    func cancelRotateTool() {
        if faceRotateActive {
            faceRotateActive = false
            return
        }
        cancelRotateAxis()
    }

    /// True while the Rotate tool is armed (face-rotate rings or body axis rotate).
    var isRotateToolActive: Bool {
        if faceRotateActive { return true }
        if case .rotatingAroundAxis = mode { return true }
        return false
    }

    func beginAlignPick() {
        guard session.document.bodies.count >= 2 else { return }
        cancelTransientPicks()
        cancelTool()
        axisEntryPart = nil
        scaleEntryActive = false
        transformPickPoints = []
        alignSourceBody = nil
        selection.removeAll()
        mode = .aligning
    }

    func cancelAlign() {
        transformPickPoints = []
        alignSourceBody = nil
        if case .aligning = mode {
            mode = .idle
        }
    }

    /// Cancel every transient pick/preview mode (rotate-around-axis preview,
    /// translate/align picks, pattern bar, split/boolean cutter picks). Each
    /// cancel is a no-op outside its own mode, so this is safe to call from
    /// any surface that takes over — palette tools, the Items panel, measure,
    /// sketching, import. Notably reverts the rotate preview, which mutates
    /// transforms outside the undo stack until committed.
    private func cancelTransientPicks() {
        cancelSymmetryAxisPick()
        cancelRotateAxis()
        cancelTranslate()
        cancelAlign()
        cancelPattern()
        cancelSplitCutterPick()
        cancelBooleanPicking()
        cancelFeatureBodyPick()
        cancelFeatureFacePick()
        cancelFeatureProfilePick()
        cancelSectionPlanePick()
        cancelImagePlanePick()
        resetBlendState()
        resetShellState()
        resetDeleteFaceState()
        resetReplaceFaceState()
        resetSketchOffsetState()
        resetAxisState()
        pendingCreateTool = nil
        // Numeric-entry armed state must die with the mode that armed it: a
        // stale `scaleEntryActive` would make the next empty-space tap commit
        // a stray scale from inside an unrelated pick (2026-08-25 review, S3).
        scaleEntryActive = false
        axisEntryPart = nil
    }

    /// Translate: first tap picks the source snap point, second the
    /// destination; the selection shifts by the exact delta.
    private func handleTranslateTap(ray: Ray) {
        guard let point = translateSnapPoint(to: ray) else { return }
        if transformPickPoints.isEmpty {
            transformPickPoints = [point]
            return
        }
        let delta = point - transformPickPoints[0]
        transformPickPoints = []
        guard simd_length(delta) > 1e-9 else {
            mode = .idle
            return
        }
        var before = [BodyID: Transform3D]()
        var after = [BodyID: Transform3D]()
        for id in selection {
            guard let body = session.document.body(with: id) else { continue }
            before[id] = body.transform
            var transform = body.transform
            transform.translation += delta
            after[id] = transform
        }
        guard !after.isEmpty else {
            mode = .idle
            return
        }
        commitTransforms(title: "Translate", before: before, after: after)
        if selection.count == 1, let id = selection.first {
            mode = .selected(id)
        } else {
            mode = .idle
        }
        session.save()
    }

    /// Snap for Translate picks: notable points (vertices, sketch points)
    /// first, then the ground-plane grid.
    private func translateSnapPoint(to ray: Ray) -> SIMD3<Double>? {
        if let notable = nearestNotablePoint(to: ray) { return notable }
        guard let t = ray.intersect(planePoint: .zero, planeNormal: SIMD3(0, 1, 0)) else {
            return nil
        }
        let world = ray.point(at: t)
        let g = SnapEngine.gridSpacing
        return SIMD3(
            (Double(world.x) / g).rounded() * g,
            0,
            (Double(world.z) / g).rounded() * g
        )
    }

    /// Align: tap a snap point on the body that moves, then the destination
    /// point on another body; the first body translates so they coincide.
    private func handleAlignTap(ray: Ray) {
        if alignSourceBody == nil {
            guard let hit = nearestBodyVertex(to: ray) else { return }
            alignSourceBody = hit.bodyID
            transformPickPoints = [hit.point]
            return
        }
        guard let source = alignSourceBody,
              let anchor = transformPickPoints.first,
              let body = session.document.body(with: source)
        else {
            cancelAlign()
            return
        }
        guard let hit = nearestBodyVertex(to: ray, excluding: source) else { return }
        transformPickPoints = []
        alignSourceBody = nil
        let delta = hit.point - anchor
        guard simd_length(delta) > 1e-9 else {
            mode = .idle
            return
        }
        var transform = body.transform
        transform.translation += delta
        commitTransforms(title: "Align", before: [source: body.transform], after: [source: transform])
        selection = [source]
        mode = .selected(source)
        session.save()
    }

    /// Nearest render vertex across visible bodies, with its owner
    /// (Align's purple snap points, v1).
    private func nearestBodyVertex(
        to ray: Ray, excluding: BodyID? = nil
    ) -> (point: SIMD3<Double>, bodyID: BodyID)? {
        let tolerance = max(0.5, 30 * worldPerPoint)
        var best: (point: SIMD3<Double>, bodyID: BodyID, distance: Double)?
        for body in session.document.bodies
        where !body.isHidden && body.id != excluding {
            for position in body.render.positions {
                let p = body.transform.applying(to: SIMD3<Double>(position))
                let pf = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
                let t = simd_dot(pf - ray.origin, ray.direction)
                guard t > 0 else { continue }
                let d = Double(simd_length(pf - ray.point(at: t)))
                if d <= tolerance, best == nil || d < best!.distance {
                    best = (p, body.id, d)
                }
            }
        }
        return best.map { ($0.point, $0.bodyID) }
    }

    // MARK: - Mirror (spec §5.6, Keep Original always on for v1)

    /// Mirror planes offered by the palette: world planes plus any
    /// construction planes in the document.
    var mirrorPlaneOptions: [(label: String, plane: SketchPlane)] {
        var options: [(label: String, plane: SketchPlane)] = [
            ("XY Plane", .worldXY),
            ("YZ Plane", .worldYZ),
            ("Ground (ZX)", .ground),
        ]
        for (index, plane) in session.document.planes.enumerated() {
            options.append(("Plane \(index + 1)", plane.plane))
        }
        return options
    }

    /// Mirror every selected body across `plane` into new bodies (one undo
    /// step for multi-selections, plan §B13).
    func mirrorSelection(across plane: SketchPlane) {
        cancelTransientPicks()
        guard !selection.isEmpty else { return }
        let n = simd_normalize(plane.normal)
        var document = session.document // local: unique names as we go
        var commands: [DocumentCommand] = []
        var ids: Set<BodyID> = []
        for id in selection {
            guard let body = session.document.body(with: id) else { continue }
            let world = body.euclidMesh().transformed(by: body.transform.euclid)
            let mirrored = KernelOps.mirror(mesh: world, across: plane)
            guard !mirrored.polygons.isEmpty else { continue }
            // Pivot of the copy: the original pivot reflected across the plane.
            let t = body.transform.translation
            let pivot = t - 2 * simd_dot(t - plane.origin, n) * n
            var transform = Transform3D.identity
            transform.translation = pivot
            let localMesh = mirrored.translated(by: Vector(-pivot.x, -pivot.y, -pivot.z))
            var copy = Body(
                name: document.uniqueBodyName(base: body.name),
                transform: transform,
                primitive: nil,
                euclidMesh: localMesh,
                revision: body.meshRevision
            )
            // Reflect the solid the same way the mesh was: bake the source's
            // transform in, mirror in world space, then bring it back into the
            // copy's own local space — the copy's placement is the reflected
            // pivot, so the brep must not carry that translation itself.
            if OCCTKernel.useOCCTAsSourceOfTruth, let sourceBrep = body.brep,
               let placed = OCCTKernel.transformed(sourceBrep, by: body.transform),
               let reflected = OCCTKernel.mirrored(placed, origin: plane.origin, normal: n) {
                var toLocal = Transform3D.identity
                toLocal.translation = -pivot
                copy.brep = OCCTKernel.transformed(reflected, by: toLocal)
            }
            document.bodies.append(copy) // keeps the next name unique
            commands.append(AddBodyCommand(body: copy, title: "Mirror"))
            // Phase D: record a `.mirror` history node for a feature-owned source
            // so the reflected copy rebuilds associatively. Bundled into the same
            // command list (one CompositeCommand) so a single undo drops the copy
            // and its node together. Non-feature sources (import/seed) can't be
            // replayed, so they're mirrored geometry-only.
            if let owner = featureNode(owning: id) {
                let mirrorNode = FeatureNode(
                    name: "Mirror",
                    kind: .mirror(
                        body: BodyRef(producer: owner.id, bodyID: id),
                        plane: PlaneRef(source: .explicit(plane)),
                        keepOriginal: true
                    ),
                    outputBodyIDs: [copy.id]
                )
                commands.append(AppendFeatureCommand(node: mirrorNode))
            }
            ids.insert(copy.id)
        }
        guard !commands.isEmpty else {
            errorMessage = "Mirror produced no geometry."
            return
        }
        session.perform(commands.count == 1
            ? commands[0]
            : CompositeCommand(title: "Mirror", commands: commands))
        selection = ids
        updateModeForSelection()
        session.save()
    }

    // MARK: - Split Body (plan §B3, spec §4.9 v1: one plane or profile cutter)

    /// "Split" in the palette: the next tap picks the cutter — a world or
    /// construction plane tile, or a sketch profile fill.
    func beginSplitCutterPick() {
        guard selection.count == 1, let target = selection.first,
              session.document.body(with: target) != nil
        else { return }
        cancelTransientPicks()
        cancelTool()
        mode = .pickingSplitCutter(target: target)
    }

    func cancelSplitCutterPick() {
        if case .pickingSplitCutter = mode {
            mode = .idle
        }
    }

    // MARK: - Chamfer / Fillet (Phase E, spec §4.3)

    /// The body whose edges the current blend picks are on (a blend is
    /// single-body v1). Cleared when the pick starts fresh on a new body.
    var blendBodyID: BodyID?
    /// Convex edges (body-LOCAL space) the user has toggled for the blend.
    var blendSelectedEdges: [SelectableEdge] = []
    /// The blend size (setback for chamfer, radius for fillet), in mm.
    var blendValue: Double = 1 {
        didSet { if blendValue != oldValue { updateBlendPreview() } }
    }
    /// Live result preview: the source body with the pending blend applied,
    /// rendered IN PLACE of the source while the pick is armed (same swap the
    /// face push/pull preview uses). Monotonic revision keeps the GPU cache
    /// fresh across recomputes.
    var blendPreview: Body?
    private var blendPreviewRevision: UInt64 = 0

    /// Arm Chamfer/Fillet from the Modify palette: the next taps toggle the
    /// convex edges of a body. A body must already be selected or tappable.
    func beginBlend(_ kind: BlendKind) {
        cancelTransientPicks()
        cancelTool()
        blendSelectedEdges = []
        blendBodyID = selection.count == 1 ? selection.first : nil
        // Blend edge picking owns the viewport now. Keeping the source body
        // selected left its transform gizmo visible, and ViewportView gives
        // those controls first refusal on taps. Retain the source identity in
        // blendBodyID, but remove the ordinary selection so the newly armed
        // tool gets an unobstructed picking surface.
        selection.removeAll()
        blendValue = 1
        blendPreview = nil
        mode = .pickingBlendEdges(kind)
    }

    /// The feature being re-edited, when the pick was entered from a History
    /// row rather than from the Modify palette. Nil for a fresh blend.
    private(set) var blendEditingFeature: FeatureID?

    /// The body reference the edited feature already names.
    ///
    /// Kept rather than rebuilt at commit time: its `producer` is the UPSTREAM
    /// feature that made the body, not the blend itself. Reconstructing it from
    /// the blend's own id yields a self-referential ref that cannot resolve.
    private var blendEditBodyRef: BodyRef?

    /// The PRE-blend body, held for the duration of an edit.
    ///
    /// A blend replaces its body in place, so the document's copy already has
    /// the blend on it; previewing and committing against that would blend the
    /// result a second time. Recovered once, when the edit begins.
    private var blendEditSource: Body?

    /// The body the current pick blends: the pre-blend one while editing an
    /// existing feature, otherwise the document's own.
    private var blendSource: Body? {
        if let editSource = blendEditSource { return editSource }
        guard let id = blendBodyID else { return nil }
        return session.document.body(with: id)
    }

    /// Re-enter edge picking for an existing chamfer/fillet, seeded with the
    /// edges and size it already has (spec: additive edit-mode selection).
    ///
    /// The edges are resolved against the body the feature CONSUMED, not the
    /// one it produced — see `DocumentSession.inputBody(for:bodyID:)`.
    /// Returns false when the feature is not a blend, or when its input can no
    /// longer be replayed.
    @discardableResult
    func beginBlendEdit(_ id: FeatureID) -> Bool {
        guard let node = session.document.features.node(id) else { return false }
        let kind: BlendKind
        let refs: [EdgeRef]
        let amount: Double
        let bodyRef: BodyRef
        switch node.kind {
        case let .fillet(body, edges, radius):
            kind = .fillet; refs = edges; amount = radius.value; bodyRef = body
        case let .chamfer(body, edges, setback):
            kind = .chamfer; refs = edges; amount = setback.value; bodyRef = body
        default:
            return false
        }
        guard let source = session.inputBody(for: id, bodyID: bodyRef.bodyID) else {
            errorMessage = "Couldn't rebuild the shape this blend started from."
            return false
        }

        cancelTransientPicks()
        cancelTool()

        // Resolve each stored EdgeRef back to a live edge. Unresolvable ones are
        // dropped rather than failing the whole edit: an upstream change may
        // have removed one edge of a chain, and re-picking is exactly how the
        // user fixes that.
        let aabb = source.render.localAABB
        let scale = Double(simd_length(aabb.max - aabb.min))
        let available = EdgeTopology.selectableEdges(from: source.render)
        blendSelectedEdges = refs.compactMap {
            EdgeTopology.resolve($0.signature, in: available, sizeScale: scale)
        }

        blendEditingFeature = id
        blendEditBodyRef = bodyRef
        blendEditSource = source
        blendBodyID = bodyRef.bodyID
        blendValue = amount
        blendPreview = nil
        mode = .pickingBlendEdges(kind)
        updateBlendPreview()
        return true
    }

    /// The History row's reference re-pick, when the kind has one: blends
    /// re-pick edges, shell and delete-face re-pick faces (G8 reference
    /// rows). The label is the context-menu item.
    func referenceEditLabel(_ id: FeatureID) -> String? {
        switch session.document.features.node(id)?.kind {
        case .fillet, .chamfer: return "Edit Edges"
        case .shell, .deleteFace: return "Edit Faces"
        case .boolean: return "Edit Tool"
        case .mirror, .pattern, .transform: return "Edit Body"
        case .pushPull, .moveFace, .scaleFace, .rotateFace: return "Edit Face"
        case .extrude, .draftExtrude, .revolve, .sweep: return "Edit Profile"
        default: return nil
        }
    }

    /// Re-enter the pick mode that edits a feature's references, seeded with
    /// what it has; false when the kind has none or its input cannot replay.
    @discardableResult
    func beginReferenceEdit(_ id: FeatureID) -> Bool {
        switch session.document.features.node(id)?.kind {
        case .fillet, .chamfer: return beginBlendEdit(id)
        case .shell: return beginShellEdit(id)
        case .deleteFace: return beginDeleteFaceEdit(id)
        case .boolean: return beginBooleanEdit(id)
        case .mirror, .pattern, .transform: return beginFeatureBodyEdit(id)
        case .pushPull, .moveFace, .scaleFace, .rotateFace: return beginFeatureFaceEdit(id)
        case .extrude, .draftExtrude, .revolve, .sweep: return beginFeatureProfileEdit(id)
        default: return false
        }
    }

    /// Whether a History row offers "Edit Edges".
    func isBlendFeature(_ id: FeatureID) -> Bool {
        switch session.document.features.node(id)?.kind {
        case .fillet, .chamfer: return true
        default: return false
        }
    }

    /// User-facing Cancel: drop the pick and restore the body selection.
    func cancelBlend() {
        guard case .pickingBlendEdges = mode else { return }
        let body = blendBodyID
        resetBlendState()
        if let body, session.document.body(with: body) != nil {
            mode = .selected(body)
            selection = [body]
        } else {
            mode = .idle
        }
    }

    /// Internal reset (delete / undo / arming another tool): clears the blend
    /// state WITHOUT touching `selection` — deleteSelection deletes whatever is
    /// in `selection`, so mutating it here would change what gets deleted.
    private func resetBlendState() {
        blendSelectedEdges = []
        blendBodyID = nil
        blendPreview = nil
        // Clearing the EDIT state here is what stops a cancelled edit leaking
        // into the next blend: `commitBlend` branches on `blendEditingFeature`,
        // so a stale one would make a fresh pick silently overwrite the edges
        // of whatever feature was last opened from the History panel.
        blendEditingFeature = nil
        blendEditBodyRef = nil
        blendEditSource = nil
        if case .pickingBlendEdges = mode { mode = .idle }
    }

    /// The source mesh with the pending blend applied to every selected edge
    /// (one batched boolean — a rim chain is dozens of segments).
    private func blendedMesh(_ kind: BlendKind, source: Body) -> Euclid.Mesh {
        func d3(_ v: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double(v.x), Double(v.y), Double(v.z)) }
        let specs = blendSelectedEdges.map {
            BlendEdgeSpec(
                p0: d3($0.start), p1: d3($0.end),
                normalA: d3($0.normalA), normalB: d3($0.normalB),
                isConvex: $0.isConvex)
        }
        return KernelOps.blendEdges(
            mesh: source.euclidMesh(), edges: specs,
            amount: blendValue, isFillet: kind == .fillet)
    }

    /// The blend result for the current pick, branching on the source's
    /// kernel exactly like `FeatureGraph.evalEdgeBlend` (2026-08-25 review,
    /// C4): a brep body blends in OCCT (`BRepFilletAPI`), so the user
    /// previews and commits the same class of geometry replay will later
    /// produce — the Euclid mesh blend on an OCCT tessellation is the
    /// documented malformed-facets path. Both the brep and the edge
    /// midpoints are body-LOCAL, so no transform juggling is needed. Nil
    /// when the blend fails (too-big radius) — preview shows invalid.
    private func blendedBody(_ kind: BlendKind, source: Body, revision: UInt64) -> Body? {
        if OCCTKernel.useOCCTAsSourceOfTruth, let brep = source.brep {
            let midpoints = blendSelectedEdges.map { edge -> SIMD3<Double> in
                SIMD3(Double(edge.midpoint.x), Double(edge.midpoint.y), Double(edge.midpoint.z))
            }
            // Deflection-derived, not body-size-derived — same rule as replay
            // (FeatureGraph.evalEdgeBlend, docs/FREECAD_PLAYBOOK.md T1).
            let tolerance = OCCTKernel.matchTolerance(for: brep)
            let blended = kind == .fillet
                ? OCCTKernel.filletResult(brep, at: midpoints, radius: blendValue,
                                          tolerance: tolerance)
                : OCCTKernel.chamferResult(brep, at: midpoints, distance: blendValue,
                                           tolerance: tolerance)
            switch blended {
            case let .failure(error):
                blendPreviewFailure = error.message
                return nil
            case let .success(handle):
                var result = Body(
                    id: source.id, name: source.name, transform: source.transform,
                    primitive: nil, euclidMesh: source.euclidMesh(), revision: revision)
                guard result.adoptBRep(handle) else { return nil }
                blendPreviewFailure = nil
                return result
            }
        }
        let mesh = blendedMesh(kind, source: source)
        guard !mesh.polygons.isEmpty else { return nil }
        return Body(
            id: source.id, name: source.name, transform: source.transform,
            primitive: nil, euclidMesh: mesh, revision: revision)
    }

    /// Wall time the last preview recompute took, and when it finished.
    ///
    /// The preview runs the CSG synchronously on the main actor, so a slow one
    /// blocks input for its whole duration. On the mesh path a cylinder-rim
    /// fillet costs ~450 ms; a drag sets `blendValue` on every touch-move, so
    /// without a gate the main thread is saturated and the app reads as frozen
    /// (and a long enough hang is its own crash risk).
    private var lastPreviewDuration: TimeInterval = 0
    private var lastPreviewFinished: TimeInterval = 0
    /// True only between `beginBlendDrag` and `endBlendDrag`.
    private var isDraggingBlendSize = false

    /// Skip this recompute if the previous one is still "paying off".
    ///
    /// Self-tuning rather than a fixed interval: the gate is the last
    /// recompute's OWN duration, so the work never occupies more than about
    /// half the wall clock. An OCCT preview (~9 ms) is never throttled at all,
    /// while a 450 ms mesh preview drops to roughly two a second and leaves the
    /// main thread free to track the finger in between. Only drags are gated —
    /// a tap or a typed size always recomputes immediately.
    private var shouldSkipPreviewDuringDrag: Bool {
        guard isDraggingBlendSize, lastPreviewDuration > 0.05 else { return false }
        return ProcessInfo.processInfo.systemUptime - lastPreviewFinished < lastPreviewDuration
    }

    /// Why the current blend preview failed to build, in user terms — the
    /// typed diagnostic from OCCT ("2 of 6 edges can't take this size…"),
    /// shown in the blend bar. Nil while the preview is valid or nothing is
    /// picked yet. Set by `blendedBody`.
    var blendPreviewFailure: String?

    /// Recompute the live blend preview (edge toggles and size edits call this).
    private func updateBlendPreview() {
        guard case .pickingBlendEdges(let kind) = mode, let source = blendSource else {
            blendPreview = nil
            blendPreviewFailure = nil
            return
        }
        guard !blendSelectedEdges.isEmpty, blendValue > 1e-6 else {
            // While EDITING, an empty pick still has something to show: the
            // body without the blend. Falling through to nil would display the
            // document's copy, which still has the old blend on it — so
            // deselecting every edge would look like it did nothing.
            blendPreview = blendEditSource.map {
                var body = $0
                blendPreviewRevision &+= 1
                body.meshRevision = (1 << 62) | blendPreviewRevision
                return body
            }
            blendPreviewFailure = nil
            return
        }
        guard !shouldSkipPreviewDuringDrag else { return }
        blendPreviewRevision &+= 1
        // High-bit revision space so preview revisions never collide with
        // the document's own mesh revisions in the GPU cache.
        let started = ProcessInfo.processInfo.systemUptime
        blendPreview = blendedBody(
            kind, source: source, revision: (1 << 62) | blendPreviewRevision)
        lastPreviewFinished = ProcessInfo.processInfo.systemUptime
        lastPreviewDuration = lastPreviewFinished - started
    }

    /// Whether the blend can be committed (edges picked on one body, a positive
    /// size, and the result is non-empty — a too-big blend that ate the body
    /// keeps Apply disabled, mirroring the red arrow).
    var canCommitBlend: Bool {
        if case .pickingBlendEdges = mode {
            return !blendSelectedEdges.isEmpty && blendValue > 1e-6
                && blendPreview != nil
        }
        return false
    }

    /// Drag-to-size: value at drag start; the drag applies a delta to it.
    private var blendDragStartValue: Double?
    /// Kernel-derived ceiling for the current fillet drag, in mm — bisection
    /// over real checked builds (docs/FREECAD_PLAYBOOK.md F3), so the clamp
    /// and Apply agree by construction. Nil for chamfers, mesh-path bodies,
    /// or when the probe found nothing blendable; the typed preview errors
    /// still cover those. Shown in the blend bar while dragging.
    var blendDragMax: Double?

    func beginBlendDrag() -> Bool {
        guard case let .pickingBlendEdges(kind) = mode, !blendSelectedEdges.isEmpty
        else { return false }
        blendDragStartValue = blendValue
        isDraggingBlendSize = true
        // Computed ONCE here (a handful of fillet builds), never per tick.
        // The edge set is frozen for the duration of the drag.
        blendDragMax = nil
        if kind == .fillet, OCCTKernel.useOCCTAsSourceOfTruth,
           let source = blendSource, let brep = source.brep {
            let midpoints = blendSelectedEdges.map { edge -> SIMD3<Double> in
                SIMD3(Double(edge.midpoint.x), Double(edge.midpoint.y), Double(edge.midpoint.z))
            }
            let cap = OCCTKernel.maxFilletRadius(
                brep, at: midpoints, tolerance: OCCTKernel.matchTolerance(for: brep))
            if cap > 0 { blendDragMax = cap }
        }
        return true
    }

    /// `delta` is world mm along the arrow's pointing direction (into the body).
    func updateBlendDrag(delta: Double) {
        guard let start = blendDragStartValue else { return }
        var next = max(0, start + delta)
        // Clamp to what the kernel can actually build, so the drag never
        // enters the range Apply would refuse.
        if let cap = blendDragMax { next = min(next, cap) }
        blendValue = next   // didSet recomputes the preview
    }

    func endBlendDrag() {
        blendDragStartValue = nil
        blendDragMax = nil
        // The gate may have skipped the last few frames, so the preview can be
        // one size behind the finger. Settle it before the user can commit.
        isDraggingBlendSize = false
        updateBlendPreview()
    }

    /// Tap while a blend is armed: pick the body, find the nearest convex edge to
    /// the tap, and toggle it in the selection. Tapping a second body restarts
    /// the pick on that body (a blend stays single-body).
    private func handleBlendEdgeTap(ray: Ray, kind: BlendKind) {
        guard let hit = HitTester.pickBody(ray: ray, in: scene) else { return }
        // While editing, edges must come from the body the feature CONSUMED —
        // the document's copy already carries the blend, so its edges are the
        // rounded ones, which are not what the feature names.
        let editing = blendEditingFeature != nil
        guard let body = (editing && hit.bodyID == blendBodyID)
                ? blendEditSource
                : session.document.body(with: hit.bodyID)
        else { return }

        // An edit stays on its own body: tapping elsewhere would have to
        // re-target the feature, which is not what "edit these edges" means.
        if editing && hit.bodyID != blendBodyID { return }

        if blendBodyID != hit.bodyID {
            blendBodyID = hit.bodyID
            blendSelectedEdges = []
        }
        // Convert the world hit to body-local space (edges live in local space).
        let inverse = simd_inverse(body.transform.matrixFloat)
        let local4 = inverse * SIMD4(hit.worldPoint, 1)
        let localPoint = SIMD3<Float>(local4.x, local4.y, local4.z)

        // Concave edges are pickable too: a blend there FILLS the corner
        // instead of cutting it away (`KernelOps.blendEdges`). They used to be
        // filtered out here, which made an internal corner simply unpickable —
        // the tap found the nearest CONVEX edge somewhere else on the body and
        // selected that instead, so it read as a mis-hit rather than as a
        // missing feature.
        let edges = EdgeTopology.selectableEdges(from: body.render)
        guard let nearest = edges.min(by: {
            Self.pointSegmentDistance(localPoint, $0.start, $0.end)
                < Self.pointSegmentDistance(localPoint, $1.start, $1.end)
        }) else { return }

        func isSelected(_ edge: SelectableEdge) -> Int? {
            blendSelectedEdges.firstIndex {
                simd_length($0.midpoint - edge.midpoint) < 1e-4
            }
        }

        // A tap on the FACE — well clear of every edge — blends every edge of
        // that planar face at once (bug report e07493b5: "tap the top of a
        // cube and chamfer all four corners of that side"); near an edge the
        // tap still means that one edge, as it always has.
        if let faceEdges = blendFaceEdges(
            body: body, hit: hit, ray: ray, nearest: nearest, edges: edges) {
            // Toggle the face's edges as a unit: all selected → deselect all.
            if faceEdges.allSatisfy({ isSelected($0) != nil }) {
                for edge in faceEdges {
                    if let idx = isSelected(edge) { blendSelectedEdges.remove(at: idx) }
                }
            } else {
                for edge in faceEdges where isSelected(edge) == nil {
                    blendSelectedEdges.append(edge)
                }
            }
            updateBlendPreview()
            return
        }

        // A curved rim (cylinder top, rounded pocket) tessellates into many
        // short segments; expand the pick to the whole tangent-continuous chain
        // so one tap blends the full rim. A straight edge is its own chain.
        let chain = EdgeTopology.smoothChain(containing: nearest, in: edges)

        // Toggle the chain as a unit: fully selected → deselect it all.
        if chain.allSatisfy({ isSelected($0) != nil }) {
            for edge in chain {
                if let idx = isSelected(edge) { blendSelectedEdges.remove(at: idx) }
            }
        } else {
            for edge in chain where isSelected(edge) == nil {
                blendSelectedEdges.append(edge)
            }
        }
        updateBlendPreview()
    }

    /// Screen distance (points) a tap must keep from every edge to count as a
    /// tap on the face rather than on the nearest edge.
    private static let blendFaceTapClearancePoints: CGFloat = 18

    /// The selectable edges bounding the planar face under a tap, when the
    /// tap is a FACE tap: clear of every edge on screen, on a flat face whose
    /// whole boundary is selectable edges. A facet of a curved wall is not —
    /// its sides are smooth — so a tap on a cylinder's wall still picks the
    /// nearest rim, as before. Nil = not a face tap.
    private func blendFaceEdges(body: Body, hit: PickHit, ray: Ray,
                                nearest: SelectableEdge,
                                edges: [SelectableEdge]) -> [SelectableEdge]? {
        guard let control = cameraControl else { return nil }
        let toLocal = simd_inverse(body.transform.matrixFloat)
        let local4 = toLocal * SIMD4(hit.worldPoint, 1)
        let local = SIMD3<Float>(local4.x, local4.y, local4.z)
        // Nearest point on the nearest edge, projected: the clearance is judged
        // on screen so it means the same thing zoomed in or out.
        let ab = nearest.end - nearest.start
        let len2 = simd_length_squared(ab)
        let t = len2 > 1e-12 ? max(0, min(1, simd_dot(local - nearest.start, ab) / len2)) : 0
        let onEdge4 = body.transform.matrixFloat * SIMD4(nearest.start + ab * t, 1)
        guard let tapScreen = control.worldToScreenPoint(SIMD3<Double>(hit.worldPoint)),
              let edgeScreen = control.worldToScreenPoint(
                SIMD3<Double>(Double(onEdge4.x), Double(onEdge4.y), Double(onEdge4.z))),
              hypot(tapScreen.x - edgeScreen.x, tapScreen.y - edgeScreen.y)
                > Self.blendFaceTapClearancePoints
        else { return nil }

        // The face under the tap, picked on the ORIGINAL mesh: while the live
        // preview replaces the body in `scene`, the hit's triangle index
        // refers to the preview's mesh.
        let originalScene = ViewportScene(bodies: [BodyDrawable(
            id: body.id,
            renderMesh: body.render,
            edges: body.edges,
            meshRevision: body.meshRevision,
            modelMatrix: body.transform.matrixFloat,
            baseColor: SIMD4(0.72, 0.74, 0.78, 1),
            selectionState: SelectionStateNone.rawValue
        )])
        guard let originalHit = HitTester.pickBody(ray: ray, in: originalScene),
              let face = FaceTopology.planarFace(
                  in: body.render, seedTriangle: originalHit.triangleIndex)
        else { return nil }

        // Edges lying on the face's boundary loops (outline and holes), and
        // every loop segment covered by one — otherwise this "face" is a
        // facet with smooth sides.
        let n = SIMD3(Double(face.normal.x), Double(face.normal.y), Double(face.normal.z))
        let loops = [face.outline] + face.holes
        let tolerance = 1e-2
        func onBoundary(_ p: SIMD3<Float>) -> Bool {
            let d = SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z)) - face.origin
            guard abs(simd_dot(d, n)) < tolerance else { return false }
            let uv = SIMD2(simd_dot(d, face.basisX), simd_dot(d, face.basisY))
            return loops.contains { loop in
                loop.indices.contains { i in
                    KernelOps.distanceToSegment(uv, loop[i], loop[(i + 1) % loop.count]) < tolerance
                }
            }
        }
        let boundary = edges.filter {
            onBoundary($0.start) && onBoundary($0.end) && onBoundary($0.midpoint)
        }
        guard !boundary.isEmpty else { return nil }
        for loop in loops {
            for i in loop.indices {
                let mid = (loop[i] + loop[(i + 1) % loop.count]) / 2
                let world = face.origin + face.basisX * mid.x + face.basisY * mid.y
                let midF = SIMD3<Float>(Float(world.x), Float(world.y), Float(world.z))
                guard boundary.contains(where: {
                    Self.pointSegmentDistance(midF, $0.start, $0.end) < Float(tolerance)
                }) else { return nil }
            }
        }
        return boundary
    }

    /// Apply the blend: build the new mesh live and record a `.chamfer`/`.fillet`
    /// feature node so it rebuilds parametrically. The EdgeRefs pin each edge by
    /// signature against the owning feature's body.
    func commitBlend() {
        guard case .pickingBlendEdges(let kind) = mode,
              let bodyID = blendBodyID,
              let source = blendSource,
              !blendSelectedEdges.isEmpty,
              blendValue > 1e-6   // a zero-size node would error on replay
        else { return }

        // Editing an existing feature: change the node and let the rebuild
        // produce the geometry, exactly as `editFeatureDistance` does. The
        // live-preview path below would instead REPLACE the body and append a
        // SECOND blend node on top of the first.
        if let featureID = blendEditingFeature, let bodyRef = blendEditBodyRef {
            let edgeRefs = blendSelectedEdges.map {
                EdgeRef(body: bodyRef, signature: EdgeTopology.signature(of: $0),
                        faceNames: mintEdgeName(body: source, edge: $0))
            }
            let after: FeatureKind = kind == .fillet
                ? .fillet(body: bodyRef, edges: edgeRefs, radius: Expr(value: blendValue))
                : .chamfer(body: bodyRef, edges: edgeRefs, setback: Expr(value: blendValue))
            prepareForHistoryChange()
            resetBlendState()
            session.editFeature(featureID, to: after)
            session.save()
            mode = .selected(bodyID)
            selection = [bodyID]
            return
        }

        // Reuse the live preview when it's current (it already carries the
        // OCCT brep for analytic bodies — C4); else compute fresh.
        let after: Body
        if var preview = blendPreview {
            preview.meshRevision = 0 // assigned by the command
            after = preview
        } else if let computed = blendedBody(kind, source: source, revision: 0) {
            after = computed
        } else {
            errorMessage = "The \(kind.title.lowercased()) produced no geometry."
            cancelBlend()
            return
        }
        let replace = ReplaceBodyCommand(title: kind.title, before: source, after: after)

        // Record a parametric node only for a feature-owned body (else geometry
        // only, like mirror — a seed/import body can't be replayed).
        if let owner = featureNode(owning: bodyID) {
            let bodyRef = BodyRef(producer: owner.id, bodyID: bodyID)
            let edgeRefs = blendSelectedEdges.map {
                EdgeRef(body: bodyRef, signature: EdgeTopology.signature(of: $0),
                        faceNames: mintEdgeName(body: source, edge: $0))
            }
            let node = FeatureNode(
                name: kind.title,
                kind: kind == .fillet
                    ? .fillet(body: bodyRef, edges: edgeRefs, radius: Expr(value: blendValue))
                    : .chamfer(body: bodyRef, edges: edgeRefs, setback: Expr(value: blendValue)),
                outputBodyIDs: [bodyID])
            session.perform(CompositeCommand(
                title: kind.title, commands: [replace, AppendFeatureCommand(node: node)]))
        } else {
            session.perform(replace)
        }
        blendSelectedEdges = []
        blendBodyID = nil
        blendPreview = nil
        mode = .selected(source.id)
        selection = [source.id]
        session.save()
    }

    // MARK: - Shell (Phase E, spec §4.4)

    /// The body the current shell pick hollows (single-body, like blends).
    var shellBodyID: BodyID?
    /// Planar faces (body-LOCAL space) the user has toggled OPEN. Empty is
    /// valid: Shapr3D's whole-body Shell yields an enclosed hollow.
    var shellSelectedFaces: [PlanarFace] = []
    /// Editing an existing shell node (History "Edit Faces"): the node, its
    /// consumed-body ref, and the replayed INPUT body the pick and preview
    /// run against — the document's copy is already hollow.
    private(set) var shellEditingFeature: FeatureID?
    private var shellEditBodyRef: BodyRef?
    private var shellEditSource: Body?
    /// The body the shell pick previews from: the replayed input while
    /// editing, else the live document body.
    private var shellSourceBody: Body? {
        if let source = shellEditSource { return source }
        return shellBodyID.flatMap { session.document.body(with: $0) }
    }
    /// Wall thickness in mm.
    var shellThickness: Double = 2 {
        didSet { if shellThickness != oldValue { updateShellPreview() } }
    }
    /// Live result preview, rendered in place of the source (same swap as the
    /// blend preview). Nil when the thickness eats the body — Apply disables.
    var shellPreview: Body?
    private var shellPreviewRevision: UInt64 = 0

    /// Arm Shell from the Modify palette: the next taps toggle planar faces
    /// open; the shell bar drives the wall thickness.
    func beginShell() {
        cancelTransientPicks()
        cancelTool()
        shellSelectedFaces = []
        shellBodyID = selection.count == 1 ? selection.first : nil
        shellThickness = shellBodyID
            .flatMap { session.document.body(with: $0) }
            .map(Self.defaultShellThickness(for:)) ?? 2
        shellPreview = nil
        mode = .pickingShellFaces
        updateShellPreview()
    }

    /// Re-enter face picking for an existing shell, seeded with the open faces
    /// and thickness it already has — the History row's "Edit Faces", the
    /// same additive edit mode as `beginBlendEdit`. Faces resolve against the
    /// body the feature CONSUMED (`DocumentSession.inputBody`), never the
    /// hollow result. False when the node is not a shell or its input cannot
    /// be replayed.
    @discardableResult
    func beginShellEdit(_ id: FeatureID) -> Bool {
        guard let node = session.document.features.node(id),
              case let .shell(bodyRef, openFaces, thickness) = node.kind
        else { return false }
        guard let source = session.inputBody(for: id, bodyID: bodyRef.bodyID) else {
            errorMessage = "Couldn't rebuild the shape this shell started from."
            return false
        }
        cancelTransientPicks()
        cancelTool()
        // Unresolvable faces are dropped, not fatal: re-picking is the repair.
        let naming = SignatureNaming()
        shellSelectedFaces = openFaces.compactMap { naming.resolve($0, in: source, table: nil)?.planar }
        shellEditingFeature = id
        shellEditBodyRef = bodyRef
        shellEditSource = source
        shellBodyID = bodyRef.bodyID
        shellThickness = thickness.value
        shellPreview = nil
        mode = .pickingShellFaces
        updateShellPreview()
        return true
    }

    /// 2 mm, clamped to a quarter of the body's smallest extent so the default
    /// never eats the body (a 2 mm plate would otherwise arm invalid).
    private static func defaultShellThickness(for body: Body) -> Double {
        let aabb = body.render.localAABB
        let size = aabb.max - aabb.min
        let minDim = Double(min(size.x, min(size.y, size.z))) * body.transform.scale
        guard minDim > 1e-6 else { return 2 }
        let fitted = min(2, minDim / 4)
        // Round to a tidy 0.1 mm step so the bar shows a friendly number.
        return max(0.1, (fitted * 10).rounded() / 10)
    }

    /// User-facing Cancel: drop the pick and restore the body selection.
    func cancelShell() {
        guard case .pickingShellFaces = mode else { return }
        let body = shellBodyID
        resetShellState()
        if let body, session.document.body(with: body) != nil {
            mode = .selected(body)
            selection = [body]
        } else {
            mode = .idle
        }
    }

    /// Internal reset (delete / undo / arming another tool): clears the shell
    /// state WITHOUT touching `selection` (same contract as `resetBlendState`).
    private func resetShellState() {
        shellSelectedFaces = []
        shellBodyID = nil
        shellPreview = nil
        shellEditingFeature = nil
        shellEditBodyRef = nil
        shellEditSource = nil
        if case .pickingShellFaces = mode { mode = .idle }
    }

    /// Tap while Shell is armed: pick the body, toggle the tapped planar face
    /// open/closed. Switching bodies restarts the pick on the new body.
    private func handleShellFaceTap(ray: Ray) {
        guard let hit = HitTester.pickBody(ray: ray, in: scene) else { return }
        // Editing an existing shell: faces come from the CONSUMED body (the
        // document's copy is already hollow), and the edit stays on its body.
        let editing = shellEditingFeature != nil
        if editing && hit.bodyID != shellBodyID { return }
        guard let body = editing ? shellEditSource : session.document.body(with: hit.bodyID)
        else { return }
        if shellBodyID != hit.bodyID {
            shellBodyID = hit.bodyID
            shellSelectedFaces = []
            shellThickness = Self.defaultShellThickness(for: body)
        }
        // While the live preview replaces the body in `scene`, the hit's
        // triangle index refers to the PREVIEW mesh. Re-pick against the
        // ORIGINAL body so the face comes from the mesh the shell recomputes
        // from — this is also what makes tapping an already-open face (through
        // the preview's hole) toggle it closed again.
        let originalScene = ViewportScene(bodies: [BodyDrawable(
            id: body.id,
            renderMesh: body.render,
            edges: body.edges,
            meshRevision: body.meshRevision,
            modelMatrix: body.transform.matrixFloat,
            baseColor: SIMD4(0.72, 0.74, 0.78, 1),
            selectionState: SelectionStateNone.rawValue
        )])
        guard let originalHit = HitTester.pickBody(ray: ray, in: originalScene),
              let face = FaceTopology.planarFace(
                  in: body.render, seedTriangle: originalHit.triangleIndex) else {
            errorMessage = "Only flat faces can be opened — tap a planar face."
            return
        }
        // Toggle: same triangle set already picked → close it again.
        let key = Set(face.triangles)
        if let idx = shellSelectedFaces.firstIndex(where: { Set($0.triangles) == key }) {
            shellSelectedFaces.remove(at: idx)
        } else {
            shellSelectedFaces.append(face)
        }
        updateShellPreview()
    }

    /// The point each open face is handed to OCCT by: a point ON the face,
    /// from the same helper the evaluator uses, so the live preview and the
    /// feature it commits pick the same faces. It used to be the centroid of
    /// the face's outline, which is the OUTER boundary: on a face with a hole
    /// that centroid lands in the hole, OCCT refused the pick, and the preview
    /// stayed empty with Apply disabled on any holed face, while the same
    /// shell built fine over the bridge and on History replay (2026-09-16).
    nonisolated static func shellOpenPoints(
        for faces: [FaceTopology.PlanarFace], mesh: RenderMesh
    ) -> [SIMD3<Double>] {
        faces.map { FeatureGraph.pointOnPlanarFace($0, mesh: mesh) }
    }

    /// Recompute the live shell preview (face toggles and thickness edits call
    /// this). An empty kernel result (thickness ate the body, or an opening
    /// rim collapsed) clears the preview — that's the invalid state.
    /// The shell result for the current pick, branching on the source's
    /// kernel exactly like `FeatureGraph.evalShell` (2026-08-25 review, C4):
    /// a brep body hollows with `BRepOffsetAPI_MakeThickSolid` so CURVED
    /// walls come out right — the mesh inset is only honest on prismatic
    /// bodies (a live-shelled cylinder used to commit wrong walls that the
    /// next rebuild silently replaced). A brep body whose OCCT shell fails
    /// shows as INVALID (matching eval, which now errors instead of
    /// degrading to the clamping mesh inset — review R3-E); the mesh path
    /// stays for brep-less bodies. Nil = invalid.
    private func shelledBody(source: Body, revision: UInt64) -> Body? {
        if OCCTKernel.useOCCTAsSourceOfTruth, let brep = source.brep {
            let openPoints = Self.shellOpenPoints(for: shellSelectedFaces, mesh: source.render)
            guard let hollow = try? OCCTKernel.shellResult(
                brep, openingAt: openPoints, thickness: shellThickness,
                tolerance: OCCTKernel.matchTolerance(for: brep)).get() else {
                return nil
            }
            var result = Body(
                id: source.id, name: source.name, transform: source.transform,
                primitive: nil, euclidMesh: source.euclidMesh(), revision: revision)
            return result.adoptBRep(hollow) ? result : nil
        }
        let mesh = KernelOps.shell(
            mesh: source.euclidMesh(), thickness: shellThickness,
            openFaces: shellSelectedFaces)
        guard !mesh.polygons.isEmpty else { return nil }
        return Body(
            id: source.id, name: source.name, transform: source.transform,
            primitive: nil, euclidMesh: mesh, revision: revision)
    }

    private func updateShellPreview() {
        guard case .pickingShellFaces = mode,
              shellBodyID != nil,
              let source = shellSourceBody,
              shellThickness > 1e-6
        else {
            shellPreview = nil
            return
        }
        shellPreviewRevision &+= 1
        shellPreview = shelledBody(
            source: source, revision: (1 << 61) | shellPreviewRevision)
    }

    /// Whether the shell can be committed: a body picked, positive thickness,
    /// and a live (non-empty) result.
    var canCommitShell: Bool {
        if case .pickingShellFaces = mode {
            return shellBodyID != nil && shellThickness > 1e-6 && shellPreview != nil
        }
        return false
    }

    /// Apply the shell: replace the body's mesh and record a `.shell` feature
    /// node so it rebuilds parametrically. Open faces pin by geometric
    /// signature against the owning feature's body (same scheme as push/pull).
    func commitShell() {
        guard case .pickingShellFaces = mode,
              let bodyID = shellBodyID,
              let source = session.document.body(with: bodyID),
              shellThickness > 1e-6
        else { return }

        // Editing an existing node: change the node and let the rebuild
        // produce the geometry (as `commitBlend` does while editing). The
        // live-preview path below would REPLACE the body and append a second
        // shell node on top of the first.
        if let featureID = shellEditingFeature, let bodyRef = shellEditBodyRef,
           let input = shellEditSource {
            let faceRefs = shellSelectedFaces.map {
                Self.shellFaceRef(face: $0, bodyRef: bodyRef, creator: bodyRef.producer,
                                  elementName: mintElementName(body: input, triangle: $0.triangles.first))
            }
            let after = FeatureKind.shell(
                body: bodyRef, openFaces: faceRefs, thickness: Expr(value: shellThickness))
            prepareForHistoryChange()
            resetShellState()
            session.editFeature(featureID, to: after)
            session.save()
            mode = .selected(bodyID)
            selection = [bodyID]
            return
        }

        // Reuse the live preview when current (it carries the OCCT brep for
        // analytic bodies — C4); else compute fresh.
        let after: Body
        if var preview = shellPreview {
            preview.meshRevision = 0 // assigned by the command
            after = preview
        } else if let computed = shelledBody(source: source, revision: 0) {
            after = computed
        } else {
            errorMessage = "The shell produced no geometry — try a thinner wall."
            cancelShell()
            return
        }
        let replace = ReplaceBodyCommand(title: "Shell", before: source, after: after)

        // Parametric node only for a feature-owned body (same rule as blends).
        if let owner = featureNode(owning: bodyID) {
            let bodyRef = BodyRef(producer: owner.id, bodyID: bodyID)
            let faceRefs = shellSelectedFaces.map {
                Self.shellFaceRef(face: $0, bodyRef: bodyRef, creator: owner.id,
                                  elementName: mintElementName(
                                      body: source,
                                      triangle: $0.triangles.first))
            }
            let node = FeatureNode(
                name: "Shell",
                kind: .shell(
                    body: bodyRef, openFaces: faceRefs,
                    thickness: Expr(value: shellThickness)),
                outputBodyIDs: [bodyID])
            session.perform(CompositeCommand(
                title: "Shell", commands: [replace, AppendFeatureCommand(node: node)]))
        } else {
            session.perform(replace)
        }
        shellSelectedFaces = []
        shellBodyID = nil
        shellPreview = nil
        mode = .selected(source.id)
        selection = [source.id]
        session.save()
    }

    // MARK: - Delete Face (direct modeling, spec §4.16)

    /// The body the current Delete Face pick edits (single-body, like Shell).
    var deleteFaceBodyID: BodyID?
    /// Faces toggled for removal, in pick order.
    var deleteFaceTargets: [DeleteFaceKit.Target] = []
    /// Editing an existing delete-face node (History "Edit Faces"), as for
    /// shell: the node, its consumed-body ref, and the replayed input body.
    private(set) var deleteFaceEditingFeature: FeatureID?
    private var deleteFaceEditBodyRef: BodyRef?
    private var deleteFaceEditSource: Body?
    private var deleteFaceSourceBody: Body? {
        if let source = deleteFaceEditSource { return source }
        return deleteFaceBodyID.flatMap { session.document.body(with: $0) }
    }
    /// Live healed result, rendered in place of the source (same swap as the
    /// shell preview). Nil when the neighbours cannot close — Apply disables,
    /// which is the honest answer: §4.16 says some deletions leave a sheet
    /// body, and shipping one of those as a "solid" is worse than refusing.
    var deleteFacePreview: Body?
    private var deleteFacePreviewRevision: UInt64 = 0

    /// Arm Delete Face from the Modify palette. The next taps toggle faces.
    func beginDeleteFace() {
        cancelTransientPicks()
        cancelTool()
        deleteFaceTargets = []
        deleteFaceBodyID = selection.count == 1 ? selection.first : nil
        deleteFacePreview = nil
        mode = .pickingDeleteFaces
    }

    /// Re-enter face picking for an existing delete-face node, seeded with
    /// the faces it removes — "Edit Faces" on its History row. Faces resolve
    /// against the consumed body (the document's copy no longer has them).
    @discardableResult
    func beginDeleteFaceEdit(_ id: FeatureID) -> Bool {
        guard let node = session.document.features.node(id),
              case let .deleteFace(bodyRef, faces) = node.kind
        else { return false }
        guard let source = session.inputBody(for: id, bodyID: bodyRef.bodyID) else {
            errorMessage = "Couldn't rebuild the shape this delete started from."
            return false
        }
        cancelTransientPicks()
        cancelTool()
        let naming = SignatureNaming()
        deleteFaceTargets = faces.compactMap { ref in
            guard let resolved = naming.resolve(ref, in: source, table: nil),
                  let seed = resolved.planar?.triangles.first ?? resolved.cylinder?.triangles.first
            else { return nil }
            return DeleteFaceKit.target(in: source.render, seedTriangle: seed)
        }
        deleteFaceEditingFeature = id
        deleteFaceEditBodyRef = bodyRef
        deleteFaceEditSource = source
        deleteFaceBodyID = bodyRef.bodyID
        deleteFacePreview = nil
        mode = .pickingDeleteFaces
        updateDeleteFacePreview()
        return true
    }

    /// User-facing Cancel: drop the pick and restore the body selection.
    func cancelDeleteFace() {
        guard case .pickingDeleteFaces = mode else { return }
        let body = deleteFaceBodyID
        resetDeleteFaceState()
        if let body, session.document.body(with: body) != nil {
            mode = .selected(body)
            selection = [body]
        } else {
            mode = .idle
        }
    }

    /// Internal reset (delete / undo / arming another tool): clears the pick
    /// WITHOUT touching `selection` (same contract as `resetShellState`).
    private func resetDeleteFaceState() {
        deleteFaceTargets = []
        deleteFaceBodyID = nil
        deleteFacePreview = nil
        deleteFaceEditingFeature = nil
        deleteFaceEditBodyRef = nil
        deleteFaceEditSource = nil
        if case .pickingDeleteFaces = mode { mode = .idle }
    }

    /// Tap while Delete Face is armed: pick the body, toggle the tapped face.
    /// Switching bodies restarts the pick on the new one.
    private func handleDeleteFaceTap(ray: Ray) {
        guard let hit = HitTester.pickBody(ray: ray, in: scene) else { return }
        // Editing an existing delete: faces come from the CONSUMED body, and
        // the edit stays on its body (same rule as the shell and blend edits).
        let editing = deleteFaceEditingFeature != nil
        if editing && hit.bodyID != deleteFaceBodyID { return }
        guard let body = editing ? deleteFaceEditSource : session.document.body(with: hit.bodyID)
        else { return }
        if deleteFaceBodyID != hit.bodyID {
            deleteFaceBodyID = hit.bodyID
            deleteFaceTargets = []
            deleteFacePreview = nil
        }
        guard body.brep != nil else {
            // Say why, once, instead of letting every tap do nothing.
            showNotice("Delete Face needs an analytic body — this one is mesh-only.")
            return
        }
        // The live preview stands in for the body in `scene`, so the hit's
        // triangle index refers to the PREVIEW mesh. Re-pick against the
        // ORIGINAL so the face comes from the mesh the heal recomputes from —
        // this is also what lets a second tap un-pick a face that the preview
        // has already removed (same trap as the shell pick).
        let originalScene = ViewportScene(bodies: [BodyDrawable(
            id: body.id,
            renderMesh: body.render,
            edges: body.edges,
            meshRevision: body.meshRevision,
            modelMatrix: body.transform.matrixFloat,
            baseColor: SIMD4(0.72, 0.74, 0.78, 1),
            selectionState: SelectionStateNone.rawValue
        )])
        guard let originalHit = HitTester.pickBody(ray: ray, in: originalScene),
              let target = DeleteFaceKit.target(
                  in: body.render, seedTriangle: originalHit.triangleIndex) else {
            showNotice("That surface isn't a face this tool can remove.")
            return
        }
        if let idx = deleteFaceTargets.firstIndex(of: target) {
            deleteFaceTargets.remove(at: idx)
        } else {
            deleteFaceTargets.append(target)
        }
        updateDeleteFacePreview()
    }

    /// The healed solid for the current pick, or nil when OCCT cannot close
    /// the gap. Shared by the preview and the commit so what you see is what
    /// you get.
    private func healedBody(source: Body, revision: UInt64) -> Body? {
        guard let brep = source.brep, !deleteFaceTargets.isEmpty else { return nil }
        guard let healed = OCCTKernel.removingFaces(
            brep,
            at: deleteFaceTargets.map(\.samplePoint),
            tolerance: OCCTKernel.matchTolerance(for: brep)) else { return nil }
        var result = Body(
            id: source.id, name: source.name, transform: source.transform,
            primitive: nil, render: source.render, revision: revision)
        guard result.adoptBRep(healed) else { return nil }
        return result
    }

    private func updateDeleteFacePreview() {
        guard case .pickingDeleteFaces = mode,
              deleteFaceBodyID != nil,
              let source = deleteFaceSourceBody
        else {
            deleteFacePreview = nil
            return
        }
        deleteFacePreviewRevision &+= 1
        deleteFacePreview = healedBody(
            source: source, revision: (1 << 57) | deleteFacePreviewRevision)
    }

    /// Whether the delete can be committed: a body, at least one face, and a
    /// live healed result.
    var canCommitDeleteFace: Bool {
        if case .pickingDeleteFaces = mode {
            return deleteFaceBodyID != nil && !deleteFaceTargets.isEmpty
                && deleteFacePreview != nil
        }
        return false
    }

    /// Apply: replace the body with the healed solid and record a
    /// `.deleteFace` node so it rebuilds parametrically.
    func commitDeleteFace() {
        guard case .pickingDeleteFaces = mode,
              let bodyID = deleteFaceBodyID,
              let source = session.document.body(with: bodyID),
              !deleteFaceTargets.isEmpty
        else { return }

        // Editing an existing node: rewrite its faces and let the rebuild
        // heal — never a second node on top of the first.
        if let featureID = deleteFaceEditingFeature, let bodyRef = deleteFaceEditBodyRef,
           let input = deleteFaceEditSource {
            let faceRefs = deleteFaceTargets.map {
                FaceRef(body: bodyRef, creator: bodyRef.producer,
                        role: .derived(index: 0), signature: $0.signature,
                        elementName: mintElementName(body: input, triangle: $0.triangles.first))
            }
            prepareForHistoryChange()
            resetDeleteFaceState()
            session.editFeature(featureID, to: .deleteFace(body: bodyRef, faces: faceRefs))
            session.save()
            mode = .selected(bodyID)
            selection = [bodyID]
            return
        }

        // Reuse the live preview when current — it already carries the healed
        // brep, and recomputing risks the two disagreeing.
        let after: Body
        if var preview = deleteFacePreview {
            preview.meshRevision = 0 // assigned by the command
            after = preview
        } else if let computed = healedBody(source: source, revision: 0) {
            after = computed
        } else {
            errorMessage = "The surrounding faces could not heal — "
                + "try deleting fewer faces, or a different one."
            return
        }
        let replace = ReplaceBodyCommand(title: "Delete Face", before: source, after: after)

        // Parametric node only for a feature-owned body (same rule as blends
        // and shell).
        if let owner = featureNode(owning: bodyID) {
            let bodyRef = BodyRef(producer: owner.id, bodyID: bodyID)
            let faceRefs = deleteFaceTargets.map {
                FaceRef(body: bodyRef, creator: owner.id,
                        role: .derived(index: 0), signature: $0.signature,
                        elementName: mintElementName(
                            body: source,
                            triangle: $0.triangles.first))
            }
            let node = FeatureNode(
                name: "Delete Face",
                kind: .deleteFace(body: bodyRef, faces: faceRefs),
                outputBodyIDs: [bodyID])
            session.perform(CompositeCommand(
                title: "Delete Face",
                commands: [replace, AppendFeatureCommand(node: node)]))
        } else {
            session.perform(replace)
        }
        deleteFaceTargets = []
        deleteFaceBodyID = nil
        deleteFacePreview = nil
        mode = .selected(source.id)
        selection = [source.id]
        session.save()
    }

    // MARK: - Replace Face (direct modeling, spec §4.12)

    /// The body whose face is being replaced.
    var replaceFaceBodyID: BodyID?
    /// Stage 1's pick: the planar face to move, in that body's LOCAL space.
    var replaceSourceFace: PlanarFace?
    /// Stage 2's pick: the plane to move it onto, converted into the SOURCE
    /// body's local space — the target is routinely on a different body, and
    /// comparing a plane from one local space against a face in another is the
    /// kind of mistake that only shows up once two bodies are far apart.
    var replaceTargetPlane: (origin: SIMD3<Double>, normal: SIMD3<Double>)?
    /// Flip Alignment (§4.12): extend to the other side when both readings are
    /// geometrically valid.
    var replaceFaceFlip = false {
        didSet { if replaceFaceFlip != oldValue { updateReplaceFacePreview() } }
    }
    /// Live result, swapped in for the source body. Nil when the kit refuses.
    var replaceFacePreview: Body?
    /// Why the current pick cannot be applied, shown in the bar. Nil = fine.
    var replaceFaceRefusal: String?
    private var replaceFacePreviewRevision: UInt64 = 0

    /// Arm Replace Face: the next tap picks the face to move, the one after
    /// it picks the face to move it onto.
    func beginReplaceFace() {
        cancelTransientPicks()
        cancelTool()
        replaceFaceBodyID = selection.count == 1 ? selection.first : nil
        replaceSourceFace = nil
        replaceTargetPlane = nil
        replaceFaceFlip = false
        replaceFacePreview = nil
        replaceFaceRefusal = nil
        mode = .pickingReplaceFace
    }

    func cancelReplaceFace() {
        guard case .pickingReplaceFace = mode else { return }
        let body = replaceFaceBodyID
        resetReplaceFaceState()
        if let body, session.document.body(with: body) != nil {
            mode = .selected(body)
            selection = [body]
        } else {
            mode = .idle
        }
    }

    /// Internal reset — never touches `selection` (same contract as the other
    /// picks).
    private func resetReplaceFaceState() {
        replaceFaceBodyID = nil
        replaceSourceFace = nil
        replaceTargetPlane = nil
        replaceFacePreview = nil
        replaceFaceRefusal = nil
        if case .pickingReplaceFace = mode { mode = .idle }
    }

    /// Which stage the pick is in, for the bar.
    var replaceFaceStage: Int { replaceSourceFace == nil ? 1 : 2 }

    /// The planar face under a tap, picked against the body's ORIGINAL mesh so
    /// the live preview standing in for it cannot skew the hit.
    private func planarFaceUnderTap(ray: Ray, body: Body) -> PlanarFace? {
        let originalScene = ViewportScene(bodies: [BodyDrawable(
            id: body.id,
            renderMesh: body.render,
            edges: body.edges,
            meshRevision: body.meshRevision,
            modelMatrix: body.transform.matrixFloat,
            baseColor: SIMD4(0.72, 0.74, 0.78, 1),
            selectionState: SelectionStateNone.rawValue
        )])
        guard let hit = HitTester.pickBody(ray: ray, in: originalScene) else { return nil }
        return FaceTopology.planarFace(in: body.render, seedTriangle: hit.triangleIndex)
    }

    /// Move a plane from `from`'s local space into `into`'s. Identity for the
    /// usual case of two feature bodies, but not for a body the user moved.
    private static func convertPlane(
        origin: SIMD3<Double>, normal: SIMD3<Double>,
        from source: Transform3D, into destination: Transform3D
    ) -> (origin: SIMD3<Double>, normal: SIMD3<Double>) {
        let toWorld = source.matrix
        let fromWorld = simd_inverse(destination.matrix)
        let worldOrigin = toWorld * SIMD4(origin, 1)
        let localOrigin = fromWorld * worldOrigin
        // A normal is a direction: rotate it, never translate it.
        let worldNormal = toWorld * SIMD4(normal, 0)
        let localNormal = fromWorld * SIMD4(worldNormal.x, worldNormal.y, worldNormal.z, 0)
        let n = SIMD3<Double>(localNormal.x, localNormal.y, localNormal.z)
        let len = simd_length(n)
        return (SIMD3(localOrigin.x, localOrigin.y, localOrigin.z),
                len > 1e-12 ? n / len : SIMD3<Double>(0, 1, 0))
    }

    private func handleReplaceFaceTap(ray: Ray) {
        guard let hit = HitTester.pickBody(ray: ray, in: scene),
              let body = session.document.body(with: hit.bodyID) else { return }

        // Stage 1 — the face to move. It has to be planar: the kit resolves a
        // replace into the prism between two PARALLEL planes, and a curved
        // face has no single plane to be parallel to.
        guard let source = replaceSourceFace, let sourceID = replaceFaceBodyID else {
            guard let face = planarFaceUnderTap(ray: ray, body: body) else {
                showNotice("Replace Face needs a flat face — tap a planar one.")
                return
            }
            replaceFaceBodyID = body.id
            replaceSourceFace = face
            replaceTargetPlane = nil
            replaceFacePreview = nil
            replaceFaceRefusal = nil
            return
        }

        // Stage 2 — the face to move it ONTO, which may be on another body.
        guard let sourceBody = session.document.body(with: sourceID) else {
            resetReplaceFaceState()
            return
        }
        guard let target = planarFaceUnderTap(ray: ray, body: body) else {
            showNotice("The target has to be a flat face too.")
            return
        }
        let targetNormal = SIMD3<Double>(
            Double(target.normal.x), Double(target.normal.y), Double(target.normal.z))
        replaceTargetPlane = Self.convertPlane(
            origin: target.origin, normal: targetNormal,
            from: body.transform, into: sourceBody.transform)
        _ = source
        updateReplaceFacePreview()
    }

    /// The replaced body for the current pick, plus the refusal text when the
    /// kit says no. Shared by preview and commit.
    private func replacedBody(
        source: Body, revision: UInt64
    ) -> (body: Body?, refusal: String?) {
        guard let face = replaceSourceFace, let target = replaceTargetPlane else {
            return (nil, nil)
        }
        let plan: ReplaceFaceKit.Plan
        do {
            plan = try ReplaceFaceKit.plan(
                face: face, targetOrigin: target.origin,
                targetNormal: target.normal, flip: replaceFaceFlip)
        } catch {
            return (nil, FeatureGraph.replaceRefusalText(error))
        }
        if OCCTKernel.useOCCTAsSourceOfTruth, let brep = source.brep,
           let replaced = ReplaceFaceKit.applyBRep(to: brep, face: face, plan: plan) {
            var result = Body(
                id: source.id, name: source.name, transform: source.transform,
                primitive: nil, render: source.render, revision: revision)
            guard result.adoptBRep(replaced) else {
                return (nil, "the replaced solid could not be built")
            }
            return (result, nil)
        }
        guard let mesh = ReplaceFaceKit.apply(
            to: source.euclidMesh(), face: face, plan: plan), !mesh.polygons.isEmpty else {
            return (nil, "the replaced solid came out empty")
        }
        return (Body(id: source.id, name: source.name, transform: source.transform,
                     primitive: nil, euclidMesh: mesh, revision: revision), nil)
    }

    private func updateReplaceFacePreview() {
        guard case .pickingReplaceFace = mode,
              let bodyID = replaceFaceBodyID,
              let source = session.document.body(with: bodyID)
        else {
            replaceFacePreview = nil
            return
        }
        replaceFacePreviewRevision &+= 1
        let outcome = replacedBody(
            source: source, revision: (1 << 56) | replaceFacePreviewRevision)
        replaceFacePreview = outcome.body
        replaceFaceRefusal = outcome.refusal
    }

    var canCommitReplaceFace: Bool {
        if case .pickingReplaceFace = mode {
            return replaceFacePreview != nil
        }
        return false
    }

    /// Apply the replace and record a `.replaceFace` node for a feature-owned
    /// body so it rebuilds.
    func commitReplaceFace() {
        guard case .pickingReplaceFace = mode,
              let bodyID = replaceFaceBodyID,
              let source = session.document.body(with: bodyID),
              let face = replaceSourceFace,
              let target = replaceTargetPlane
        else { return }

        let after: Body
        if var preview = replaceFacePreview {
            preview.meshRevision = 0 // assigned by the command
            after = preview
        } else {
            let outcome = replacedBody(source: source, revision: 0)
            guard let computed = outcome.body else {
                errorMessage = "Couldn't replace that face — "
                    + (outcome.refusal ?? "the operation failed") + "."
                return
            }
            after = computed
        }
        let replace = ReplaceBodyCommand(title: "Replace Face", before: source, after: after)

        if let owner = featureNode(owning: bodyID) {
            let bodyRef = BodyRef(producer: owner.id, bodyID: bodyID)
            let faceRef = FaceRef(
                body: bodyRef, creator: owner.id, role: .derived(index: 0),
                signature: SignatureNaming.signature(planar: face),
                elementName: mintElementName(body: source,
                                             triangle: face.triangles.first))
            let node = FeatureNode(
                name: "Replace Face",
                kind: .replaceFace(
                    face: faceRef,
                    targetOrigin: PointWrapper(target.origin),
                    targetNormal: PointWrapper(target.normal),
                    flip: replaceFaceFlip),
                outputBodyIDs: [bodyID])
            session.perform(CompositeCommand(
                title: "Replace Face",
                commands: [replace, AppendFeatureCommand(node: node)]))
        } else {
            session.perform(replace)
        }
        resetReplaceFaceState()
        mode = .selected(source.id)
        selection = [source.id]
        session.save()
    }

    /// A `FaceRef` pinning an open face by geometric signature in body-local
    /// space (mirrors `pushPullFaceRef`; role is only a resolve tiebreak).
    private static func shellFaceRef(
        face: PlanarFace, bodyRef: BodyRef, creator: FeatureID,
        elementName: ElementName? = nil
    ) -> FaceRef {
        let n = SIMD3<Double>(
            Double(face.normal.x), Double(face.normal.y), Double(face.normal.z))
        var area = abs(Profile.signedArea(face.outline))
        for hole in face.holes { area -= abs(Profile.signedArea(hole)) }
        let signature = FaceSignature(
            kind: .planar, normal: n, centroid: face.origin,
            area: max(area, 0), planeOffset: simd_dot(n, face.origin))
        return FaceRef(
            body: bodyRef, creator: creator,
            role: .derived(index: 0), signature: signature,
            elementName: elementName)
    }

    /// Distance from a point to a segment (both body-local).
    /// Screen-sized edge target for a plain tap: within `edgeTapPoints` of
    /// a sharp edge the tap means that edge, not the face beside it. Kept
    /// tight (a thin wall at model-mode zoom is only a few points tall, and
    /// its centre must still read as the wall — CylinderGrowShotUITests),
    /// and limited to sharp dihedrals so tessellation seams never count.
    static let edgeTapPoints: Double = 5
    static let edgeTapMinimumDihedralDegrees: Float = 45

    private func tapIsNearBodyEdge(hit: PickHit, body: Body) -> Bool {
        // Only from a flat face: a tap on a curved wall is the wall (its
        // rims are exactly where an edge-on view puts a wall tap, and the
        // radial edit is what the wall means — CylinderGrowShotUITests).
        // The native rim click observed 2026-09-13 was from the cap side.
        if FaceTopology.smoothRegion(in: body.render, seedTriangle: hit.triangleIndex)?.isCurved == true {
            return false
        }
        let flattest = cos(Self.edgeTapMinimumDihedralDegrees * .pi / 180)
        let sharp = EdgeTopology.selectableEdges(from: body.render).filter {
            simd_dot($0.normalA, $0.normalB) <= flattest
        }
        guard !sharp.isEmpty else { return false }
        // Measured in WORLD units at the camera's current scale, never on
        // screen: a screen-space test has no depth, and perspective draws a
        // box's hidden bottom edges inward under its top face, where a tap
        // on the face lands within a few points of them (PlanesUITests
        // testSketchOnFaceThenExtrudeNewBody, 2026-09-13).
        let inverse = simd_inverse(body.transform.matrixFloat)
        let local4 = inverse * SIMD4(hit.worldPoint, 1)
        let local = SIMD3<Float>(local4.x, local4.y, local4.z)
        let tolerance = Float(Self.edgeTapPoints * worldPerPoint / max(body.transform.scale, 1e-9))
        return sharp.contains { Self.pointSegmentDistance(local, $0.start, $0.end) <= tolerance }
    }

    private static func pointSegmentDistance(
        _ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>
    ) -> Float {
        let ab = b - a
        let len2 = simd_dot(ab, ab)
        guard len2 > 1e-12 else { return simd_length(p - a) }
        let t = max(0, min(1, simd_dot(p - a, ab) / len2))
        return simd_length(p - (a + ab * t))
    }

    /// Tap while the split pick is armed: plane tiles win over the body
    /// (cutter planes usually pass through it), then profile fills. Taps that
    /// miss every cutter keep the pick armed.
    private func handleSplitCutterTap(target: BodyID, ray: Ray) {
        guard let body = session.document.body(with: target) else {
            mode = .idle
            return
        }
        let world = body.euclidMesh().transformed(by: body.transform.euclid)
        let tiles = worldPlaneTiles + constructionPlaneTiles
        if let hit = PlanePicking.pick(ray: ray, tiles: tiles) {
            let halves = KernelOps.split(body: world, byPlane: hit.tile.plane)
            performSplit(of: body, halves: (halves.kept, halves.other))
            return
        }
        if let fill = profileHit(ray: ray) {
            let halves = KernelOps.split(
                body: world, byProfile: fill.profile, holes: fill.holes, in: fill.plane
            )
            performSplit(of: body, halves: (halves.inside, halves.outside))
        }
    }

    /// Replace the body with the first half and add the second as a new body
    /// (one undo step — Keep Originals is what undo restores); both halves
    /// end up selected. Halves are named "<name> A" / "<name> B" so the Items
    /// Manager shows where they came from.
    private func performSplit(of body: Body, halves: (Euclid.Mesh, Euclid.Mesh)) {
        guard !halves.0.polygons.isEmpty, !halves.1.polygons.isEmpty else {
            errorMessage = "The cutter doesn't pass through the body — nothing to split."
            return
        }
        var document = session.document // local: unique name + revision
        // First half keeps the original pivot (like commitToolResult).
        let pivotA = body.transform.translation
        var transformA = Transform3D.identity
        transformA.translation = pivotA
        let first = Body(
            id: body.id,
            name: document.uniqueBodyName(base: "\(body.name) A"),
            transform: transformA,
            primitive: nil,
            euclidMesh: halves.0.translated(by: Vector(-pivotA.x, -pivotA.y, -pivotA.z)),
            revision: 0 // assigned by the command
        )
        // Second half pivots at its own bounds center.
        let boundsB = halves.1.bounds
        let pivotB = SIMD3(
            (boundsB.min.x + boundsB.max.x) / 2,
            (boundsB.min.y + boundsB.max.y) / 2,
            (boundsB.min.z + boundsB.max.z) / 2
        )
        var transformB = Transform3D.identity
        transformB.translation = pivotB
        let second = Body(
            name: document.uniqueBodyName(base: "\(body.name) B"),
            transform: transformB,
            primitive: nil,
            euclidMesh: halves.1.translated(by: Vector(-pivotB.x, -pivotB.y, -pivotB.z)),
            revision: document.nextRevision()
        )
        session.perform(CompositeCommand(title: "Split", commands: [
            ReplaceBodyCommand(title: "Split", before: body, after: first),
            AddBodyCommand(body: second, title: "Split"),
        ]))
        selection = [body.id, second.id]
        mode = .idle
        session.save()
    }

    // MARK: - Pattern (plan §B5, spec §5.7 bodies / §1.11 sketch profiles, v1)

    struct PatternState {
        enum Kind: String, CaseIterable {
            case linear = "Linear"
            case circular = "Circular"
        }

        /// A construction axis chosen instead of a world axis. The manual's
        /// own first stated reason to build one is "creating an axis for a
        /// circular pattern" (spec §6.2), and unlike X/Y/Z it carries a
        /// POSITION — so the pattern can spin about something other than the
        /// world origin, which is all v1 could do.
        var constructionAxisID: ConstructionAxisID?

        enum Axis: String, CaseIterable {
            case x = "X"
            case y = "Y"
            case z = "Z"

            var direction: SIMD3<Double> {
                switch self {
                case .x: SIMD3(1, 0, 0)
                case .y: SIMD3(0, 1, 0)
                case .z: SIMD3(0, 0, 1)
                }
            }

            /// In-plane direction for sketch patterns (Z folds onto X).
            var sketchDirection: SIMD2<Double> {
                self == .y ? SIMD2(0, 1) : SIMD2(1, 0)
            }
        }

        var kind: Kind = .linear
        var axis: Axis = .x
        /// Total instances, original included.
        var count = 3
        /// Adjacent-center distance (linear).
        var spacing = 6.0
        /// First→last sweep in degrees (circular; 360 closes the ring).
        var totalAngle = 360.0
        /// Body being patterned; nil for a sketch-profile pattern.
        var bodyID: BodyID?
        /// Sketch-profile pattern (armed from extrude mode): source sketch
        /// plus the profile's entities.
        var sketchID: SketchID?
        var entityIDs: Set<UUID> = []

        var isSketchPattern: Bool { bodyID == nil }
    }

    var patternState: PatternState? {
        didSet { fitCameraToPatternGhosts() }
    }

    /// Keep every ghost instance in frame while the pattern bar is up —
    /// param changes can push instances far outside the current view.
    private func fitCameraToPatternGhosts() {
        guard case .patterning = mode, let state = patternState,
              let bodyID = state.bodyID,
              let body = session.document.body(with: bodyID)
        else { return }
        let aabb = body.render.localAABB
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = -lo
        for transform in patternTransforms(state) {
            let matrix = Self.composedPatternTransform(transform, base: body.transform).matrixFloat
            for i in 0..<8 {
                let corner = SIMD3<Float>(
                    (i & 1) == 0 ? aabb.min.x : aabb.max.x,
                    (i & 2) == 0 ? aabb.min.y : aabb.max.y,
                    (i & 4) == 0 ? aabb.min.z : aabb.max.z
                )
                let world = matrix * SIMD4(corner, 1)
                lo = simd_min(lo, SIMD3(world.x, world.y, world.z))
                hi = simd_max(hi, SIMD3(world.x, world.y, world.z))
            }
        }
        guard lo.x <= hi.x else { return }
        cameraControl?.fitTo(bounds: (lo, hi))
    }

    /// True when the palette Pattern action applies: one body selected, or a
    /// sketch profile armed in the extrude tool.
    var canBeginPattern: Bool {
        if selection.count == 1 { return true }
        if case .extruding = mode, let context = toolContext,
           case .extrude = context.kind, context.sketchID != nil {
            return true
        }
        return false
    }

    /// "Pattern" in the palette: opens the pattern bar for the selected body,
    /// or — while a profile fill is armed for extrude — for the profile's
    /// sketch entities (patterned in-plane, spec §1.11).
    func beginPattern() {
        cancelTransientPicks()
        if case .extruding = mode, let context = toolContext,
           case .extrude = context.kind, let sketchID = context.sketchID {
            var ids = context.profile.sourceEntityIDs
            for hole in context.holes {
                ids.formUnion(hole.sourceEntityIDs)
            }
            guard !ids.isEmpty else { return }
            cancelTool()
            var state = PatternState()
            state.sketchID = sketchID
            state.entityIDs = ids
            patternState = state
            mode = .patterning
            return
        }
        guard selection.count == 1, let id = selection.first,
              session.document.body(with: id) != nil
        else { return }
        cancelTool()
        var state = PatternState()
        state.bodyID = id
        patternState = state
        mode = .patterning
        fitCameraToPatternGhosts() // mode wasn't set yet during didSet
    }

    func cancelPattern() {
        patternState = nil
        if case .patterning = mode {
            mode = .idle
        }
    }

    /// The rotation line a pattern should use: a chosen construction axis if
    /// one is set and still exists, else the world axis through the origin.
    ///
    /// Falling back when the axis has been DELETED matters — the pattern bar
    /// can outlive the axis it references, and silently spinning about the
    /// origin is better than crashing or freezing the preview.
    func patternAxisLine(_ state: PatternState) -> (direction: SIMD3<Double>, center: SIMD3<Double>) {
        if let id = state.constructionAxisID,
           let axis = session.document.axes.first(where: { $0.id == id }) {
            return (axis.direction, axis.origin)
        }
        return (state.axis.direction, .zero)
    }

    /// 3D instance transforms for the current parameters; the first is always
    /// identity (the original).
    private func patternTransforms(_ state: PatternState) -> [Transform3D] {
        let line = patternAxisLine(state)
        switch state.kind {
        case .linear:
            return PatternKit.linearTransforms(
                direction: line.direction,
                spacing: state.spacing,
                count: max(1, state.count)
            )
        case .circular:
            return PatternKit.circularTransforms(
                center: line.center,
                axis: line.direction,
                count: max(1, state.count),
                totalAngle: state.totalAngle * .pi / 180,
                rotateInstances: true
            )
        }
    }

    /// Sketch-space instance transforms (spec §1.11); circular patterns spin
    /// about the sketch-plane origin in v1.
    private func sketchPatternTransforms(_ state: PatternState) -> [SketchPatternTransform] {
        switch state.kind {
        case .linear:
            return PatternKit.linearSketchTransforms(
                direction: state.axis.sketchDirection,
                spacing: state.spacing,
                count: max(1, state.count)
            )
        case .circular:
            return PatternKit.circularSketchTransforms(
                center: .zero,
                count: max(1, state.count),
                totalAngle: state.totalAngle * .pi / 180,
                rotateInstances: true
            )
        }
    }

    /// Pattern transform composed onto a body transform:
    /// world = q.act(base(x)) + t, so rotation/translation pre-compose.
    nonisolated static func composedPatternTransform(
        _ pattern: Transform3D, base: Transform3D
    ) -> Transform3D {
        var result = base
        result.rotation = simd_normalize(pattern.rotation * base.rotation)
        result.translation = pattern.rotation.act(base.translation) + pattern.translation
        return result
    }

    /// Commit the armed pattern: one CompositeCommand adding count−1
    /// instances (bodies, or transformed sketch entities).
    func commitPattern() {
        guard case .patterning = mode, let state = patternState else { return }
        guard state.count >= 2 else {
            errorMessage = "Pattern needs a quantity of at least 2."
            return
        }
        if state.isSketchPattern {
            commitSketchPattern(state)
        } else {
            commitBodyPattern(state)
        }
    }

    private func commitBodyPattern(_ state: PatternState) {
        guard let bodyID = state.bodyID,
              let body = session.document.body(with: bodyID)
        else {
            cancelPattern()
            return
        }
        var document = session.document // local: unique names + revisions
        var commands: [DocumentCommand] = []
        var ids: Set<BodyID> = [body.id]
        // Ordered copy ids (instance 1..<count) so the recorded feature node's
        // outputBodyIDs line up with `evalPattern`, which emits copies at
        // outputBodyIDs[i-1] for transform i. Same ids are used for both the
        // AddBodyCommand geometry and the recorded node, so replay reuses them.
        var copyIDs: [BodyID] = []
        for transform in patternTransforms(state).dropFirst() {
            var copy = Body(
                id: BodyID(),
                name: document.uniqueBodyName(base: body.name),
                transform: Self.composedPatternTransform(transform, base: body.transform),
                primitive: body.primitive,
                render: body.render,
                revision: document.nextRevision()
            )
            copy.euclid = body.euclid
            // Same reasoning as `FeatureGraph.evalPattern`: a copy is the same
            // body-local solid at a different placement, so it shares the
            // source's brep. Without this the LIVE pattern silently dropped
            // analytic geometry on every copy while replay kept it — the two
            // paths must agree, or a rebuild would change the model.
            copy.brep = body.brep
            document.bodies.append(copy) // keeps the next name unique
            commands.append(AddBodyCommand(body: copy, title: "Pattern"))
            ids.insert(copy.id)
            copyIDs.append(copy.id)
        }
        guard !commands.isEmpty else { return }
        // Phase D: record a `.pattern` history node when the SOURCE body is
        // feature-owned, so the copies rebuild associatively (and the panel can
        // edit count/spacing/angle). Bundled into the SAME CompositeCommand so a
        // single undo drops every copy + the node. A pattern of an imported /
        // copied body can't be replayed, so it stays geometry-only.
        if let owner = featureNode(owning: bodyID) {
            let patternNode = FeatureNode(
                name: "Pattern",
                kind: .pattern(
                    body: BodyRef(producer: owner.id, bodyID: bodyID),
                    spec: patternSpec(from: state)
                ),
                outputBodyIDs: copyIDs
            )
            commands.append(AppendFeatureCommand(node: patternNode))
        }
        session.perform(CompositeCommand(title: "Pattern", commands: commands))
        patternState = nil
        selection = ids
        mode = .idle
        session.save()
    }

    private func commitSketchPattern(_ state: PatternState) {
        guard let sketchID = state.sketchID,
              let sketch = session.document.sketches.first(where: { $0.id == sketchID })
        else {
            cancelPattern()
            return
        }
        let entities = sketch.entities.filter { state.entityIDs.contains($0.id) }
        guard !entities.isEmpty else {
            cancelPattern()
            return
        }
        var commands: [DocumentCommand] = []
        for transform in sketchPatternTransforms(state).dropFirst() {
            for entity in entities {
                for copy in PatternKit.transformed(entity, by: transform) {
                    commands.append(AddSketchEntityCommand(sketchID: sketchID, entity: copy))
                }
            }
        }
        guard !commands.isEmpty else { return }
        session.perform(CompositeCommand(title: "Pattern", commands: commands))
        patternState = nil
        mode = .idle
        session.save()
    }

    // MARK: - Profile fills (cached per sketch content)

    private var fillCache: [SketchID: (
        entities: [SketchEntity], construction: Set<UUID>, batches: [SketchFillBatch]
    )] = [:]

    private func fillBatches(for sketch: Sketch) -> [SketchFillBatch] {
        if let cached = fillCache[sketch.id], cached.entities == sketch.entities,
           cached.construction == sketch.constructionEntityIDs {
            return cached.batches
        }
        let profiles = ProfileDetector.detectProfiles(in: sketch)
        var batches: [SketchFillBatch] = []
        let fillColor = SIMD4<Float>(0.36, 0.58, 0.92, 0.28)
        for profile in profiles {
            let holes = ProfileDetector.holes(of: profile, among: profiles)
            let triangles = SketchTessellator.fillTriangles(
                for: profile, holes: holes, on: sketch.plane
            )
            if !triangles.isEmpty {
                batches.append(SketchFillBatch(triangles: triangles, color: fillColor))
            }
        }
        fillCache[sketch.id] = (sketch.entities, sketch.constructionEntityIDs, batches)
        return batches
    }

    // MARK: - Toolbar actions

    func deleteSelection() {
        if case .sketching = mode {
            // A selected constraint/dimension glyph deletes first (undoable).
            if let cid = selectedConstraintID {
                deleteConstraint(cid)
                return
            }
            if let did = selectedDimensionID {
                deleteDimension(did)
                return
            }
            guard !selectedSketchEntityIDs.isEmpty, let sketch = activeSketch else { return }
            // Phase D: deleting sketch entities changes referenced profiles —
            // the dependent-feature rebuild lands in the SAME undo step (S6).
            session.performWithSketchRebuild(
                RemoveSketchEntitiesCommand(ids: selectedSketchEntityIDs, sketch: sketch),
                sketchID: sketch.id)
            selectedSketchEntityIDs.removeAll()
            return
        }
        if let image = selectedImage {
            deleteImage(image.id)
            return
        }
        if let plane = selectedPlane {
            selectedPlaneID = nil
            deleteItem(.plane(plane.id))
            return
        }
        // Sketch entities picked with the Select tool (tap or marquee) delete
        // OUTSIDE sketch mode too — one undo step across their owning sketches.
        if !selectedSketchEntityIDs.isEmpty {
            var commands: [DocumentCommand] = []
            var touchedSketchIDs: [SketchID] = []
            for sketch in session.document.sketches {
                let ids = Set(sketch.entities.map(\.id)).intersection(selectedSketchEntityIDs)
                guard !ids.isEmpty else { continue }
                commands.append(RemoveSketchEntitiesCommand(ids: ids, sketch: sketch))
                touchedSketchIDs.append(sketch.id)
            }
            if !selection.isEmpty {
                cancelTransientPicks()
                commands.append(DeleteBodiesCommand(ids: selection, document: session.document))
            }
            guard !commands.isEmpty else { return }
            // Delete + dependent-feature rebuild in ONE undo step (S6). One
            // rebuild covers every touched sketch — the replay is whole-graph.
            session.performWithSketchRebuild(
                commands.count == 1
                    ? commands[0]
                    : CompositeCommand(title: "Delete", commands: commands),
                sketchIDs: Set(touchedSketchIDs))
            selectedSketchEntityIDs.removeAll()
            selection.removeAll()
            cancelTool()
            mode = .idle
            return
        }
        guard !selection.isEmpty else { return }
        // Revert any transient preview first (the rotate preview mutates
        // transforms outside undo) so the delete captures clean state.
        cancelTransientPicks()
        session.perform(DeleteBodiesCommand(ids: selection, document: session.document))
        selection.removeAll()
        // Clear any active extrude/face tool so its on-screen pill + pull arrow
        // disappear with the deleted body (they key off toolContext, not mode).
        cancelTool()
        mode = .idle
    }

    func undo() {
        if isPickingSymmetryAxis { cancelSymmetryAxisPick(); return }
        if hasPendingRectangle { clearRectanglePlacement(); return }
        // Native three-point construction leaves drawing mode when Undo
        // changes committed history. Pending-placement cancellation above
        // remains separate and does not consume document history.
        if mode.sketchTool == .rect && rectangleType == .threePoint {
            deselectSketchTool()
        } else if mode.sketchTool == .circle && selectedCircleCenterID != nil {
            // Only the armed, freshly selected center workflow is live-proven
            // to disarm and clear on Undo. Ordinary radial/transform history
            // retains its existing selection/readout lifecycle.
            deselectSketchTool()
            selectedSketchPoints.removeAll()
            selectedSketchEntityIDs.removeAll()
            selectedDimensionID = nil
            selectedConstraintID = nil
            editingDimension = nil
        }
        // Direct radius Unlock while Circle is armed clears/disarms on native
        // Undo. Keep this scoped to that command, not radial drag/transform history.
        if mode.sketchTool == .circle, !sketchTransformActive,
           let removal = session.undoStack.undoCommands.last as? RemoveSketchDimensionCommand,
           removal.sketchID == activeSketch?.id, removal.dimension.kind == .radius,
           removal.dimension.refs.count == 1,
           let id = removal.dimension.refs.first?.entityID,
           selectedSketchEntityIDs.contains(id), let sketch = activeSketch,
           case .circle? = sketchEntity(id, in: sketch) {
            deselectSketchTool()
            clearCircleNumericSelection()
        }
        clearCircleNumericSelection(for: session.undoStack.undoCommands.last)
        clearLineDimensionSelection(for: session.undoStack.undoCommands.last)
        clearAppliedRelationSelection(for: session.undoStack.undoCommands.last)
        clearItemRenameSelection(for: session.undoStack.undoCommands.last)
        prepareForHistoryChange()
        session.undo()
        sanitizeAfterHistoryChange()
    }

    func redo() {
        clearCircleNumericSelection(for: session.undoStack.redoCommands.last)
        clearLineDimensionSelection(for: session.undoStack.redoCommands.last)
        clearAppliedRelationSelection(for: session.undoStack.redoCommands.last)
        clearItemRenameSelection(for: session.undoStack.redoCommands.last)
        prepareForHistoryChange()
        session.redo()
        sanitizeAfterHistoryChange()
    }

    private func clearItemRenameSelection(for command: DocumentCommand?) {
        guard let rename = command as? RenameItemCommand,
              let item = rename.item else { return }
        if case .sketch = item {
            // Native model-mode sketch-name history drops its item selection.
            // Active sketch/tool history retains its existing semantics.
            if case .idle = mode {
                itemSelectedSketchID = nil
                selectedSketchEntityIDs.removeAll()
                selectedSketchPoints.removeAll()
            }
            return
        }
        guard case .body = item else { return }
        // Native body-name history deselects; do not change active tool history.
        switch mode {
        case .selected, .editingPrimitive, .idle:
            selection.removeAll()
            mode = .idle
        default:
            break
        }
    }

    private func clearLineDimensionSelection(for command: DocumentCommand?) {
        guard let change = command as? SetLineDimensionKindCommand,
              change.sketchID == activeSketch?.id else { return }
        selectedSketchEntityIDs.removeAll()
        selectedSketchPoints.removeAll()
        selectedDimensionID = nil
        selectedConstraintID = nil
        editingDimension = nil
    }

    private func clearAppliedRelationSelection(for command: DocumentCommand?) {
        guard mode.isSketching, let sketchID = activeSketch?.id else { return }
        func addsDeselectingRelation(_ command: DocumentCommand) -> Bool {
            if let group = command as? CompositeCommand {
                return group.commands.contains(where: addsDeselectingRelation)
            }
            guard let addition = command as? AddSketchConstraintCommand else { return false }
            return addition.sketchID == sketchID && clearsSelectionAfterApplying(addition.constraint)
        }
        guard let command, addsDeselectingRelation(command) else { return }
        clearAppliedRelationSelection()
    }

    private func clearAppliedRelationSelection() {
        selectedSketchEntityIDs.removeAll()
        selectedSketchPoints.removeAll()
        selectedDimensionID = nil
        selectedConstraintID = nil
        editingDimension = nil
    }

    private func clearsSelectionAfterApplying(_ constraint: SketchConstraint) -> Bool {
        let ordinaryAxisAlignment = (constraint.kind == .horizontal || constraint.kind == .vertical) && constraint.refs.count == 1 &&
            constraint.refs[0].role == .whole && activeSketch?.entities.contains(where: {
                if case .line = $0 { return $0.id == constraint.refs[0].entityID }
                return false
            }) == true
        let ordinaryParallelPair = constraint.kind == .parallel && constraint.refs.count == 2 &&
            constraint.refs.allSatisfy { ref in
                ref.role == .whole && activeSketch?.entities.contains(where: {
                    if case .line = $0 { return $0.id == ref.entityID }
                    return false
                }) == true
            }
        let shapePointPair = constraint.kind == .coincident && constraint.refs.count == 2 &&
            constraint.refs.allSatisfy { $0.role != .whole } &&
            constraint.refs.contains { ref in
                activeSketch?.entities.contains { entity in
                    if case .line = entity { return entity.id == ref.entityID }
                    return false
                } == true
            } &&
            constraint.refs.contains { ref in
                activeSketch?.entities.contains { entity in
                    guard entity.id == ref.entityID else { return false }
                    switch entity { case .circle, .rect: return true; default: return false }
                } == true
            }
        return ordinaryAxisAlignment || ordinaryParallelPair || shapePointPair || constraint.kind == .perpendicular || constraint.kind == .midpoint ||
            constraint.kind == .tangent || constraint.kind == .concentric ||
            (constraint.kind == .coincident && constraint.refs.count == 2 &&
             constraint.refs.filter { $0.role == .whole }.count == 1)
    }

    /// The paired disarmed-circle numeric workflow clears its rim/readout on
    /// commit and history. Do not apply this to free radial drags or transforms.
    private func clearCircleNumericSelection(for command: DocumentCommand?) {
        guard mode.isSketching, mode.sketchTool == nil, !sketchTransformActive,
              let sketch = activeSketch, let command else { return }
        func affectsSelectedCircle(_ command: DocumentCommand) -> Bool {
            if let group = command as? CompositeCommand {
                return group.commands.contains(where: affectsSelectedCircle)
            }
            let dimension: SketchDimension
            let sketchID: SketchID
            if let add = command as? AddSketchDimensionCommand {
                dimension = add.dimension; sketchID = add.sketchID
            } else if let update = command as? UpdateSketchDimensionCommand {
                dimension = update.after; sketchID = update.sketchID
            } else { return false }
            guard sketchID == sketch.id, dimension.refs.count == 1,
                  dimension.kind == .radius || dimension.kind == .diameter,
                  let id = dimension.refs.first?.entityID,
                  selectedSketchEntityIDs.contains(id) || selectedSketchPoints.contains(where: { $0.entityID == id }),
                  case .circle? = sketchEntity(id, in: sketch) else { return false }
            return true
        }
        if affectsSelectedCircle(command) { clearCircleNumericSelection() }
    }

    private func clearCircleNumericSelection() {
        selectedSketchEntityIDs.removeAll()
        selectedSketchPoints.removeAll()
        selectedDimensionID = nil
        selectedConstraintID = nil
        retainedCircleCenterReadoutID = nil
        editingDimension = nil
    }

    /// MUST run BEFORE any history mutation (undo/redo/rollback). An armed
    /// rotate-axis tool has applied its preview to the document via
    /// `session.preview` (outside the undo stack) and holds `before`
    /// transforms captured against the CURRENT document. Restoring that
    /// baseline now — while the document still matches it — cleanly reverts
    /// the preview; restoring it AFTER the history change would silently
    /// re-apply pre-change transforms the undo/rollback just removed
    /// (2026-08-25 review, finding C3).
    private func prepareForHistoryChange() {
        cancelSymmetryAxisPick()
        retainedCircleCenterReadoutID = nil
        if selectedSketchPoints.count == 1,
           let point = selectedSketchPoints.first, point.role == .center,
           let sketch = activeSketch, sketch.rotatedRectangleEdges[point.entityID] != nil,
           sketch.rectangleSizingAnchors[point.entityID] == nil {
            selectedSketchPoints.removeAll()
            selectedSketchEntityIDs.removeAll()
            selectedDimensionID = nil
            selectedConstraintID = nil
            editingDimension = nil
        }
        // Direct migrated-corner history clears the endpoint/readouts in
        // native, just as explicit transform history clears its selection.
        if selectedMigratedRectangleCornerEdges != nil {
            selectedSketchPoints.removeAll()
            selectedDimensionID = nil
            selectedConstraintID = nil
            editingDimension = nil
        }
        // Native drops the operation selection/value but keeps Move/Rotate
        // armed: selecting another sketch entity restores transform controls.
        if sketchTransformActive {
            selectedSketchEntityIDs.removeAll()
            selectedSketchPoints.removeAll()
            retainedSketchTransform = nil
            sketchCopyOnDrag = false
            editingDimension = nil
        }
        activeSketchTransformControl = nil
        clearRectanglePlacement()
        if case .rotatingAroundAxis = mode { cancelRotateAxis() }
    }

    private func sanitizeAfterHistoryChange() {
        // Face/tool contexts reference geometry that may have changed.
        cancelTool()
        // A blend/shell/offset/axis pick references geometry that may have changed.
        resetBlendState()
        resetShellState()
        resetDeleteFaceState()
        resetReplaceFaceState()
        resetSketchOffsetState()
        resetAxisState()
        axisEntryPart = nil
        scaleEntryActive = false
        // Pending sketch state may reference entities that no longer exist.
        pendingArc = nil
        arcTapStart = nil
        if arcEndpointHoverPreviewActive {
            pendingEntity = nil
            arcEndpointHoverPreviewActive = false
        }
        adjustingArcBulge = false
        clearChain()
        sketchEntityDrag = nil
        sketchGizmoDrag = nil
        let liveEntityIDs = Set(session.document.sketches.flatMap { $0.entities.map(\.id) })
        selectedSketchEntityIDs = selectedSketchEntityIDs.intersection(liveEntityIDs)
        selectedSketchPoints = selectedSketchPoints.filter { liveEntityIDs.contains($0.entityID) }
        // A selected constraint/dimension may have been undone away.
        let liveConstraintIDs = Set(session.document.sketches.flatMap { $0.constraints.map(\.id) })
        let liveDimensionIDs = Set(session.document.sketches.flatMap { $0.dimensions.map(\.id) })
        if let cid = selectedConstraintID, !liveConstraintIDs.contains(cid) { selectedConstraintID = nil }
        if let did = selectedDimensionID, !liveDimensionIDs.contains(did) { selectedDimensionID = nil }
        // Selection/mode may reference bodies that no longer exist.
        let liveIDs = Set(session.document.bodies.map(\.id))
        selection = selection.intersection(liveIDs)
        // The selected image (and any pending drag baseline) may be undone away.
        imageInteractionBaseline = nil
        imageInteractionPerformed = false
        if let imageID = selectedImageID, session.document.imageIndex(of: imageID) == nil {
            selectedImageID = nil
        }
        if let planeID = selectedPlaneID, !session.document.planes.contains(where: { $0.id == planeID }) {
            selectedPlaneID = nil
        }
        // Isolation over undone-away bodies would blank the scene — drop the
        // dead ids, and the whole override once nothing is left isolated.
        if let isolated = isolatedBodyIDs {
            let alive = isolated.intersection(liveIDs)
            isolatedBodyIDs = alive.isEmpty ? nil : alive
        }
        switch mode {
        case .editingPrimitive(let id) where !liveIDs.contains(id),
             .selected(let id) where !liveIDs.contains(id),
             .pickingSplitCutter(let id) where !liveIDs.contains(id):
            mode = .idle
        case .sketching(let id, _)
            where !session.document.sketches.contains(where: { $0.id == id }):
            mode = .idle
        case .patterning:
            // The pattern source (body or sketch) may have been undone away.
            let valid: Bool
            if let bodyID = patternState?.bodyID {
                valid = liveIDs.contains(bodyID)
            } else if let sketchID = patternState?.sketchID {
                valid = session.document.sketches.contains { $0.id == sketchID }
            } else {
                valid = false
            }
            if !valid {
                patternState = nil
                mode = .idle
            }
        case .rotatingAroundAxis:
            // Unreachable from undo/redo/rollback (prepareForHistoryChange
            // cancelled the tool BEFORE the change). Defensive only: drop the
            // state WITHOUT writing the baseline back — post-change it is
            // stale, and re-applying it would corrupt the document (C3).
            rotateAxisState = nil
            mode = .idle
        case .translating:
            cancelTranslate()
        case .aligning:
            cancelAlign()
        default:
            break
        }
    }

    // MARK: - Viewport events

    func handle(_ event: ViewportEvent) {
        switch event {
        case .tap(let ray):
            handleTap(ray: ray)
        case .doubleTap(let ray):
            handleDoubleTap(ray: ray)
        }
    }

    func fitView() {
        cameraControl?.fitScene()
    }

    // MARK: - Views popover (standard views + projection, spec §7.3)

    /// Orthographic projection toggle state (mirrored to the camera).
    var orthographicEnabled = false

    /// True while sketching with the camera off head-on; shows the Look at
    /// Sketch button. Maintained by the viewport as the camera moves AND
    /// recomputed on sketch entry — entering a sketch no longer moves the
    /// camera, so waiting for motion would hide the affordance exactly when
    /// an angled view makes it most useful.
    var lookAtSketchAvailable = false

    /// Degrees off head-on past which Look at Sketch is offered. Shared with
    /// the viewport so the button's appearance and the angle it reports agree.
    static let lookAtSketchThresholdDegrees: Double = 10

    func applyStandardView(_ view: StandardView) {
        // Shapr3D (observed 2026-09-13, seven trials): a named view that is
        // not the active sketch's head-on view or its underside ends the
        // sketch — Front, Right and the oblique home view all did; Top and
        // Bottom on a ground sketch did not, and free rotation never does.
        // Without this the sketch stayed open edge-on, where taps place
        // nothing. Free orbit keeps the sketch and offers Look at Sketch.
        if case .sketching = mode, let plane = activeSketch?.plane,
           !view.isHeadOn(to: plane) {
            finishSketch()
        }
        cameraControl?.animateToStandardView(view)
    }

    func setOrthographic(_ enabled: Bool) {
        orthographicEnabled = enabled
        cameraControl?.setProjection(orthographic: enabled)
    }

    /// Re-aim the camera head-on at the active sketch plane.
    func lookAtSketch() {
        guard let plane = activeSketch?.plane else { return }
        cameraControl?.moveCameraHeadOn(to: plane)
    }

    // MARK: - Display modes & Isolate (spec §16.2/§16.4, plan §B12)

    /// Viewport shading mode; mirrored into the scene every rebuild. Not
    /// persisted — a reopened design starts Shaded, like Shapr3D.
    var displayMode: DisplayMode = .shaded

    /// Extra low-alpha edge pass with a reversed depth test (spec §16.4).
    var showHiddenEdges = false

    /// Ground blob shadows (plan §B15); mirrored into the scene every
    /// rebuild. Not persisted, like the display mode.
    var groundShadowEnabled = false

    // MARK: - Materials (plan §B15)

    /// Material sheet presentation flag (Material palette action).
    var showMaterialSheet = false

    /// The material the sheet opens on: the first selected body's, or the
    /// document default.
    var materialForSelection: BodyMaterialSpec {
        for body in session.document.bodies where selection.contains(body.id) {
            return body.material ?? .default
        }
        return .default
    }

    /// Material sheet Apply: one undo step over the whole selection.
    func applyMaterial(_ spec: BodyMaterialSpec) {
        guard !selection.isEmpty else { return }
        session.perform(SetMaterialCommand(
            bodyIDs: selection, material: spec.clamped, document: session.document
        ))
    }

    /// Isolate (spec §16.2): while non-nil, only these bodies render; exit
    /// restores everything. A transient view-model override — persisted
    /// per-item visibility (SetItemVisibility) is untouched.
    private(set) var isolatedBodyIDs: Set<BodyID>?

    var isIsolateActive: Bool { isolatedBodyIDs != nil }

    /// Hide everything except the current selection.
    func enterIsolate() {
        guard !selection.isEmpty else { return }
        isolatedBodyIDs = selection
    }

    func exitIsolate() {
        isolatedBodyIDs = nil
    }

    // MARK: - Section View (spec §16.1, plan §B11)

    /// Section plane: the picked plane plus a pull offset along its normal.
    /// Not persisted; Section Off restores the full model.
    struct SectionState: Equatable {
        var basePlane: SketchPlane
        /// Pull-arrow travel along the (unflipped) base-plane normal.
        var offset: Double = 0
        /// Flip badge: keep the other side instead.
        var flipped = false
        /// On-screen plane rectangle size (sized to the scene at pick time).
        var size: Double = 8

        /// The base plane shifted by the current offset.
        var plane: SketchPlane {
            var plane = basePlane
            plane.origin += simd_normalize(basePlane.normal) * offset
            return plane
        }
    }

    private(set) var sectionState: SectionState?
    /// Axis param where the section-arrow drag grabbed (nil = screen-space
    /// fallback), and the offset when it began — the offset-plane pattern.
    private var sectionDragAnchor: Float?
    private var sectionDragStartOffset: Double = 0

    /// "Section" in the Views menu: show the plane tiles; the next tap on a
    /// tile or a planar face becomes the section plane.
    func beginSectionPlanePick() {
        cancelTool()
        cancelTransientPicks()
        selection.removeAll()
        mode = .pickingSectionPlane
    }

    func cancelSectionPlanePick() {
        if case .pickingSectionPlane = mode {
            mode = .idle
        }
    }

    /// Flip badge: switch which side of the plane stays visible.
    func flipSection() {
        sectionState?.flipped.toggle()
    }

    /// Section off: restore the full model.
    func endSection() {
        sectionState = nil
        sectionDragAnchor = nil
        cancelSectionPlanePick()
    }

    /// Tap routing while Section View waits for its plane: a world or
    /// construction plane tile, or a planar body face (spec §16.1).
    private func handleSectionPlanePick(ray: Ray) {
        let tiles = worldPlaneTiles + constructionPlaneTiles
        let tileHit = PlanePicking.pick(ray: ray, tiles: tiles)
        let bodyHit = HitTester.pickBody(ray: ray, in: scene)

        let picked: SketchPlane?
        if let tileHit, bodyHit == nil || tileHit.distance <= bodyHit!.distance + 1e-3 {
            picked = tileHit.tile.plane
        } else if let bodyHit {
            picked = worldFacePlane(bodyID: bodyHit.bodyID, triangleIndex: bodyHit.triangleIndex)
        } else {
            picked = nil
        }
        // Taps that miss keep the picker armed (Cancel dismisses it).
        guard let plane = picked else { return }

        // Rectangle sized to cover the model from wherever the plane sits.
        var size = 8.0
        if let bounds = scene.worldBounds {
            size = max(size, Double(simd_length(bounds.max - bounds.min)) * 1.4)
        }
        sectionState = SectionState(basePlane: plane, size: size)
        mode = .idle
    }

    /// A drag starting near the section pull arrow moves the plane along its
    /// normal; anywhere else orbits. Claim test mirrors the extrude anchor
    /// math with a screen-space tolerance around the arrow's axis.
    func beginSectionDrag(ray: Ray) -> Bool {
        guard let section = sectionState, toolContext == nil else { return false }
        let plane = section.plane
        let n = simd_normalize(section.basePlane.normal)
        let axisOrigin = SIMD3<Float>(
            Float(plane.origin.x), Float(plane.origin.y), Float(plane.origin.z)
        )
        let axisDirection = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
        // Head-on views have no stable axis anchor and the arrow points at
        // the camera — let the drag orbit instead.
        guard abs(simd_dot(ray.direction, axisDirection)) < 0.95,
              let param = LineMath.closestParamOnLine(
                  origin: axisOrigin, direction: axisDirection, to: ray
              )
        else { return false }
        let closest = axisOrigin + axisDirection * param
        let along = max(simd_dot(closest - ray.origin, ray.direction), 0)
        let gap = simd_length(ray.origin + ray.direction * along - closest)
        // Forgiving grab: within ~36pt of the axis, ~220pt of the origin.
        guard gap <= Float(36 * worldPerPoint),
              abs(param) <= Float(220 * worldPerPoint)
        else { return false }
        sectionDragAnchor = param
        sectionDragStartOffset = section.offset
        return true
    }

    func updateSectionDrag(ray: Ray, screenDeltaWorld: Double) {
        guard var section = sectionState else { return }
        let n = simd_normalize(section.basePlane.normal)
        let originAtStart = section.basePlane.origin + n * sectionDragStartOffset
        let axisOrigin = SIMD3<Float>(
            Float(originAtStart.x), Float(originAtStart.y), Float(originAtStart.z)
        )
        let axisDirection = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
        let raw: Double
        if let anchor = sectionDragAnchor,
           let param = LineMath.closestParamOnLine(
               origin: axisOrigin, direction: axisDirection, to: ray
           ) {
            raw = sectionDragStartOffset + Double(param - anchor)
        } else {
            raw = sectionDragStartOffset + screenDeltaWorld
        }
        // Snap to 0.5 steps, like the extrude pull.
        let snapped = (raw / 0.5).rounded() * 0.5
        section.offset = abs(raw - snapped) < 0.15 ? snapped : raw
        sectionState = section
    }

    func endSectionDrag() {
        sectionDragAnchor = nil
    }

    private func handleTap(ray: Ray) {
        // Any viewport tap dismisses pending gizmo numeric entry and an
        // Items plane selection.
        axisEntryPart = nil
        selectedPlaneID = nil
        // A Modify-group operation armed from the palette consumes the next tap.
        if let tool = pendingCreateTool {
            applyPendingCreate(tool, ray: ray)
            return
        }
        if scaleEntryActive {
            // Spec §5.4: tapping an empty grid area commits the pending
            // scale; tapping a body just dismisses the field.
            if HitTester.pickBody(ray: ray, in: scene) == nil {
                commitScale(factor: scalePendingFactor)
                return
            }
            scaleEntryActive = false
            scaleCopyOnCommit = false
        }
        switch mode {
        case .idle, .editingPrimitive, .selected, .faceSelected:
            selectFaceOrBody(ray: ray)
        case .extruding:
            // Tapping another fill adds its profile to the tool; anywhere
            // else — "select an empty area of the grid to complete the tool."
            if addProfileToExtrude(ray: ray) { return }
            commitTool()
        case .pickingRevolveAxis:
            pickRevolveAxis(ray: ray)
        case .pickingSweepPath:
            pickSweepPathEntity(ray: ray)
        case .pickingLoftProfiles:
            pickLoftProfile(ray: ray)
        case .pickingBooleanTool(let kind, let targetID):
            handleBooleanToolTap(kind: kind, targetID: targetID, ray: ray)
        case .pickingFeatureBody(let featureID):
            handleFeatureBodyTap(featureID: featureID, ray: ray)
        case .pickingFeatureFace(let featureID):
            handleFeatureFaceTap(featureID: featureID, ray: ray)
        case .pickingFeatureProfile(let featureID):
            handleFeatureProfileTap(featureID: featureID, ray: ray)
        case .pickingSplitCutter(let target):
            handleSplitCutterTap(target: target, ray: ray)
        case .patterning:
            break // parameters live in the pattern bar; Apply/Cancel there
        case .rotatingAroundAxis:
            handleRotateAxisTap(ray: ray)
        case .translating:
            handleTranslateTap(ray: ray)
        case .aligning:
            handleAlignTap(ray: ray)
        case .pickingSketchPlane(let tool):
            handlePlanePick(ray: ray, tool: tool)
        case .sketching(_, let tool):
            handleSketchTap(ray: ray, tool: tool)
        case .measuring:
            handleMeasureTap(ray: ray)
        case .pickingSectionPlane:
            handleSectionPlanePick(ray: ray)
        case .pickingImagePlane:
            handleImagePlanePick(ray: ray)
        case .pickingBlendEdges(let kind):
            handleBlendEdgeTap(ray: ray, kind: kind)
        case .pickingShellFaces:
            handleShellFaceTap(ray: ray)
        case .pickingDeleteFaces:
            handleDeleteFaceTap(ray: ray)
        case .pickingReplaceFace:
            handleReplaceFaceTap(ray: ray)
        case .pickingAxisReferences:
            handleAxisReferenceTap(ray: ray)
        }
    }

    /// Shapr3D: double-tap selects the whole body; on empty space, fit view.
    /// While sketching, double-tap selects the tapped entity's whole
    /// connected chain (spec §1.10, endpoint adjacency).
    private func handleDoubleTap(ray: Ray) {
        if case .sketching = mode {
            // A double-tap ends an in-progress line tap-chain (finish an open
            // polyline without closing it), matching the Shapr3D line tool.
            if tapChainActive {
                clearChain()
                return
            }
            guard let sketch = activeSketch,
                  let raw = rawSketchPoint(from: ray),
                  let hit = SketchHitTester.nearestEntity(
                      to: raw, in: sketch.entities, tolerance: entityPickTolerance
                  )
            else { return }
            selectedSketchEntityIDs = ProfileDetector.connectedEntityIDs(
                from: hit.entity.id, in: sketch.entities
            )
            return
        }
        if let hit = HitTester.pickBody(ray: ray, in: scene) {
            cancelTool()
            selection = [hit.bodyID]
            if let body = session.document.body(with: hit.bodyID), body.primitive != nil {
                mode = .editingPrimitive(hit.bodyID)
            } else {
                mode = .selected(hit.bodyID)
            }
        } else {
            cameraControl?.fitScene()
        }
    }

    /// Shapr3D: a single tap on a body selects the planar face under it.
    private func selectFaceOrBody(ray: Ray) {
        let bodyHit = HitTester.pickBody(ray: ray, in: scene)

        // Multi-select chip (plan §B13, spec §8.1): additive taps toggle
        // whole bodies in and out of the selection; an empty tap keeps the
        // selection (Shift-click convention) instead of clearing it.
        if selectionAdditive {
            if let hit = bodyHit {
                toggleSelection(of: hit.bodyID)
            } else {
                // Select-mode taps also gather sketch entities (spec §8.2),
                // matching what the marquee offers.
                _ = toggleSketchEntityUnderRay(ray)
            }
            return
        }

        // Plain (non-additive) taps drop any sketch-entity selection left
        // over from Select mode, so the orange highlight can't get stuck.
        selectedSketchEntityIDs.removeAll()
        selectedSketchPoints.removeAll()
        selectedConstraintID = nil
        selectedDimensionID = nil
        editingDimension = nil

        if bodyHit == nil, case .faceSelected = mode, let context = toolContext,
           let distance = context.distance, abs(distance) > 1e-4 {
            // Spec §4.1/§18: tapping empty grid commits a nonzero face pull
            // (same rule as profile extrudes); a zero pull cancels below.
            commitTool()
            return
        }

        // Outline taps select sketch geometry; profile interiors still start
        // extrusion. Respect depth so hidden-behind-body sketches cannot steal taps.
        let imageDepth = imageHit(ray: ray)?.distance
        let occluderDepth = min(bodyHit?.distance ?? .infinity, imageDepth ?? .infinity)
        if let hit = SketchHitTester.nearestEntity(
            along: ray, in: session.document.sketches,
            tolerance: modelSketchPickTolerance, maximumDepth: occluderDepth
        ) {
            cancelTool()
            selection.removeAll()
            selectedImageID = nil
            selectedSketchEntityIDs = [hit.entity.id]
            mode = .idle
            return
        }

        // Fills win over coincident (or farther) body faces, so a profile
        // sketched ON a face stays tappable for extrude.
        if let fill = profileHit(ray: ray),
           bodyHit == nil || fill.distance <= bodyHit!.distance * 1.001 + 1e-2 {
            selectedImageID = nil
            startExtrude(with: fill)
            return
        }

        // Inserted images (plan §B10): nearer than any body hit → select the
        // image (gizmo + image bar). Fills stay on top so tracing sketches
        // drawn OVER an image remain extrudable.
        if let imageHit = imageHit(ray: ray),
           bodyHit == nil || imageHit.distance < bodyHit!.distance {
            cancelTool()
            selection.removeAll()
            mode = .idle
            selectedImageID = imageHit.id
            return
        }
        selectedImageID = nil

        if let hit = bodyHit {
            cancelTool()
            selection = [hit.bodyID]
            guard let body = session.document.body(with: hit.bodyID) else {
                mode = .selected(hit.bodyID)
                return
            }

            // An EDGE under the finger selects the edge and offers
            // Chamfer/Fillet — Shapr3D's adaptive tool for an edge selection
            // (observed 2026-09-13: "1 edge", length and radius readouts,
            // "Chamfer/Fillet (F)"). Here that is the blend pick with the edge
            // already chosen; the info bar reads the edge count and length.
            if tapIsNearBodyEdge(hit: hit, body: body) {
                beginBlend(.fillet)
                handleBlendEdgeTap(ray: ray, kind: .fillet)
                return
            }

            // Curved side surface? A plain cylinder's wall push/pulls radially
            // (edits the diameter); other curved surfaces just select the body,
            // so a single tessellation facet can never be extruded into a tab.
            if let cyl = FaceTopology.cylindricalFace(in: body.render, seedTriangle: hit.triangleIndex) {
                if cyl.matchesWholeBody {
                    beginCylinderRadial(body: body, cylinder: cyl, hit: hit)
                } else {
                    mode = .selected(hit.bodyID) // curved but compound → whole body
                }
                return
            }

            let face = FaceTopology.planarFace(in: body.render, seedTriangle: hit.triangleIndex)
            let smooth = FaceTopology.smoothRegion(in: body.render, seedTriangle: hit.triangleIndex)

            // A CURVED smooth face (a twisted wall, a blend): `planarFace` only
            // ever returns the coplanar sliver under the finger there, because no
            // two facets of a curved surface are coplanar. Select the whole
            // smooth region instead — tapping a twisted wall should grab the
            // wall, not one of its polygons.
            if let smooth, smooth.isCurved,
               face.map({ $0.triangles.count < smooth.triangles.count }) ?? true {
                toolContext = curvedFaceContext(body: body, triangles: smooth.triangles,
                                                seedTriangle: hit.triangleIndex)
                faceMoveActive = false
                faceScaleActive = false
                faceRotateActive = false
                mode = .faceSelected(body.id)
                return
            }

            guard let face else {
                // Unrecognized region → whole body.
                mode = .selected(hit.bodyID)
                return
            }

            toolContext = faceContext(body: body, face: face)
            faceMoveActive = false // a fresh face selection shows extrude only
            faceScaleActive = false
            faceRotateActive = false
            mode = .faceSelected(body.id)
            return
        }

        // Tapping a construction plane starts a new sketch on it.
        if let hit = PlanePicking.pick(ray: ray, tiles: constructionPlaneTiles) {
            cancelTool()
            selection.removeAll()
            beginSketch(on: hit.tile.plane, tool: .line)
            return
        }

        cancelTool()
        selection.removeAll()
        mode = .idle
    }

    // MARK: - Multi-select & area select (plan §B13, spec §8.1–8.2)

    /// Additive tap/Shift-click: toggle a body's membership in the
    /// selection; the mode follows the resulting selection.
    func toggleSelection(of id: BodyID) {
        cancelTool()
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
        updateModeForSelection(anchor: id)
    }

    /// Point `mode` at the current `selection` after a multi-select change:
    /// none → idle, a single primitive → its dimension editor, anything
    /// else → selected (the gizmo shows at the shared centroid).
    private func updateModeForSelection(anchor: BodyID? = nil) {
        guard !selection.isEmpty else {
            mode = .idle
            return
        }
        let id = anchor.flatMap { selection.contains($0) ? $0 : nil } ?? selection.first!
        if selection.count == 1, session.document.body(with: id)?.primitive != nil {
            mode = .editingPrimitive(id)
        } else {
            mode = .selected(id)
        }
    }

    /// Route a finished marquee drag through AreaSelect and apply the
    /// result: bodies land in `selection`, sketch entities in
    /// `selectedSketchEntityIDs`. Screen coordinates and the world→screen
    /// projection come from the viewport; drag direction picks window
    /// (left→right) vs crossing (right→left) semantics.
    func performAreaSelect(
        dragStart: SIMD2<Double>,
        dragEnd: SIMD2<Double>,
        filter: AreaSelect.Filter = .bodiesAndSketchEntities,
        project: (SIMD3<Float>) -> SIMD2<Double>?
    ) {
        // Only from the passive modes — active tools keep their taps/drags.
        switch mode {
        case .idle, .selected, .editingPrimitive, .faceSelected:
            break
        default:
            return
        }
        var candidates: [AreaSelectCandidate] = []
        for body in session.document.bodies {
            let matrix = body.transform.matrixFloat
            let points = body.render.positions.map { position -> SIMD3<Float> in
                let world = matrix * SIMD4(position, 1)
                return SIMD3(world.x, world.y, world.z)
            }
            candidates.append(AreaSelectCandidate(
                item: .body(body.id), points: points, isHidden: body.isHidden
            ))
        }
        if filter != .bodiesOnly {
            for sketch in session.document.sketches {
                for entity in sketch.entities {
                    candidates.append(AreaSelectCandidate(
                        item: .sketchEntity(entity.id),
                        points: SketchTessellator.segments(for: [entity], on: sketch.plane),
                        isHidden: sketch.isHidden
                    ))
                }
            }
        }
        let items = AreaSelect.select(
            candidates: candidates,
            dragStart: dragStart,
            dragEnd: dragEnd,
            filter: filter,
            project: project
        )
        var bodies: Set<BodyID> = []
        var entities: Set<UUID> = []
        for item in items {
            switch item {
            case .body(let id):
                bodies.insert(id)
            case .sketchEntity(let id):
                entities.insert(id)
            }
        }
        cancelTool()
        if selectionAdditive {
            selection.formUnion(bodies)
            selectedSketchEntityIDs.formUnion(entities)
        } else {
            selection = bodies
            selectedSketchEntityIDs = entities
        }
        updateModeForSelection()
    }

    /// Select-mode tap fallback: toggle the sketch entity under the ray
    /// (nearest across every visible sketch). Returns false on a miss.
    private func toggleSketchEntityUnderRay(_ ray: Ray) -> Bool {
        guard let hit = SketchHitTester.nearestEntity(
            along: ray, in: session.document.sketches, tolerance: modelSketchPickTolerance,
            maximumDepth: imageHit(ray: ray)?.distance ?? .infinity
        ) else { return false }
        if selectedSketchEntityIDs.contains(hit.entity.id) {
            selectedSketchEntityIDs.remove(hit.entity.id)
        } else {
            selectedSketchEntityIDs.insert(hit.entity.id)
        }
        return true
    }

    // MARK: - Select mode (plan §B13 UI, spec §8.2)

    /// Palette "Select" toggle: while on, one-finger viewport drags draw a
    /// marquee (window/crossing by drag direction) instead of orbiting, and
    /// taps toggle bodies additively (`selectionAdditive`).
    private(set) var selectModeActive = false

    /// Marquee filter chips (spec §8.2's B/F/E keys reduced to
    /// Bodies | Sketches for v1). At least one kind always stays on.
    private(set) var areaSelectIncludesBodies = true
    private(set) var areaSelectIncludesSketches = true

    var areaSelectFilter: AreaSelect.Filter {
        switch (areaSelectIncludesBodies, areaSelectIncludesSketches) {
        case (true, false): return .bodiesOnly
        case (false, true): return .sketchEntitiesOnly
        default: return .bodiesAndSketchEntities
        }
    }

    func toggleAreaSelectBodies() {
        guard !areaSelectIncludesBodies || areaSelectIncludesSketches else { return }
        areaSelectIncludesBodies.toggle()
    }

    func toggleAreaSelectSketches() {
        guard !areaSelectIncludesSketches || areaSelectIncludesBodies else { return }
        areaSelectIncludesSketches.toggle()
    }

    func toggleSelectMode() {
        if selectModeActive {
            exitSelectMode()
            return
        }
        if case .sketching = mode { finishSketch() }
        cancelTransientPicks()
        selectModeActive = true
        selectionAdditive = true
    }

    func exitSelectMode() {
        selectModeActive = false
        selectionAdditive = false
        marqueeState = nil
    }

    /// Live marquee rectangle for the SwiftUI overlay; screen points in
    /// viewport coordinates. Drag direction picks the semantics and the
    /// standard visual cue: left→right window (solid border), right→left
    /// crossing (dashed).
    struct MarqueeState {
        var start: SIMD2<Double>
        var current: SIMD2<Double>
        var isWindow: Bool { current.x >= start.x }
    }

    private(set) var marqueeState: MarqueeState?

    /// Claim a one-finger drag as a marquee (select mode, passive modes
    /// only). Returning false lets the drag orbit the camera instead.
    func beginMarquee(at point: SIMD2<Double>) -> Bool {
        guard selectModeActive else { return false }
        switch mode {
        case .idle, .selected, .editingPrimitive, .faceSelected:
            break
        default:
            return false
        }
        marqueeState = MarqueeState(start: point, current: point)
        return true
    }

    func updateMarquee(to point: SIMD2<Double>) {
        marqueeState?.current = point
    }

    /// Finish the marquee: run AreaSelect over the current drawables with
    /// the chip filter. `project` is the renderer camera's world→screen map.
    func endMarquee(project: (SIMD3<Float>) -> SIMD2<Double>?) {
        guard let marquee = marqueeState else { return }
        marqueeState = nil
        performAreaSelect(
            dragStart: marquee.start,
            dragEnd: marquee.current,
            filter: areaSelectFilter,
            project: project
        )
    }

    // MARK: - Select Through (plan §B13, spec §8.3)

    struct SelectThroughCandidate: Identifiable {
        enum Target {
            case body(BodyID)
            case face(PickHit)
            case profile(SketchID, SIMD2<Double>)
        }
        let id: String
        let name: String
        let target: Target
        var isBody: Bool { if case .body = target { return true }; return false }
    }

    /// Long-press hit list (front→back); non-nil presents the popup menu.
    var selectThroughCandidates: [SelectThroughCandidate]?

    /// Long-press: list every body under the screen point through depth
    /// (`pickAllBodies`) so occluded bodies stay selectable. No-op while an
    /// active tool owns viewport input.
    func presentSelectThrough(ray: Ray) {
        switch mode {
        case .idle, .selected, .editingPrimitive, .faceSelected:
            break
        default:
            return
        }
        var candidates: [SelectThroughCandidate] = []
        var seenFaces: Set<String> = []
        for hit in HitTester.pickAllSurfaces(ray: ray, in: scene) {
            guard let body = session.document.body(with: hit.bodyID) else { continue }
            // A curved wall is one smooth face (Shapr3D lists each wall hit as
            // "Face - Extrusion N"; observed 2026-09-13 on a cylinder), not a
            // collection of flat facets: key it by its whole smooth region.
            let representative: Int
            if let smooth = FaceTopology.smoothRegion(in: body.render, seedTriangle: hit.triangleIndex),
               smooth.isCurved, let seed = smooth.triangles.min() {
                representative = seed
            } else if let face = FaceTopology.planarFace(in: body.render, seedTriangle: hit.triangleIndex),
                      let seed = face.triangles.min() {
                representative = seed
            } else { continue }
            let id = "face-\(body.id.raw)-\(representative)"
            guard seenFaces.insert(id).inserted else { continue }
            candidates.append(SelectThroughCandidate(id: id, name: "Face — \(body.name)",
                                                      target: .face(hit)))
        }
        candidates += HitTester.pickAllBodies(ray: ray, in: scene).compactMap { hit in
            session.document.body(with: hit.bodyID).map {
                SelectThroughCandidate(id: "body-\($0.id.raw)", name: $0.name, target: .body($0.id))
            }
        }
        // Visible sketch fills remain selectable behind body surfaces.
        for sketch in session.document.sketches where !sketch.isHidden {
            let plane = sketch.plane
            let origin = SIMD3<Float>(plane.origin)
            let normal = SIMD3<Float>(plane.normal)
            guard let distance = ray.intersect(planePoint: origin, planeNormal: normal) else { continue }
            let local = plane.toLocal(SIMD3<Double>(ray.point(at: distance)))
            guard !ProfileDetector.profiles(at: local, in: sketch).isEmpty else { continue }
            candidates.append(SelectThroughCandidate(id: "profile-\(sketch.id.raw)",
                name: "Profile — \(sketch.name)", target: .profile(sketch.id, local)))
        }
        guard !candidates.isEmpty else { return }
        selectThroughCandidates = candidates
    }

    func chooseSelectThrough(_ candidate: SelectThroughCandidate) {
        switch candidate.target {
        case .body(let id): chooseSelectThrough(id)
        case .profile(let id, let point):
            selectThroughCandidates = nil
            guard let sketch = session.document.sketches.first(where: { $0.id == id && !$0.isHidden }),
                  let profile = ProfileDetector.profiles(at: point, in: sketch).first else { return }
            let holes = ProfileDetector.holes(of: profile, among: ProfileDetector.detectProfiles(in: sketch))
            cancelTool()
            selectedImageID = nil
            startExtrude(with: (profile, holes, sketch.plane, sketch.id, 0))
        case .face(let hit):
            selectThroughCandidates = nil
            guard let body = session.document.body(with: hit.bodyID) else { return }
            cancelTool()
            selection = [body.id]
            selectedImageID = nil
            // A curved choice lands where a direct tap on that wall lands: a
            // plain cylinder's wall arms the radial push/pull, any other
            // curved smooth region selects as a face.
            if let cyl = FaceTopology.cylindricalFace(in: body.render, seedTriangle: hit.triangleIndex),
               cyl.matchesWholeBody {
                beginCylinderRadial(body: body, cylinder: cyl, hit: hit)
                return
            }
            let planar = FaceTopology.planarFace(in: body.render, seedTriangle: hit.triangleIndex)
            if let smooth = FaceTopology.smoothRegion(in: body.render, seedTriangle: hit.triangleIndex),
               smooth.isCurved, planar.map({ $0.triangles.count < smooth.triangles.count }) ?? true {
                toolContext = curvedFaceContext(body: body, triangles: smooth.triangles,
                                                seedTriangle: hit.triangleIndex)
            } else if let planar {
                toolContext = faceContext(body: body, face: planar)
            } else {
                mode = .selected(body.id)
                return
            }
            faceMoveActive = false
            faceScaleActive = false
            faceRotateActive = false
            mode = .faceSelected(body.id)
        }
    }

    /// Popup choice: select that body (additively while in select mode).
    func chooseSelectThrough(_ id: BodyID) {
        selectThroughCandidates = nil
        guard session.document.body(with: id) != nil else { return }
        cancelTool()
        if selectionAdditive {
            selection.insert(id)
        } else {
            selection = [id]
        }
        updateModeForSelection(anchor: id)
    }

    // MARK: - Primitive dimension editing

    /// The primitive being edited, if the mode says so.
    var editingPrimitiveBody: Body? {
        guard case .editingPrimitive(let id) = mode else { return nil }
        return session.document.body(with: id)
    }

    func commitPrimitiveSpec(_ newSpec: PrimitiveSpec) {
        guard case .editingPrimitive(let id) = mode,
              let body = session.document.body(with: id),
              let currentSpec = body.primitive,
              currentSpec != newSpec
        else { return }
        let resize = ResizePrimitiveCommand(bodyID: id, beforeSpec: currentSpec, afterSpec: newSpec)

        // Phase D (Task C2): keep the owning primitive feature node in sync, or
        // create one so the box/cylinder/sphere becomes an editable history step.
        // `placement` is identity — the body's own transform carries its world
        // placement across rebuilds (rebuildFrom preserves it), so the replayed
        // (identity-transform, origin-local) primitive lands in the same spot.
        if let node = featureNode(owning: id), case .primitive = node.kind {
            let after = FeatureKind.primitive(spec: newSpec, placement: .identity)
            let edit = EditFeatureCommand(featureID: node.id, before: node.kind, after: after)
            session.perform(CompositeCommand(title: resize.title, commands: [resize, edit]))
        } else {
            let node = FeatureNode(
                name: newSpec.displayName,
                kind: .primitive(spec: newSpec, placement: .identity),
                outputBodyIDs: [id]
            )
            session.perform(CompositeCommand(
                title: resize.title, commands: [resize, AppendFeatureCommand(node: node)]))
        }
    }

    func finishEditing() {
        mode = .idle
        selection.removeAll()
    }

    // MARK: - Booleans

    /// True while a CSG operation runs off the main actor.
    var isComputingBoolean = false
    /// Cancellation flag for a detached CSG run. The main actor SETS it while
    /// Euclid's own worker threads READ it (KernelOps passes the getter in as
    /// a `@Sendable` closure), so the storage is lock-guarded rather than a
    /// bare `Bool` behind `@unchecked` — the unsynchronised version was a
    /// genuine race the compiler had been told to stop reporting.
    private nonisolated final class CancelToken: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: false)
        var isCancelled: Bool {
            get { state.withLock { $0 } }
            set { state.withLock { $0 = newValue } }
        }
    }
    private var booleanCancelToken: CancelToken?

    func armBoolean(_ kind: BooleanKind) {
        guard selection.count == 1, let target = selection.first else { return }
        cancelTransientPicks()
        cancelTool()
        mode = .pickingBooleanTool(kind, target: target)
    }

    /// Editing an existing boolean node (History "Edit Tool"): the tool pick
    /// is re-entered on the node's own target, and the next tapped body
    /// becomes the node's tool — the rebuild does the CSG, no live compute.
    private(set) var booleanEditingFeature: FeatureID?

    /// Re-enter the tool pick for an existing boolean, on its target. False
    /// when the node is not a boolean or its target body is gone.
    @discardableResult
    func beginBooleanEdit(_ id: FeatureID) -> Bool {
        guard let node = session.document.features.node(id),
              case let .boolean(kind, target, _) = node.kind
        else { return false }
        guard session.document.body(with: target.bodyID) != nil else {
            errorMessage = "The target body of this \(kind.rawValue) is gone — re-pick is not possible."
            return false
        }
        cancelTransientPicks()
        cancelTool()
        booleanEditingFeature = id
        selection = [target.bodyID]
        mode = .pickingBooleanTool(kind, target: target.bodyID)
        return true
    }

    func cancelBooleanPicking() {
        booleanEditingFeature = nil
        if case .pickingBooleanTool = mode {
            mode = .idle
        }
    }

    // MARK: - Body operand re-pick (History "Edit Body" on mirror / pattern / transform)

    /// Re-enter a body pick for an existing mirror / pattern / transform node:
    /// the next tapped body becomes its operand. False for any other kind.
    @discardableResult
    func beginFeatureBodyEdit(_ id: FeatureID) -> Bool {
        guard let node = session.document.features.node(id) else { return false }
        let current: BodyRef
        switch node.kind {
        case let .mirror(body, _, _): current = body
        case let .pattern(body, _): current = body
        case let .transform(body, _): current = body
        default: return false
        }
        cancelTransientPicks()
        cancelTool()
        selection = session.document.body(with: current.bodyID) != nil ? [current.bodyID] : []
        mode = .pickingFeatureBody(id)
        return true
    }

    func cancelFeatureBodyPick() {
        if case .pickingFeatureBody = mode { mode = .idle }
    }

    // MARK: - Face operand re-pick (History "Edit Face" on push/pull and the face tools)

    /// The body a face re-pick resolves against: the node's CONSUMED input,
    /// replayed — the document's copy already carries the push / move.
    private var featureFaceEditSource: Body?

    /// The `FaceRef` a node's face operand holds, for the kinds that have one.
    private static func faceOperand(of kind: FeatureKind) -> FaceRef? {
        switch kind {
        case let .pushPull(face, _, _): return face
        case let .moveFace(face, _): return face
        case let .scaleFace(face, _): return face
        case let .rotateFace(face, _, _): return face
        default: return nil
        }
    }

    /// Re-enter a face pick for an existing push/pull / move / scale /
    /// rotate-face node. False for other kinds, a radial push/pull (its face
    /// is cylindrical — the pick here is planar), or an input that cannot be
    /// replayed.
    @discardableResult
    func beginFeatureFaceEdit(_ id: FeatureID) -> Bool {
        guard let node = session.document.features.node(id),
              let face = Self.faceOperand(of: node.kind) else { return false }
        if case .pushPull(_, _, .cylinderRadial) = node.kind {
            errorMessage = "A radial push/pull follows a cylindrical face — re-pick is planar-only for now."
            return false
        }
        guard let source = session.inputBody(for: id, bodyID: face.body.bodyID) else {
            errorMessage = "Couldn't rebuild the shape this \(node.name.lowercased()) started from."
            return false
        }
        cancelTransientPicks()
        cancelTool()
        featureFaceEditSource = source
        selection = session.document.body(with: face.body.bodyID) != nil ? [face.body.bodyID] : []
        mode = .pickingFeatureFace(id)
        return true
    }

    func cancelFeatureFacePick() {
        featureFaceEditSource = nil
        if case .pickingFeatureFace = mode { mode = .idle }
    }

    // MARK: - Profile re-pick (History "Edit Profile" on extrude / draft / revolve / sweep)

    /// Re-enter a profile pick for an existing extrude / draft extrude /
    /// revolve / sweep node: the next tapped sketch fill becomes its profile.
    /// False for other kinds (a loft's sections are several — not yet).
    @discardableResult
    func beginFeatureProfileEdit(_ id: FeatureID) -> Bool {
        guard let node = session.document.features.node(id) else { return false }
        switch node.kind {
        case .extrude, .draftExtrude, .revolve, .sweep: break
        default: return false
        }
        cancelTransientPicks()
        cancelTool()
        selection = Set(node.outputBodyIDs.filter { session.document.body(with: $0) != nil })
        mode = .pickingFeatureProfile(id)
        return true
    }

    func cancelFeatureProfilePick() {
        if case .pickingFeatureProfile = mode { mode = .idle }
    }

    /// The status pill's prompt while a profile is being re-picked.
    var featureProfilePickPrompt: String? {
        guard case let .pickingFeatureProfile(id) = mode,
              let node = session.document.features.node(id) else { return nil }
        return "Tap the profile for \(node.name)"
    }

    /// The same sketch region: same sketch, same loop entities, same holes —
    /// the seed point and entity order are incidental to how it was tapped.
    private static func sameProfile(_ a: ProfileRef, _ b: ProfileRef) -> Bool {
        a.sketchID == b.sketchID
            && Set(a.entityIDs) == Set(b.entityIDs)
            && Set(a.holeEntityIDs.map { Set($0) }) == Set(b.holeEntityIDs.map { Set($0) })
    }

    private func handleFeatureProfileTap(featureID: FeatureID, ray: Ray) {
        guard let node = session.document.features.node(featureID) else { cancelFeatureProfilePick(); return }
        // Hidden sketches count too: the sketch an extrude consumed is usually
        // hidden, and the whole point is to point the node at a profile again.
        guard let hit = profileHit(ray: ray, includeHidden: true) else { return }
        let ref = profileRef(profile: hit.profile, holes: hit.holes, sketchID: hit.sketchID)
        let plane = PlaneRef(source: .sketch(hit.sketchID))
        let after: FeatureKind
        switch node.kind {
        case let .extrude(profile, _, distance, symmetric, boolean, _):
            guard !Self.sameProfile(profile, ref) else { cancelFeatureProfilePick(); return }
            // Extra profiles belonged to the old sketch region; the re-pick is one profile.
            after = .extrude(profile: ref, plane: plane, distance: distance,
                             symmetric: symmetric, boolean: boolean, extraProfiles: [])
        case let .draftExtrude(profile, _, distance, taperAngle, symmetric, boolean):
            guard !Self.sameProfile(profile, ref) else { cancelFeatureProfilePick(); return }
            after = .draftExtrude(profile: ref, plane: plane, distance: distance,
                                  taperAngle: taperAngle, symmetric: symmetric, boolean: boolean)
        case let .revolve(profile, _, axis, angle, boolean):
            guard !Self.sameProfile(profile, ref) else { cancelFeatureProfilePick(); return }
            after = .revolve(profile: ref, plane: plane, axis: axis, angle: angle, boolean: boolean)
        case let .sweep(profile, _, spine, boolean, helix):
            guard !Self.sameProfile(profile, ref) else { cancelFeatureProfilePick(); return }
            after = .sweep(profile: ref, plane: plane, spine: spine, boolean: boolean, helix: helix)
        default:
            cancelFeatureProfilePick()
            return
        }
        cancelFeatureProfilePick()
        prepareForHistoryChange()
        session.editFeature(featureID, to: after)
        session.save()
        let produced = node.outputBodyIDs.filter { session.document.body(with: $0) != nil }
        if let first = produced.first {
            selection = Set(produced)
            mode = .selected(first)
        }
    }

    /// The status pill's prompt while a face operand is being re-picked.
    var featureFacePickPrompt: String? {
        guard case let .pickingFeatureFace(id) = mode,
              let node = session.document.features.node(id) else { return nil }
        return "Tap the face for \(node.name)"
    }

    /// A planar `FaceRef` on `source` from a seed triangle — the signature
    /// `pushPullFaceRef` mints, without needing a tool context.
    private func planarFaceRef(on source: Body, seedTriangle seed: Int, bodyRef: BodyRef) -> FaceRef? {
        guard let face = FaceTopology.planarFace(in: source.render, seedTriangle: seed) else { return nil }
        let n = SIMD3<Double>(Double(face.normal.x), Double(face.normal.y), Double(face.normal.z))
        var area = abs(Profile.signedArea(face.outline))
        for hole in face.holes { area -= abs(Profile.signedArea(hole)) }
        let signature = FaceSignature(
            kind: .planar, normal: n, centroid: face.origin,
            area: max(area, 0), planeOffset: simd_dot(n, face.origin))
        let role: FaceRole
        if case .primitive(let spec, _)? = session.document.features.node(bodyRef.producer)?.kind,
           case .box = spec {
            role = .boxFace(Self.boxFace(for: n))
        } else {
            role = .derived(index: 0)
        }
        return FaceRef(body: bodyRef, creator: bodyRef.producer, role: role, signature: signature,
                       elementName: mintElementName(body: source, triangle: seed))
    }

    private func handleFeatureFaceTap(featureID: FeatureID, ray: Ray) {
        guard let node = session.document.features.node(featureID),
              let current = Self.faceOperand(of: node.kind),
              let source = featureFaceEditSource
        else { cancelFeatureFacePick(); return }
        guard let hit = HitTester.pickBody(ray: ray, in: scene) else { return }
        // The edit stays on its own body.
        guard hit.bodyID == current.body.bodyID else { return }
        // The document's copy already carries the push / move: re-pick the
        // face on the replayed INPUT (the shell and delete-face edits' trap).
        let originalScene = ViewportScene(bodies: [BodyDrawable(
            id: source.id, renderMesh: source.render, edges: source.edges,
            meshRevision: source.meshRevision, modelMatrix: source.transform.matrixFloat,
            baseColor: SIMD4(0.72, 0.74, 0.78, 1), selectionState: SelectionStateNone.rawValue)])
        guard let originalHit = HitTester.pickBody(ray: ray, in: originalScene),
              let ref = planarFaceRef(on: source, seedTriangle: originalHit.triangleIndex, bodyRef: current.body)
        else {
            errorMessage = "Tap a flat face — only planar faces can be re-picked here."
            return
        }
        let after: FeatureKind
        switch node.kind {
        case let .pushPull(_, distance, pushMode): after = .pushPull(face: ref, distance: distance, mode: pushMode)
        case let .moveFace(_, delta): after = .moveFace(face: ref, delta: delta)
        case let .scaleFace(_, factor): after = .scaleFace(face: ref, factor: factor)
        case let .rotateFace(_, angle, axis): after = .rotateFace(face: ref, angle: angle, axis: axis)
        default: cancelFeatureFacePick(); return
        }
        let bodyID = current.body.bodyID
        cancelFeatureFacePick()
        prepareForHistoryChange()
        session.editFeature(featureID, to: after)
        session.save()
        if session.document.body(with: bodyID) != nil {
            selection = [bodyID]
            mode = .selected(bodyID)
        }
    }

    /// The status pill's prompt while a body operand is being re-picked.
    var featureBodyPickPrompt: String? {
        guard case let .pickingFeatureBody(id) = mode,
              let node = session.document.features.node(id) else { return nil }
        return "Tap the body for \(node.name)"
    }

    private func handleFeatureBodyTap(featureID: FeatureID, ray: Ray) {
        guard let hit = HitTester.pickBody(ray: ray, in: scene) else { return }
        guard let node = session.document.features.node(featureID) else { cancelFeatureBodyPick(); return }
        // Same rules as a boolean's tool: feature-produced, and produced
        // BEFORE this node so the replay can find it.
        guard let owner = featureNode(owning: hit.bodyID) else {
            errorMessage = "Only a body created by a feature can be re-picked here — this one is an import or copy."
            return
        }
        if let ownerIndex = session.document.features.index(of: owner.id),
           let selfIndex = session.document.features.index(of: featureID),
           ownerIndex >= selfIndex {
            errorMessage = "Pick a body created before this \(node.name.lowercased()) in the history."
            return
        }
        let ref = BodyRef(producer: owner.id, bodyID: hit.bodyID)
        let after: FeatureKind
        switch node.kind {
        case let .mirror(body, plane, keepOriginal):
            guard body != ref else { cancelFeatureBodyPick(); return }
            after = .mirror(body: ref, plane: plane, keepOriginal: keepOriginal)
        case let .pattern(body, spec):
            guard body != ref else { cancelFeatureBodyPick(); return }
            after = .pattern(body: ref, spec: spec)
        case let .transform(body, delta):
            guard body != ref else { cancelFeatureBodyPick(); return }
            after = .transform(body: ref, delta: delta)
        default:
            cancelFeatureBodyPick()
            return
        }
        mode = .idle
        prepareForHistoryChange()
        session.editFeature(featureID, to: after)
        session.save()
        if session.document.body(with: hit.bodyID) != nil {
            selection = [hit.bodyID]
            mode = .selected(hit.bodyID)
        }
    }

    func handleBooleanToolTap(kind: BooleanKind, targetID: BodyID, ray: Ray) {
        guard let hit = HitTester.pickBody(ray: ray, in: scene) else { return }
        // Tapping the target itself used to do nothing at all, which after a
        // Union reads as "subtract is broken": the two parts are ONE body
        // now, so the "second one" the user taps is the body being edited
        // (bug report a1ee4e4a, 2026-09-05). Say so.
        guard hit.bodyID != targetID else {
            showNotice("That's the body already selected — tap a different body to \(kind.rawValue). "
                       + "After a Union the parts are one body; undo the union to \(kind.rawValue) them.")
            return
        }
        if let featureID = booleanEditingFeature {
            // Rewrite the node's tool and let the rebuild do the CSG. The tool
            // must be feature-produced (else the node could not replay) and
            // created BEFORE the boolean (replay order), like a fresh boolean.
            guard let node = session.document.features.node(featureID),
                  case let .boolean(nodeKind, target, _) = node.kind
            else { cancelBooleanPicking(); return }
            guard let owner = featureNode(owning: hit.bodyID) else {
                errorMessage = "Only a body created by a feature can be the tool — this one is an import or copy."
                return
            }
            if let ownerIndex = session.document.features.index(of: owner.id),
               let selfIndex = session.document.features.index(of: featureID),
               ownerIndex >= selfIndex {
                errorMessage = "Pick a body created before this \(nodeKind.rawValue) in the history."
                return
            }
            let tools = [BodyRef(producer: owner.id, bodyID: hit.bodyID)]
            booleanEditingFeature = nil
            prepareForHistoryChange()
            session.editFeature(featureID, to: .boolean(kind: nodeKind, target: target, tools: tools))
            session.save()
            selection = [targetID]
            mode = .selected(targetID)
            return
        }
        runBoolean(kind, targetID: targetID, toolID: hit.bodyID)
    }

    private func runBoolean(_ kind: BooleanKind, targetID: BodyID, toolID: BodyID) {
        guard let target = session.document.body(with: targetID),
              let toolIndex = session.document.bodyIndex(of: toolID)
        else { return }
        let tool = session.document.bodies[toolIndex]

        // A tool that never reaches the target's bounds cannot cut or
        // intersect it. The CSG would hand the target back unchanged and the
        // commit would look like nothing happened — say why instead.
        if kind != .union,
           !Self.worldBounds(of: target).intersects(Self.worldBounds(of: tool)) {
            showNotice("“\(tool.name)” doesn't touch “\(target.name)” — move them so they overlap, then \(kind.rawValue).")
            return
        }

        isComputingBoolean = true
        mode = .idle
        let token = CancelToken()
        booleanCancelToken = token
        // Snapshot the document generation: the CSG below runs detached, and
        // the "Computing…" card blocks nothing, so the user can undo, delete
        // or move either body meanwhile. Committing the stale result then
        // would bake pre-edit transforms into the document (review, S3).
        let dispatchedChangeCount = session.changeCount

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Body? in
                let mesh = KernelOps.boolean(kind, target: target, tool: tool) {
                    token.isCancelled
                }
                guard !token.isCancelled, !mesh.polygons.isEmpty else { return nil }
                return Body(
                    id: target.id,
                    name: target.name,
                    transform: .identity,
                    primitive: nil,
                    euclidMesh: mesh,
                    revision: 0 // set by the command against the live document
                )
            }.value

            guard let self else { return }
            self.isComputingBoolean = false
            self.booleanCancelToken = nil
            guard let result, !token.isCancelled else {
                if !token.isCancelled {
                    self.errorMessage =
                        "The \(kind.rawValue) operation produced no geometry — the bodies may not overlap."
                }
                return
            }
            guard self.session.changeCount == dispatchedChangeCount else {
                self.showNotice(
                    "The \(kind.rawValue) was discarded — the model changed while it was computing."
                )
                return
            }
            var composed = result
            // Compose the analytic solids too — the same decision feature
            // replay makes (evalBoolean), so a live boolean and its later
            // rebuild produce the same class of geometry instead of the live
            // result silently degrading to mesh-only (review C4). On the
            // MainActor, per BRepHandle's serialization caveat. When OCCT
            // OWNS the op (both sides analytic) and fails for cause, refuse
            // the commit: replay would error on the very next rebuild, so
            // committing the mesh result would store a feature that cannot
            // reproduce itself.
            switch OCCTKernel.composedBooleanResult(kind, target: target, tool: tool) {
            case let .success(outcome):
                composed.adoptBRep(outcome.handle)
            case let .failure(error):
                self.errorMessage = "The \(kind.rawValue) failed: \(error.message)"
                return
            case nil:
                break  // an operand is mesh-only — the mesh result stands
            }
            let boolean = BooleanCommand(
                kind: kind,
                targetBefore: target,
                toolIndex: toolIndex,
                toolBefore: tool,
                result: composed
            )
            // Phase D (Task C2): record a `.boolean` feature node when BOTH the
            // target and tool are feature-produced, so replay can reconstruct
            // them before re-applying the CSG. If either is a non-feature body
            // (import/copy), skip — the node couldn't be faithfully replayed.
            if let node = self.booleanFeatureNode(kind: kind, target: target, tool: tool) {
                self.session.perform(CompositeCommand(
                    title: kind.rawValue.capitalized,
                    commands: [boolean, AppendFeatureCommand(node: node)]))
            } else {
                self.session.perform(boolean)
            }
            self.selection = [target.id]
            self.mode = .selected(target.id)
            self.session.save()
        }
    }

    func cancelBooleanComputation() {
        booleanCancelToken?.isCancelled = true
    }

    // MARK: - Profile tools (Extrude / Revolve)

    struct ToolContext {
        enum Kind {
            case extrude(distance: Double)
            /// Axis is a line in sketch-plane coordinates; angle in degrees.
            case revolve(axis: RevolveAxis, angle: Double)
            /// Offset construction plane pulled off a face along its normal.
            case offsetPlane(distance: Double)
            /// Sweep the profile along a world-space polyline spine (plan §B1).
            case sweep(spine: [SIMD3<Double>])
            /// Loft through `loftProfiles` in selection order (plan §B2).
            case loft
        }

        var profile: Profile
        var holes: [Profile]
        var plane: SketchPlane
        /// Sketch that produced the profile (nil for face extrudes).
        var sketchID: SketchID?
        /// The body whose face is being pushed/pulled (nil for sketch profiles).
        var sourceBody: BodyID?
        /// Face triangles for the selection highlight (face extrudes).
        var faceTriangles: [Int] = []
        /// Set when pushing/pulling a body's cylindrical side: distance is a
        /// RADIAL delta (grows/shrinks the radius), not an axial extrusion.
        var cylinderFace: FaceTopology.CylindricalFace?
        /// True when the selection is a CURVED smooth face (a twisted wall, a
        /// blend, …) picked whole rather than a planar patch. It highlights and
        /// can be measured or deleted, but push/pull and the face transforms all
        /// assume a plane, so they stay off for it.
        var curvedRegion = false
        var kind: Kind
        /// Extra fills added while extruding (multi-profile: union of prisms).
        var extraProfiles: [(profile: Profile, holes: [Profile])] = []
        /// Entities already chained into the sweep path (tap order).
        var sweepPathEntityIDs: [UUID] = []
        /// Ordered loft sections (seeded with the armed profile; taps append).
        var loftProfiles: [(profile: Profile, holes: [Profile], plane: SketchPlane, sketchID: SketchID)] = []
        /// Boolean badge: manual result override (auto = sample-point rules).
        var booleanOverride: BooleanOverride = .auto
        /// Symmetric sides: solid centered on the plane, total depth 2×.
        var symmetric = false
        /// False when committing now would fail (arrow renders red).
        var isPendingValid = true
        /// True while the preview should REPLACE the source body in the scene
        /// (face push/pull: the preview is the whole modified body, not an
        /// overlapping tool prism).
        var previewReplacesSource = false
        var previewRevision: UInt64 = 1
        var preview: Body?

        /// A push/pull of an existing body's planar face (vs. a fresh sketch
        /// extrude). These need a coincident-wall-safe truncation, not a
        /// same-cross-section boolean.
        var isFaceOperation: Bool { sourceBody != nil && !faceTriangles.isEmpty }
        var isCylinderRadial: Bool { cylinderFace != nil }

        var distance: Double? {
            switch kind {
            case .extrude(let distance), .offsetPlane(let distance):
                return distance
            case .revolve, .sweep, .loft:
                return nil
            }
        }

        var angle: Double? {
            if case .revolve(_, let angle) = kind { return angle }
            return nil
        }
    }

    var toolContext: ToolContext?
    /// A 3D-create operation armed from the body-mode "Modify" palette group,
    /// waiting for the user to tap a sketch region to apply it (Shapr3D: pick
    /// the tool, then the profile). Consumed by the next viewport tap.
    var pendingCreateTool: CreateTool?
    /// Present the Helix options sheet — hoisted from `NumericInputBar` so the
    /// Modify group can trigger it after arming a profile.
    var showHelixOptions = false
    private var extrudeDragAnchor: Float?
    /// The push/pull source body's world-space mesh, memoised for the duration
    /// of a face drag. The source doesn't change until commit, so rebuilding it
    /// from the render blob every drag frame (Euclid deserialize + transform)
    /// was pure waste — the dominant cost behind sluggish push/pull.
    private var cachedPullWorldBody: Euclid.Mesh?
    /// Distance (extrude) or angle (revolve) when the drag began.
    private var toolDragStartValue: Double = 0
    /// Stable identity for the preview drawable so GPU buffers cache by revision.
    private let toolPreviewID = BodyID()

    /// The profile (with holes) under the ray, across all sketches, with the
    /// world-space hit distance (rays are unit-direction).
    private func profileHit(
        ray: Ray, includeHidden: Bool = false
    ) -> (profile: Profile, holes: [Profile], plane: SketchPlane, sketchID: SketchID, distance: Float)? {
        var best: (profile: Profile, holes: [Profile], plane: SketchPlane, sketchID: SketchID, distance: Float)?
        for sketch in session.document.sketches where includeHidden || !sketch.isHidden {
            let plane = sketch.plane
            let planePoint = SIMD3<Float>(Float(plane.origin.x), Float(plane.origin.y), Float(plane.origin.z))
            let n = plane.normal
            let planeNormal = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
            guard let t = ray.intersect(planePoint: planePoint, planeNormal: planeNormal) else {
                continue
            }
            let world = ray.point(at: t)
            let local = plane.toLocal(SIMD3(Double(world.x), Double(world.y), Double(world.z)))
            let candidates = ProfileDetector.profiles(at: local, in: sketch)
            guard let innermost = candidates.first else { continue }
            if best == nil || t < best!.distance {
                let all = ProfileDetector.detectProfiles(in: sketch)
                let holes = ProfileDetector.holes(of: innermost, among: all)
                best = (innermost, holes, plane, sketch.id, t)
            }
        }
        return best
    }

    /// Tap on a filled profile arms the Extrude command at ZERO distance:
    /// just the pull arrow + numeric bar, no geometry until the user drags
    /// the arrow or types a height (Shapr3D). Committing at 0 cancels.
    private func startExtrude(
        with hit: (profile: Profile, holes: [Profile], plane: SketchPlane, sketchID: SketchID, distance: Float)
    ) {
        selection.removeAll()
        var context = ToolContext(
            profile: hit.profile,
            holes: hit.holes,
            plane: hit.plane,
            sketchID: hit.sketchID,
            kind: .extrude(distance: 0)
        )
        rebuildToolPreview(&context)
        toolContext = context
        mode = .extruding
    }

    /// True when at least one visible sketch has an extrudable profile, so the
    /// body-mode "Modify" group can offer to start a 3D-create operation.
    var hasExtrudableProfile: Bool {
        session.document.sketches.contains {
            !$0.isHidden && !ProfileDetector.detectProfiles(in: $0).isEmpty
        }
    }

    /// Body-mode "Modify" group: arm a 3D-create operation (Shapr3D picks the
    /// tool first). The next viewport tap on a sketch region applies it.
    func beginCreate(_ tool: CreateTool) {
        cancelTransientPicks()
        cancelTool()
        selection.removeAll()
        pendingCreateTool = tool
    }

    func cancelCreate() { pendingCreateTool = nil }

    /// Consume a pending Modify-group operation on a region tap: build the
    /// extrude context (same as a plain fill tap), then route into the specific
    /// operation's existing pick flow. An empty tap just cancels.
    private func applyPendingCreate(_ tool: CreateTool, ray: Ray) {
        pendingCreateTool = nil
        guard let fill = profileHit(ray: ray) else { return }
        selectedImageID = nil
        startExtrude(with: fill)
        switch tool {
        case .extrude: break                 // extrude bar is already up
        case .revolve: beginRevolveAxisPick()
        case .sweep:   beginSweepPathPick()
        case .loft:    beginLoftProfilePick()
        case .helix:   showHelixOptions = true
        }
    }

    /// Drag starting on a filled profile pulls it into 3D directly
    /// (push/pull). Committing happens on release.
    func beginFillPull(ray: Ray) -> Bool {
        pendingCreateTool = nil // a drag resumes normal fill-pull behaviour
        if case .measuring = mode { return false } // measure taps/drags never extrude
        // Split/pattern/transform picks never start an extrude; unclaimed
        // drags orbit (rotate-axis angle drags are claimed upstream).
        if case .pickingSplitCutter = mode { return false }
        if case .patterning = mode { return false }
        if case .rotatingAroundAxis = mode { return false }
        if case .translating = mode { return false }
        if case .aligning = mode { return false }
        if case .pickingSectionPlane = mode { return false }
        if case .pickingImagePlane = mode { return false }
        guard HitTester.pickBody(ray: ray, in: scene) == nil,
              let hit = profileHit(ray: ray)
        else { return false }

        selection.removeAll()
        var context = ToolContext(
            profile: hit.profile,
            holes: hit.holes,
            plane: hit.plane,
            sketchID: hit.sketchID,
            kind: .extrude(distance: 0)
        )
        rebuildToolPreview(&context)
        toolContext = context
        mode = .extruding

        // Anchor the drag on the pull axis (profile centroid, plane normal).
        // Near head-on views (looking straight down the axis) have no stable
        // axis anchor — the screen-space fallback in updateToolDrag covers
        // that, so a nil anchor is fine.
        let centroid = hit.profile.centroid
        let world = hit.plane.toWorld(centroid)
        let n = hit.plane.normal
        let axisOrigin = SIMD3<Float>(Float(world.x), Float(world.y), Float(world.z))
        let axisDirection = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
        if abs(simd_dot(ray.direction, axisDirection)) < 0.95 {
            extrudeDragAnchor = LineMath.closestParamOnLine(
                origin: axisOrigin, direction: axisDirection, to: ray
            )
        } else {
            extrudeDragAnchor = nil
        }
        toolDragStartValue = 0
        return true
    }

    /// Drag starting on the selected face pulls it (push/pull on bodies).
    func beginFacePull(ray: Ray) -> Bool {
        guard case .faceSelected(let bodyID) = mode,
              let context = toolContext,
              let hit = HitTester.pickBody(ray: ray, in: scene),
              hit.bodyID == bodyID,
              context.faceTriangles.contains(hit.triangleIndex)
        else { return false }
        return beginToolDrag(ray: ray)
    }

    private func rebuildToolPreview(_ context: inout ToolContext) {
        if case .offsetPlane = context.kind {
            // The pending plane renders as a quad, not a preview body.
            context.preview = nil
            context.isPendingValid = true
            return
        }
        let mesh: Euclid.Mesh
        switch context.kind {
        case .offsetPlane:
            return // handled above
        case .extrude(let distance):
            // Face push/pull: preview the whole modified body so the viewport
            // matches the committed result (no overlapping-prism z-fighting).
            if context.isFaceOperation {
                context.previewReplacesSource = true
                if abs(distance) <= 1e-4 {
                    context.preview = nil
                    context.isPendingValid = true
                    return
                }
                let modified = faceModifiedMesh(context, distance: distance, finalize: false)
                context.isPendingValid = !(modified?.polygons.isEmpty ?? true)
                guard let modified, !modified.polygons.isEmpty else {
                    context.preview = nil
                    return
                }
                context.previewRevision += 1
                context.preview = Body(
                    id: toolPreviewID,
                    name: "Tool Preview",
                    transform: .identity,
                    primitive: nil,
                    euclidMesh: modified,
                    revision: context.previewRevision
                )
                return
            }
            var solid = KernelOps.extrude(
                profile: context.profile,
                holes: context.holes,
                in: context.plane,
                distance: distance,
                symmetric: context.symmetric
            )
            for extra in context.extraProfiles {
                solid = solid.union(KernelOps.extrude(
                    profile: extra.profile,
                    holes: extra.holes,
                    in: context.plane,
                    distance: distance,
                    symmetric: context.symmetric
                ))
            }
            mesh = solid
        case .revolve(let axis, let angle):
            mesh = KernelOps.revolve(
                profile: context.profile,
                holes: context.holes,
                in: context.plane,
                axis: axis,
                angle: angle
            )
        case .sweep(let spine):
            mesh = KernelOps.sweep(
                profile: context.profile,
                holes: context.holes,
                in: context.plane,
                alongPath: spine
            )
        case .loft:
            mesh = KernelOps.loft(
                profiles: context.loftProfiles.map { ($0.profile, $0.holes, $0.plane) }
            )
        }
        updatePendingValidity(&context, toolMesh: mesh)
        guard !mesh.polygons.isEmpty else {
            context.preview = nil
            return
        }
        context.previewRevision += 1
        context.preview = Body(
            id: toolPreviewID,
            name: "Tool Preview",
            transform: .identity,
            primitive: nil,
            euclidMesh: mesh,
            revision: context.previewRevision
        )
    }

    /// Operation-validity feedback (spec §18), throttled to preview rebuilds.
    /// Cheap: bounds prefilters; real CSG runs only when a wipeout cut or an
    /// empty intersection is plausible.
    private func updatePendingValidity(_ context: inout ToolContext, toolMesh: Euclid.Mesh) {
        context.isPendingValid = true
        guard case .extrude(let distance) = context.kind,
              abs(distance) > 1e-4,
              context.booleanOverride != .newBody,
              !toolMesh.polygons.isEmpty
        else { return }

        let toolBounds = toolMesh.bounds
        let n = context.plane.normal
        let sign: Double = distance >= 0 ? 1 : -1
        let sampleWorld = context.plane.toWorld(context.profile.centroid) + n * sign * 0.01
        let sample = Vector(sampleWorld.x, sampleWorld.y, sampleWorld.z)

        var intersectHasOverlap = false
        for target in booleanCandidates(for: context) {
            let bounds = Self.worldBounds(of: target)
            guard toolBounds.intersects(bounds) else { continue }
            switch context.booleanOverride {
            case .intersect:
                if !intersectHasOverlap {
                    let worldTarget = target.euclidMesh().transformed(by: target.transform.euclid)
                    intersectHasOverlap = !worldTarget.intersection(toolMesh).polygons.isEmpty
                }
            case .subtract, .auto:
                // Cut wipeout only possible when the tool encloses the body.
                let mayCut = context.booleanOverride == .subtract || bounds.intersects(sample)
                if mayCut, toolBounds.contains(bounds) {
                    let worldTarget = target.euclidMesh().transformed(by: target.transform.euclid)
                    if worldTarget.subtracting(toolMesh).polygons.isEmpty {
                        context.isPendingValid = false
                        return
                    }
                }
            case .union, .newBody:
                break
            }
        }
        if context.booleanOverride == .intersect {
            context.isPendingValid = intersectHasOverlap
        }
    }

    /// Bodies a tool commit could combine with: the pull's source body, or
    /// every body for sketch-profile tools.
    private func booleanCandidates(for context: ToolContext) -> [Body] {
        if let source = context.sourceBody {
            return session.document.body(with: source).map { [$0] } ?? []
        }
        // Heavy imported meshes are scenery, never CSG operands
        // (`BooleanCandidacy`) — the scan that took Extrude down.
        return session.document.bodies.filter(BooleanCandidacy.allows)
    }

    /// World-space AABB from the render mesh's local AABB (cheap — no Euclid
    /// mesh rebuild).
    private static func worldBounds(of body: Body) -> Euclid.Bounds {
        let aabb = body.render.localAABB
        var lo = SIMD3<Double>(.infinity, .infinity, .infinity)
        var hi = -lo
        for i in 0..<8 {
            let corner = SIMD3<Double>(
                Double((i & 1) == 0 ? aabb.min.x : aabb.max.x),
                Double((i & 2) == 0 ? aabb.min.y : aabb.max.y),
                Double((i & 4) == 0 ? aabb.min.z : aabb.max.z)
            )
            let world = body.transform.applying(to: corner)
            lo = simd_min(lo, world)
            hi = simd_max(hi, world)
        }
        return Euclid.Bounds(
            min: Vector(lo.x, lo.y, lo.z),
            max: Vector(hi.x, hi.y, hi.z)
        )
    }

    /// While extruding a sketch profile, tapping another fill in the same
    /// sketch adds it to the tool (multi-profile extrude).
    private func addProfileToExtrude(ray: Ray) -> Bool {
        guard var context = toolContext, case .extrude = context.kind,
              let sketchID = context.sketchID,
              let hit = profileHit(ray: ray),
              hit.sketchID == sketchID,
              !hit.profile.sourceEntityIDs.isEmpty
        else { return false }
        // Tapping an already-included fill falls through to commit.
        let ids = hit.profile.sourceEntityIDs
        guard context.profile.sourceEntityIDs != ids,
              !context.extraProfiles.contains(where: { $0.profile.sourceEntityIDs == ids })
        else { return false }
        context.extraProfiles.append((hit.profile, hit.holes))
        rebuildToolPreview(&context)
        toolContext = context
        return true
    }

    func setExtrudeDistance(_ distance: Double) {
        guard var context = toolContext, case .extrude(let current) = context.kind else { return }
        // A pan delivers `.changed` at up to the display rate; snapping and
        // sub-pixel jitter make many consecutive events resolve to the SAME
        // distance. Skip the (expensive) CSG rebuild when nothing moved so the
        // drag stays responsive instead of backing up behind redundant rebuilds.
        guard abs(distance - current) > 1e-6 else { return }
        context.kind = .extrude(distance: distance)
        rebuildToolPreview(&context)
        toolContext = context
    }

    // MARK: - Extrude arrow value pill (Shapr3D on-arrow dimension)

    struct ExtrudeArrowLabel {
        var world: SIMD3<Double>   // arrow-tip world position
        var text: String           // "12.0 mm" or "⌀ 24.0 mm"
        var isDiameter: Bool
        var symmetric: Bool
    }

    /// True while the on-arrow value pill is being typed into.
    var editingExtrudeArrow = false

    /// The editable value pill riding the extrude/diameter arrow, or nil.
    var extrudeArrowLabel: ExtrudeArrowLabel? {
        guard let context = toolContext, case .extrude(let distance) = context.kind else { return nil }
        let centroid = context.plane.toWorld(context.profile.centroid)
        // Anchor the pill at the arrow's midpoint (Shapr3D centres it on the
        // line), nudged just off-axis so it doesn't overlap the shaft.
        let mid = centroid + context.plane.normal * (distance * 0.5)
        let unit = CADPreferences.shared.unit
        if let cyl = context.cylinderFace {
            let dia = 2 * (cyl.radius + distance / max(sourceScale(context), 1e-6))
            return ExtrudeArrowLabel(
                world: mid, text: "⌀ " + unit.compactLengthString(fromMM: dia),
                isDiameter: true, symmetric: false
            )
        }
        let shown = context.symmetric ? abs(distance) * 2 : abs(distance)
        return ExtrudeArrowLabel(
            world: mid, text: unit.compactLengthString(fromMM: shown),
            isDiameter: false, symmetric: context.symmetric
        )
    }

    private func sourceScale(_ context: ToolContext) -> Double {
        context.sourceBody.flatMap { session.document.body(with: $0) }?.transform.scale ?? 1
    }

    func beginExtrudeArrowEdit() { editingExtrudeArrow = true }

    /// Commit a typed value from the on-arrow pill: set the distance/diameter
    /// (Enter commits the feature, matching the bottom bar).
    func commitExtrudeArrowEdit(_ text: String) {
        defer { editingExtrudeArrow = false }
        guard let typed = ExpressionEvaluator.evaluate(text),
              let context = toolContext, case .extrude = context.kind
        else { return }
        // The pill shows and edits the DISPLAY unit; the tool works in mm.
        let value = CADPreferences.shared.unit.mm(fromDisplay: typed)
        if let cyl = context.cylinderFace {
            setExtrudeDistance(value / 2 - cyl.radius)
        } else {
            // Honor an explicitly typed sign ("-5" pushes inward); when no sign
            // is typed, keep the current drag direction (the pill shows |dist|).
            let hasExplicitSign = text.contains("-") || text.contains("+")
            let signed: Double
            if hasExplicitSign {
                signed = value
            } else {
                signed = (context.distance ?? 0) < 0 ? -abs(value) : abs(value)
            }
            setExtrudeDistance(context.symmetric ? signed / 2 : signed)
        }
        commitTool()
    }

    func cancelExtrudeArrowEdit() { editingExtrudeArrow = false }

    /// Extrude end condition (Through All / Up To Next): resolve it against
    /// the document's bodies from the profile's centroid along the current
    /// direction, apply it as the tool's distance and return the value in
    /// mm (signed like the current distance). nil when nothing lies ahead —
    /// the caller tells the person and leaves the distance alone.
    @discardableResult
    func resolveExtrudeEnd(_ end: ExtrudeEnd) -> Double? {
        guard let context = toolContext, case .extrude(let current) = context.kind else { return nil }
        let sign: Double = current < 0 ? -1 : 1
        let direction = sign * context.plane.normal
        guard let mm = ExtrudeEndKit.resolve(end, plane: context.plane, seed: context.profile.centroid,
                                             direction: direction, symmetric: context.symmetric,
                                             bodies: session.document.bodies) else {
            errorMessage = "\(end.title): nothing ahead of the sketch along the extrude direction."
            return nil
        }
        // With Symmetric on the field is per side; Through All resolved the
        // farther reach already, so it is the per-side value as it stands.
        let signed = sign * mm
        setExtrudeDistance(signed)
        return signed
    }

    func setExtrudeSymmetric(_ symmetric: Bool) {
        guard var context = toolContext, case .extrude = context.kind,
              context.symmetric != symmetric
        else { return }
        context.symmetric = symmetric
        rebuildToolPreview(&context)
        toolContext = context
    }

    func setBooleanOverride(_ result: BooleanOverride) {
        guard var context = toolContext, context.booleanOverride != result else { return }
        context.booleanOverride = result
        // Validity depends on the pending result kind.
        rebuildToolPreview(&context)
        toolContext = context
    }

    func setRevolveAngle(_ angle: Double) {
        guard var context = toolContext, case .revolve(let axis, let current) = context.kind else { return }
        let clamped = min(max(angle, 1), 360)
        // Skip the redundant CSG rebuild when the (snapped) angle is unchanged —
        // see setExtrudeDistance for why consecutive drag events repeat values.
        guard abs(clamped - current) > 1e-6 else { return }
        context.kind = .revolve(axis: axis, angle: clamped)
        rebuildToolPreview(&context)
        toolContext = context
    }

    /// Commits whichever profile tool is active (extrude or revolve).
    func commitTool() {
        cachedPullWorldBody = nil
        guard let context = toolContext else {
            cancelTool()
            return
        }
        switch context.kind {
        case .extrude(let distance):
            commitExtrude(context, distance: distance)
        case .revolve(_, let angle):
            commitRevolve(context, angle: angle)
        case .offsetPlane(let distance):
            commitOffsetPlane(context, distance: distance)
        case .sweep(let spine):
            commitSweep(context, spine: spine)
        case .loft:
            commitLoft(context)
        }
    }

    // MARK: - Offset construction plane (spec §6.1, Offset)

    /// "Offset Plane" on a selected face: switch the pull to dragging a copy
    /// of the face plane along its normal.
    func beginOffsetPlane() {
        guard case .faceSelected = mode, var context = toolContext else { return }
        context.kind = .offsetPlane(distance: 2)
        context.preview = nil
        toolContext = context
    }

    func setOffsetPlaneDistance(_ distance: Double) {
        guard var context = toolContext, case .offsetPlane = context.kind else { return }
        context.kind = .offsetPlane(distance: distance)
        toolContext = context
    }

    /// The dragged plane: the face plane shifted along its normal, sized to
    /// cover the face outline with a margin.
    private func offsetPlanePreview(
        _ context: ToolContext, distance: Double
    ) -> (plane: SketchPlane, size: Double) {
        let n = simd_normalize(context.plane.normal)
        let centroid = context.profile.centroid
        let origin = context.plane.toWorld(centroid) + n * distance
        var radius = 1.0
        for p in context.profile.loop {
            radius = max(radius, simd_length(p - centroid))
        }
        // Offset from a body face: lay the new plane out like a face sketch
        // (see `SketchPlane.readable`); offset from a sketch keeps its axes.
        let plane = context.sourceBody != nil
            ? SketchPlane.readable(origin: origin, normal: context.plane.normal)
            : SketchPlane(origin: origin, xAxis: context.plane.xAxis, yAxis: context.plane.yAxis)
        return (plane, radius * 2.5)
    }

    private func commitOffsetPlane(_ context: ToolContext, distance: Double) {
        guard abs(distance) > 1e-4 else {
            cancelTool()
            return
        }
        let pending = offsetPlanePreview(context, distance: distance)
        session.perform(AddConstructionPlaneCommand(
            plane: ConstructionPlane(plane: pending.plane, size: pending.size)
        ))
        toolContext = nil
        selection.removeAll()
        mode = .idle
        session.save()
    }

    private func commitExtrude(_ context: ToolContext, distance: Double) {
        guard abs(distance) > 1e-4, let preview = context.preview else {
            cancelTool()
            return
        }

        // Face push/pull modifies its own body directly (coincident-wall-safe
        // truncation/extension), not via a same-cross-section boolean.
        if context.isFaceOperation, context.booleanOverride == .auto {
            commitFaceOperation(context, distance: distance)
            return
        }

        // Automatic boolean (Shapr3D Extrude): pulled away from a body →
        // union; pushed into a body → subtract; touching nothing → new body.
        let n = context.plane.normal
        let sign: Double = distance >= 0 ? 1 : -1
        let sampleWorld = context.plane.toWorld(context.profile.centroid) + n * sign * 0.01
        let sample = Vector(sampleWorld.x, sampleWorld.y, sampleWorld.z)

        commitToolResult(
            preview: preview,
            mergeTool: overlapExtrudeTool(context, distance: distance),
            sample: sample,
            title: "Extrude",
            context: context
        )
    }

    /// The source body's world mesh after a face push/pull. Robust against
    /// coincident walls (the failure mode of a same-cross-section boolean):
    /// - inward push (distance < 0) truncates via a half-space cut whose lateral
    ///   walls sit far outside the body, so only the new face plane cuts;
    /// - outward pull (distance > 0) unions a flush prism (union tolerates the
    ///   coincident side walls, merging them into one continuous wall).
    /// Returns nil when the source body is gone or the result is empty.
    /// Enter radial push/pull on a plain cylinder: the pull arrow points
    /// radially outward at the tap point, and dragging edits the radius.
    private func beginCylinderRadial(
        body: Body, cylinder cyl: FaceTopology.CylindricalFace, hit: PickHit
    ) {
        let transform = body.transform
        let worldAxisDir = simd_normalize(transform.rotation.act(cyl.axisDir))
        let worldAxisPoint = transform.applying(to: cyl.axisPoint)
        let hitWorld = SIMD3<Double>(Double(hit.worldPoint.x), Double(hit.worldPoint.y), Double(hit.worldPoint.z))
        let along = simd_dot(hitWorld - worldAxisPoint, worldAxisDir)
        let onAxis = worldAxisPoint + worldAxisDir * along
        var radialWorld = hitWorld - onAxis
        radialWorld = simd_length(radialWorld) < 1e-9 ? SIMD3(1, 0, 0) : simd_normalize(radialWorld)

        // Plane whose normal is the outward radial: pull arrow points outward.
        let xAxis = worldAxisDir
        var yAxis = simd_cross(radialWorld, worldAxisDir)
        yAxis = simd_length(yAxis) < 1e-9
            ? simd_normalize(simd_cross(radialWorld, SIMD3(0, 1, 0)))
            : simd_normalize(yAxis)
        var plane = SketchPlane(origin: hitWorld, xAxis: xAxis, yAxis: yAxis)
        if simd_dot(plane.normal, radialWorld) < 0 {
            plane = SketchPlane(origin: hitWorld, xAxis: xAxis, yAxis: -yAxis)
        }

        // A tiny profile centred at the plane origin anchors the pull arrow.
        let tiny: [SIMD2<Double>] = [
            SIMD2(-0.001, -0.001), SIMD2(0.001, -0.001),
            SIMD2(0.001, 0.001), SIMD2(-0.001, 0.001),
        ]
        toolContext = ToolContext(
            profile: Profile(loop: tiny, kind: .polygonal, sourceEntityIDs: []),
            holes: [],
            plane: plane,
            sketchID: nil,
            sourceBody: body.id,
            faceTriangles: cyl.triangles,
            cylinderFace: cyl,
            kind: .extrude(distance: 0)
        )
        mode = .faceSelected(body.id)
    }

    /// - Parameter finalize: when false (the live drag preview) the expensive
    ///   `makeWatertight()` seam-weld is skipped — the raw boolean renders fine
    ///   and only the committed mesh needs to be watertight.
    private func faceModifiedMesh(_ context: ToolContext, distance: Double, finalize: Bool = true) -> Euclid.Mesh? {
        guard let sourceID = context.sourceBody,
              let source = session.document.body(with: sourceID)
        else { return nil }

        // Cylindrical side push/pull: rebuild the whole cylinder at the new
        // radius (distance is the radial delta). Local params → world via the
        // body transform.
        if let cyl = context.cylinderFace {
            let newRadius = cyl.radius + distance / max(source.transform.scale, 1e-6)
            guard newRadius > 1e-3 else { return nil }
            let grown = KernelOps.cylinderAlongAxis(
                baseCenter: cyl.baseCenter,
                axisDir: cyl.axisDir,
                radius: newRadius,
                height: cyl.height,
                slices: 48
            )
            return grown.transformed(by: source.transform.euclid)
        }

        // The source is immutable for the whole drag, so deserialize + transform
        // it once and reuse the cached copy on every subsequent frame.
        let worldBody: Euclid.Mesh
        if let cached = cachedPullWorldBody {
            worldBody = cached
        } else {
            worldBody = source.euclidMesh().transformed(by: source.transform.euclid)
            cachedPullWorldBody = worldBody
        }
        let n = context.plane.normal

        if distance < 0 {
            // Move the face plane into the body; keep the interior (−n) side.
            let cutOrigin = context.plane.origin + n * distance
            let cutPlane = SketchPlane(
                origin: cutOrigin, xAxis: context.plane.xAxis, yAxis: context.plane.yAxis
            )
            let truncated = SplitKit.split(mesh: worldBody, byPlane: cutPlane).other
            return truncated.polygons.isEmpty ? nil : truncated
        } else {
            let prism = KernelOps.extrude(
                profile: context.profile,
                holes: context.holes,
                in: context.plane,
                distance: distance
            )
            guard !prism.polygons.isEmpty else { return nil }
            let merged = worldBody.union(prism)
            return finalize ? merged.makeWatertight() : merged
        }
    }

    /// Slightly overlapped tool (union of all profile prisms) so coplanar
    /// seams merge cleanly. Delegates to `KernelOps.overlapExtrudeTool` so the
    /// live cut and the feature-graph replay share one implementation.
    private func overlapExtrudeTool(_ context: ToolContext, distance: Double) -> Euclid.Mesh {
        KernelOps.overlapExtrudeTool(
            profile: context.profile,
            holes: context.holes,
            extraProfiles: context.extraProfiles,
            in: context.plane,
            distance: distance,
            symmetric: context.symmetric
        )
    }

    /// Commit a face push/pull: replace the source body with its truncated or
    /// extended mesh, preserving the pivot (rotation/scale bake in).
    private func commitFaceOperation(_ context: ToolContext, distance: Double) {
        guard let sourceID = context.sourceBody,
              let source = session.document.body(with: sourceID),
              let modified = faceModifiedMesh(context, distance: distance),
              !modified.polygons.isEmpty
        else {
            errorMessage = distance < 0
                ? "The push removed the entire body."
                : "The pull produced no geometry."
            cancelTool()
            return
        }
        let pivot = source.transform.translation
        var transform = Transform3D.identity
        transform.translation = pivot
        let localMesh = modified.translated(by: Vector(-pivot.x, -pivot.y, -pivot.z))
        let after = Body(
            id: source.id,
            name: source.name,
            transform: transform,
            primitive: nil,
            euclidMesh: localMesh,
            revision: 0
        )
        let replace = ReplaceBodyCommand(title: "Push/Pull", before: source, after: after)

        // Phase D (Task C2): record a `.pushPull(.planarAxial)` feature node when
        // this is a PLANAR face op on a feature-produced body. The FaceRef pins
        // the pushed face by geometric signature so it follows the geometry after
        // an upstream edit. Cylinder-radial pulls (tranche 2) and face ops on
        // non-feature bodies are skipped (couldn't be faithfully replayed).
        if context.cylinderFace == nil,
           let owner = featureNode(owning: sourceID),
           let faceRef = pushPullFaceRef(context: context, source: source, creator: owner.id) {
            let node = FeatureNode(
                name: "Push/Pull",
                kind: .pushPull(
                    face: faceRef, distance: Expr(value: distance), mode: .planarAxial),
                outputBodyIDs: [sourceID])
            session.perform(CompositeCommand(
                title: "Push/Pull", commands: [replace, AppendFeatureCommand(node: node)]))
        } else {
            session.perform(replace)
        }
        toolContext = nil
        mode = .selected(source.id)
        selection = [source.id]
        session.save()
    }

    private func commitRevolve(_ context: ToolContext, angle: Double) {
        guard angle >= 1, let preview = context.preview else {
            cancelTool()
            return
        }
        // The revolved solid has no push/pull direction: no subtract sample;
        // overlapping bodies merge by union, otherwise it's a new body.
        commitToolResult(
            preview: preview,
            mergeTool: preview.euclidMesh(),
            sample: nil,
            title: "Revolve",
            context: context
        )
    }

    /// Shared commit tail: honor the Boolean badge override, or scan candidate
    /// bodies for an automatic boolean (inside `sample` → subtract,
    /// overlapping → union), else add a new stand-alone body from the preview.
    private func commitToolResult(
        preview: Body,
        mergeTool: Euclid.Mesh,
        sample: Vector?,
        title: String,
        context: ToolContext
    ) {
        if context.booleanOverride == .newBody {
            addStandaloneToolBody(preview: preview, title: title, context: context)
            return
        }

        // Scan: which bodies does the tool touch, and does it push into any?
        // "Touch" requires REAL overlap volume — a body merely flush against
        // the tool (shared wall) intersects into zero-volume slivers and must
        // stay untouched, or extrudes would grab adjacent bodies.
        //
        // An EXPLICIT Union is the exception: a boss sketched on a face and
        // extruded away from it touches the body only along that face — zero
        // overlap volume — and "Union" is the user saying "join it anyway".
        // Found building SOLIDWORKS practice problem 1.1 by touch (2026-09-04):
        // the stepped tower extruded off the base's face with Result = Union
        // came back as a SECOND body. The flush contact leaves zero-volume
        // sliver polygons in the intersection (the very signal Auto had to
        // stop trusting), so an explicit union accepts contact as touching.
        // AABB gate before any CSG: bodies nowhere near the tool cost
        // nothing. Inflated a hair so flush contact (explicit Union) passes.
        let toolBounds = mergeTool.bounds
        let gate = Euclid.Bounds(
            min: toolBounds.min - Vector(1e-3, 1e-3, 1e-3),
            max: toolBounds.max + Vector(1e-3, 1e-3, 1e-3))
        var touched: [(target: Body, worldTarget: Euclid.Mesh, pushesIn: Bool)] = []
        for target in booleanCandidates(for: context) {
            guard context.sourceBody == target.id
                    || gate.intersects(Self.worldBounds(of: target)) else { continue }
            let worldTarget = target.euclidMesh().transformed(by: target.transform.euclid)
            let pushesIn = sample.map { worldTarget.intersects($0) } ?? false
            let overlap = worldTarget.intersection(mergeTool)
            let touches = pushesIn
                || context.sourceBody == target.id
                || KernelOps.volume(of: overlap) > 1e-4
                || (context.booleanOverride == .union && !overlap.polygons.isEmpty)
            if touches {
                touched.append((target, worldTarget, pushesIn))
            }
        }

        // An explicit boolean aimed at a heavy mesh gets told why nothing
        // happened, instead of a silent stand-alone body or a stall.
        if touched.isEmpty, context.booleanOverride != .auto,
           let heavy = BooleanCandidacy.heavyBodies(in: session.document.bodies)
               .first(where: { gate.intersects(Self.worldBounds(of: $0)) }) {
            errorMessage = BooleanCandidacy.refusalMessage(for: heavy)
            return
        }

        let kind: BooleanKind
        switch context.booleanOverride {
        case .auto:
            guard !touched.isEmpty else {
                addStandaloneToolBody(preview: preview, title: title, context: context)
                return
            }
            kind = touched.contains { $0.pushesIn } ? .subtract : .union
        case .union:
            guard !touched.isEmpty else {
                // Spec §4.1: a Union touching no body stays a separate body.
                addStandaloneToolBody(preview: preview, title: title, context: context)
                return
            }
            kind = .union
        case .subtract, .intersect:
            guard !touched.isEmpty else {
                // Keep the tool active so the user can adjust and retry.
                errorMessage = "The \(context.booleanOverride.rawValue.lowercased()) result is empty — the tool doesn't touch any body."
                return
            }
            kind = context.booleanOverride == .subtract ? .subtract : .intersect
        case .newBody:
            return // handled above
        }

        // Cut scope (spec §4.1): a subtract applies to EVERY intersected
        // body; union/intersect keep the first touched target.
        let targets = kind == .subtract ? touched : [touched[0]]
        let hides = consumedSketchHideCommands(context)

        // Phase D: a SINGLE feature-owned target replays through the graph, so
        // the committed body is the evaluator's result — an OCCT B-rep with
        // analytic holes, STEP export and fast blends — not the Euclid mesh the
        // preview was drawn from. Found live 2026-09-03: a touch-committed cut
        // left the body mesh-only (a 25 mm hole came out a 48-gon, 0.29 %
        // small) while the same node over the agent bridge stayed exact,
        // because the node was appended here but never evaluated. The mesh
        // result below stays the fallback when the replay reports an error,
        // and the path for multi-body cuts and non-feature targets, which the
        // evaluators can't replay.
        if targets.count == 1,
           let targetOwner = featureNode(owning: targets[0].target.id),
           let node = toolFeatureNode(
               context: context,
               boolean: BooleanIntent(
                   op: kind.featureOp,
                   resolvedTargets: [BodyRef(
                       producer: targetOwner.id, bodyID: targets[0].target.id)]),
               outputBodyIDs: [targets[0].target.id]) {
            session.recordAndRebuild([node], extra: hides, title: title)
            if session.lastEvalErrors[node.id] == nil {
                finishToolCommit(selecting: targets[0].target.id)
                return
            }
            session.undo()
        }

        var commands: [DocumentCommand] = []
        for entry in targets {
            let merged: Euclid.Mesh
            switch kind {
            case .union:
                merged = entry.worldTarget.union(mergeTool).makeWatertight()
            case .subtract:
                merged = entry.worldTarget.subtracting(mergeTool).makeWatertight()
            case .intersect:
                merged = entry.worldTarget.intersection(mergeTool).makeWatertight()
            }
            guard !merged.polygons.isEmpty else {
                errorMessage = kind == .intersect
                    ? "The intersection is empty — the bodies don't overlap."
                    : "The cut removed the entire body."
                cancelTool()
                return
            }

            // Preserve the pivot; rotation/scale bake into the mesh.
            let pivot = entry.target.transform.translation
            var transform = Transform3D.identity
            transform.translation = pivot
            let localMesh = merged.translated(by: Vector(-pivot.x, -pivot.y, -pivot.z))
            let after = Body(
                id: entry.target.id,
                name: entry.target.name,
                transform: transform,
                primitive: nil,
                euclidMesh: localMesh,
                revision: 0 // assigned by the command
            )
            commands.append(ReplaceBodyCommand(title: title, before: entry.target, after: after))
        }

        // Shapr3D parity (spec §11): sketches auto-hide once a tool consumes
        // them into a body, in the same undo step.
        commands.append(contentsOf: hides)
        // Record the tool's feature node with the resolved boolean intent even
        // on this mesh path (as before the replay above existed), but only for
        // a SINGLE feature-owned target — the evaluators apply one boolean
        // into one target, so a multi-body cut or a non-feature target
        // couldn't be faithfully replayed.
        if targets.count == 1,
           let targetOwner = featureNode(owning: targets[0].target.id),
           let node = toolFeatureNode(
               context: context,
               boolean: BooleanIntent(
                   op: kind.featureOp,
                   resolvedTargets: [BodyRef(
                       producer: targetOwner.id, bodyID: targets[0].target.id)]),
               outputBodyIDs: [targets[0].target.id]) {
            commands.append(AppendFeatureCommand(node: node))
        }
        if commands.count == 1 {
            session.perform(commands[0])
        } else {
            // Multi-body cut is one undo step.
            session.perform(CompositeCommand(title: title, commands: commands))
        }
        finishToolCommit(selecting: targets[0].target.id)
    }

    /// The tool is down; its result is the selection.
    private func finishToolCommit(selecting id: BodyID) {
        toolContext = nil
        mode = .selected(id)
        selection = [id]
        session.save()
    }

    /// New stand-alone body from the preview, pivot at the profile centroid.
    private func addStandaloneToolBody(preview: Body, title: String, context: ToolContext) {
        let centroidWorld = context.plane.toWorld(context.profile.centroid)
        var transform = Transform3D.identity
        transform.translation = centroidWorld
        let localMesh = preview.euclidMesh().translated(
            by: Vector(-centroidWorld.x, -centroidWorld.y, -centroidWorld.z)
        )

        let name = session.document.uniqueBodyName(base: title)
        let body = Body(
            name: name,
            transform: transform,
            primitive: nil,
            euclidMesh: localMesh,
            revision: preview.meshRevision
        )
        let hides = consumedSketchHideCommands(context)
        // A new stand-alone tool body is a `.newBody` history node; replaying
        // it makes the body the evaluator's B-rep (see `commitToolResult`).
        // The preview mesh below is the fallback when the replay errors.
        if let node = toolFeatureNode(
            context: context,
            boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
            outputBodyIDs: [body.id]) {
            session.recordAndRebuild([node], extra: hides, title: title)
            if session.lastEvalErrors[node.id] == nil,
               session.document.bodies.contains(where: { $0.id == body.id }) {
                finishToolCommit(selecting: body.id)
                return
            }
            session.undo()
        }
        var commands: [DocumentCommand] = [AddBodyCommand(body: body, title: title)]
        commands.append(contentsOf: hides)
        if let node = toolFeatureNode(
            context: context,
            boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
            outputBodyIDs: [body.id]) {
            commands.append(AppendFeatureCommand(node: node))
        }
        if commands.count == 1 {
            session.perform(commands[0])
        } else {
            session.perform(CompositeCommand(title: title, commands: commands))
        }
        finishToolCommit(selecting: body.id)
    }

    /// Hide-the-consumed-sketch commands for a committing tool (Shapr3D
    /// parity, spec §11): every sketch that fed the new body — the profile's
    /// sketch, each loft section's, and any sweep-spine sketch — auto-hides
    /// in the same undo step. Face pulls have no sketch, and already-hidden
    /// sketches need no command.
    private func consumedSketchHideCommands(_ context: ToolContext) -> [DocumentCommand] {
        var ids: [SketchID] = []
        if let id = context.sketchID { ids.append(id) }
        for entry in context.loftProfiles where !ids.contains(entry.sketchID) {
            ids.append(entry.sketchID)
        }
        if !context.sweepPathEntityIDs.isEmpty {
            for sketch in session.document.sketches
            where !ids.contains(sketch.id) && sketch.entities.contains(where: {
                context.sweepPathEntityIDs.contains($0.id)
            }) {
                ids.append(sketch.id)
            }
        }
        return ids.compactMap { id in
            guard let sketch = session.document.sketches.first(where: { $0.id == id }),
                  !sketch.isHidden
            else { return nil }
            return SetItemVisibilityCommand(item: .sketch(id), isHidden: true)
        }
    }

    func cancelTool() {
        toolContext = nil
        extrudeDragAnchor = nil
        cachedPullWorldBody = nil
        faceMoveActive = false
        faceScaleActive = false
        faceRotateActive = false
        switch mode {
        case .extruding, .faceSelected, .pickingRevolveAxis,
             .pickingSweepPath, .pickingLoftProfiles:
            mode = .idle
        default:
            break
        }
    }

    // MARK: - Revolve axis picking

    /// "Revolve" in the extrude bar: the next tap must land on a sketch line,
    /// which becomes the axis of revolution.
    func beginRevolveAxisPick() {
        guard case .extruding = mode, let context = toolContext,
              context.sketchID != nil
        else { return }
        mode = .pickingRevolveAxis
    }

    func cancelRevolveAxisPick() {
        if case .pickingRevolveAxis = mode {
            mode = .extruding
        }
    }

    private func pickRevolveAxis(ray: Ray) {
        guard let context = toolContext,
              let sketchID = context.sketchID,
              let sketch = session.document.sketches.first(where: { $0.id == sketchID })
        else {
            cancelTool()
            return
        }
        let plane = context.plane
        let planePoint = SIMD3<Float>(Float(plane.origin.x), Float(plane.origin.y), Float(plane.origin.z))
        let n = plane.normal
        let planeNormal = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
        guard let t = ray.intersect(planePoint: planePoint, planeNormal: planeNormal) else { return }
        let world = ray.point(at: t)
        let local = plane.toLocal(SIMD3(Double(world.x), Double(world.y), Double(world.z)))

        let tolerance = SnapEngine.pointTolerance * 2

        // A construction axis lying in the sketch plane is a first-class
        // revolve axis (spec §6.2 — "creating an axis for a revolved body" is
        // one of the manual's own stated reasons to make one). Checked before
        // sketch lines because an axis is the more deliberate choice: you had
        // to build it.
        if let axis = nearestUsableRevolveAxis(to: world, plane: plane, tolerance: tolerance) {
            applyRevolveAxis(axis, context: context)
            return
        }

        // Otherwise the nearest line entity within a forgiving tap tolerance;
        // taps that miss everything keep the picking mode armed. Construction
        // lines are preferred axis candidates (spec §3.3): any construction hit
        // beats any regular hit; ties within a class break by distance.
        var best: (a: SIMD2<Double>, b: SIMD2<Double>, distance: Double, isConstruction: Bool)?
        for entity in sketch.entities {
            guard case .line(let id, let a, let b) = entity else { continue }
            let d = Self.distanceToSegment(local, a: a, b: b)
            guard d <= tolerance else { continue }
            let isConstruction = sketch.isConstruction(id)
            let better: Bool = if let current = best {
                isConstruction != current.isConstruction
                    ? isConstruction
                    : d < current.distance
            } else {
                true
            }
            if better {
                best = (a, b, d, isConstruction)
            }
        }
        guard let line = best else { return }
        applyRevolveAxis(
            RevolveAxis(point: line.a, direction: line.b - line.a), context: context)
    }

    /// Commit a chosen revolve axis into the live tool context, or report the
    /// one failure Shapr3D also reports.
    private func applyRevolveAxis(_ axis: RevolveAxis, context: ToolContext) {
        var candidate = context
        candidate.kind = .revolve(axis: axis, angle: 360)
        rebuildToolPreview(&candidate)
        guard candidate.preview != nil else {
            // Profile crosses (or collapses onto) the axis — Shapr3D errors too.
            errorMessage = "The profile crosses the axis line. Pick a line beside the profile."
            mode = .extruding
            return
        }
        toolContext = candidate
        mode = .extruding
    }

    /// The nearest visible construction axis to a tapped world point that can
    /// actually serve as a revolve axis for `plane`.
    ///
    /// "Can serve" means it LIES IN the plane: revolving a profile about an
    /// axis skew to its own plane is not defined, so an axis that merely
    /// passes nearby is rejected rather than silently projected onto the plane
    /// (which would revolve about a line the user never drew).
    private func nearestUsableRevolveAxis(
        to world: SIMD3<Float>, plane: SketchPlane, tolerance: Double
    ) -> RevolveAxis? {
        let p = SIMD3<Double>(Double(world.x), Double(world.y), Double(world.z))
        var best: (axis: RevolveAxis, distance: Double)?
        for axis in session.document.axes where !axis.isHidden {
            let distance = axis.distance(to: p)
            guard distance <= tolerance else { continue }
            let (start, end) = axis.endpoints
            // Both ends on the plane ⇒ the whole (infinite) line is on it.
            guard abs(simd_dot(start - plane.origin, plane.normal)) <= tolerance,
                  abs(simd_dot(end - plane.origin, plane.normal)) <= tolerance
            else { continue }
            let a = plane.toLocal(start)
            let b = plane.toLocal(end)
            guard simd_length(b - a) > 1e-9 else { continue }
            if best == nil || distance < best!.distance {
                best = (RevolveAxis(point: a, direction: b - a), distance)
            }
        }
        return best?.axis
    }

    static func distanceToSegment(
        _ p: SIMD2<Double>, a: SIMD2<Double>, b: SIMD2<Double>
    ) -> Double {
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 1e-18 else { return simd_length(p - a) }
        let t = min(max(simd_dot(p - a, ab) / lengthSquared, 0), 1)
        return simd_length(p - (a + ab * t))
    }

    // MARK: - Sweep path picking (plan §B1, spec §4.11)

    /// "Sweep" in the extrude bar: subsequent taps on open sketch entities
    /// (lines/arcs, any visible sketch) chain into the sweep spine.
    func beginSweepPathPick() {
        guard case .extruding = mode, let context = toolContext,
              context.sketchID != nil
        else { return }
        mode = .pickingSweepPath
    }

    /// Cancel returns to the plain extrude tool (like the revolve axis pick).
    func cancelSweepPathPick() {
        guard case .pickingSweepPath = mode else { return }
        guard var context = toolContext else {
            mode = .idle
            return
        }
        context.kind = .extrude(distance: 2)
        context.sweepPathEntityIDs = []
        rebuildToolPreview(&context)
        toolContext = context
        mode = .extruding
    }

    /// Tap while picking the sweep path: the nearest open entity chains onto
    /// the spine; tapping empty space commits a nonempty path (extrude's rule).
    private func pickSweepPathEntity(ray: Ray) {
        guard var context = toolContext else {
            cancelTool()
            return
        }
        let tolerance = SketchHitTester.screenPickTolerance(worldUnitsPerPoint: worldPerPoint)
        var best: (entity: SketchEntity, plane: SketchPlane, distance: Double)?
        for sketch in session.document.sketches where !sketch.isHidden {
            guard let local = localPoint(of: ray, on: sketch.plane) else { continue }
            for entity in sketch.entities {
                guard let points = Self.sweepPathPolyline(of: entity) else { continue }
                var distance = Double.infinity
                for i in 1..<points.count {
                    distance = min(
                        distance,
                        Self.distanceToSegment(local, a: points[i - 1], b: points[i])
                    )
                }
                if distance <= tolerance, best == nil || distance < best!.distance {
                    best = (entity, sketch.plane, distance)
                }
            }
        }
        guard let hit = best else {
            if case .sweep = context.kind { commitTool() }
            return
        }
        guard !context.sweepPathEntityIDs.contains(hit.entity.id),
              let localPolyline = Self.sweepPathPolyline(of: hit.entity)
        else { return }

        let segment = localPolyline.map { hit.plane.toWorld($0) }
        let spine: [SIMD3<Double>]
        if case .sweep(let existing) = context.kind, existing.count >= 2 {
            guard let joined = Self.chainedSpine(existing, adding: segment) else {
                errorMessage = "That segment doesn't connect to the end of the path."
                return
            }
            spine = joined
        } else {
            // First segment: start at the endpoint nearest the profile.
            let anchor = context.plane.toWorld(context.profile.centroid)
            spine = simd_length(segment.last! - anchor) < simd_length(segment.first! - anchor)
                ? segment.reversed()
                : segment
        }
        context.sweepPathEntityIDs.append(hit.entity.id)
        context.kind = .sweep(spine: spine)
        rebuildToolPreview(&context)
        toolContext = context
    }

    /// Plane-local polyline of an OPEN entity (lines/arcs); closed entities
    /// can't chain into a spine.
    nonisolated static func sweepPathPolyline(of entity: SketchEntity) -> [SIMD2<Double>]? {
        switch entity {
        case let .line(_, a, b):
            return [a, b]
        case let .arc(_, center, radius, startAngle, endAngle):
            let points = SketchEntity.arcPoints(
                center: center, radius: radius,
                startAngle: startAngle, endAngle: endAngle,
                segmentsPerTurn: SketchTessellator.circleSegments
            )
            return points.count >= 2 ? points : nil
        case let .spline(_, points, closed):
            // An open spline is a valid sweep spine — this is the main reason
            // to have splines at all (spec §4.11 sweeps along a drawn curve).
            guard !closed else { return nil }
            let curve = SketchEntity.splinePoints(points, closed: false)
            return curve.count >= 2 ? curve : nil
        case .rect, .circle, .ellipse, .polygon:
            return nil
        }
    }

    /// Append `segment` to `spine`, reversed so its nearer endpoint meets the
    /// spine's end; nil when neither endpoint is within `tolerance`. The
    /// junction point is dropped so tiny gaps close onto the spine end.
    nonisolated static func chainedSpine(
        _ spine: [SIMD3<Double>],
        adding segment: [SIMD3<Double>],
        tolerance: Double = 0.75
    ) -> [SIMD3<Double>]? {
        guard let end = spine.last, let first = segment.first, let last = segment.last
        else { return nil }
        let dFirst = simd_length(first - end)
        let dLast = simd_length(last - end)
        guard min(dFirst, dLast) <= tolerance else { return nil }
        let oriented: [SIMD3<Double>] = dLast < dFirst ? segment.reversed() : segment
        return spine + oriented.dropFirst()
    }

    /// Ray → plane-local point on an arbitrary plane.
    private func localPoint(of ray: Ray, on plane: SketchPlane) -> SIMD2<Double>? {
        let planePoint = SIMD3<Float>(
            Float(plane.origin.x), Float(plane.origin.y), Float(plane.origin.z)
        )
        let n = plane.normal
        let planeNormal = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
        guard let t = ray.intersect(planePoint: planePoint, planeNormal: planeNormal) else {
            return nil
        }
        let world = ray.point(at: t)
        return plane.toLocal(SIMD3(Double(world.x), Double(world.y), Double(world.z)))
    }

    private func commitSweep(_ context: ToolContext, spine: [SIMD3<Double>]) {
        guard spine.count >= 2, let preview = context.preview else {
            cancelTool()
            return
        }
        // Like revolve: no push/pull direction — union overlapping bodies,
        // otherwise a new body.
        commitToolResult(
            preview: preview,
            mergeTool: preview.euclidMesh(),
            sample: nil,
            title: "Sweep",
            context: context
        )
    }

    // MARK: - Loft (plan §B2, spec §4.5 profiles-only)

    /// "Loft" in the extrude bar: the armed profile becomes section 1; taps
    /// on more profile fills (any plane) append sections in tap order.
    func beginLoftProfilePick() {
        guard case .extruding = mode, var context = toolContext,
              let sketchID = context.sketchID
        else { return }
        context.loftProfiles = [(context.profile, context.holes, context.plane, sketchID)]
        context.kind = .loft
        rebuildToolPreview(&context)
        toolContext = context
        mode = .pickingLoftProfiles
    }

    /// Cancel returns to the plain extrude tool.
    func cancelLoftProfilePick() {
        guard case .pickingLoftProfiles = mode else { return }
        guard var context = toolContext else {
            mode = .idle
            return
        }
        context.kind = .extrude(distance: 2)
        context.loftProfiles = []
        rebuildToolPreview(&context)
        toolContext = context
        mode = .extruding
    }

    /// Tap while picking loft sections: any profile fill appends a section.
    private func pickLoftProfile(ray: Ray) {
        guard var context = toolContext, case .loft = context.kind else {
            cancelTool()
            return
        }
        guard let hit = profileHit(ray: ray) else { return }
        // The same fill can't be a section twice.
        guard !context.loftProfiles.contains(where: {
            $0.sketchID == hit.sketchID
                && $0.profile.sourceEntityIDs == hit.profile.sourceEntityIDs
        }) else { return }
        context.loftProfiles.append((hit.profile, hit.holes, hit.plane, hit.sketchID))
        rebuildToolPreview(&context)
        toolContext = context
    }

    private func commitLoft(_ context: ToolContext) {
        guard context.loftProfiles.count >= 2 else {
            cancelTool()
            return
        }
        // Coplanar sections loft to a zero-thickness sheet — reject upfront
        // and keep the tool armed so another section can be added.
        let firstPlane = context.loftProfiles[0].plane
        guard context.loftProfiles.contains(where: {
            !$0.plane.isCoincident(with: firstPlane)
        }) else {
            errorMessage = "Loft sections must lie on different planes — add a profile on another plane or face."
            return
        }
        guard let preview = context.preview else {
            errorMessage = "The loft produced no geometry."
            cancelTool()
            return
        }
        commitToolResult(
            preview: preview,
            mergeTool: preview.euclidMesh(),
            sample: nil,
            title: "Loft",
            context: context
        )
    }

    // MARK: - Helix (plan §B16, spec §1.17 minimal: a helix drives a sweep)

    /// "Helix" in the extrude bar: sweep the armed profile along a generated
    /// helical spine (coiling up the sketch-plane normal, starting at the
    /// profile centroid) and commit immediately.
    func commitHelixSweep(radius: Double, pitch: Double, turns: Double) {
        guard var context = toolContext, case .extrude = context.kind else { return }
        guard radius > 1e-6, turns > 1e-3, abs(pitch) > 1e-9 else {
            errorMessage = "Helix needs a positive radius, pitch, and turns."
            return
        }
        // Center the coil so the spine STARTS at the profile centroid — the
        // profile rides the helix (Shapr3D: profile at the path start).
        let center = context.profile.centroid - SIMD2(radius, 0)
        let spine = HelixKit.path(
            radius: radius, pitch: pitch, turns: turns,
            center: center, in: context.plane
        )
        guard spine.count >= 2 else {
            errorMessage = "The helix parameters produced no path."
            return
        }
        context.kind = .sweep(spine: spine)
        context.sweepPathEntityIDs = []
        rebuildToolPreview(&context)
        guard context.preview != nil else {
            errorMessage = "The helix sweep produced no geometry."
            return
        }
        toolContext = context
        commitTool()
    }

    // MARK: - Tool drag (extrude: pull along the plane normal; revolve: angle)

    /// Degrees of revolve sweep per world unit of screen-space drag.
    private static let revolveDegreesPerWorldUnit: Double = 30

    func beginToolDrag(ray: Ray) -> Bool {
        guard let context = toolContext else { return false }
        // Start each drag with a clean cache so the first preview frame rebuilds
        // from the current source (not a body memoised during a prior commit).
        cachedPullWorldBody = nil
        switch context.kind {
        case .extrude(let distance), .offsetPlane(let distance):
            let centroid = context.profile.centroid
            let world = context.plane.toWorld(centroid)
            let n = context.plane.normal
            let axisOrigin = SIMD3<Float>(Float(world.x), Float(world.y), Float(world.z))
            let axisDirection = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
            if abs(simd_dot(ray.direction, axisDirection)) < 0.95 {
                extrudeDragAnchor = LineMath.closestParamOnLine(
                    origin: axisOrigin, direction: axisDirection, to: ray
                )
            } else {
                extrudeDragAnchor = nil // head-on: screen-space fallback
            }
            toolDragStartValue = distance
        case .revolve(_, let angle):
            extrudeDragAnchor = nil // angle drags are always screen-space
            toolDragStartValue = angle
        case .sweep, .loft:
            return false // no drag-editable parameter
        }
        return true
    }

    /// `screenDeltaWorld`: cumulative drag distance since `.began` converted
    /// to world units by the viewport (positive = screen-up). Used when the
    /// camera looks straight down the pull axis, and to scrub revolve angles.
    func updateToolDrag(ray: Ray, screenDeltaWorld: Double) {
        guard let context = toolContext else { return }
        switch context.kind {
        case .extrude, .offsetPlane:
            let raw: Double
            if let anchor = extrudeDragAnchor {
                let centroid = context.profile.centroid
                let world = context.plane.toWorld(centroid)
                let n = context.plane.normal
                let axisOrigin = SIMD3<Float>(Float(world.x), Float(world.y), Float(world.z))
                let axisDirection = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
                guard let param = LineMath.closestParamOnLine(
                    origin: axisOrigin, direction: axisDirection, to: ray
                ) else { return }
                raw = toolDragStartValue + Double(param - anchor)
            } else {
                raw = toolDragStartValue + screenDeltaWorld
            }
            // Snap to 0.5 steps, like the sketch grid.
            let snapped = (raw / 0.5).rounded() * 0.5
            let value = abs(raw - snapped) < 0.15 ? snapped : raw
            if case .offsetPlane = context.kind {
                setOffsetPlaneDistance(value)
            } else {
                setExtrudeDistance(value)
            }
        case .revolve:
            let raw = toolDragStartValue + screenDeltaWorld * Self.revolveDegreesPerWorldUnit
            // Snap to 15° stops (90, 180, …) with a small capture window.
            let snapped = (raw / 15).rounded() * 15
            setRevolveAngle(abs(raw - snapped) < 4 ? snapped : raw)
        case .sweep, .loft:
            break // no drag-editable parameter
        }
    }

    func endToolDrag() {
        // Shapr3D: releasing the drag keeps the dynamic preview so you can
        // refine the value; commit by tapping empty space or the tool button
        // ("select an empty area of the grid to complete the tool").
        extrudeDragAnchor = nil
        cachedPullWorldBody = nil
    }

    // MARK: - Sketch mode

    private(set) var rectangleType: RectangleType = .diagonal
    private var rectangleAnchor: SIMD2<Double>?
    private var rectangleBaseline: (a: SIMD2<Double>, b: SIMD2<Double>)?
    private var rectangleIDs = (0..<4).map { _ in UUID() }
    private var rectanglePreview: [SketchEntity] = []
    private var rectangleBaselineDimension: SketchDimension?
    var hasPendingRectangle: Bool { rectangleAnchor != nil || rectangleBaseline != nil }
    var rectangleInstruction: String {
        if rectangleType == .threePoint {
            return rectangleBaseline == nil ? "Draw the baseline" : "Draw the perpendicular height"
        }
        return rectangleType == .center ? "Draw from center to corner" : "Draw between opposite corners"
    }

    func setRectangleType(_ type: RectangleType) {
        clearRectanglePlacement()
        editingDimension = nil
        rectangleType = type
    }

    func clearRectanglePlacement() {
        rectangleAnchor = nil
        rectangleBaseline = nil
        rectangleBaselineDimension = nil
        rectanglePreview = []
        rectangleIDs = (0..<4).map { _ in UUID() }
        if mode.sketchTool == .rect {
            pendingEntity = nil
            sketchStrokeStart = nil
            sketchStrokeStartRaw = nil
            sketchStrokeCurrent = nil
            activeSnap = nil
            activeGuides = []
            pendingInferredConstraints = []
        }
    }

    private func updateRectanglePreview(from start: SIMD2<Double>, to end: SIMD2<Double>) {
        if let base = rectangleBaseline {
            rectanglePreview = RectangleConstruction.threePoint(
                a: base.a, b: base.b, heightPoint: end, ids: rectangleIDs)
            if rectanglePreview.isEmpty {
                rectanglePreview = [.line(id: rectangleIDs[0], a: base.a, b: base.b)]
            }
        } else {
            rectanglePreview = [.line(id: rectangleIDs[0], a: start, b: end)]
        }
    }

    private func placeThreePointRectangle(from start: SIMD2<Double>, to end: SIMD2<Double>,
                                          sketchID: SketchID) {
        guard let base = rectangleBaseline else {
            guard simd_length(end - start) > 1e-3 else { return }
            rectangleBaseline = (start, end)
            rectangleAnchor = nil
            rectanglePreview = [.line(id: rectangleIDs[0], a: start, b: end)]
            return
        }
        let edges = RectangleConstruction.threePoint(a: base.a, b: base.b,
                                                    heightPoint: end, ids: rectangleIDs)
        guard edges.count == 4 else { return }
        let constraints = RectangleConstruction.constraints(for: edges)
        guard let before = activeSketch, before.id == sketchID else { return }
        var after = before
        after.entities += edges
        after.constraints += constraints
        // Persist the ordered rectangle identity without center-sizing intent.
        // Its center is a control, not a new geometric entity or default Lock.
        after.rotatedRectangleEdges[edges[0].id] = edges.map(\.id)
        if let dimension = rectangleBaselineDimension {
            after.dimensions.append(dimension)
        }
        session.perform(ReplaceSketchGeometryCommand(title: "Draw Rectangle", before: before, after: after))
        clearRectanglePlacement()
        // Keep the whole completed rectangle selected, exposing its two
        // adjacent lengths without automatically opening a keypad.
        selectedSketchEntityIDs = Set(edges.map(\.id))
        selectedSketchPoints = [.init(entityID: edges[0].id, role: .center)]
        session.save()
    }

    private func handleRectangleTap(ray: Ray) {
        guard case .sketching(let sketchID, _) = mode,
              let point = sketchPoint(from: ray), let sketch = activeSketch else { return }
        editingDimension = nil
        if rectangleType == .threePoint, let base = rectangleBaseline {
            placeThreePointRectangle(from: base.a, to: point, sketchID: sketchID)
        } else if let anchor = rectangleAnchor {
            if rectangleType == .threePoint {
                placeThreePointRectangle(from: anchor, to: point, sketchID: sketchID)
            } else if let entity = RectangleConstruction.axisAligned(
                from: anchor, to: point, centered: rectangleType == .center) {
                pendingInferredConstraints = []
                commitDrawnEntity(entity, sketchID: sketchID, in: sketch, rectangleEnd: point)
                clearRectanglePlacement()
                selectedSketchEntityIDs = [entity.id]
                selectedSketchPoints = rectangleType == .center
                    ? [.init(entityID: entity.id, role: .center)] : []
            }
        } else {
            selectedSketchEntityIDs.removeAll()
            selectedSketchPoints.removeAll()
            rectangleAnchor = point
        }
    }

    /// In-progress entity during a sketch drag (rubber band).
    var pendingEntity: SketchEntity?
    /// A chained Arc stays armed after its third-point commit. Pointer/Pencil
    /// hover previews the next chord from the prior endpoint without advancing
    /// the tap state; the next click still owns endpoint two.
    private var arcEndpointHoverPreviewActive = false
    private let arcEndpointPreviewID = UUID()
    private var sketchStrokeStart: SIMD2<Double>?
    /// Where the drag currently is, plane-local. Only the live dimension
    /// readout needs it — a circle's Ø leader swings to follow the finger.
    private var sketchStrokeCurrent: SIMD2<Double>?

    /// The snap the pointer is currently latched to, for the on-screen chip.
    /// Cleared when the stroke ends so the chip never outlives the gesture.
    private(set) var activeSnap: (kind: SnapKind, point: SIMD2<Double>)?

    /// Named snap under the pointer, ready for the overlay to place: Shapr3D
    /// tells you WHICH snap caught you ("Endpoint") so a near miss is obvious
    /// before you commit. Grid snaps remain unlabelled to avoid labelling every stroke.
    var activeSnapLabel: (text: String, world: SIMD3<Double>)? {
        guard CADPreferences.shared.showSnapHints,
              let snap = activeSnap, let text = snap.kind.label,
              let plane = activeSketch?.plane else { return nil }
        return (text, plane.toWorld(snap.point))
    }

    // MARK: Live dimensions while drawing (spec §1.1)

    /// One live measurement, ready for the overlay to project.
    struct LiveDimensionLabel: Identifiable {
        let id: String
        let text: String
        /// Ends of the dimension line itself.
        let worldLineStart: SIMD3<Double>
        let worldLineEnd: SIMD3<Double>
        /// The points on the geometry the measurement refers to; the witness
        /// lines run from these out to the dimension line.
        let worldWitnessStart: SIMD3<Double>
        let worldWitnessEnd: SIMD3<Double>
        let worldLabel: SIMD3<Double>
        /// Ticks marking where the measurement meets the geometry (diameters).
        let drawsEdgeTicks: Bool
        /// False when the dimension line sits ON the geometry, so the witness
        /// leaders would be zero-length.
        let hasWitnessLines: Bool
        let isArcRadius: Bool
        let isPendingRectangleBaseline: Bool
        let worldArcCenter: SIMD3<Double>?
        let worldArcPoints: [SIMD3<Double>]
    }

    /// Dimensions for the stroke in flight — width/height while dragging a
    /// rectangle, Ø while dragging a circle. Empty when nothing is being drawn,
    /// so the overlay disappears the moment the stroke commits.
    var liveDimensionLabels: [LiveDimensionLabel] {
        guard let sketch = activeSketch else { return [] }
        // A pending arc is still being shaped (its bulge is draggable), so it
        // keeps its readout after the initial drag ends.
        let entities = (pendingEntity ?? pendingArcEntity).map { [$0] }
            ?? Array(rectanglePreview.prefix(2))
        let unit = CADPreferences.shared.unit
        return entities.enumerated().flatMap { index, entity in
            LiveDimensionKit.dimensions(for: entity, towards: sketchStrokeCurrent,
                circleUsesRadius: CADPreferences.shared.circularAnnotations == .alwaysRadius).map { d in
                let pendingBaseline = rectangleType == .threePoint
                    && rectangleBaseline != nil && rectanglePreview.count == 1
                return LiveDimensionLabel(
                    id: rectanglePreview.isEmpty ? d.id : "rectangle-\(index)-\(d.id)",
                    text: pendingBaseline ? unit.compactLengthString(fromMM: d.value)
                        : LiveDimensionKit.label(d, unit: unit),
                    worldLineStart: sketch.plane.toWorld(d.lineStart),
                    worldLineEnd: sketch.plane.toWorld(d.lineEnd),
                    worldWitnessStart: sketch.plane.toWorld(d.start),
                    worldWitnessEnd: sketch.plane.toWorld(d.end),
                    worldLabel: sketch.plane.toWorld(d.labelPoint),
                    drawsEdgeTicks: d.kind.drawsEdgeTicks,
                    hasWitnessLines: simd_length(d.offset) > 1e-9,
                    isArcRadius: d.kind == .radius && d.arcCenter != nil,
                    isPendingRectangleBaseline: pendingBaseline,
                    worldArcCenter: d.arcCenter.map(sketch.plane.toWorld),
                    worldArcPoints: d.arcPoints.map(sketch.plane.toWorld))
            }
        }
    }

    // MARK: - Auto-constraint / inference (plan §B, spec §3, contract D)

    /// Live auto-constraint inference settings, persisted across launches via
    /// UserDefaults (saved on every mutation).
    var autoConstrainSettings = AutoConstraintSettings() {
        didSet { saveAutoConstrainSettings() }
    }

    /// Point acquisition must not sneak back in through inference when the
    /// user explicitly disables sketch guidepoints. Other relationships remain independent.
    private var effectiveAutoConstrainSettings: AutoConstraintSettings {
        var settings = autoConstrainSettings
        settings.pointSnap = settings.pointSnap && CADPreferences.shared.snapToSketchGuidepoints
        return settings
    }

    private func inferSketchInput(tool: SketchTool, anchor: SIMD2<Double>,
                                  current: SIMD2<Double>, existing: [SketchEntity],
                                  settings: AutoConstraintSettings) -> AutoConstraintEngine.Result {
        if tool == .line {
            return AutoConstraintEngine.inferLineInput(anchor: anchor, current: current,
                existing: existing, settings: settings,
                guideLines: CADPreferences.shared.snapToSketchGuidelines,
                guideDistanceTolerance: 4 * worldPerPoint)
        }
        return AutoConstraintEngine.infer(tool: tool, anchor: anchor, current: current,
                                         existing: existing, settings: settings)
    }

    /// Presents the auto-constrain settings panel (sheet).
    var showConstraintSettings = false

    /// Inference guides to render while the current stroke is drawn (violet
    /// reference lines). Cleared when the stroke ends/cancels.
    var activeGuides: [AutoConstraintEngine.Guide] = []

    /// Constraints inferred for the in-progress stroke; emitted (defensively,
    /// never over-constraining) when the stroke commits.
    private var pendingInferredConstraints: [AutoConstraintEngine.Inferred] = []

    private static let autoConstrainDefaultsKey = "autoConstrainSettings"

    private func saveAutoConstrainSettings() {
        if let data = try? JSONEncoder().encode(autoConstrainSettings) {
            UserDefaults.standard.set(data, forKey: Self.autoConstrainDefaultsKey)
        }
    }

    private func loadAutoConstrainSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.autoConstrainDefaultsKey),
              let decoded = try? JSONDecoder().decode(AutoConstraintSettings.self, from: data)
        else { return }
        autoConstrainSettings = decoded
    }

    /// A per-point DOF marker for the active sketch overlay (contract D): blue
    /// hollow = free, green = constrained, blue square = locked.
    struct SketchPointMarker: Identifiable, Sendable {
        var id: String
        var world: SIMD3<Float>
        var state: SketchPointState
        var isRectangleCorner = false
        var isSelected = false
    }

    /// Memoized `sketchPointMarkers`, keyed on the document revision and active
    /// sketch. `@ObservationIgnored` so writing it from the getter never itself
    /// triggers observation. Point states depend only on the sketch, never the
    /// camera — so an orbit/pan (which re-runs the overlay via `cameraEpoch`)
    /// hits this cache instead of re-solving.
    @ObservationIgnored
    private var pointMarkerCache: (changeCount: Int, sketchID: SketchID?, markers: [SketchPointMarker])?

    /// DOF markers for every point of the ACTIVE sketch (empty when not
    /// sketching or no active sketch). Reuses `SketchSolverBridge.pointStates`
    /// (a full solve + null-space eigen decomposition), memoized per document
    /// revision; the overlay reprojects each cached marker on camera moves.
    private func migratedRectangleEdgeIDs(in sketch: Sketch) -> Set<UUID> {
        let lineIDs = Set(sketch.entities.compactMap { entity -> UUID? in
            if case .line = entity { return entity.id }
            return nil
        })
        return Set(sketch.rotatedRectangleEdges.values.filter {
            $0.count == 4 && Set($0).count == 4 && Set($0).isSubset(of: lineIDs)
        }.flatMap { $0 })
    }

    var sketchPointMarkers: [SketchPointMarker] {
        let cc = session.changeCount
        guard let sketch = activeSketch else {
            pointMarkerCache = nil
            return []
        }
        if let cache = pointMarkerCache, cache.changeCount == cc, cache.sketchID == sketch.id {
            return cache.markers
        }
        let analysis = SketchSolverBridge.pointStateAnalysis(sketch)
        let states = analysis.points
        let migratedEdges = migratedRectangleEdgeIDs(in: sketch)
        var out: [SketchPointMarker] = []
        out.reserveCapacity(states.count)
        for (key, state) in states {
            guard let local = localPoint(
                ConstraintRef(entityID: key.entityID, role: key.role), in: sketch
            ) else { continue }
            let w = sketch.plane.toWorld(local)
            out.append(SketchPointMarker(
                id: "\(key.entityID):\(key.role.rawValue)",
                world: SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z)),
                state: state, isRectangleCorner: analysis.rectangleCorners[key.entityID] != nil ||
                    (migratedEdges.contains(key.entityID) && (key.role == .endpointA || key.role == .endpointB))
            ))
        }
        for case let .rect(id, lo, hi) in sketch.entities {
            guard let corners = analysis.rectangleCorners[id], corners.count == 4 else { continue }
            for (index, local) in [(1, SIMD2(hi.x, lo.y)), (3, SIMD2(lo.x, hi.y))] {
                out.append(SketchPointMarker(id: "\(id):corner\(index)",
                    world: SIMD3<Float>(sketch.plane.toWorld(local)), state: corners[index], isRectangleCorner: true))
            }
        }
        pointMarkerCache = (cc, sketch.id, out)
        return out
    }

    /// Rectangle centers are rigid-translation controls, not independent
    /// solver points. Keep them separate from endpoint constraint markers.
    static let rectangleCenterLockOffset: CGFloat = 40
    static let rectangleCenterLockHitSize: CGFloat = 22

    var sketchRectangleCenterLockMarkers: [SketchPointMarker] {
        let releasedCenter = (mode.sketchTool == .circle ||
            (mode.sketchTool == .rect && (rectangleType == .center || rectangleType == .threePoint)))
            && !hasPendingRectangle && pendingEntity == nil
        guard mode.isSketching, mode.sketchTool == nil || releasedCenter,
              editingDimension == nil, !sketchTransformActive else { return [] }
        return (sketchRectangleCenterMarkers + sketchCircleCenterMarkers).filter(\.isSelected)
    }

    /// Shared projected bounds for direct-touch delivery through the viewport.
    /// Mouse/accessibility delivery may instead invoke the SwiftUI button.
    func toggleRectangleCenterLock(at point: CGPoint) -> Bool {
        let half = Self.rectangleCenterLockHitSize / 2
        for marker in sketchRectangleCenterLockMarkers {
            guard let center = cameraControl?.worldToScreenPoint(SIMD3<Double>(marker.world)),
                  abs(point.x - center.x) <= half,
                  abs(point.y - center.y - Self.rectangleCenterLockOffset) <= half else { continue }
            toggleRectangleCenterLock()
            return true
        }
        return false
    }

    /// Native direct Lock finishes the point selection; direct Unlock leaves
    /// it selected so the now-free center is immediately available to move.
    func toggleRectangleCenterLock() {
        guard !sketchRectangleCenterLockMarkers.isEmpty else { return }
        // Release may retain the rectangle's edges to show its two sizes.
        // The direct padlock acts on the selected center, not those edges.
        let circleID = selectedCircleCenterID
        selectedSketchEntityIDs.removeAll()
        let unlocking = canUnlockSketchSelection
        toggleSketchSelectionLock()
        if !unlocking && canUnlockSketchSelection {
            selectedSketchPoints = []
            selectedSketchEntityIDs = []
            selectedConstraintID = nil
            retainedCircleCenterReadoutID = circleID
        }
    }

    /// Circle centers remain ordinary solver points. The selected release
    /// control uses the same local Lock action as a rectangle center.
    var selectedCircleCenterID: UUID? {
        guard selectedSketchPoints.count == 1, let point = selectedSketchPoints.first,
              point.role == .center, let sketch = activeSketch,
              case .circle? = sketchEntity(point.entityID, in: sketch) else { return nil }
        return point.entityID
    }

    var sketchCircleCenterMarkers: [SketchPointMarker] {
        guard let sketch = activeSketch else { return [] }
        return sketch.entities.compactMap { entity in
            guard case let .circle(id, center, _) = entity else { return nil }
            let state = sketchPointMarkers.first { $0.id == "\(id):center" }?.state ?? .free
            return SketchPointMarker(id: "\(id):circleCenter",
                world: SIMD3<Float>(sketch.plane.toWorld(center)), state: state,
                isSelected: selectedSketchPoints.contains(.init(entityID: id, role: .center)))
        }
    }

    var sketchRectangleCenterMarkers: [SketchPointMarker] {
        guard let sketch = activeSketch else { return [] }
        return sketch.entities.compactMap { entity in
            let id = entity.id
            let center: SIMD2<Double>
            if case let .rect(_, lo, hi) = entity {
                center = (lo + hi) / 2
            } else if let (a, b) = RectangleConstruction.centerDiagonalReferences(id, in: sketch),
                      let first = localPoint(a, in: sketch), let opposite = localPoint(b, in: sketch) {
                center = (first + opposite) / 2
            } else { return nil }
            let locked = sketch.constraints.contains { constraint in
                constraint.kind == .fixed && constraint.refs.contains {
                    $0.entityID == id && ($0.role == .center || ($0.role == .whole && $0.rectangleEdge == nil))
                }
            }
            return SketchPointMarker(id: "\(id):rectangleCenter",
                world: SIMD3<Float>(sketch.plane.toWorld(center)), state: locked ? .locked : .free,
                isSelected: selectedSketchPoints.contains(.init(entityID: id, role: .center)))
        }
    }

    private func migratedRectangleCenter(at raw: SIMD2<Double>, in sketch: Sketch) -> (UUID, SIMD2<Double>)? {
        sketch.rotatedRectangleEdges.keys.compactMap { id -> (UUID, SIMD2<Double>)? in
            guard RectangleConstruction.centerDiagonalReferences(id, in: sketch) != nil,
                  let center = localPoint(.init(entityID: id, role: .center), in: sketch),
                  simd_distance(center, raw) <= controlPointTolerance else { return nil }
            return (id, center)
        }.min { simd_distance($0.1, raw) < simd_distance($1.1, raw) }
    }

    // MARK: - Sketch element selection + drag-editing

    /// Selected entities of the active sketch (accent highlight; palette
    /// Delete removes them).
    var retainedCircleCenterReadoutID: UUID?
    /// Membership remains a Set for fast rendering checks, while this sidecar
    /// preserves the tap order required by the First/Last anchored-entity
    /// constraint preference.
    private(set) var selectedSketchEntityOrder: [UUID] = []
    private var itemSelectedSketchID: SketchID?
    var selectedSketchEntityIDs: Set<UUID> = [] {
        didSet {
            reconcileSketchSelectionOrder(added: selectedSketchEntityIDs.subtracting(oldValue))
            retainedCircleCenterReadoutID = nil
            if oldValue != selectedSketchEntityIDs {
                itemSelectedSketchID = nil
                retainedSketchTransform = nil
                temporaryDiameterLabelOffsets.removeAll()
                if mode.sketchTool != nil { sketchTransformActive = false }
                sketchRadialDrag = nil
                selectedAxisRectangleEdge = nil
            }
        }
    }

    /// A selected model point (endpoint/center) on a sketch entity, addressed
    /// by the role the constraint solver understands (plan §C3).
    struct SketchPointSelection: Hashable, Sendable {
        var entityID: UUID
        var role: PointRole
    }

    /// Points tapped for constraints (endpoints/centers). Independent of
    /// `selectedSketchEntityIDs` so a mixed selection (e.g. a point + a line
    /// for Midpoint) is expressible.
    var selectedSketchPoints: Set<SketchPointSelection> = [] {
        didSet {
            reconcileSketchSelectionOrder(added: Set(selectedSketchPoints.subtracting(oldValue).map(\.entityID)))
            retainedCircleCenterReadoutID = nil
        }
    }

    private func reconcileSketchSelectionOrder(added: Set<UUID>) {
        let live = selectedSketchEntityIDs.union(selectedSketchPoints.map(\.entityID))
        selectedSketchEntityOrder.removeAll { !live.contains($0) }
        let documentOrder = activeSketch?.entities.map(\.id) ?? []
        let additions = added.filter { live.contains($0) && !selectedSketchEntityOrder.contains($0) }
            .sorted {
                (documentOrder.firstIndex(of: $0) ?? .max) <
                (documentOrder.firstIndex(of: $1) ?? .max)
            }
        selectedSketchEntityOrder.append(contentsOf: additions)
    }

    /// Deterministic seam for multi-select routes and acceptance tests. Normal
    /// canvas taps still build the same order incrementally via the observers.
    func selectSketchEntitiesInOrder(_ ids: [UUID]) {
        selectedSketchEntityIDs.removeAll()
        selectedSketchPoints.removeAll()
        selectedSketchEntityOrder = []
        for id in ids { selectedSketchEntityIDs.insert(id) }
    }

    /// The constraint glyph currently selected (tap-select in the overlay or the
    /// Items panel). Palette/keyboard Delete removes it. Mutually exclusive with
    /// `selectedDimensionID`.
    var selectedConstraintID: UUID?

    /// The dimension currently selected in the Items panel (for delete). The
    /// overlay label tap opens the numeric editor instead, so this is set from
    /// the Items list.
    var selectedDimensionID: UUID?

    /// A drag editing one entity: a control point (endpoint/center/handle)
    /// or the whole body (nil control = translate). The command is pushed on
    /// the first change and amend-coalesced for the rest of the drag.
    private struct SketchEntityDrag {
        var sketchID: SketchID
        var control: SketchHitTester.ControlKind?
        var before: SketchEntity
        /// Raw plane point where the drag grabbed the entity (translations).
        var grabPoint: SIMD2<Double>
        /// Pre-drag snapshot of ALL sketch entities. Used by the solve-on-edit
        /// path (plan §C1) as the fixed baseline every frame solves from — and
        /// as the command's undo `before`.
        var baseline: [SketchEntity]
        var showedBlockedNotice = false
        var pushed = false
        /// Structural DOF from the first solved tick; the constraint system
        /// does not change while dragging, so later ticks pass it back and
        /// skip the null-space analysis (most of a large sketch's tick).
        var structuralDOF: Int?
    }
    private var sketchEntityDrag: SketchEntityDrag?

    /// Screen-sized acquisition targets at the current camera scale. Only a
    /// numerical epsilon floor remains; model-unit floors swallow short edges.
    private var worldPerPoint: Double { cameraControl?.worldUnitsPerPoint ?? 0.01 }
    private var sketchSnapTolerance: Double {
        SnapEngine.screenPointTolerance(worldUnitsPerPoint: worldPerPoint)
    }
    private var controlPointTolerance: Double {
        SketchHitTester.screenControlPointTolerance(worldUnitsPerPoint: worldPerPoint)
    }
    private var modelSketchPickTolerance: Double {
        SketchHitTester.screenPickTolerance(worldUnitsPerPoint: worldPerPoint)
    }
    private var entityPickTolerance: Double {
        SketchHitTester.screenPickTolerance(worldUnitsPerPoint: worldPerPoint)
    }

    // MARK: - Sketch Move/Rotate gizmo (plan §B6, spec §1.10)

    /// Copy chip while sketching (spec §1.10): the next gizmo drag
    /// moves/rotates duplicates of the selection. Resets after each drag.
    var sketchCopyOnDrag = false
    var sketchTransformActive = false {
        didSet { if !sketchTransformActive { retainedSketchTransform = nil } }
    }

    private struct RetainedSketchTransform {
        var control: SketchTransformControl
        var value: Double
        var drag: SketchGizmoDrag
        var result: Sketch
    }
    private var retainedSketchTransform: RetainedSketchTransform?
    private var activeSketchTransformControl: SketchTransformControl?
    private var activeSketchTransformValue = 0.0

    private var validRetainedSketchTransform: RetainedSketchTransform? {
        guard sketchTransformActive, let retained = retainedSketchTransform,
              let sketch = activeSketch, sketch.id == retained.result.id,
              sketch.entities == retained.result.entities,
              sketch.constraints == retained.result.constraints,
              selectedSketchEntityIDs == Set(retained.drag.originals.map(\.id)) else { return nil }
        return retained
    }

    func retainedSketchTransformValue(_ control: SketchTransformControl) -> Double? {
        guard let retained = validRetainedSketchTransform, retained.control == control else { return nil }
        return retained.value
    }

    var sketchTransformFrameAngle: Double {
        if let drag = sketchGizmoDrag, let control = activeSketchTransformControl {
            return drag.frameAngle + (control == .rotation ? activeSketchTransformValue * .pi / 180 : 0)
        }
        guard let retained = validRetainedSketchTransform else { return 0 }
        return retained.drag.frameAngle + (retained.control == .rotation ? retained.value * .pi / 180 : 0)
    }

    private func sketchTransformOffset(_ control: SketchTransformControl, value: Double, angle: Double) -> SIMD2<Double> {
        control == .x ? SIMD2(cos(angle), sin(angle)) * value : SIMD2(-sin(angle), cos(angle)) * value
    }

    enum SketchTransformControl: String, CaseIterable {
        case x, y, rotation
        var title: String { self == .rotation ? "Angle" : (self == .x ? "X" : "Y") }
    }

    /// The overlay supplies signed plane-axis distance or degrees, independent
    /// of zoom. Reuse the same baseline, Copy and coalesced history as canvas drags.
    private var rotationWouldDiscardRectangleReferences: Bool {
        guard !sketchCopyOnDrag, let sketch = activeSketch else { return false }
        if selectedSketchEntityIDs.count == 1, let id = selectedSketchEntityIDs.first,
           RectangleConstruction.prepareCenterRotation(sketch, id: id,
                edgeIDs: [id, UUID(), UUID(), UUID()]) != nil { return false }
        let ids = Set(sketch.entities.compactMap { entity -> UUID? in
            guard selectedSketchEntityIDs.contains(entity.id), case .rect = entity else { return nil }
            return entity.id
        })
        return sketch.constraints.contains { $0.refs.contains { ids.contains($0.entityID) } }
            || sketch.dimensions.contains { $0.refs.contains { ids.contains($0.entityID) } }
    }

    func updateSketchTransformControl(_ control: SketchTransformControl, value: Double) {
        guard value.isFinite, sketchTransformActive, let center = sketchSelectionCentroid else { return }
        if control == .rotation, rotationWouldDiscardRectangleReferences {
            showNotice("Rotation of dimensioned or constrained rectangles isn't supported yet.")
            return
        }
        if sketchGizmoDrag == nil {
            if let retained = validRetainedSketchTransform, retained.control == control, !sketchCopyOnDrag {
                var resumed = retained.drag
                resumed.pushed = false
                resumed.undoEntities = activeSketch?.entities
                if resumed.replacementBefore != nil { resumed.replacementBefore = activeSketch }
                sketchGizmoDrag = resumed
            } else {
                let frameAngle = sketchTransformFrameAngle
                retainedSketchTransform = nil
                let grab = control == .rotation ? center + SIMD2(1, 0) : center
                guard beginSketchGizmoDrag(at: grab, forcedKind: control == .rotation ? .rotate : .move) else { return }
                // Starting a different local-axis operation keeps the accepted
                // frame and pivot rather than recomputing the new geometry bounds.
                sketchGizmoDrag?.frameAngle = frameAngle
                sketchGizmoDrag?.pivot = center
            }
        }
        activeSketchTransformControl = control
        activeSketchTransformValue = value
        guard let drag = sketchGizmoDrag else { return }
        let raw: SIMD2<Double>
        switch control {
        case .x, .y:
            raw = drag.grabPoint + sketchTransformOffset(control, value: value, angle: drag.frameAngle)
        case .rotation:
            let angle = value * .pi / 180
            raw = drag.pivot + SIMD2(cos(angle), sin(angle))
        }
        updateSketchGizmoDrag(raw: raw, quantize: false)
    }

    func endSketchTransformControl() {
        guard let drag = sketchGizmoDrag else { return }
        sketchGizmoDrag = nil
        if drag.pushed {
            session.rebuildForSketchChange(drag.sketchID)
            session.save()
            if let control = activeSketchTransformControl, let result = activeSketch,
               drag.originals.allSatisfy({
                   switch $0 { case .line, .circle, .arc: return true; default: return false }
               }) {
                retainedSketchTransform = RetainedSketchTransform(control: control,
                    value: activeSketchTransformValue, drag: drag, result: result)
            }
        }
        activeSketchTransformControl = nil
    }

    @discardableResult
    func commitSketchTransformControl(_ control: SketchTransformControl, text: String) -> Bool {
        if control == .rotation, rotationWouldDiscardRectangleReferences {
            showNotice("Rotation of dimensioned or constrained rectangles isn't supported yet.")
            return false
        }
        guard let parsed = ExpressionEvaluator.evaluate(text, variables: session.variableValues()), parsed.isFinite else {
            showNotice("Enter a valid distance or angle.")
            return false
        }
        let suffix = NumericParsing.trailingUnit(in: text)
        guard control == .rotation ? (suffix == nil || suffix == "deg") : suffix != "deg" else {
            showNotice("Use an angle for rotation or a length for movement.")
            return false
        }
        let value = control == .rotation ? parsed :
            (Self.lengthUnit(forSuffix: suffix) ?? CADPreferences.shared.unit).mm(fromDisplay: parsed)
        if abs(value) > 1e-10 || retainedSketchTransformValue(control) != nil { updateSketchTransformControl(control, value: value) }
        endSketchTransformControl()
        return true
    }

    var selectedSingleRadialEntity: SketchEntity? {
        guard mode.isSketching, mode.sketchTool == nil,
              selectedSketchEntityIDs.count == 1,
              let entity = activeSketch?.entities.first(where: { selectedSketchEntityIDs.contains($0.id) }) else { return nil }
        switch entity {
        case .arc, .circle: return entity
        default: return nil
        }
    }

    var selectedAxisRectangleEdge: (id: UUID, index: Int)?

    var rectangleHandleGeometry: (a: SIMD2<Double>, b: SIMD2<Double>, normal: SIMD2<Double>)? {
        guard mode.isSketching, mode.sketchTool == nil, selectedSketchPoints.isEmpty,
              let sketch = activeSketch else { return nil }
        if let pick = selectedAxisRectangleEdge, selectedSketchEntityIDs == [pick.id],
           let entity = sketch.entities.first(where: { $0.id == pick.id }) {
            return RectangleConstruction.axisEdge(entity, index: pick.index)
        }
        guard let edge = selectedRectangleEdge, case let .line(_, a, b) = edge,
              let loop = RectangleConstruction.dimensionEdges(containing: edge.id, in: sketch),
              let index = loop.firstIndex(of: edge.id),
              let opposite = sketch.entities.first(where: { $0.id == loop[(index + 2) % 4] }),
              case let .line(_, c, d) = opposite else { return nil }
        return (a, b, simd_normalize((a + b - c - d) / 2))
    }

    var selectedRectangleEdge: SketchEntity? {
        guard mode.isSketching, mode.sketchTool == nil,
              selectedSketchEntityIDs.count == 1, let sketch = activeSketch,
              let entity = sketch.entities.first(where: { selectedSketchEntityIDs.contains($0.id) }),
              case .line = entity,
              RectangleConstruction.dimensionEdges(containing: entity.id, in: sketch) != nil
        else { return nil }
        return entity
    }

    var hasContextualSketchHandle: Bool {
        selectedSingleRadialEntity != nil || rectangleHandleGeometry != nil
    }

    /// Native single-line selection exposes its dimension, not the transform
    /// gizmo. Keep direct body/endpoint dragging; Move/Rotate or Copy opts in.
    var usesExplicitSketchTransform: Bool {
        if hasContextualSketchHandle || selectedMigratedRectangleCornerEdges != nil { return true }
        if selectedSketchPoints.isEmpty, let sketch = activeSketch,
           sketch.rotatedRectangleEdges.values.contains(where: { Set($0) == selectedSketchEntityIDs }) {
            return true
        }
        guard selectedSketchEntityIDs.count == 1, selectedSketchPoints.isEmpty,
              let entity = selectedSketchEntities.first else { return false }
        if case .line = entity { return true }
        if case .rect = entity { return true }
        return false
    }

    private struct RectangleEdgeDrag {
        var sketch: Sketch
        var edge: SketchEntity
        var oppositeID: UUID
        var axisEdge: Int? = nil
        var normal: SIMD2<Double>
        var pushed = false
        var showedBlockedNotice = false
    }
    private var rectangleEdgeDrag: RectangleEdgeDrag?

    func updateRectangleEdgeDrag(delta: Double) {
        if rectangleEdgeDrag == nil, let pick = selectedAxisRectangleEdge,
           let sketch = activeSketch, let edge = sketch.entities.first(where: { $0.id == pick.id }),
           let geometry = rectangleHandleGeometry {
            rectangleEdgeDrag = .init(sketch: sketch, edge: edge, oppositeID: edge.id,
                                      axisEdge: pick.index, normal: geometry.normal)
        }
        if rectangleEdgeDrag == nil {
            guard let sketch = activeSketch, let edge = selectedRectangleEdge,
                  case let .line(_, a, b) = edge,
                  let loop = RectangleConstruction.dimensionEdges(containing: edge.id, in: sketch),
                  let index = loop.firstIndex(of: edge.id),
                  let opposite = sketch.entities.first(where: { $0.id == loop[(index + 2) % 4] }),
                  case let .line(_, c, d) = opposite else { return }
            var normal = simd_normalize(SIMD2(-(b - a).y, (b - a).x))
            if simd_dot((a + b - c - d) / 2, normal) < 0 { normal = -normal }
            rectangleEdgeDrag = .init(sketch: sketch, edge: edge, oppositeID: opposite.id, normal: normal)
        }
        guard var drag = rectangleEdgeDrag else { return }
        let targets = SketchTransform.translate(entities: [drag.edge], by: drag.normal * delta)
        let outcome: [SketchEntity]?
        if let edge = drag.axisEdge {
            outcome = SketchSolverBridge.solveAxisRectangleEdge(drag.sketch, id: drag.edge.id, edge: edge, delta: delta)
        } else {
            outcome = SketchSolverBridge.solveLineTransform(drag.sketch, targets: targets,
                preservingLineID: drag.oppositeID)
        }
        guard let solved = outcome else {
            if !drag.showedBlockedNotice {
                showNotice("Locked or constrained sketch parts can't be moved.")
                drag.showedBlockedNotice = true; rectangleEdgeDrag = drag
            }
            return
        }
        if solved == drag.sketch.entities, abs(delta) > 1e-6, !drag.showedBlockedNotice {
            showNotice("Locked or constrained sketch parts can't be moved.")
            drag.showedBlockedNotice = true
        }
        if solved != drag.sketch.entities || drag.pushed {
            let command = UpdateSketchEntitiesCommand(sketchID: drag.sketch.id,
                before: drag.sketch.entities, after: solved)
            if drag.pushed { session.amend(command) }
            else { session.perform(command); drag.pushed = true }
        }
        rectangleEdgeDrag = drag
    }

    func endRectangleEdgeDrag() {
        if let drag = rectangleEdgeDrag, drag.pushed {
            session.rebuildForSketchChange(drag.sketch.id)
            session.save()
        }
        rectangleEdgeDrag = nil
    }

    var selectedSingleArc: SketchEntity? {
        guard case .arc? = selectedSingleRadialEntity else { return nil }
        return selectedSingleRadialEntity
    }

    private struct SketchRadialDragState {
        var sketch: Sketch
        var entityID: UUID
        var radius: Double
        var pushed = false
        var showedBlockedNotice = false
    }
    private var sketchRadialDrag: SketchRadialDragState?

    func updateRadialRadiusDrag(delta: Double) {
        if sketchRadialDrag == nil {
            guard let sketch = activeSketch, let entity = selectedSingleRadialEntity else { return }
            let radius: Double
            switch entity {
            case let .arc(_, _, r, _, _), let .circle(_, _, r): radius = r
            default: return
            }
            editingDimension = nil
            sketchRadialDrag = .init(sketch: sketch, entityID: entity.id, radius: radius)
        }
        guard var drag = sketchRadialDrag else { return }
        guard let entities = SketchRadialDrag.solve(drag.sketch, entityID: drag.entityID,
                  radius: max(1e-3 + 1e-8, drag.radius + delta)) else {
            if !drag.showedBlockedNotice, abs(delta) > 1e-6 {
                showNotice("Locked or constrained sketch parts can't be moved.")
                drag.showedBlockedNotice = true
                sketchRadialDrag = drag
            }
            return
        }
        guard entities != drag.sketch.entities || drag.pushed else { return }
        let command = UpdateSketchEntitiesCommand(sketchID: drag.sketch.id,
            before: drag.sketch.entities, after: entities)
        if drag.pushed { session.amend(command) }
        else { session.perform(command); drag.pushed = true }
        sketchRadialDrag = drag
    }

    func endRadialRadiusDrag() {
        if let drag = sketchRadialDrag, drag.pushed {
            session.rebuildForSketchChange(drag.sketch.id)
            session.save()
        }
        sketchRadialDrag = nil
    }


    private enum SketchGizmoDragKind { case move, rotate }

    /// A drag on the sketch selection gizmo: the handle translates the
    /// selected entities, the ring rotates them about the centroid. One
    /// command per drag (perform once, then amend-coalesce).
    private struct SketchGizmoDrag {
        var kind: SketchGizmoDragKind
        var sketchID: SketchID
        /// Entities when the drag began (transform baseline).
        var originals: [SketchEntity]
        var baselineSketch: Sketch
        var pivot: SIMD2<Double>
        var grabPoint: SIMD2<Double>
        var pushed = false
        var showedBlockedNotice = false
        var undoEntities: [SketchEntity]?
        var replacementBefore: Sketch?
        var directRectangleCorner = false
        var frameAngle = 0.0
    }
    private var sketchGizmoDrag: SketchGizmoDrag?

    /// Gizmo dimensions in plane units (floored for constant screen size).
    private var sketchGizmoHandleRadius: Double { sketchTransformActive ? 22 * worldPerPoint : max(0.4, 22 * worldPerPoint) }
    private var sketchGizmoRingRadius: Double { max(1.4, 64 * worldPerPoint) }
    private var sketchGizmoRingWidth: Double { max(0.35, 16 * worldPerPoint) }

    /// Centroid of the selected sketch entities (gizmo anchor), plane-local.
    var sketchSelectionCentroid: SIMD2<Double>? {
        if let drag = sketchGizmoDrag, let control = activeSketchTransformControl {
            return control == .rotation ? drag.pivot : drag.pivot + sketchTransformOffset(control,
                value: activeSketchTransformValue, angle: drag.frameAngle)
        }
        if let retained = validRetainedSketchTransform {
            return retained.control == .rotation ? retained.drag.pivot : retained.drag.pivot + sketchTransformOffset(retained.control,
                value: retained.value, angle: retained.drag.frameAngle)
        }
        guard let sketch = activeSketch else { return nil }
        let selected = sketch.entities.filter { selectedSketchEntityIDs.contains($0.id) }
        guard !selected.isEmpty else { return nil }
        if sketchTransformActive, selected.count == 1 {
            return Self.explicitSketchTransformCenter(selected[0])
        }
        let sum = selected.reduce(SIMD2<Double>.zero) { $0 + Self.entityCenter($1) }
        return sum / Double(selected.count)
    }

    /// Native's initial single-arc transform pivot is the visible arc bounds,
    /// not the center of its supporting circle. Include cardinal extrema so
    /// short/major arcs and angle seams do not depend on tessellation density.
    nonisolated static func explicitSketchTransformCenter(_ entity: SketchEntity) -> SIMD2<Double> {
        guard case let .arc(_, center, radius, start, end) = entity else { return entityCenter(entity) }
        let sweep = SketchEntity.arcSweep(startAngle: start, endAngle: end)
        var angles = [start, end]
        for cardinal in [0.0, Double.pi / 2, Double.pi, 3 * Double.pi / 2] {
            var offset = (cardinal - start).truncatingRemainder(dividingBy: 2 * .pi)
            if offset < 0 { offset += 2 * .pi }
            if offset <= sweep + 1e-10 { angles.append(cardinal) }
        }
        let points = angles.map { SketchEntity.arcPoint(center: center, radius: radius, angle: $0) }
        let lo = points.reduce(points[0]) { simd_min($0, $1) }
        let hi = points.reduce(points[0]) { simd_max($0, $1) }
        return (lo + hi) / 2
    }

    nonisolated static func entityCenter(_ entity: SketchEntity) -> SIMD2<Double> {
        switch entity {
        case let .line(_, a, b): (a + b) / 2
        case let .rect(_, lo, hi): (lo + hi) / 2
        case let .circle(_, center, _), let .arc(_, center, _, _, _),
             let .ellipse(_, center, _, _, _), let .polygon(_, center, _, _, _):
            center
        case let .spline(_, points, _):
            points.isEmpty
                ? .zero
                : points.reduce(SIMD2<Double>.zero, +) / Double(points.count)
        }
    }

    /// Overlay line segments for the selection gizmo: a cross + diamond
    /// handle at the centroid and the surrounding rotate ring.
    private func sketchGizmoSegments(
        centroid: SIMD2<Double>, plane: SketchPlane
    ) -> [SIMD3<Float>] {
        guard !isPickingSymmetryAxis else { return [] }
        func world(_ p: SIMD2<Double>) -> SIMD3<Float> {
            let w = plane.toWorld(p)
            return SIMD3(Float(w.x), Float(w.y), Float(w.z))
        }
        var segments: [SIMD3<Float>] = []
        let r = sketchGizmoHandleRadius
        segments += [
            world(centroid - SIMD2(r, 0)), world(centroid + SIMD2(r, 0)),
            world(centroid - SIMD2(0, r)), world(centroid + SIMD2(0, r)),
        ]
        let diamond = [SIMD2(r, 0.0), SIMD2(0.0, r), SIMD2(-r, 0.0), SIMD2(0.0, -r)]
        for i in 0..<4 {
            segments.append(world(centroid + diamond[i]))
            segments.append(world(centroid + diamond[(i + 1) % 4]))
        }
        let ring = sketchGizmoRingRadius
        let ringSegments = 48
        for i in 0..<ringSegments {
            let t0 = Double(i) / Double(ringSegments) * 2 * .pi
            let t1 = Double(i + 1) / Double(ringSegments) * 2 * .pi
            segments.append(world(centroid + SIMD2(cos(t0), sin(t0)) * ring))
            segments.append(world(centroid + SIMD2(cos(t1), sin(t1)) * ring))
        }
        return segments
    }

    /// A drag starting on the selection gizmo claims the stroke: the center
    /// handle translates, the ring rotates. Copy chip duplicates first.
    private func beginSketchGizmoDrag(at raw: SIMD2<Double>, forcedKind: SketchGizmoDragKind? = nil) -> Bool {
        guard !usesExplicitSketchTransform || sketchTransformActive else { return false }
        guard case .sketching(let sketchID, _) = mode,
              !selectedSketchEntityIDs.isEmpty,
              let centroid = sketchSelectionCentroid,
              let sketch = activeSketch
        else { return false }
        let distance = simd_length(raw - centroid)
        let kind: SketchGizmoDragKind
        if let forcedKind {
            kind = forcedKind
        } else if distance <= sketchGizmoHandleRadius {
            kind = .move
        } else if !sketchTransformActive, abs(distance - sketchGizmoRingRadius) <= sketchGizmoRingWidth {
            kind = .rotate
        } else {
            return false
        }
        var entities = sketch.entities.filter { selectedSketchEntityIDs.contains($0.id) }
        guard !entities.isEmpty else { return false }

        if kind == .rotate, !sketchCopyOnDrag, entities.count == 1,
           let id = entities.first?.id,
           let prepared = RectangleConstruction.prepareCenterRotation(sketch, id: id,
                edgeIDs: [id, UUID(), UUID(), UUID()]),
           let edges = RectangleConstruction.dimensionEdges(containing: id, in: prepared) {
            sketchGizmoDrag = SketchGizmoDrag(kind: kind, sketchID: sketchID,
                originals: prepared.entities.filter { edges.contains($0.id) },
                baselineSketch: prepared, pivot: centroid, grabPoint: raw,
                replacementBefore: sketch)
            sketchStrokeStart = nil
            pendingEntity = nil
            return true
        }

        // Decomposition currently removes the primitive and its references.
        // Consume the gesture without changing history until rotation can
        // migrate those references, rather than silently losing saved intent.
        if kind == .rotate, rotationWouldDiscardRectangleReferences {
            showNotice("Rotation of dimensioned or constrained rectangles isn't supported yet.")
            return true
        }

        // Copy chip: duplicate first; the drag then moves the copies.
        if sketchCopyOnDrag {
            sketchCopyOnDrag = false
            let retainTransformMode = sketchTransformActive
            entities = duplicateSketchEntities(entities, in: sketchID)
            // The copied IDs are a continuation of this explicit operation,
            // not a new canvas selection that should dismiss Move/Rotate.
            sketchTransformActive = retainTransformMode
        }

        // Rotation decomposes rects into 4 lines once, up front, so every
        // later step maps entities one-to-one (amend-friendly commands).
        let containsRect = entities.contains {
            if case .rect = $0 { return true }
            return false
        }
        if kind == .rotate, containsRect {
            entities = decomposeSelectedRects(entities, in: sketchID)
        }

        sketchGizmoDrag = SketchGizmoDrag(
            kind: kind,
            sketchID: sketchID,
            originals: entities,
            baselineSketch: activeSketch ?? sketch,
            pivot: centroid,
            grabPoint: raw
        )
        sketchStrokeStart = nil
        pendingEntity = nil
        return true
    }

    /// Clone `entities` with fresh IDs in one undo step; the copies become
    /// the selection and the drag baseline.
    func duplicateSketchEntities(
        _ entities: [SketchEntity], in sketchID: SketchID
    ) -> [SketchEntity] {
        var copies: [SketchEntity] = []
        var sourceIDs: [UUID: UUID] = [:]
        var commands: [DocumentCommand] = []
        for entity in entities {
            for copy in PatternKit.transformed(entity, by: .identity) {
                copies.append(copy)
                sourceIDs[copy.id] = entity.id
                commands.append(AddSketchEntityCommand(sketchID: sketchID, entity: copy))
            }
        }
        guard !commands.isEmpty else { return entities }
        // Copies initially overlap their sources. Prevent the solver's proximity
        // weld from moving originals along with them, including after undo/reopen.
        // Preserve coincident joins *within* the copied line group explicitly.
        if let sketch = activeSketch {
            var slots: [(ConstraintRef, SIMD2<Double>)] = []
            for copy in copies {
                if case let .line(id, a, b) = copy {
                    slots.append((.init(entityID: id, role: .endpointA), a))
                    slots.append((.init(entityID: id, role: .endpointB), b))
                }
            }
            if !slots.isEmpty {
                var constraints = sketch.constraints
                for i in slots.indices {
                    for j in slots.indices where j > i {
                        if slots[i].0.entityID != slots[j].0.entityID,
                           simd_distance(slots[i].1, slots[j].1) < 1e-6 {
                            guard let firstID = sourceIDs[slots[i].0.entityID],
                                  let secondID = sourceIDs[slots[j].0.entityID] else { continue }
                            let first = ConstraintRef(entityID: firstID, role: slots[i].0.role)
                            let second = ConstraintRef(entityID: secondID, role: slots[j].0.role)
                            let explicitlyJoined = sketch.constraints.contains {
                                $0.kind == .coincident && $0.refs.contains(first) && $0.refs.contains(second)
                            }
                            guard explicitlyJoined || (!sketch.disconnectedEndpoints.contains(first)
                                && !sketch.disconnectedEndpoints.contains(second)) else { continue }
                            constraints.append(.init(kind: .coincident,
                                refs: [slots[i].0, slots[j].0]))
                        }
                    }
                }
                commands.append(DisconnectSketchEndpointsCommand(sketchID: sketchID,
                    beforeConstraints: sketch.constraints, afterConstraints: constraints,
                    beforeEndpoints: sketch.disconnectedEndpoints,
                    afterEndpoints: sketch.disconnectedEndpoints + slots.map { $0.0 }))
            }
        }
        session.perform(commands.count == 1
            ? commands[0]
            : CompositeCommand(title: "Copy", commands: commands))
        selectedSketchEntityIDs = Set(copies.map(\.id))
        return copies
    }

    /// Replace each selected rect with its 4 edge lines (one undo step); the
    /// first line inherits the rect's ID, like SketchTransform.rotate.
    private func decomposeSelectedRects(
        _ entities: [SketchEntity], in sketchID: SketchID
    ) -> [SketchEntity] {
        guard let sketch = activeSketch else { return entities }
        var result: [SketchEntity] = []
        var commands: [DocumentCommand] = []
        for entity in entities {
            guard case let .rect(id, lo, hi) = entity else {
                result.append(entity)
                continue
            }
            let corners = [lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y)]
            var lines: [SketchEntity] = []
            for i in 0..<4 {
                lines.append(.line(
                    id: i == 0 ? id : UUID(),
                    a: corners[i], b: corners[(i + 1) % 4]
                ))
            }
            commands.append(RemoveSketchEntitiesCommand(ids: [id], sketch: sketch))
            for line in lines {
                commands.append(AddSketchEntityCommand(sketchID: sketchID, entity: line))
            }
            result.append(contentsOf: lines)
        }
        guard !commands.isEmpty else { return entities }
        session.perform(CompositeCommand(title: "Rotate", commands: commands))
        selectedSketchEntityIDs = Set(result.map(\.id))
        return result
    }

    private func updateSketchGizmoDrag(raw: SIMD2<Double>, quantize: Bool = true) {
        guard var drag = sketchGizmoDrag else { return }
        let after: [SketchEntity]
        switch drag.kind {
        case .move:
            // Grid-capture each axis, like single-entity translates.
            var delta = raw - drag.grabPoint
            let snapped = SIMD2(
                (delta.x / SnapEngine.gridSpacing).rounded() * SnapEngine.gridSpacing,
                (delta.y / SnapEngine.gridSpacing).rounded() * SnapEngine.gridSpacing
            )
            if quantize, CADPreferences.shared.snapToGrid, abs(delta.x - snapped.x) < 0.15 { delta.x = snapped.x }
            if quantize, CADPreferences.shared.snapToGrid, abs(delta.y - snapped.y) < 0.15 { delta.y = snapped.y }
            after = SketchTransform.translate(entities: drag.originals, by: delta)
        case .rotate:
            // 5° steps while dragging (matches the body rings).
            let anchorAngle = atan2(
                drag.grabPoint.y - drag.pivot.y, drag.grabPoint.x - drag.pivot.x
            )
            let currentAngle = atan2(raw.y - drag.pivot.y, raw.x - drag.pivot.x)
            let rawDegrees = (currentAngle - anchorAngle) * 180 / .pi
            let degrees = quantize && !drag.directRectangleCorner ? (rawDegrees / 5).rounded() * 5 : rawDegrees
            after = SketchTransform.rotate(
                entities: drag.originals, about: drag.pivot, angle: degrees * .pi / 180
            )
        }
        // Rects were pre-decomposed, so the mapping is always one-to-one.
        guard after.count == drag.originals.count else { return }
        if drag.originals.allSatisfy({
            switch $0 { case .line, .circle, .arc: return true; default: return false }
        }) {
            guard let solved = SketchSolverBridge.solvePointTransform(drag.baselineSketch, targets: after)
            else {
                showNotice("Locked or constrained sketch parts can't be moved.")
                return
            }
            if solved == drag.baselineSketch.entities, after != drag.originals,
               !drag.showedBlockedNotice {
                showNotice("Locked or constrained sketch parts can't be moved.")
                drag.showedBlockedNotice = true
                sketchGizmoDrag = drag
            }
            // A circle rotated about its center has unchanged geometry, but
            // native retains the rotated operation frame and an Undo step.
            // Record that accepted operation without perturbing its center,
            // radius, or constraints just to force a geometric difference.
            let circleFrameOnly = activeSketchTransformControl == .rotation
                && drag.originals.count == 1
                && drag.originals.allSatisfy { if case .circle = $0 { return true }; return false }
                && after == drag.originals
                && retainedSketchTransform?.value != activeSketchTransformValue
            guard solved != (drag.undoEntities ?? drag.baselineSketch.entities) || drag.pushed || circleFrameOnly else { return }
            let command: DocumentCommand
            if let before = drag.replacementBefore {
                var migrated = drag.baselineSketch
                migrated.entities = solved
                command = ReplaceSketchGeometryCommand(title: "Rotate", before: before, after: migrated)
            } else {
                command = UpdateSketchEntitiesCommand(sketchID: drag.sketchID,
                    before: drag.undoEntities ?? drag.baselineSketch.entities, after: solved)
            }
            if drag.pushed { session.amend(command) }
            else {
                session.perform(command)
                drag.pushed = true
                if drag.replacementBefore != nil { selectedSketchEntityIDs = Set(drag.originals.map(\.id)) }
                sketchGizmoDrag = drag
            }
            return
        }
        guard after != drag.originals || drag.pushed else { return }
        let updates: [DocumentCommand] = zip(drag.originals, after).map {
            UpdateSketchEntityCommand(sketchID: drag.sketchID, before: $0.0, after: $0.1)
        }
        let command: DocumentCommand = updates.count == 1
            ? updates[0]
            : CompositeCommand(
                title: drag.kind == .move ? "Move" : "Rotate", commands: updates
            )
        if drag.pushed {
            session.amend(command)
        } else {
            session.perform(command)
            drag.pushed = true
            sketchGizmoDrag = drag
        }
    }

    /// Tap while sketching: Trim cuts the span under the tap; Offset picks the
    /// entities to offset; other tools toggle entity selection, or finalize/
    /// clear pending state on empty space.
    private func handleSketchTap(ray: Ray, tool: SketchTool?) {
        if isPickingSymmetryAxis {
            if let raw = rawSketchPoint(from: ray), let sketch = activeSketch,
               let hit = SketchHitTester.nearestEntity(to: raw, in: sketch.entities.filter {
                   if case .line = $0 { return true }; return false
               }, tolerance: entityPickTolerance) {
                completeSymmetryAxisPick(hit.entity.id)
            }
            return
        }
        // Native click-away accepts the value; the same tap must not also
        // place a point or trim geometry underneath the editor.
        if editingDimension != nil {
            finishDimensionEditOnClickAway()
            return
        }
        if tool == .rect {
            handleRectangleTap(ray: ray)
            return
        }
        if tool == .trim {
            performTrim(ray: ray)
            return
        }
        if tool == .offset {
            // A tap on empty space is not "clear the pick" here — the picks
            // are the tool's whole state and the bar is the way out.
            handleSketchOffsetTap(ray: ray)
            return
        }
        if tool == .text {
            clearChain()
            // Tap-to-place (spec §1.12): the tapped point anchors the text
            // dialog's glyph baseline.
            if let point = sketchPoint(from: ray) {
                textPlacement = point
            }
            return
        }
        if tool == .project {
            clearChain()
            projectTappedBody(ray: ray)
            return
        }
        if pendingSymbolID != nil {
            // Insert Symbol armed (plan §B16): the tap stamps an instance.
            clearChain()
            placePendingSymbol(ray: ray)
            return
        }
        if tool == .arc, pendingArc == nil {
            guard let raw = rawSketchPoint(from: ray) else { return }
            let point = SnapEngine.snap(raw, in: activeSketch,
                faceLoops: activeFaceSnapLoops(), options: CADPreferences.shared.snapOptions,
                tolerance: sketchSnapTolerance).point
            clearChain()
            if let start = arcTapStart {
                guard simd_length(point - start) > 1e-6 else { return }
                pendingEntity = nil
                arcEndpointHoverPreviewActive = false
                pendingArc = PendingArc(a: start, b: point,
                    sagitta: Self.defaultSagitta(a: start, b: point))
                arcTapStart = nil
            } else {
                arcTapStart = point
                selectedSketchEntityIDs.removeAll()
                selectedSketchPoints.removeAll()
            }
            return
        }
        if pendingArc != nil {
            // Pointer/Pencil hover normally establishes the third-point shape.
            // A touch-only device has no hover, so the committing tap must also
            // apply its location before finalizing the arc.
            if var arc = pendingArc, let raw = rawSketchPoint(from: ray) {
                arc.sagitta = Self.clampedSagitta(Self.signedSagitta(of: raw, arc: arc), arc: arc)
                pendingArc = arc
            }
            clearChain()
            commitPendingArc(chain: true)
            return
        }
        // Line tool: taps place polyline vertices (extend the chain / close the
        // polygon) rather than ending it — the Shapr3D line workflow.
        if tool == .line {
            placeLineChainPoint(ray: ray)
            return
        }
        clearChain() // a tap ends line chaining (other tools)
        guard let sketch = activeSketch, let raw = rawSketchPoint(from: ray) else { return }
        if !selectSketchGeometryTap(at: raw, in: sketch) {
            // Empty tap: clear the current sketch selection.
            selectedSketchEntityIDs.removeAll()
            selectedSketchPoints.removeAll()
        }
    }

    /// Toggle-select the sketch point or entity under `raw` (the constraint /
    /// dimension pick, plan §C3). A tap near a model point (endpoint/center)
    /// selects that POINT; the tight point tolerance means the body of a
    /// line/curve still selects the whole entity. Returns true when something
    /// was hit, false on an empty tap so the caller can decide what an empty
    /// tap means (clear the selection, or extend a line chain).
    @discardableResult
    private func selectSketchGeometryTap(
        at raw: SIMD2<Double>, in sketch: Sketch
    ) -> Bool {
        editingDimension = nil
        // Tapping geometry clears any constraint/dimension glyph selection.
        selectedConstraintID = nil
        selectedDimensionID = nil
        if let (id, _) = migratedRectangleCenter(at: raw, in: sketch) {
            let point = SketchPointSelection(entityID: id, role: .center)
            let wasSelected = selectedSketchPoints == [point]
            selectedSketchEntityIDs = []
            selectedSketchPoints = wasSelected ? [] : [point]
            return true
        }
        if let control = SketchHitTester.nearestControlPoint(
            to: raw, in: sketch.entities, tolerance: controlPointTolerance),
           control.kind == .center, case .rect = control.entity {
            let point = SketchPointSelection(entityID: control.entity.id, role: .center)
            let wasSelected = selectedSketchPoints == [point]
            selectedSketchEntityIDs.removeAll()
            selectedAxisRectangleEdge = nil
            selectedSketchPoints = wasSelected ? [] : [point]
            return true
        }
        if let pt = SketchHitTester.nearestPoint(
            to: raw, in: sketch.entities, tolerance: controlPointTolerance,
            preservingLineInterior: true
        ) {
            let sel = SketchPointSelection(entityID: pt.entityID, role: pt.role)
            if selectedSketchPoints.contains(sel) {
                selectedSketchPoints.remove(sel)
            } else {
                selectedSketchPoints.insert(sel)
            }
            return true
        }
        if let hit = SketchHitTester.nearestEntity(
            to: raw, in: sketch.entities, tolerance: entityPickTolerance
        ) {
            if case .rect = hit.entity,
               let index = RectangleConstruction.nearestAxisEdge(hit.entity, to: raw) {
                selectedSketchPoints.remove(SketchPointSelection(entityID: hit.entity.id, role: .center))
                if selectedSketchEntityIDs.contains(hit.entity.id),
                   selectedAxisRectangleEdge?.id == hit.entity.id,
                   selectedAxisRectangleEdge?.index == index {
                    selectedSketchEntityIDs.remove(hit.entity.id)
                } else {
                    selectedSketchEntityIDs.insert(hit.entity.id)
                    selectedAxisRectangleEdge = (hit.entity.id, index)
                }
            } else if selectedSketchEntityIDs.contains(hit.entity.id) {
                selectedSketchEntityIDs.remove(hit.entity.id)
            } else {
                selectedSketchEntityIDs.insert(hit.entity.id)
            }
            return true
        }
        return false
    }

    /// Trim (spec §1.14): delete the tapped span between the entity's nearest
    /// intersections with the other entities.
    private func performTrim(ray: Ray) {
        guard case .sketching(let sketchID, _) = mode,
              let sketch = activeSketch,
              let raw = rawSketchPoint(from: ray),
              let hit = SketchHitTester.nearestEntity(
                  to: raw, in: sketch.entities, tolerance: entityPickTolerance
              ),
              let fragments = SketchTrimmer.trim(entity: hit.entity, at: raw, in: sketch),
              let index = sketch.entities.firstIndex(where: { $0.id == hit.entity.id })
        else { return }
        selectedSketchEntityIDs.remove(hit.entity.id)
        // Phase D: trimming edits sketch geometry — the dependent-feature
        // rebuild lands in the SAME undo step (S6). The sketch-aware init
        // re-anchors constraints/dimensions onto the surviving fragments and
        // drops what can't transfer (R2-2) — say so when it does, since a
        // silently vanished dimension reads as data loss.
        let command = TrimCommand(
            sketch: sketch, index: index, removed: hit.entity, fragments: fragments)
        session.performWithSketchRebuild(command, sketchID: sketchID)
        let droppedCount = command.droppedConstraints.count + command.droppedDimensions.count
        if droppedCount > 0 {
            showNotice(droppedCount == 1
                ? "1 constraint on the trimmed span was removed"
                : "\(droppedCount) constraints on the trimmed span were removed")
        }
    }

    // MARK: - Construction axes (spec §6.2)

    /// One reference the Add Axis tool has picked, already in WORLD space.
    ///
    /// The axis construction is *derived* from the accumulated picks rather
    /// than chosen from a type menu first. That is the manual's own adaptive
    /// route — "pre-select an element that will be used to define the axis,
    /// then select Add Axis" — and it collapses four separate tools into one
    /// gesture: tap an edge, a round face, or one/two flat faces.
    nonisolated enum AxisPick: Equatable {
        case edge(start: SIMD3<Double>, end: SIMD3<Double>)
        case planarFace(origin: SIMD3<Double>, normal: SIMD3<Double>)
        case cylindrical(origin: SIMD3<Double>, direction: SIMD3<Double>, length: Double)
    }

    private(set) var axisPicks: [AxisPick] = []

    /// Display extent of the axis being defined — the spec's Length parameter.
    /// Never affects the math, only how long the drawn line is.
    var axisLength: Double = 100 {
        didSet { if oldValue != axisLength { recomputeAxisPreview() } }
    }

    private(set) var pendingAxisPreview: ConstructionAxis?

    /// Names the construction the current picks resolve to, for the bar.
    var axisConstructionLabel: String {
        switch axisPicks.count {
        case 0: return "Tap an edge or face"
        case 1:
            switch axisPicks[0] {
            case .edge: return "Along Edge"
            case .cylindrical: return "Axis of Cylinder/Cone"
            case .planarFace: return "Perpendicular to Face"
            }
        default:
            if case .planarFace = axisPicks[0], case .planarFace = axisPicks[1] {
                return "Through 2 Planes"
            }
            return "Tap an edge or face"
        }
    }

    var canCommitAxis: Bool { pendingAxisPreview != nil }

    func beginAxisTool() {
        cancelTransientPicks()
        axisPicks = []
        pendingAxisPreview = nil
        axisLength = Self.defaultAxisLength(for: session.document)
        mode = .pickingAxisReferences
    }

    func cancelAxisTool() {
        resetAxisState()
        if case .pickingAxisReferences = mode { mode = .idle }
    }

    /// State only — never writes `selection` (gotcha 7).
    func resetAxisState() {
        axisPicks = []
        pendingAxisPreview = nil
    }

    /// Scale the default display length to the model so the axis is visible on
    /// a 3 mm part and not absurd on a 3 m one.
    private static func defaultAxisLength(for document: DesignDocument) -> Double {
        var extent = 0.0
        for body in document.bodies {
            extent = max(extent, Self.worldBounds(of: body).size.length)
        }
        return extent > 1e-6 ? extent * 1.5 : 100
    }

    /// Tap while Add Axis is armed: pick an edge or a face off the tapped body.
    private func handleAxisReferenceTap(ray: Ray) {
        guard let hit = HitTester.pickBody(ray: ray, in: scene),
              let body = session.document.body(with: hit.bodyID)
        else { return }
        let matrix = body.transform.matrixFloat
        func world(_ p: SIMD3<Double>) -> SIMD3<Double> {
            let w = matrix * SIMD4(SIMD3<Float>(p), 1)
            return SIMD3(Double(w.x), Double(w.y), Double(w.z))
        }
        func worldDirection(_ d: SIMD3<Double>) -> SIMD3<Double> {
            // A direction is not a point: translation must not apply.
            let w = matrix * SIMD4(SIMD3<Float>(d), 0)
            return SIMD3(Double(w.x), Double(w.y), Double(w.z))
        }

        // An edge near the tap wins over the face behind it: "Along Edge" is
        // only reachable by aiming at an edge, whereas a face can always be hit
        // in its middle.
        if let edge = nearestStraightEdge(on: body, worldHit: hit.worldPoint) {
            appendAxisPick(.edge(
                start: world(SIMD3<Double>(edge.start)),
                end: world(SIMD3<Double>(edge.end))))
            return
        }

        // A round face gives its own fitted axis, so it wins outright.
        if let cylinder = FaceTopology.cylindricalFace(
            in: body.render, seedTriangle: hit.triangleIndex
        ) {
            appendAxisPick(.cylindrical(
                origin: world(cylinder.axisPoint),
                direction: worldDirection(cylinder.axisDir),
                length: max(cylinder.height, 1e-6)
            ))
            return
        }
        if let face = FaceTopology.planarFace(
            in: body.render, seedTriangle: hit.triangleIndex
        ) {
            appendAxisPick(.planarFace(
                origin: world(face.origin),
                normal: worldDirection(SIMD3<Double>(face.normal))
            ))
            return
        }
        errorMessage = "Tap a flat face, a round face, or an edge to define an axis."
    }

    /// The straight edge near a tap on `body`, in the body's LOCAL space, or
    /// nil when the tap is out in the middle of a face.
    ///
    /// Two filters matter here, and they are the whole reason this is not just
    /// `edges.min(by: distance)` the way Chamfer/Fillet does it:
    ///
    /// * **Proximity.** Blend only ever wants an edge, so it takes the nearest
    ///   one unconditionally. This tool has to choose between the edge and the
    ///   face behind it, so an edge has to be genuinely near the tap — within a
    ///   band scaled to the body, so the same gesture works at any model size.
    /// * **Straightness.** A tessellated rim is dozens of short segments, and
    ///   one segment of a circle is a meaningless axis. `smoothChain` is the
    ///   honest test: a straight edge is its own chain, a curved one is not.
    private func nearestStraightEdge(
        on body: Body, worldHit: SIMD3<Float>
    ) -> SelectableEdge? {
        let inverse = simd_inverse(body.transform.matrixFloat)
        let local4 = inverse * SIMD4(worldHit, 1)
        let localPoint = SIMD3<Float>(local4.x, local4.y, local4.z)

        let aabb = body.render.localAABB
        let diagonal = Double(simd_length(aabb.max - aabb.min))
        guard diagonal > 1e-9 else { return nil }
        let tolerance = Float(diagonal * Self.axisEdgePickFraction)

        let edges = EdgeTopology.selectableEdges(from: body.render)
        guard let nearest = edges.min(by: {
            Self.pointSegmentDistance(localPoint, $0.start, $0.end)
                < Self.pointSegmentDistance(localPoint, $1.start, $1.end)
        }) else { return nil }
        guard Self.pointSegmentDistance(localPoint, nearest.start, nearest.end) <= tolerance
        else { return nil }
        guard EdgeTopology.smoothChain(containing: nearest, in: edges).count == 1
        else { return nil }
        return nearest
    }

    /// How close to an edge a tap must land to mean "that edge", as a fraction
    /// of the body's diagonal — proportional so it behaves the same on a 3 mm
    /// part and a 3 m one.
    private static let axisEdgePickFraction = 0.04

    /// Picks are capped at two: every construction the tool derives needs one
    /// reference or two, so a third tap starts over rather than silently
    /// ignoring the user.
    private func appendAxisPick(_ pick: AxisPick) {
        if axisPicks.contains(pick) {
            axisPicks.removeAll { $0 == pick }
        } else if axisPicks.count >= 2 {
            axisPicks = [pick]
        } else {
            axisPicks.append(pick)
        }
        recomputeAxisPreview()
    }

    private func recomputeAxisPreview() {
        pendingAxisPreview = Self.deriveAxis(from: axisPicks, length: axisLength)
    }

    /// Pure derivation, so it is unit-testable without an `EditorViewModel`
    /// (gotcha 1: an in-process `ModelContainer` crashes XCTest).
    nonisolated static func deriveAxis(
        from picks: [AxisPick], length: Double
    ) -> ConstructionAxis? {
        func sized(_ axis: ConstructionAxis?) -> ConstructionAxis? {
            guard var axis else { return nil }
            axis.length = length
            return axis
        }
        switch picks.count {
        case 1:
            switch picks[0] {
            case let .edge(start, end):
                return sized(ConstructionAxisKit.alongEdge(start: start, end: end))
            case let .planarFace(origin, normal):
                return sized(ConstructionAxisKit.perpendicular(toFaceNormal: normal, at: origin))
            case let .cylindrical(origin, direction, _):
                return sized(ConstructionAxis(origin: origin, direction: direction))
            }
        case 2:
            guard case let .planarFace(originA, normalA) = picks[0],
                  case let .planarFace(originB, normalB) = picks[1]
            else { return nil }
            return sized(ConstructionAxisKit.intersection(
                planeAOrigin: originA, planeANormal: normalA,
                planeBOrigin: originB, planeBNormal: normalB
            ))
        default:
            return nil
        }
    }

    func commitAxis() {
        guard case .pickingAxisReferences = mode, var axis = pendingAxisPreview else { return }
        axis.name = "Axis \(session.document.axes.count + 1)"
        session.perform(AddConstructionAxisCommand(axis: axis))
        resetAxisState()
        mode = .idle
    }

    /// Dashed world segments for a drawn axis — dashed so a construction axis
    /// never reads as model geometry.
    nonisolated static func axisSegments(_ axis: ConstructionAxis) -> [SIMD3<Float>] {
        let (start, end) = axis.endpoints
        let dashes = 24
        var out: [SIMD3<Float>] = []
        for i in stride(from: 0, to: dashes, by: 2) {
            let t0 = Double(i) / Double(dashes)
            let t1 = Double(i + 1) / Double(dashes)
            out.append(SIMD3<Float>(simd_mix(start, end, SIMD3(repeating: t0))))
            out.append(SIMD3<Float>(simd_mix(start, end, SIMD3(repeating: t1))))
        }
        return out
    }

    // MARK: - Offset Edge (sketch, spec §1.9)

    /// Single vs Chain, mirroring the manual's Offset Edge **Type** menu.
    /// Changing it re-expands the existing picks rather than clearing them, so
    /// flipping the type after picking does the obvious thing.
    var sketchOffsetType: SketchOffsetType = .single {
        didSet { if oldValue != sketchOffsetType { recomputeSketchOffsetPreview() } }
    }

    /// Signed offset distance. Negative offsets inward on a closed profile;
    /// on an open chain the sign picks the side (see `SketchOffset`).
    var sketchOffsetDistance: Double = 1 {
        didSet { if oldValue != sketchOffsetDistance { recomputeSketchOffsetPreview() } }
    }

    /// The entities the user tapped. Expanded through `sketchOffsetType` at
    /// preview time — storing the SEEDS (not the expansion) is what lets the
    /// type flip re-derive without a re-pick.
    private(set) var sketchOffsetSeedIDs: Set<UUID> = []

    /// Live result of offsetting the current selection; rendered in place of
    /// nothing (it is new geometry, so it never hides the source).
    private(set) var sketchOffsetPreview: [SketchEntity] = []

    /// Entities the current picks resolve to, in sketch order.
    var sketchOffsetSourceEntities: [SketchEntity] {
        guard let sketch = activeSketch else { return [] }
        return SketchOffset.entitiesToOffset(
            seedIDs: sketchOffsetSeedIDs, type: sketchOffsetType, in: sketch.entities
        )
    }

    /// Apply is live only once a pick actually produces geometry — a distance
    /// that collapses the source (a rect shrunk past its midlines) yields an
    /// empty preview, and committing it would be a silent no-op.
    var canCommitSketchOffset: Bool { !sketchOffsetPreview.isEmpty }

    /// Tap while the Offset tool is armed: toggle the entity under the ray.
    @discardableResult
    func handleSketchOffsetTap(ray: Ray) -> Bool {
        guard case .sketching(_, .offset) = mode,
              let sketch = activeSketch,
              let raw = rawSketchPoint(from: ray),
              let hit = SketchHitTester.nearestEntity(
                  to: raw, in: sketch.entities, tolerance: entityPickTolerance
              )
        else { return false }
        if sketchOffsetSeedIDs.contains(hit.entity.id) {
            sketchOffsetSeedIDs.remove(hit.entity.id)
        } else {
            sketchOffsetSeedIDs.insert(hit.entity.id)
        }
        recomputeSketchOffsetPreview()
        return true
    }

    private func recomputeSketchOffsetPreview() {
        let sources = sketchOffsetSourceEntities
        guard !sources.isEmpty, abs(sketchOffsetDistance) > 1e-9 else {
            sketchOffsetPreview = []
            return
        }
        sketchOffsetPreview = KernelOps.offsetSketchEntities(sources, by: sketchOffsetDistance)
    }

    /// Commit the previewed offset as new sketch entities.
    func commitSketchOffset() {
        guard case .sketching(let sketchID, .offset) = mode,
              canCommitSketchOffset
        else { return }
        // Offsetting ADDS geometry, so downstream profiles keep resolving; the
        // sketch rebuild still runs so a dependent feature sees the new loop.
        session.performWithSketchRebuild(AddSketchEntitiesCommand(
            sketchID: sketchID,
            entities: sketchOffsetPreview,
            title: "Offset Edge"
        ), sketchID: sketchID)
        resetSketchOffsetState()
    }

    func cancelSketchOffset() {
        resetSketchOffsetState()
        deselectSketchTool()
    }

    /// State only — never touches `selection` (gotcha 7: internal cleanup
    /// paths that write to `selection` make Delete delete the wrong thing).
    func resetSketchOffsetState() {
        sketchOffsetSeedIDs = []
        sketchOffsetPreview = []
    }

    /// A drag landing on an entity edits it instead of drawing: control
    /// points (endpoints/centers/handles) win, then the entity body
    /// (translate). Selects the grabbed entity.
    private func beginSketchEntityDrag(at raw: SIMD2<Double>, in sketch: Sketch) -> Bool {
        if let (id, center) = migratedRectangleCenter(at: raw, in: sketch),
           let edges = RectangleConstruction.dimensionEdges(containing: id, in: sketch) {
            selectedSketchEntityIDs = []
            selectedSketchPoints = [.init(entityID: id, role: .center)]
            sketchGizmoDrag = SketchGizmoDrag(kind: .move, sketchID: sketch.id,
                originals: sketch.entities.filter { edges.contains($0.id) }, baselineSketch: sketch,
                pivot: center, grabPoint: raw)
            sketchStrokeStart = nil
            pendingEntity = nil
            return true
        }
        // Coincident centers have equal hit distances. Keep the explicitly
        // selected circle as the drag target instead of choosing entity order.
        let selectedCenterControl: SketchHitTester.ControlHit? = {
            guard let id = selectedCircleCenterID,
                  let entity = sketchEntity(id, in: sketch),
                  case let .circle(_, center, _) = entity,
                  simd_distance(raw, center) <= controlPointTolerance else { return nil }
            return .init(entity: entity, kind: .center, point: center,
                         distance: simd_distance(raw, center))
        }()
        let control = selectedCenterControl ?? SketchHitTester.nearestControlPoint(
            to: raw, in: sketch.entities, tolerance: controlPointTolerance
        )
        let body = control == nil ? SketchHitTester.nearestEntity(
            to: raw, in: sketch.entities, tolerance: entityPickTolerance
        ) : nil
        guard let entity = control?.entity ?? body?.entity else { return false }
        if case .rectCorner? = control?.kind,
           sketch.constraints.contains(where: { $0.kind == .fixed && $0.refs == [.init(entityID: entity.id, role: .center)] }),
           Set(sketch.dimensions.filter { $0.refs.contains(where: { $0.entityID == entity.id }) }.map(\.kind)) == [.horizontal, .vertical],
           let prepared = RectangleConstruction.prepareCenterRotation(sketch, id: entity.id,
                edgeIDs: [entity.id, UUID(), UUID(), UUID()]),
           let edges = RectangleConstruction.dimensionEdges(containing: entity.id, in: prepared) {
            selectedSketchPoints = []
            selectedSketchEntityIDs = [entity.id]
            sketchGizmoDrag = SketchGizmoDrag(kind: .rotate, sketchID: sketch.id,
                originals: prepared.entities.filter { edges.contains($0.id) }, baselineSketch: prepared,
                pivot: Self.entityCenter(entity), grabPoint: raw,
                replacementBefore: sketch, directRectangleCorner: true)
            sketchStrokeStart = nil
            pendingEntity = nil
            return true
        }
        if (control?.kind == .lineStart || control?.kind == .lineEnd),
           (sketch.rotatedRectangleEdges.values.contains(where: { $0.contains(entity.id) })
            || selectedSketchPoints.contains(.init(entityID: entity.id,
                role: control?.kind == .lineStart ? .endpointA : .endpointB))) {
            // Keep the grabbed endpoint, not its entire edge, selected.
            // This also applies to a directly selected ordinary endpoint after
            // Disconnect. Adding its parent creates a false zero-distance label.
            selectedSketchEntityIDs.removeAll()
            selectedSketchPoints = [.init(entityID: entity.id,
                role: control?.kind == .lineStart ? .endpointA : .endpointB)]
        } else if mode.sketchTool == nil, control?.kind == .center, case .circle = entity,
                  selectedSketchPoints.contains(.init(entityID: entity.id, role: .center)) {
            // A disarmed selected center remains point-only while translating.
            // Armed Circle retains its creation readout during center movement.
            selectedSketchEntityIDs.removeAll()
            selectedSketchPoints = [.init(entityID: entity.id, role: .center)]
        } else if control?.kind == .center, case .rect = entity {
            selectedSketchEntityIDs.removeAll()
            selectedAxisRectangleEdge = nil
            selectedSketchPoints = [.init(entityID: entity.id, role: .center)]
        } else {
            if case .rect = entity {
                selectedSketchPoints.remove(.init(entityID: entity.id, role: .center))
                if let index = RectangleConstruction.nearestAxisEdge(entity, to: raw) {
                    selectedAxisRectangleEdge = (entity.id, index)
                }
            }
            if !selectedSketchEntityIDs.contains(entity.id) {
                selectedSketchEntityIDs = [entity.id]
            }
        }
        sketchEntityDrag = SketchEntityDrag(
            sketchID: sketch.id,
            control: control?.kind,
            before: entity,
            grabPoint: raw,
            baseline: sketch.entities
        )
        sketchStrokeStart = nil
        pendingEntity = nil
        return true
    }

    private func updateSketchEntityDrag(raw: SIMD2<Double>) {
        guard var drag = sketchEntityDrag, let sketch = activeSketch else { return }

        if drag.control == .center, case let .rect(id, lo, hi) = drag.before {
            var baseline = sketch
            baseline.entities = drag.baseline
            let others = Sketch(plane: sketch.plane,
                entities: drag.baseline.filter { $0.id != id })
            let center = (lo + hi) / 2
            let target = SnapEngine.snap(center + raw - drag.grabPoint, in: others,
                options: CADPreferences.shared.snapOptions, tolerance: sketchSnapTolerance).point
            let solved = SketchSolverBridge.solveAxisRectangleTranslation(
                baseline, id: id, delta: target - center)
            if (solved == nil || solved == drag.baseline),
               simd_distance(target, center) > 2 * worldPerPoint, !drag.showedBlockedNotice {
                showNotice("Locked or constrained sketch parts can't be moved.")
                drag.showedBlockedNotice = true
                sketchEntityDrag = drag
            }
            guard let solved else { return }
            guard solved != drag.baseline || drag.pushed else { return }
            let command = UpdateSketchEntitiesCommand(sketchID: drag.sketchID,
                before: drag.baseline, after: solved)
            if drag.pushed { session.amend(command) }
            else { session.perform(command); drag.pushed = true }
            sketchEntityDrag = drag
            return
        }

        // Solve-on-edit (plan §C1): when the sketch carries constraints or
        // dimensions, route a control-point drag through the solver so
        // constrained geometry holds and under-constrained geometry follows.
        // Body translates keep the direct path (the solver pins a single
        // point, which would deform rather than translate a whole entity).
        if drag.control != nil,
           !(sketch.constraints.isEmpty && sketch.dimensions.isEmpty) {
            updateSolvedSketchEntityDrag(&drag, raw: raw, sketch: sketch)
            return
        }

        let after: SketchEntity
        if let control = drag.control {
            // Snap against the rest of the sketch (not the dragged entity —
            // its own points would pin the handle in place).
            let others = Sketch(
                plane: sketch.plane,
                entities: sketch.entities.filter { $0.id != drag.before.id }
            )
            let point = SnapEngine.snap(raw, in: others, options: CADPreferences.shared.snapOptions, tolerance: sketchSnapTolerance).point
            after = SketchHitTester.applying(control, at: point, to: drag.before)
        } else {
            // Body translate: grid-capture each axis, like the extrude drag.
            var delta = raw - drag.grabPoint
            let snapped = SIMD2(
                (delta.x / SnapEngine.gridSpacing).rounded() * SnapEngine.gridSpacing,
                (delta.y / SnapEngine.gridSpacing).rounded() * SnapEngine.gridSpacing
            )
            if CADPreferences.shared.snapToGrid, abs(delta.x - snapped.x) < 0.15 { delta.x = snapped.x }
            if CADPreferences.shared.snapToGrid, abs(delta.y - snapped.y) < 0.15 { delta.y = snapped.y }
            after = SketchHitTester.translated(drag.before, by: delta)
        }
        let current = sketch.entities.first { $0.id == drag.before.id }
        guard after != current else { return }
        let command = UpdateSketchEntityCommand(
            sketchID: drag.sketchID, before: drag.before, after: after
        )
        if drag.pushed {
            session.amend(command)
        } else {
            session.perform(command)
            drag.pushed = true
            sketchEntityDrag = drag
        }
    }

    /// Solve-on-edit drag frame (plan §C1): pull the grabbed control point
    /// toward the drag target through the constraint solver, then coalesce the
    /// whole solved sketch into ONE amendable `UpdateSketchEntitiesCommand`.
    /// Fully-defined (zero-DOF) geometry refuses to move — the solve is a
    /// no-op and the geometry springs back to its baseline.
    private func updateSolvedSketchEntityDrag(
        _ drag: inout SketchEntityDrag, raw: SIMD2<Double>, sketch: Sketch
    ) {
        // Target for the grabbed point: snap against the OTHER entities (its own
        // points would pin the handle in place), matching the direct path.
        let others = Sketch(
            plane: sketch.plane,
            entities: drag.baseline.filter { $0.id != drag.before.id }
        )
        let target = SnapEngine.snap(raw, in: others, options: CADPreferences.shared.snapOptions, tolerance: sketchSnapTolerance).point

        // Always solve from the fixed pre-drag baseline so the target is
        // absolute and the result is deterministic across frames.
        var baselineSketch = sketch
        baselineSketch.entities = drag.baseline
        let outcome = SketchSolverBridge.solveOutcome(
            baselineSketch, movingEntity: drag.before.id, dragTarget: target,
            knownDOF: drag.structuralDOF
        )
        // Conflicting constraint system: the solver's output is a best-fit
        // COMPROMISE that satisfies nothing, and amending it into the
        // document every drag frame was review R2-3 — the sketch visibly
        // "melted" toward the compromise. Hold the baseline (spring back)
        // and badge the conflict instead, the same gate planegcs applies
        // before updating geometry (docs/FREECAD_PLAYBOOK.md S1).
        guard outcome.structuralResidual <= Self.overConstraintTolerance else {
            // Attribute once per conflict episode: the structural system does
            // not change while dragging (only geometry moves), so the guilty
            // set is stable until the flag clears.
            if !sketchSolveConflict {
                sketchConflictAttribution = SketchSolverBridge.conflictAttribution(
                    baselineSketch, tolerance: Self.overConstraintTolerance)
            }
            sketchSolveConflict = true
            return
        }
        sketchSolveConflict = false
        if !sketchConflictAttribution.isEmpty { sketchConflictAttribution = .init() }
        let (solved, dof) = (outcome.entities, outcome.dof)
        if drag.structuralDOF == nil {
            drag.structuralDOF = dof
            sketchEntityDrag = drag // remembered even when the sketch is rigid
        }

        // Rigid sketch: refuse to move (no-op / spring back to baseline).
        guard dof > 0 else { return }
        guard solved != drag.baseline || drag.pushed else { return }

        let command = UpdateSketchEntitiesCommand(
            sketchID: drag.sketchID, before: drag.baseline, after: solved
        )
        if drag.pushed {
            session.amend(command)
        } else {
            session.perform(command)
            drag.pushed = true
        }
        sketchEntityDrag = drag
    }

    /// Polygon tool: number of sides for the next placement (NumericInputBar).
    var polygonSides: Int = 6

    /// Arc awaiting bulge adjustment: the chord drag placed the endpoints, a
    /// follow-up drag on the arc's midpoint adjusts the sagitta. Committed on
    /// the next tool action / tap elsewhere.
    struct PendingArc {
        let id = UUID()
        var a: SIMD2<Double>
        var b: SIMD2<Double>
        var sagitta: Double
    }
    var pendingArc: PendingArc?
    private var arcTapStart: SIMD2<Double>?
    private var adjustingArcBulge = false

    var pendingArcEntity: SketchEntity? {
        guard let arc = pendingArc else { return nil }
        return Self.arcEntity(id: arc.id, a: arc.a, b: arc.b, sagitta: arc.sagitta)
    }

    /// How near the chain's start a tap must land (plane-local mm) to close the
    /// polygon. Larger than `SnapEngine.pointTolerance` so finger-closing a
    /// loop is forgiving, while the committed endpoint still welds exactly onto
    /// the start.
    static let lineCloseTolerance: Double = 1.2

    /// Line chaining: the endpoint of the last committed line; the next line
    /// stroke starting within snap tolerance pre-anchors exactly there.
    /// The stroke's start BEFORE snapping, so an H/V constraint can be judged
    /// against where the user actually aimed rather than where the grid put it.
    private var sketchStrokeStartRaw: SIMD2<Double>?

    private var chainAnchor: SIMD2<Double>?
    /// Creation-only sizing intent; Escape/tool changes clear it with the chain.
    private var freshLineSizingID: UUID?
    /// First point of the chain — a stroke closing onto it ends the chain.
    private var chainStart: SIMD2<Double>?
    /// The chain's first segment, so `chainStart` can be re-read from the
    /// SOLVED sketch (see `refreshChainAnchors`).
    private var chainStartEntityID: UUID?
    /// True while the user is building a polyline by TAPS (tap-to-place
    /// vertices, close on the start). A drag-drawn line still sets `chainAnchor`
    /// for drag-continuation, but leaves this false so a follow-up tap selects
    /// the line (to dimension it) instead of extending a chain.
    private(set) var tapChainActive = false

    /// True while a hover is previewing the next line segment (pointer/Pencil),
    /// so the preview can be torn down without disturbing a real drag.
    private var lineHoverPreviewActive = false
    private var lineSnapHoverActive = false
    /// The hovered next-segment endpoint sits on the chain's start, so the next
    /// tap will CLOSE the loop — the overlay highlights the start to signal it.
    private(set) var lineWillClose = false
    /// Stable id for the hover preview entity (keeps render diffing cheap).
    private let linePreviewID = UUID()

    /// Escape abandons only the unfinished line continuation. A second Escape
    /// disarms Line, matching the native two-stage workflow; committed segments
    /// and the document's undo stack are untouched.
    func cancelLineInput() {
        guard mode.sketchTool == .line, editingDimension == nil else { return }
        if chainAnchor != nil {
            clearChain()
        } else {
            deselectSketchTool()
        }
    }

    /// Rectangle Escape first discards unfinished placement, then disarms the
    /// tool. Neither step mutates committed geometry or creates history.
    func cancelRectangleInput() {
        guard mode.sketchTool == .rect, editingDimension == nil else { return }
        if hasPendingRectangle {
            clearRectanglePlacement()
        } else {
            deselectSketchTool()
        }
    }

    /// Native Delete finishes Line without deleting the last committed segment.
    /// Numeric editing owns its own Delete key and must not disarm the tool.
    func deleteLineInput() {
        guard mode.sketchTool == .line, editingDimension == nil else { return }
        deselectSketchTool()
    }

    /// Return finishes the current open polyline without placing another
    /// segment. Native keeps Line armed, so the next empty or endpoint tap can
    /// start a new chain while the committed geometry and history remain.
    func finishLineInput() {
        guard mode.sketchTool == .line, editingDimension == nil else { return }
        clearChain()
    }

    /// Escape abandons an unfinished three-point arc without committing it.
    /// Native also drops the Arc tool in this state; a following Escape may
    /// therefore leave sketch mode instead of reviving the discarded preview.
    func cancelArcInput() {
        guard case .sketching(let id, tool: .arc) = mode,
              editingDimension == nil else { return }
        pendingArc = nil
        arcTapStart = nil
        if arcEndpointHoverPreviewActive {
            pendingEntity = nil
            arcEndpointHoverPreviewActive = false
        }
        adjustingArcBulge = false
        activeGuides = []
        activeSnap = nil
        mode = .sketching(id, tool: nil)
    }

    /// Native Circle Escape disarms while retaining the completed size selection.
    /// Dimension-field cancellation owns Escape first; no document history here.
    func cancelCircleInput() {
        guard mode.sketchTool == .circle, editingDimension == nil else { return }
        pendingEntity = nil
        sketchStrokeStart = nil
        sketchStrokeCurrent = nil
        activeGuides = []
        activeSnap = nil
        pendingInferredConstraints = []
        deselectSketchTool()
    }

    /// Hardware Return accepts the default/current third-point shape without
    /// requiring a canvas tap. Native Shapr3D keeps Arc armed and chains from
    /// the accepted endpoint, so this is the same commit path as a third tap.
    func finishArcInput() {
        guard mode.sketchTool == .arc, pendingArc != nil,
              editingDimension == nil else { return }
        commitPendingArc(chain: true)
    }

    /// Register the sketch-level Escape only in a settled, unselected state.
    /// Tool input and contextual operations own Escape ahead of this fallback.
    var canExitSketchWithEscape: Bool {
        mode.isSketching && mode.sketchTool == nil && editingDimension == nil &&
        !sketchTransformActive && !selectModeActive && pendingSymbolID == nil &&
        selectedSketchEntityIDs.isEmpty && selectedSketchPoints.isEmpty &&
        selectedConstraintID == nil && selectedDimensionID == nil
    }

    private func clearChain() {
        freshLineSizingID = nil
        chainAnchor = nil
        chainStart = nil
        chainStartEntityID = nil
        tapChainActive = false
        _ = clearLinePreviewIfNeeded()
    }

    /// The viewport's last reported pointer/Pencil hover, nil once it leaves.
    var hoverRay: Ray?

    /// Space (Shapr3D): start a Line sketch on the plane or face under the
    /// pointer — the origin tiles, a construction plane, a planar body face
    /// or the bare grid. Outside a sketch only; nothing hovered, or a hover
    /// that is not a sketch plane (a curved wall), is a no-op.
    func sketchOnHoveredPlane() -> Bool {
        guard let ray = hoverRay else { return false }
        switch mode {
        case .sketching, .pickingSketchPlane: return false
        default: break
        }
        startSketch(tool: .line)
        if case .pickingSketchPlane(let tool) = mode {
            handlePlanePick(ray: ray, tool: tool)
        }
        if mode.isSketching { return true }
        cancelPlanePicking()
        return false
    }

    /// Pointer/Pencil-hover previews for tap-built sketch tools. An arc's third
    /// point is the hovered point after its two endpoints; Line and Rectangle
    /// retain their existing rubber-band previews below. A nil ray keeps an
    /// arc's last valid shape and clears only the transient line preview.
    @discardableResult
    func updateLinePreview(ray: Ray?) -> Bool {
        if mode.sketchTool == .arc, var arc = pendingArc,
           let ray, let raw = rawSketchPoint(from: ray) {
            let before = arc.sagitta
            arc.sagitta = Self.clampedSagitta(Self.signedSagitta(of: raw, arc: arc), arc: arc)
            pendingArc = arc
            return abs(before - arc.sagitta) > 1e-9
        }
        if mode.sketchTool == .arc, pendingArc == nil, let start = arcTapStart {
            let previous = pendingEntity
            guard let ray, let sketch = activeSketch,
                  let raw = rawSketchPoint(from: ray) else {
                pendingEntity = nil
                arcEndpointHoverPreviewActive = false
                return previous != nil
            }
            let snap = SnapEngine.snap(raw, in: sketch,
                faceLoops: activeFaceSnapLoops(), options: CADPreferences.shared.snapOptions,
                tolerance: sketchSnapTolerance)
            guard simd_length(snap.point - start) > 1e-6 else {
                pendingEntity = nil
                arcEndpointHoverPreviewActive = false
                return previous != nil
            }
            pendingEntity = Self.arcEntity(id: arcEndpointPreviewID, a: start, b: snap.point,
                sagitta: Self.defaultSagitta(a: start, b: snap.point))
            sketchStrokeCurrent = snap.point
            activeSnap = snap.snappedToPoint ? (snap.kind, snap.point) : nil
            arcEndpointHoverPreviewActive = pendingEntity != nil
            return previous != pendingEntity
        }
        if arcEndpointHoverPreviewActive {
            pendingEntity = nil
            arcEndpointHoverPreviewActive = false
        }
        // Before the first click, identify the point the line would start on.
        // This is feedback only: do not create an anchor, segment or undo entry.
        if mode.sketchTool == .line, !tapChainActive, sketchStrokeStart == nil {
            let previous = activeSnap
            if let ray, let sketch = activeSketch, let raw = rawSketchPoint(from: ray) {
                let snap = SnapEngine.snap(raw, in: sketch,
                    faceLoops: activeFaceSnapLoops(), options: CADPreferences.shared.snapOptions, tolerance: sketchSnapTolerance)
                activeSnap = snap.snappedToPoint ? (snap.kind, snap.point) : nil
            } else {
                activeSnap = nil
            }
            lineSnapHoverActive = activeSnap != nil
            return previous?.kind != activeSnap?.kind || previous?.point != activeSnap?.point
        }
        if mode.sketchTool == .rect, hasPendingRectangle {
            let before = rectanglePreview
            let previousEntity = pendingEntity
            if let ray, let point = sketchPoint(from: ray) {
                sketchStrokeCurrent = point
                if rectangleType == .threePoint {
                    if let start = rectangleBaseline?.a ?? rectangleAnchor {
                        updateRectanglePreview(from: start, to: point)
                    }
                } else if let anchor = rectangleAnchor {
                    pendingEntity = RectangleConstruction.axisAligned(from: anchor, to: point,
                        centered: rectangleType == .center, id: rectangleIDs[0])
                }
            } else {
                pendingEntity = nil
                rectanglePreview = rectangleBaseline.map {
                    [.line(id: rectangleIDs[0], a: $0.a, b: $0.b)]
                } ?? []
            }
            return before != rectanglePreview || previousEntity != pendingEntity
        }
        guard case .sketching(_, .some(.line)) = mode,
              tapChainActive, let anchor = chainAnchor,
              let ray, let sketch = activeSketch, let raw = rawSketchPoint(from: ray)
        else { return clearLinePreviewIfNeeded() }

        let snap = SnapEngine.snap(raw, in: sketch, faceLoops: activeFaceSnapLoops(), options: CADPreferences.shared.snapOptions, tolerance: sketchSnapTolerance)
        var end = snap.point
        var willClose = false
        if let start = chainStart,
           simd_length(start - anchor) > SnapEngine.pointTolerance,
           simd_length(raw - start) <= (CADPreferences.shared.snapToSketchGuidepoints
                ? Self.lineCloseTolerance : 1e-9) {
            end = start
            willClose = true
        }
        if !willClose {
            let result = inferSketchInput(tool: .line, anchor: anchor, current: end,
                existing: sketch.entities, settings: effectiveAutoConstrainSettings)
            end = result.snappedPoint
            activeGuides = result.guides
        } else {
            activeGuides = []
        }
        let entity = SketchEntity.line(id: linePreviewID, a: anchor, b: end)
        let changed = pendingEntity != entity || lineWillClose != willClose
                || !lineHoverPreviewActive
        pendingEntity = entity
        sketchStrokeStart = anchor
        sketchStrokeCurrent = end
        if willClose {
            activeSnap = (kind: .endpoint, point: end)
        } else {
            activeSnap = snap.snappedToPoint ? (kind: snap.kind, point: end) : nil
        }
        lineWillClose = willClose
        lineHoverPreviewActive = true
        return changed
    }

    @discardableResult
    private func clearLinePreviewIfNeeded() -> Bool {
        guard lineHoverPreviewActive || lineSnapHoverActive else { return false }
        lineSnapHoverActive = false
        lineHoverPreviewActive = false
        lineWillClose = false
        pendingEntity = nil
        sketchStrokeStart = nil
        sketchStrokeCurrent = nil
        activeSnap = nil
        activeGuides = []
        return true
    }

    /// A small "+" marker (world-space segment pairs) at the line chain's
    /// current anchor, so the tap-to-place vertex is visible even before the
    /// next segment is drawn.
    nonisolated static func chainAnchorMarkerSegments(
        at anchor: SIMD2<Double>, on plane: SketchPlane
    ) -> [SIMD3<Float>] {
        let arm = 0.22
        let pts = [
            anchor + SIMD2(-arm, 0), anchor + SIMD2(arm, 0),
            anchor + SIMD2(0, -arm), anchor + SIMD2(0, arm),
        ]
        return pts.map {
            let w = plane.toWorld($0)
            return SIMD3(Float(w.x), Float(w.y), Float(w.z))
        }
    }

    /// A small ring (world-space segment pairs) at the chain's start, drawn when
    /// a hover is about to close the loop — the Shapr3D "you're closing" cue.
    nonisolated static func closeLoopMarkerSegments(
        at start: SIMD2<Double>, on plane: SketchPlane
    ) -> [SIMD3<Float>] {
        let radius = 0.5
        let steps = 16
        var out: [SIMD3<Float>] = []
        func world(_ a: Double) -> SIMD3<Float> {
            let p = start + SIMD2(cos(a), sin(a)) * radius
            let w = plane.toWorld(p)
            return SIMD3(Float(w.x), Float(w.y), Float(w.z))
        }
        for i in 0..<steps {
            let a0 = Double(i) / Double(steps) * 2 * .pi
            let a1 = Double(i + 1) / Double(steps) * 2 * .pi
            out.append(world(a0))
            out.append(world(a1))
        }
        return out
    }

    /// The active sketch while in sketching mode.
    var activeSketch: Sketch? {
        guard case .sketching(let id, _) = mode else { return nil }
        return session.document.sketches.first { $0.id == id }
    }

    /// Definition state of the active sketch for the status chip (plan §C4):
    /// remaining structural DOF and whether the sketch is fully defined
    /// (0 DOF). `nil` when not sketching or the sketch has no geometry yet.
    var sketchDefinitionStatus: (dof: Int, fullyDefined: Bool)? {
        guard let sketch = activeSketch, !sketch.entities.isEmpty,
              let report = sketchDefinitionReport(for: sketch) else { return nil }
        return (report.dof, report.dof == 0)
    }

    // MARK: - Definition state (memoised, solved off the main thread)

    /// Sketch colours by definition state (plan §C4): GREEN fully defined,
    /// BLUE under-defined. Static so tests can name them.
    static let definedSketchColor = SIMD4<Float>(0.20, 0.70, 0.35, 1)
    static let underDefinedSketchColor = SIMD4<Float>(0.22, 0.44, 0.82, 1)

    /// The solver behind `sketchDefinitionReport` — a test seam (count the
    /// calls, return canned states). Runs on a background thread.
    @ObservationIgnored var definitionSolver: @Sendable (Sketch) -> SketchSolverBridge.DefinitionReport =
        SketchSolverBridge.definitionReport

    /// Bumped on the main actor when a background definition solve lands, so
    /// every view that read a stale or missing report re-evaluates.
    private(set) var sketchDefinitionEpoch = 0

    @ObservationIgnored private var definitionMemo:
        (sketch: Sketch, report: SketchSolverBridge.DefinitionReport)?
    @ObservationIgnored private var definitionInFlight: Sketch?
    @ObservationIgnored private var definitionPending: Sketch?

    /// The active sketch's definition report — per-entity fully-defined
    /// flags and the structural DOF — WITHOUT solving on the main thread.
    /// The solve is a Jacobian null-space analysis, cubic in the variable
    /// count (1.5 s for 150 constrained lines in Debug); it used to run
    /// inside the `scene` getter on EVERY viewport update while sketching,
    /// and again in the status chip on every editor body. Both read this
    /// memo now, keyed on the sketch VALUE (so a body edit never invalidates
    /// it). A miss schedules one background solve for the newest sketch —
    /// latest wins, so drag ticks coalesce — and returns the previous report
    /// for the same sketch, so colours hold steady until the fresh result
    /// bumps `sketchDefinitionEpoch`.
    func sketchDefinitionReport(for sketch: Sketch) -> SketchSolverBridge.DefinitionReport? {
        _ = sketchDefinitionEpoch // observation dependency: re-read when a solve lands
        if let memo = definitionMemo, memo.sketch == sketch { return memo.report }
        scheduleDefinitionSolve(for: sketch)
        return definitionMemo?.sketch.id == sketch.id ? definitionMemo?.report : nil
    }

    private func scheduleDefinitionSolve(for sketch: Sketch) {
        if let inFlight = definitionInFlight {
            if inFlight != sketch { definitionPending = sketch }
            return
        }
        definitionInFlight = sketch
        let solver = definitionSolver
        Task.detached(priority: .userInitiated) { [weak self] in
            let report = solver(sketch)
            guard let self else { return }
            await MainActor.run { self.definitionSolveDidFinish(sketch, report) }
        }
    }

    private func definitionSolveDidFinish(
        _ sketch: Sketch, _ report: SketchSolverBridge.DefinitionReport
    ) {
        definitionInFlight = nil
        definitionMemo = (sketch, report)
        sketchDefinitionEpoch += 1
        if let next = definitionPending {
            definitionPending = nil
            if next != sketch { scheduleDefinitionSolve(for: next) }
        }
    }

    /// Wait for the in-flight and pending definition solves (tests).
    func settleSketchDefinition() async {
        while definitionInFlight != nil || definitionPending != nil {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// True while the active sketch's constraint system is CONFLICTING — the
    /// solver could not satisfy every constraint/dimension simultaneously, so
    /// drags spring back instead of writing the solver's compromise into the
    /// document (review R2-3). Set/cleared by the solved drag path; shown as
    /// a red chip in the sketch pill.
    var sketchSolveConflict = false

    /// Stage-2 conflict attribution: WHICH constraints/dimensions the solver
    /// could not satisfy (every member of the clashing cluster — two dueling
    /// lengths both light up). Computed when a drag first detects the
    /// conflict, cleared with `sketchSolveConflict`; the glyph and dimension
    /// overlays paint these red.
    var sketchConflictAttribution = SketchSolverBridge.ConflictAttribution()

    func startSketch(tool: SketchTool) {
        cancelSymmetryAxisPick()
        clearRectanglePlacement()
        if case .sketching(let id, _) = mode {
            commitPendingArc()
            clearChain()
            // Native accepts a pending numeric value when clicking another
            // tool. Explicit cancellation remains a separate action.
            finishDimensionEditOnClickAway()
            mode = .sketching(id, tool: tool) // just switch tools
            return
        }
        cancelTransientPicks()
        selectedImageID = nil
        // Sketch-on-plane: a construction plane selected in Items IS the
        // sketch plane (Shapr3D: select the plane, then Sketch).
        if let plane = selectedPlane {
            selectedPlaneID = nil
            cancelTool()
            selection.removeAll()
            beginSketch(on: plane.plane, tool: tool)
            return
        }
        // Sketch-on-face: a selected planar face IS the sketch plane
        // (spec §2.3); read it before cancelTool clears the context.
        if case .faceSelected = mode, let plane = toolContext?.plane {
            cancelTool()
            selection.removeAll()
            // The selection's plane keeps the face's own basis (face moves are
            // stored in it); the sketch gets the upright layout.
            beginSketch(on: .readable(origin: plane.origin, normal: plane.normal), tool: tool)
            return
        }
        cancelTool()
        selection.removeAll()
        // No plane yet: show the origin plane tiles. Tapping one — or a
        // planar face, a construction plane, or the bare ground — starts
        // the sketch there.
        mode = .pickingSketchPlane(tool: tool)
    }

    /// Tap the active tool off (palette toggle, same pattern as CreateTool):
    /// stay in the sketch with no drawing tool armed, so empty-space drags
    /// orbit the camera instead of drawing.
    func deselectSketchTool() {
        cancelSymmetryAxisPick()
        guard case .sketching(let id, _) = mode else { return }
        clearRectanglePlacement()
        editingDimension = nil
        commitPendingArc()
        clearChain()
        // Offset picks belong to the tool, not the sketch: dropping the tool
        // drops them, so re-arming starts clean rather than resuming a pick
        // the user has visually lost track of.
        resetSketchOffsetState()
        mode = .sketching(id, tool: nil)
    }

    func cancelPlanePicking() {
        if case .pickingSketchPlane = mode {
            mode = .idle
        }
    }

    /// Tap routing while the plane tiles are up.
    private func handlePlanePick(ray: Ray, tool: SketchTool) {
        let tiles = worldPlaneTiles + constructionPlaneTiles
        let tileHit = PlanePicking.pick(ray: ray, tiles: tiles)
        let bodyHit = HitTester.pickBody(ray: ray, in: scene)

        if let tileHit, bodyHit == nil || tileHit.distance <= bodyHit!.distance + 1e-3 {
            beginSketch(on: tileHit.tile.plane, tool: tool)
            return
        }
        if let bodyHit {
            if let plane = worldFacePlane(bodyID: bodyHit.bodyID, triangleIndex: bodyHit.triangleIndex) {
                beginSketch(on: plane, tool: tool)
            }
            // A body was tapped, not the grid: a refused face (curved) keeps
            // the picker armed rather than sketching on the ground behind it
            // — the same rule as the Section View picker.
            return
        }
        // Ground fallback: tapping the bare grid sketches on the ground plane.
        if ray.intersect(planePoint: .zero, planeNormal: SIMD3(0, 1, 0)) != nil {
            beginSketch(on: .ground, tool: tool)
            return
        }
        mode = .idle
    }

    /// A body's tapped planar face as a world-space sketch plane. A CURVED
    /// face (a cylinder wall, a blend) is not a sketch plane — `planarFace`
    /// would hand back the single facet under the finger, and a sketch on
    /// that sliver is never what was meant (Shapr3D refuses it) — so the
    /// pick is declined and the caller decides what a refused tap does.
    private func worldFacePlane(bodyID: BodyID, triangleIndex: Int) -> SketchPlane? {
        guard let body = session.document.body(with: bodyID),
              let face = FaceTopology.planarFace(in: body.render, seedTriangle: triangleIndex)
        else { return nil }
        if let smooth = FaceTopology.smoothRegion(in: body.render, seedTriangle: triangleIndex),
           smooth.isCurved, face.triangles.count < smooth.triangles.count {
            return nil
        }
        let transform = body.transform
        return SketchPlane.readable(
            origin: transform.applying(to: face.origin),
            normal: transform.rotation.act(simd_cross(face.basisX, face.basisY))
        )
    }

    /// An unselected plane-based entry creates an independent sketch, even on
    /// a coincident plane. Continue an existing sketch through its item/outline
    /// instead; geometric coincidence alone is not document identity.
    private func beginSketch(on plane: SketchPlane, tool: SketchTool) {
        let sketch = Sketch(name: session.document.uniqueSketchName(), plane: plane)
        session.preview { $0.sketches.append(sketch) }
        provisionalSketch = (sketch.id, session.undoStack.undoCommands.count)
        mode = .sketching(sketch.id, tool: tool)
        // Direct reference verification (2026-09-07): choosing a sketch plane
        // enters its normal drawing view. Do not require a second Look at
        // Sketch action before the user can place geometry predictably.
        // Subsequent user orbiting remains available inside sketch mode.
        if let control = cameraControl {
            control.moveCameraHeadOn(to: sketch.plane)
            lookAtSketchAvailable = false
        }
    }

    /// Degrees off head-on past which a sketch plane is too edge-on to draw on.
    static let grazingSketchAngle: Double = 80

    func finishSketch() {
        let itemSelectionToRetain: Set<UUID> = {
            guard let sketch = activeSketch, itemSelectedSketchID == sketch.id,
                  selectedSketchPoints.isEmpty,
                  selectedSketchEntityIDs == Set(sketch.entities.map(\.id)) else { return [] }
            return selectedSketchEntityIDs
        }()
        itemSelectedSketchID = nil
        cancelSymmetryAxisPick()
        clearRectanglePlacement()
        editingDimension = nil
        commitPendingArc()
        clearChain()
        textPlacement = nil
        pendingSymbolID = nil
        pendingEntity = nil
        sketchStrokeStart = nil
        activeGuides = []
        pendingInferredConstraints = []
        adjustingArcBulge = false
        sketchEntityDrag = nil
        sketchGizmoDrag = nil
        sketchCopyOnDrag = false
        sketchTransformActive = false
        sketchRadialDrag = nil
        sketchSolveConflict = false
        sketchConflictAttribution = .init()
        selectedSketchEntityIDs.removeAll()
        selectedSketchPoints.removeAll()
        selectedConstraintID = nil
        selectedDimensionID = nil
        if case .sketching(let sketchID, _) = mode {
            // Phase D (belt-and-suspenders): rebuild dependent features on the
            // way out of the sketch, so any edit not caught at its own commit
            // boundary still propagates. No-op when nothing references it.
            session.rebuildForSketchChange(sketchID)
            mode = .idle
            removeSketchIfEmpty(sketchID)
        }
        if !itemSelectionToRetain.isEmpty {
            selectedSketchEntityIDs = itemSelectionToRetain
        }
        session.save()
    }

    /// Sketch rows materialize transiently at entry (`beginSketch` uses
    /// `session.preview`, not a command — the entity commands that follow are
    /// what make the sketch durable). A sketch entered and left without
    /// content would therefore linger as an invisible Items row that no undo
    /// can ever remove (2026-08-25 review, S3): drop it the same transient
    /// way on exit. Only a sketch CREATED at this entry is eligible, and only
    /// when no command has been pushed or undone since — any undo/redo entry
    /// might reference the sketch, and deleting the row out from under it
    /// would break the history.
    private func removeSketchIfEmpty(_ id: SketchID) {
        defer { provisionalSketch = nil }
        guard let provisional = provisionalSketch,
              provisional.id == id,
              session.undoStack.undoCommands.count == provisional.undoDepth,
              !session.undoStack.canRedo,
              let sketch = session.document.sketches.first(where: { $0.id == id }),
              sketch.entities.isEmpty,
              sketch.constraints.isEmpty,
              sketch.dimensions.isEmpty
        else { return }
        session.preview { doc in
            doc.sketches.removeAll { $0.id == id }
        }
    }

    /// A new entry with no geometry is a drawing context, not an Items row.
    /// Undo may empty it again; retain its document/history identity underneath.
    /// Persisted empty sketches are not provisional and remain discoverable.
    var itemSketches: [Sketch] {
        guard let provisional = provisionalSketch else { return session.document.sketches }
        return session.document.sketches.filter { sketch in
            sketch.id != provisional.id || !sketch.entities.isEmpty ||
                !sketch.constraints.isEmpty || !sketch.dimensions.isEmpty
        }
    }

    /// Set by `beginSketch` when it creates a brand-new sketch row: the id
    /// plus the undo depth at creation, consumed by `removeSketchIfEmpty`.
    private var provisionalSketch: (id: SketchID, undoDepth: Int)?

    /// Ray → unsnapped plane-local point, while sketching.
    private func rawSketchPoint(from ray: Ray) -> SIMD2<Double>? {
        guard let sketch = activeSketch else { return nil }
        let plane = sketch.plane
        let planePoint = SIMD3<Float>(Float(plane.origin.x), Float(plane.origin.y), Float(plane.origin.z))
        let normal = plane.normal
        let planeNormal = SIMD3<Float>(Float(normal.x), Float(normal.y), Float(normal.z))
        guard let t = ray.intersect(planePoint: planePoint, planeNormal: planeNormal) else {
            return nil
        }
        let world = ray.point(at: t)
        return plane.toLocal(SIMD3(Double(world.x), Double(world.y), Double(world.z)))
    }

    /// Ray → snapped plane-local point, while sketching.
    private func sketchPoint(from ray: Ray) -> SIMD2<Double>? {
        guard let raw = rawSketchPoint(from: ray) else { return nil }
        let result = SnapEngine.snap(raw, in: activeSketch, faceLoops: activeFaceSnapLoops(), options: CADPreferences.shared.snapOptions, tolerance: sketchSnapTolerance)
        activeSnap = (result.kind, result.point)
        return result.point
    }

    /// Boundary loops of any solid face lying IN the active sketch plane, in
    /// sketch 2D coordinates. Sketching on a bare face has no sketch geometry to
    /// snap to, so without these a rectangle lands wherever the finger was —
    /// straddling an edge, off centre. Cached per (plane, document revision)
    /// because this runs on every drag frame.
    private func activeFaceSnapLoops() -> [[SIMD2<Double>]] {
        guard case .sketching = mode, let plane = activeSketch?.plane else { return [] }
        var meshRevision: UInt64 = 0
        for body in session.document.bodies { meshRevision &+= body.meshRevision }
        let key = FaceSnapCacheKey(plane: plane, revision: session.document.bodies.count,
                                   meshRevision: meshRevision)
        if let cached = faceSnapCache, cached.key == key { return cached.loops }
        let loops = faceLoops(in: plane)
        faceSnapCache = (key, loops)
        return loops
    }

    private struct FaceSnapCacheKey: Equatable {
        let plane: SketchPlane
        let revision: Int
        let meshRevision: UInt64
    }
    private var faceSnapCache: (key: FaceSnapCacheKey, loops: [[SIMD2<Double>]])?

    /// Every planar solid face coincident with `plane`, as 2D loops in it.
    private func faceLoops(in plane: SketchPlane) -> [[SIMD2<Double>]] {
        var loops: [[SIMD2<Double>]] = []
        let n = simd_normalize(plane.normal)
        for body in session.document.bodies {
            let transform = body.transform
            let scale = transform.scale
            for face in FaceTopology.enumerateFaces(in: body.render).planar {
                let originWorld = transform.applying(to: face.origin)
                let faceNormal = SIMD3<Double>(Double(face.normal.x), Double(face.normal.y),
                                               Double(face.normal.z))
                let normalWorld = simd_normalize(transform.rotation.act(faceNormal))
                // Same plane? (either facing — a face's normal may point away.)
                guard abs(abs(simd_dot(normalWorld, n)) - 1) < 1e-3,
                      abs(simd_dot(originWorld - plane.origin, n)) < 1e-3
                else { continue }
                let xWorld = transform.rotation.act(face.basisX)
                let yWorld = transform.rotation.act(face.basisY)
                func toPlane(_ p: SIMD2<Double>) -> SIMD2<Double> {
                    plane.toLocal(originWorld + xWorld * (p.x * scale) + yWorld * (p.y * scale))
                }
                loops.append(face.outline.map(toPlane))
                for hole in face.holes { loops.append(hole.map(toPlane)) }
            }
        }
        return loops
    }

    func beginSketchStroke(ray: Ray) -> Bool {
        guard !isPickingSymmetryAxis else { return false }
        guard case .sketching(_, let tool) = mode,
              let raw = rawSketchPoint(from: ray)
        else { return false }
        editingDimension = nil
        sketchEntityDrag = nil
        if tool == .trim || tool == .text || tool == .project || tool == .offset {
            return false // These tools work by taps; unclaimed drags orbit.
        }
        if pendingSymbolID != nil {
            return false // Insert Symbol places by taps; drags orbit.
        }

        // A drag starting on the pending arc's midpoint adjusts its bulge.
        if tool == .arc, let arc = pendingArc,
           simd_length(raw - Self.arcBulgePoint(of: arc)) <= SnapEngine.pointTolerance {
            adjustingArcBulge = true
            sketchStrokeStart = nil
            pendingEntity = nil
            return true
        }
        commitPendingArc()

        // Native's freshly selected circle center remains a move control
        // while Circle is armed. An unselected center still starts a new circle.
        if tool == .circle, let sketch = activeSketch,
           selectedSketchPoints.contains(where: { point in
               guard point.role == .center,
                     case let .circle(_, center, _)? = sketchEntity(point.entityID, in: sketch)
               else { return false }
               return simd_distance(raw, center) <= controlPointTolerance
           }), beginSketchEntityDrag(at: raw, in: sketch) { return true }

        // An armed drawing tool owns the stroke, even on existing geometry.
        // Toggle it off to drag points, entities, or the selection gizmo.
        if tool == nil {
            if beginSketchGizmoDrag(at: raw) { return true }
            if let sketch = activeSketch, beginSketchEntityDrag(at: raw, in: sketch) { return true }
        }

        // No drawing tool armed: empty-space drags orbit the camera so the
        // sketch can be viewed from an angle (Shapr3D).
        guard tool != nil else { return false }
        var point = SnapEngine.snap(raw, in: activeSketch, faceLoops: activeFaceSnapLoops(), options: CADPreferences.shared.snapOptions, tolerance: sketchSnapTolerance).point
        if tool == .line, let anchor = chainAnchor {
            if simd_length(raw - anchor) <= (CADPreferences.shared.snapToSketchGuidepoints
                ? sketchSnapTolerance : 1e-9) {
                point = anchor // continue the chain exactly at the last endpoint
            } else {
                clearChain()
            }
        }
        if tool == .rect, let anchor = rectangleAnchor { point = anchor }
        if tool != .offset {
            selectedSketchEntityIDs.removeAll()
            selectedSketchPoints.removeAll()
            selectedConstraintID = nil
            selectedDimensionID = nil
        }
        sketchStrokeStart = point
        sketchStrokeStartRaw = raw
        sketchStrokeCurrent = point
        pendingEntity = nil
        return true
    }

    /// Drop inferred horizontal/vertical constraints whose stroke was not
    /// actually aimed within the screen-distance band (or angular fallback).
    /// Pure, so it is testable without a
    /// gesture. Non-H/V inferences (point snaps, parallel, tangent…) pass
    /// through untouched — they are about what the stroke MET, not its angle.
    nonisolated static func aimedConstraints(
        _ constraints: [AutoConstraintEngine.Inferred],
        from rawStart: SIMD2<Double>?,
        to rawEnd: SIMD2<Double>?,
        toleranceDeg: Double,
        axisDistanceTolerance: Double? = nil
    ) -> [AutoConstraintEngine.Inferred] {
        guard let rawStart, let rawEnd else { return constraints }
        let d = rawEnd - rawStart
        guard simd_length(d) > 1e-9 else { return constraints }
        let tol = toleranceDeg * .pi / 180
        let devHorizontal = atan2(abs(d.y), abs(d.x))
        let devVertical = atan2(abs(d.x), abs(d.y))
        return constraints.filter { inferred in
            switch inferred.kind {
            case .horizontal: axisDistanceTolerance.map { AutoConstraintEngine.withinAxisDistance(d.y, tolerance: $0) } ?? (devHorizontal <= tol)
            case .vertical: axisDistanceTolerance.map { AutoConstraintEngine.withinAxisDistance(d.x, tolerance: $0) } ?? (devVertical <= tol)
            default: true
            }
        }
    }

    func updateSketchStroke(ray: Ray) {
        guard case .sketching(_, let tool) = mode else { return }
        if adjustingArcBulge {
            guard var arc = pendingArc, let raw = rawSketchPoint(from: ray) else { return }
            arc.sagitta = Self.clampedSagitta(Self.signedSagitta(of: raw, arc: arc), arc: arc)
            pendingArc = arc
            return
        }
        if sketchGizmoDrag != nil {
            guard let raw = rawSketchPoint(from: ray) else { return }
            updateSketchGizmoDrag(raw: raw)
            return
        }
        if sketchEntityDrag != nil {
            guard let raw = rawSketchPoint(from: ray) else { return }
            updateSketchEntityDrag(raw: raw)
            return
        }
        guard let tool, let start = sketchStrokeStart,
              var current = sketchPoint(from: ray)
        else { return }
        // Live auto-constraint inference (plan §B): snap the moving endpoint,
        // collect the guides to render, and stash the constraints to emit if
        // the stroke commits. `existing` = committed entities (the in-progress
        // entity is `pendingEntity`, not yet in the sketch).
        if (autoConstrainSettings.enabled || (tool == .line && CADPreferences.shared.snapToSketchGuidelines)), !(tool == .rect && rectangleType != .diagonal), let sketch = activeSketch {
            let result = inferSketchInput(
                tool: tool, anchor: start, current: current,
                existing: sketch.entities, settings: effectiveAutoConstrainSettings
            )
            current = result.snappedPoint
            activeGuides = result.guides
            // Record an H/V constraint only if the stroke was AIMED within
            // tolerance. Both ends arrive here already pulled onto the grid,
            // and zoomed out one grid step swallows several degrees — so a line
            // aimed 1.6° off reached the engine as exactly 0° and picked up a
            // Horizontal nobody asked for. The snap can still flatten the
            // geometry (that is the grid's job); it must not manufacture a
            // constraint. Judged raw end to raw start, so neither is displaced.
            pendingInferredConstraints = Self.aimedConstraints(
                result.constraints,
                from: sketchStrokeStartRaw,
                to: rawSketchPoint(from: ray),
                toleranceDeg: autoConstrainSettings.angleToleranceDeg,
                axisDistanceTolerance: CADPreferences.shared.snapToSketchGuidelines && tool == .line
                    ? 4 * worldPerPoint : nil)
        } else {
            activeGuides = []
            pendingInferredConstraints = []
        }
        sketchStrokeCurrent = current
        if tool == .rect, rectangleType == .threePoint {
            updateRectanglePreview(from: start, to: current)
            pendingEntity = nil
        } else {
            pendingEntity = makeEntity(tool: tool, from: start, to: current)
        }
    }

    func endSketchStroke(ray: Ray) {
        defer {
            pendingEntity = nil
            sketchStrokeStart = nil
            sketchStrokeCurrent = nil
            activeSnap = nil
            activeGuides = []
            pendingInferredConstraints = []
        }
        if adjustingArcBulge {
            adjustingArcBulge = false
            return
        }
        if let drag = sketchGizmoDrag {
            sketchGizmoDrag = nil // commands already pushed/amended live
            if drag.pushed {
                session.rebuildForSketchChange(drag.sketchID)
                session.save()
            }
            return
        }
        if let drag = sketchEntityDrag {
            // Drop-to-weld (plan §B): releasing a control point onto a nearby
            // point adds an explicit coincident (its own undo step, guarded).
            maybeAddDragCoincident(drag)
            sketchEntityDrag = nil // move command already pushed/amended live
            // Phase D: an entity move reshapes any profile a feature reads —
            // rebuild dependent features at the drag-commit boundary (cheap when
            // nothing downstream references this sketch).
            session.rebuildForSketchChange(drag.sketchID)
            return
        }
        guard case .sketching(let sketchID, .some(let tool)) = mode,
              let start = sketchStrokeStart,
              let sketch = activeSketch
        else { return }
        var end = sketchPoint(from: ray) ?? start
        // Re-run inference at the release point so the committed geometry and
        // the emitted constraints stay consistent with the on-screen preview.
        if (autoConstrainSettings.enabled || (tool == .line && CADPreferences.shared.snapToSketchGuidelines)), !(tool == .rect && rectangleType != .diagonal) {
            let result = inferSketchInput(
                tool: tool, anchor: start, current: end,
                existing: sketch.entities, settings: effectiveAutoConstrainSettings
            )
            end = result.snappedPoint
            // Same aim gate as `updateSketchStroke` — this re-run happens at
            // release and would otherwise overwrite the gated set with one
            // derived from the grid-snapped point.
            pendingInferredConstraints = Self.aimedConstraints(
                result.constraints,
                from: sketchStrokeStartRaw,
                to: rawSketchPoint(from: ray),
                toleranceDeg: autoConstrainSettings.angleToleranceDeg,
                axisDistanceTolerance: CADPreferences.shared.snapToSketchGuidelines && tool == .line
                    ? 4 * worldPerPoint : nil)
        }
        if tool == .rect, rectangleType == .threePoint {
            placeThreePointRectangle(from: start, to: end, sketchID: sketchID)
            return
        }
        guard let entity = makeEntity(tool: tool, from: start, to: end) else { return }
        if tool == .arc {
            // Held as pending so a follow-up drag can adjust the bulge.
            pendingArc = PendingArc(a: start, b: end, sagitta: Self.defaultSagitta(a: start, b: end))
            return
        }
        commitDrawnEntity(entity, sketchID: sketchID, in: sketch, rectangleEnd: end)
        if tool == .rect { clearRectanglePlacement() }
        // Paired native rechecks: rectangles retain both size badges and
        // circles retain their diameter and polygons their radius on release.
        // Open numeric input only after an explicit dimension tap.
        if tool == .circle || tool == .rect || tool == .polygon {
            selectedSketchEntityIDs = [entity.id]
            selectedSketchPoints = tool == .circle || (tool == .rect && rectangleType == .center)
                ? [.init(entityID: entity.id, role: .center)] : []
        }
        if tool == .line {
            let first = chainStart ?? start
            if simd_length(end - first) <= 1e-9 {
                clearChain() // stroke closed onto the chain start
            } else {
                chainStart = first
                chainAnchor = end
            }
        }
    }

    /// Commit a freshly drawn entity, folding any inferred auto-constraints
    /// into the SAME "Draw" undo step (plan §B); each survivor is checked so
    /// it never over-constrains, then the accepted set is solved so geometry
    /// settles. Shared by drag-draw (`endSketchStroke`) and the line tool's
    /// tap-to-place chaining (`placeLineChainPoint`).
    private func commitDrawnEntity(
        _ entity: SketchEntity, sketchID: SketchID, in sketch: Sketch,
        rectangleEnd: SIMD2<Double>? = nil
    ) {
        var sizingAnchor: RectangleSizingAnchor?
        if case let .rect(_, lo, _) = entity,
           let first = rectangleAnchor ?? sketchStrokeStart {
            sizingAnchor = rectangleType == .center
                ? rectangleEnd.map { .centered(from: first, to: $0) } ?? .center
                : .diagonal(first: first, min: lo)
        }
        var radiusDirection: SIMD2<Double>?
        if CADPreferences.shared.circularAnnotations == .alwaysRadius,
           case let .circle(_, center, _) = entity, let end = rectangleEnd,
           simd_length(end - center) > 1e-9 {
            radiusDirection = simd_normalize(end - center)
        }
        let addEntity = AddSketchEntityCommand(sketchID: sketchID, entity: entity,
                                             rectangleSizingAnchor: sizingAnchor,
                                             circleRadiusDirection: radiusDirection)
        let constraintCommands = inferredConstraintCommands(
            for: entity, sketchID: sketchID, in: sketch
        )
        if constraintCommands.isEmpty {
            session.perform(addEntity)
        } else {
            session.perform(CompositeCommand(
                title: "Draw", commands: [addEntity] + constraintCommands
            ))
        }
        // Keep the completed segment's measured length visible without
        // opening the keypad or ending line chaining (live Shapr3D comparison).
        if case .line = entity {
            freshLineSizingID = entity.id
            selectedSketchEntityIDs = [entity.id]
            selectedSketchPoints.removeAll()
        }
    }

    /// Line tool tap (spec §1): build a polyline by tapping vertices, the
    /// Shapr3D line workflow.
    ///
    /// While a tap-chain is in progress each tap extends it (or closes it on the
    /// start point). When no tap-chain is active, a tap that lands on existing
    /// geometry SELECTS it (so a just-drawn line can be tapped to dimension it),
    /// and a tap on empty space STARTS a new chain.
    private func placeLineChainPoint(ray: Ray) {
        guard case .sketching(let sketchID, _) = mode,
              let sketch = activeSketch,
              let raw = rawSketchPoint(from: ray)
        else { return }
        _ = clearLinePreviewIfNeeded() // the tap supersedes any hover preview

        let target = SnapEngine.snap(raw, in: sketch, faceLoops: activeFaceSnapLoops(), options: CADPreferences.shared.snapOptions, tolerance: sketchSnapTolerance).point

        guard tapChainActive, let anchor = chainAnchor, let start = chainStart else {
            // Not chaining: an endpoint resumes from that exact point, matching
            // native Line after Return. The entity body still selects for
            // dimensions/constraints; an empty tap starts a free chain.
            if let point = SketchHitTester.nearestPoint(
                to: raw, in: sketch.entities, tolerance: controlPointTolerance,
                preservingLineInterior: true
            ), point.role == .endpointA || point.role == .endpointB {
                selectedSketchEntityIDs.removeAll()
                selectedSketchPoints.removeAll()
                chainStart = point.point
                chainAnchor = point.point
                chainStartEntityID = nil
                tapChainActive = true
                return
            }
            if selectSketchGeometryTap(at: raw, in: sketch) { return }
            chainStart = target
            chainAnchor = target
            tapChainActive = true
            return
        }

        // Close the loop: a tap near the start of a chain that already has a
        // segment welds shut and ends the chain. The close target is more
        // generous than the point-weld tolerance (Shapr3D highlights the start
        // as you approach) so finger-closing a polygon is reliable.
        if simd_length(start - anchor) > SnapEngine.pointTolerance,
           simd_length(raw - start) <= (CADPreferences.shared.snapToSketchGuidepoints
                ? Self.lineCloseTolerance : 1e-9) {
            commitChainSegment(from: anchor, to: start, closing: true,
                               sketchID: sketchID, in: sketch)
            return
        }

        // Extend the chain by one segment.
        if simd_length(target - anchor) <= SnapEngine.pointTolerance { return }
        commitChainSegment(from: anchor, to: target, closing: false,
                           sketchID: sketchID, in: sketch)
    }

    /// Commit one polyline segment for the line tool's tap chaining, folding in
    /// auto-constraints like a drag (except when closing, where the weld onto
    /// the start must stay exact so the loop actually closes), then re-anchor
    /// or clear the chain.
    private func commitChainSegment(
        from anchor: SIMD2<Double>, to rawEnd: SIMD2<Double>,
        closing: Bool, sketchID: SketchID, in sketch: Sketch
    ) {
        var end = rawEnd
        if !closing, autoConstrainSettings.enabled || CADPreferences.shared.snapToSketchGuidelines {
            let result = inferSketchInput(
                tool: .line, anchor: anchor, current: end,
                existing: sketch.entities, settings: effectiveAutoConstrainSettings
            )
            end = result.snappedPoint
            // `anchor` and `rawEnd` are both pre-snap here, so this is already
            // the aimed direction; gating keeps the rule in one place.
            pendingInferredConstraints = Self.aimedConstraints(
                result.constraints, from: anchor, to: rawEnd,
                toleranceDeg: autoConstrainSettings.angleToleranceDeg,
                axisDistanceTolerance: CADPreferences.shared.snapToSketchGuidelines ? 4 * worldPerPoint : nil)
        } else {
            pendingInferredConstraints = []
        }
        defer {
            pendingInferredConstraints = []
            activeGuides = []
        }
        guard let entity = makeEntity(tool: .line, from: anchor, to: end) else { return }
        commitDrawnEntity(entity, sketchID: sketchID, in: sketch)
        if closing {
            clearChain()
        } else {
            if chainStart == nil {
                chainStart = anchor
                chainStartEntityID = entity.id
            }
            chainAnchor = end
            refreshChainAnchors(lastEntityID: entity.id)
        }
    }

    /// Re-read the chain's anchor and start from the sketch AFTER the commit
    /// solved the inferred constraints. An inferred equal-length (3 % of an
    /// existing line — a 98 next to a 96 qualifies) is a real constraint the
    /// solver then satisfies by MOVING the new segment's end, but the chain
    /// kept the pre-solve point: the next tap started from where the finger
    /// had been rather than where the segment now ends, and the closing tap
    /// compared against a start the solver had since shifted. Found drawing
    /// SOLIDWORKS practice problem 4.38's L-profile by touch (2026-09-04): six
    /// taps left an open loop with a 2 mm step at one corner and no region to
    /// extrude. Anchoring on the committed geometry keeps a tap-chain
    /// continuous through whatever the solver decides.
    private func refreshChainAnchors(lastEntityID: UUID) {
        guard let entities = activeSketch?.entities else { return }
        for entity in entities {
            guard case let .line(id, a, b) = entity else { continue }
            if id == lastEntityID { chainAnchor = b }
            if id == chainStartEntityID { chainStart = a }
        }
    }

    /// Commits the pending arc (next tool action / tap elsewhere / exit).
    func commitPendingArc(chain: Bool = false) {
        if !chain {
            arcTapStart = nil
            if arcEndpointHoverPreviewActive {
                pendingEntity = nil
                arcEndpointHoverPreviewActive = false
            }
        }
        guard let arc = pendingArc else { return }
        pendingArc = nil
        pendingEntity = nil
        arcEndpointHoverPreviewActive = false
        adjustingArcBulge = false
        guard case .sketching(let sketchID, _) = mode,
              let sketch = activeSketch,
              let entity = Self.arcEntity(id: arc.id, a: arc.a, b: arc.b, sagitta: arc.sagitta)
        else { return }
        pendingInferredConstraints = AutoConstraintEngine.inferArcTangencies(
            arc: entity, existing: sketch.entities,
            settings: effectiveAutoConstrainSettings)
        commitDrawnEntity(entity, sketchID: sketchID, in: sketch)
        pendingInferredConstraints = []
        if chain,
           let committed = activeSketch?.entities.first(where: { $0.id == entity.id }),
           case let .arc(_, center, radius, start, end) = committed {
            let a = SketchEntity.arcPoint(center: center, radius: radius, angle: start)
            let b = SketchEntity.arcPoint(center: center, radius: radius, angle: end)
            arcTapStart = simd_length(a - arc.b) <= simd_length(b - arc.b) ? a : b
        } else {
            arcTapStart = chain ? arc.b : nil
        }
    }

    // MARK: - Arc math (chord + sagitta → SketchEntity.arc)

    static func defaultSagitta(a: SIMD2<Double>, b: SIMD2<Double>) -> Double {
        // Paired native endpoint placement: start at 45 degrees on the
        // chord's right side. Reversing the endpoints reverses the bulge.
        // s = (chord / 2) * tan(sweep / 4).
        -simd_length(b - a) * 0.5 * tan(.pi / 16)
    }

    /// The point that drags the bulge: the arc midpoint (chord mid + sagitta
    /// along the chord's left normal).
    static func arcBulgePoint(of arc: PendingArc) -> SIMD2<Double> {
        let chord = arc.b - arc.a
        guard simd_length(chord) > 1e-9 else { return arc.a }
        let n = simd_normalize(SIMD2(-chord.y, chord.x))
        return (arc.a + arc.b) / 2 + n * arc.sagitta
    }

    /// Signed distance of `p` from the chord line (positive = left of a→b).
    static func signedSagitta(of p: SIMD2<Double>, arc: PendingArc) -> Double {
        let chord = arc.b - arc.a
        guard simd_length(chord) > 1e-9 else { return arc.sagitta }
        let n = simd_normalize(SIMD2(-chord.y, chord.x))
        return simd_dot(p - (arc.a + arc.b) / 2, n)
    }

    /// Keeps the sagitta away from zero so the arc never degenerates flat.
    static func clampedSagitta(_ s: Double, arc: PendingArc) -> Double {
        let minimum = max(simd_length(arc.b - arc.a) * 0.02, 1e-3)
        if abs(s) < minimum {
            return s < 0 ? -minimum : minimum
        }
        return s
    }

    /// Circular arc from endpoints + sagitta (perpendicular height of the arc
    /// midpoint over the chord midpoint; positive bulges left of a→b).
    static func arcEntity(
        id: UUID, a: SIMD2<Double>, b: SIMD2<Double>, sagitta: Double
    ) -> SketchEntity? {
        SketchHitTester.arcFromChord(id: id, a: a, b: b, sagitta: sagitta)
    }

    private func makeEntity(
        tool: SketchTool, from a: SIMD2<Double>, to b: SIMD2<Double>
    ) -> SketchEntity? {
        let minimum: Double = 1e-3
        switch tool {
        case .line:
            guard simd_length(b - a) > minimum else { return nil }
            return .line(id: UUID(), a: a, b: b)
        case .rect:
            return RectangleConstruction.axisAligned(from: a, to: b, centered: rectangleType == .center)
        case .circle:
            let radius = simd_length(b - a)
            guard radius > minimum else { return nil }
            return .circle(id: UUID(), center: a, radius: radius)
        case .arc:
            return Self.arcEntity(
                id: UUID(), a: a, b: b, sagitta: Self.defaultSagitta(a: a, b: b)
            )
        case .ellipse:
            let radiusX = abs(b.x - a.x)
            let radiusY = abs(b.y - a.y)
            guard radiusX > minimum, radiusY > minimum else { return nil }
            return .ellipse(id: UUID(), center: a, radiusX: radiusX, radiusY: radiusY, rotation: 0)
        case .polygon:
            let delta = b - a
            let radius = simd_length(delta)
            guard radius > minimum else { return nil }
            return .polygon(
                id: UUID(), center: a, radius: radius,
                sides: max(3, polygonSides), rotation: atan2(delta.y, delta.x)
            )
        case .trim, .text, .project, .offset:
            return nil // These tools never rubber-band draw.
        }
    }

    // MARK: - Auto-constraint emission on commit (plan §B)

    /// Build the commands for the auto-inferred constraints of a freshly
    /// committed entity. Each candidate is accepted only if it does not
    /// over-constrain the sketch (residual guard, matching `applyConstraint`),
    /// then the accepted system is solved so under-defined geometry settles
    /// onto the inferred relationships. Returns `[]` when nothing survives.
    private func inferredConstraintCommands(
        for entity: SketchEntity, sketchID: SketchID, in sketch: Sketch
    ) -> [DocumentCommand] {
        var candidates = pendingInferredConstraints
        // The circle's anchor is a real solver center, unlike its dragged rim.
        // Preserve an acquired existing circle center as part of the Draw step.
        // Require actual positional coincidence; never attract a nearby center.
        if effectiveAutoConstrainSettings.enabled, effectiveAutoConstrainSettings.pointSnap,
           case let .circle(_, center, _) = entity,
           let target = sketch.entities.first(where: {
               guard case let .circle(_, existingCenter, _) = $0 else { return false }
               return simd_distance(center, existingCenter) <= 1e-6
           }) {
            candidates.append(.init(kind: .coincident, selfRole: .center,
                targetEntityID: target.id, targetRole: .center))
        }
        guard !candidates.isEmpty else { return [] }
        // Proposed sketch = committed sketch + the new entity; candidates are
        // added one at a time so each is validated against the accumulated set.
        var proposed = sketch
        proposed.entities.append(entity)
        var accepted: [SketchConstraint] = []
        for inferred in candidates {
            let refs = inferredRefs(inferred, newEntityID: entity.id)
            guard !refs.isEmpty else { continue }
            let constraint = SketchConstraint(kind: inferred.kind, refs: refs)
            var trial = proposed
            trial.constraints.append(constraint)
            if SketchSolverBridge.residualNorm(trial) > Self.overConstraintTolerance {
                continue // would conflict — skip defensively
            }
            proposed = trial
            accepted.append(constraint)
        }
        guard !accepted.isEmpty else { return [] }
        var commands: [DocumentCommand] = accepted.map {
            AddSketchConstraintCommand(sketchID: sketchID, constraint: $0)
        }
        // Solve the accepted system so geometry settles; emit an update for
        // each moved entity (the new entity included — it is appended last).
        let (solved, _) = SketchSolverBridge.solve(proposed, movingEntity: nil, dragTarget: nil)
        for (before, after) in zip(proposed.entities, solved) where before != after {
            commands.append(UpdateSketchEntityCommand(
                sketchID: sketchID, before: before, after: after
            ))
        }
        return commands
    }

    /// Resolve an inferred relationship to concrete constraint refs: `selfRole`
    /// addresses the NEW entity; a non-nil target addresses an existing entity.
    /// A nil target is a pure axis constraint (horizontal / vertical).
    private func inferredRefs(
        _ inferred: AutoConstraintEngine.Inferred, newEntityID: UUID
    ) -> [ConstraintRef] {
        let selfRef = ConstraintRef(entityID: newEntityID, role: inferred.selfRole)
        if let targetID = inferred.targetEntityID {
            return [selfRef, ConstraintRef(entityID: targetID, role: inferred.targetRole ?? .whole)]
        }
        return [selfRef]
    }

    /// On releasing a control-point drag, weld it to a nearby point with an
    /// explicit coincident constraint (plan §B) — its own undo step, guarded
    /// against over-constraint, and skipped when already coincident.
    private func maybeAddDragCoincident(_ drag: SketchEntityDrag) {
        guard effectiveAutoConstrainSettings.enabled, effectiveAutoConstrainSettings.pointSnap,
              let control = drag.control,
              let role = Self.pointRole(for: control),
              case .sketching(let sketchID, _) = mode,
              let sketch = activeSketch,
              let dragged = sketch.entities.first(where: { $0.id == drag.before.id }),
              let point = SketchHitTester.modelPoints(of: dragged)
                  .first(where: { $0.role == role })?.point
        else { return }
        // Nearest point on any OTHER entity, within snap tolerance.
        let others = sketch.entities.filter { $0.id != dragged.id }
        guard let hit = SketchHitTester.nearestPoint(
            to: point, in: others, tolerance: SnapEngine.pointTolerance
        ) else { return }
        let a = SketchPointSelection(entityID: dragged.id, role: role)
        let b = SketchPointSelection(entityID: hit.entityID, role: hit.role)
        // Skip if these two points are already welded by a coincident.
        if sketch.constraints.contains(where: { Self.isCoincidentBetween($0, a, b) }) { return }
        // Skip if they were already a shared joint BEFORE the drag — welded by
        // proximity (e.g. an existing rectangle corner) rather than an explicit
        // constraint. Drop-to-weld only links points the drag brought together
        // from genuinely separate locations, never a point to its own
        // already-coincident neighbour.
        if let bd = Self.baselinePoint(drag.baseline, a),
           let bh = Self.baselinePoint(drag.baseline, b) {
            let d = bd - bh
            if d.x * d.x + d.y * d.y < 1e-12 { return }
        }
        let constraint = SketchConstraint(kind: .coincident, refs: [
            ConstraintRef(entityID: a.entityID, role: a.role),
            ConstraintRef(entityID: b.entityID, role: b.role),
        ])
        var proposed = sketch
        proposed.constraints.append(constraint)
        if SketchSolverBridge.residualNorm(proposed) > Self.overConstraintTolerance { return }
        session.perform(AddSketchConstraintCommand(sketchID: sketchID, constraint: constraint))
        session.save()
    }

    /// The solver `PointRole` a draggable control point maps to, or nil for
    /// handles the solver treats as derived (rim / radius / arc endpoints /
    /// off-diagonal rect corners) that carry no coincident-addressable point.
    private static func pointRole(for control: SketchHitTester.ControlKind) -> PointRole? {
        switch control {
        case .lineStart: return .endpointA
        case .lineEnd: return .endpointB
        case .center: return .center
        case .rectCorner(0): return .endpointA
        case .rectCorner(2): return .endpointB
        default: return nil
        }
    }

    /// The plane-local coordinate of `sel` in a pre-drag baseline snapshot.
    private static func baselinePoint(
        _ baseline: [SketchEntity], _ sel: SketchPointSelection
    ) -> SIMD2<Double>? {
        guard let e = baseline.first(where: { $0.id == sel.entityID }) else { return nil }
        return SketchHitTester.modelPoints(of: e).first { $0.role == sel.role }?.point
    }

    /// True when `c` is a coincident constraint welding exactly points `a`↔`b`.
    private static func isCoincidentBetween(
        _ c: SketchConstraint, _ a: SketchPointSelection, _ b: SketchPointSelection
    ) -> Bool {
        guard c.kind == .coincident, c.refs.count == 2 else { return false }
        let refA = SketchPointSelection(entityID: c.refs[0].entityID, role: c.refs[0].role)
        let refB = SketchPointSelection(entityID: c.refs[1].entityID, role: c.refs[1].role)
        return (refA == a && refB == b) || (refA == b && refB == a)
    }

    // MARK: - Text tool (plan §B7, spec §1.12 v1)

    /// Plane-local baseline point for the pending text placement; non-nil
    /// presents the text dialog (set by a tap with the Text tool active).
    var textPlacement: SIMD2<Double>?

    /// Commit from the text dialog: glyph outlines as one undo step. The
    /// resulting closed loops are ordinary sketch entities, so their profiles
    /// fill and extrude like any other.
    func commitText(content: String, height: Double, fontName: String?) {
        guard case .sketching(let sketchID, _) = mode else {
            textPlacement = nil
            return
        }
        let origin = textPlacement ?? .zero
        textPlacement = nil
        let entities = TextSketch.glyphEntities(
            text: content, fontName: fontName, height: height, at: origin
        )
        guard !entities.isEmpty else {
            errorMessage = "No outlines for that text — try different content or a larger height."
            return
        }
        session.perform(CompositeCommand(
            title: "Text",
            commands: [AddSketchEntitiesCommand(
                sketchID: sketchID, entities: entities, title: "Text"
            )]
        ))
    }

    // MARK: - Project (plan §B8, spec §1.13 v1: unlinked body → sketch plane)

    /// Project-tool tap: flatten the tapped body's feature edges onto the
    /// active sketch plane as regular line entities (one undo step, so they
    /// participate in profiles for the CNC flat-layout workflow).
    private func projectTappedBody(ray: Ray) {
        guard case .sketching(let sketchID, _) = mode,
              let sketch = activeSketch,
              let hit = HitTester.pickBody(ray: ray, in: scene),
              let body = session.document.body(with: hit.bodyID)
        else { return }
        let entities = ProjectionKit.project(body: body, onto: sketch.plane)
        guard !entities.isEmpty else {
            errorMessage = "Nothing to project — the body has no edges to flatten onto this plane."
            return
        }
        session.perform(CompositeCommand(
            title: "Project",
            commands: [AddSketchEntitiesCommand(
                sketchID: sketchID, entities: entities, title: "Project"
            )]
        ))
    }

    // MARK: - Symbols (plan §B16, spec §1.16)

    /// Presents the Make Symbol name prompt (palette button; alert lives in
    /// EditorView).
    var showMakeSymbolPrompt = false

    /// Armed Insert Symbol: while non-nil, each sketch tap stamps an instance
    /// of this symbol at the tapped plane point until Done/Esc exits.
    var pendingSymbolID: SymbolID?

    var pendingSymbol: Symbol? {
        guard let id = pendingSymbolID else { return nil }
        return session.document.symbols.first { $0.id == id }
    }

    var canMakeSymbol: Bool {
        mode.isSketching && !selectedSketchEntityIDs.isEmpty
    }

    /// Capture the selected sketch entities as a named reusable symbol
    /// (SymbolKit normalizes them about their centroid; one undo step).
    func makeSymbol(named name: String) {
        guard let sketch = activeSketch else { return }
        let entities = sketch.entities.filter { selectedSketchEntityIDs.contains($0.id) }
        guard !entities.isEmpty else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let symbol = SymbolKit.capture(
            name: trimmed.isEmpty ? session.document.uniqueSymbolName() : trimmed,
            entities: entities
        )
        session.perform(AddSymbolCommand(symbol: symbol))
    }

    /// Arm tap-to-place for the symbol (sketching only).
    func beginInsertSymbol(_ id: SymbolID) {
        guard mode.isSketching else { return }
        clearChain()
        pendingEntity = nil
        selectedSketchEntityIDs.removeAll()
        pendingSymbolID = id
    }

    func cancelInsertSymbol() {
        pendingSymbolID = nil
    }

    /// Armed tap: stamp one instance at the tapped (snapped) plane point —
    /// fresh IDs, one undoable command per placement.
    private func placePendingSymbol(ray: Ray) {
        guard case .sketching(let sketchID, _) = mode,
              let symbol = pendingSymbol,
              let point = sketchPoint(from: ray)
        else { return }
        session.perform(AddSketchEntitiesCommand(
            sketchID: sketchID,
            entities: SymbolKit.instantiate(symbol, at: point),
            title: "Insert Symbol"
        ))
    }

    /// Items panel rename (no-ops on empty/unchanged names, like items).
    func renameSymbol(_ id: SymbolID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let command = RenameSymbolCommand(id: id, to: trimmed, document: session.document),
              command.before != trimmed
        else { return }
        session.perform(command)
    }

    /// Items panel delete (undoable; disarms a pending placement of it).
    func deleteSymbol(_ id: SymbolID) {
        if pendingSymbolID == id { pendingSymbolID = nil }
        guard let command = RemoveSymbolCommand(id: id, document: session.document) else { return }
        session.perform(command)
    }

    // MARK: - Sketch constraints (plan §C3, spec §3.2)

    /// Residual-norm ceiling above which a proposed constraint/dimension is
    /// treated as conflicting (over-constrained) and refused. Geometry is in
    /// millimetres, so an unsatisfiable residual is order-of-magnitude the
    /// geometry size; anything above this fine tolerance is a genuine conflict.
    nonisolated static let overConstraintTolerance = 1e-3

    /// Selected sketch entities of the given kind (helpers for the adaptive
    /// constraint menu). Lines feed direction constraints; circle/arc/polygon
    /// (entities the solver gives a radius variable) feed concentric/radius/
    /// tangent.
    private var selectedSketchEntities: [SketchEntity] {
        guard let sketch = activeSketch else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: sketch.entities.map { ($0.id, $0) })
        let ordered = selectedSketchEntityOrder.compactMap { id in
            selectedSketchEntityIDs.contains(id) ? byID[id] : nil
        }
        let known = Set(ordered.map(\.id))
        return ordered + sketch.entities.filter {
            selectedSketchEntityIDs.contains($0.id) && !known.contains($0.id)
        }
    }

    private var selectedLineEntities: [SketchEntity] {
        selectedSketchEntities.filter { if case .line = $0 { return true }; return false }
    }

    private var selectedRectEntities: [SketchEntity] {
        selectedSketchEntities.filter { if case .rect = $0 { return true }; return false }
    }

    private var selectedRadiusEntities: [SketchEntity] {
        selectedSketchEntities.filter {
            switch $0 {
            case .circle, .arc, .polygon: return true
            default: return false
            }
        }
    }

    /// Adaptive enablement (Shapr3D rule, spec §3.2): a constraint is offered
    /// only when the current selection supports it.
    // MARK: - Sketch plane (spec §2.4)

    /// Planes a sketch can be re-hosted onto: the ground plane plus every
    /// construction plane in the document, minus the one it already sits on.
    func availableSketchPlanes(for sketchID: SketchID) -> [SketchPlane] {
        let current = session.document.sketches.first { $0.id == sketchID }?.plane
        let candidates = [SketchPlane.ground] + session.document.planes.map(\.plane)
        return candidates.filter { plane in
            guard let current else { return true }
            // Same origin AND same normal ⇒ effectively the same plane.
            return simd_length(plane.origin - current.origin) > 1e-6
                || abs(simd_dot(plane.normal, current.normal)) < 0.999999
        }
    }

    /// Re-host `sketchID` on `plane` (spec §2.4). Entity coordinates are
    /// plane-local, so the drawing keeps its shape and moves to the new plane;
    /// dependent features rebuild so an extrude follows it. One undo step.
    func changeSketchPlane(of sketchID: SketchID, to plane: SketchPlane) {
        guard let sketch = session.document.sketches.first(where: { $0.id == sketchID }),
              sketch.plane != plane
        else { return }
        session.performWithSketchRebuild(ChangeSketchPlaneCommand(
            sketchID: sketchID, before: sketch.plane, after: plane), sketchID: sketchID)
        session.save()
    }

    /// Two similar entities retain their operands while the user chooses an axis.
    /// This is transient interaction state, never document geometry or history.
    private(set) var pendingSymmetryEntityIDs: [UUID] = []
    var isPickingSymmetryAxis: Bool { !pendingSymmetryEntityIDs.isEmpty }

    private var selectedSymmetryEntities: [UUID] {
        guard selectedSketchEntityIDs.count == 2, let sketch = activeSketch else { return [] }
        let ids = selectedSketchEntityOrder.filter { selectedSketchEntityIDs.contains($0) }
        guard ids.count == 2,
              let first = sketch.entities.first(where: { $0.id == ids[0] }),
              let second = sketch.entities.first(where: { $0.id == ids[1] }) else { return [] }
        let roles: Set<PointRole>
        switch (first, second) {
        case (.circle, .circle): roles = [.center]
        case let (.line(_, a, b), .line(_, c, d)):
            guard simd_distance(a, b) > 1e-8, simd_distance(c, d) > 1e-8 else { return [] }
            roles = [.endpointA, .endpointB]
        default: return []
        }
        return selectedSketchPoints.allSatisfy {
            ids.contains($0.entityID) && roles.contains($0.role)
        } ? ids : []
    }

    func cancelSymmetryAxisPick() {
        pendingSymmetryEntityIDs = []
    }

    func completeSymmetryAxisPick(_ axisID: UUID) {
        guard isPickingSymmetryAxis, let sketch = activeSketch,
              !pendingSymmetryEntityIDs.contains(axisID),
              case let .line(_, a, b)? = sketch.entities.first(where: { $0.id == axisID }),
              simd_distance(a, b) > 1e-8,
              pendingSymmetryEntityIDs.count == 2,
              let first = sketch.entities.first(where: { $0.id == pendingSymmetryEntityIDs[0] }),
              let second = sketch.entities.first(where: { $0.id == pendingSymmetryEntityIDs[1] }) else { return }
        let ids = pendingSymmetryEntityIDs
        let axisRef = ConstraintRef(entityID: axisID, role: .whole)
        let refs: [ConstraintRef]
        switch (first, second) {
        case (.circle, .circle):
            refs = ids.map { ConstraintRef(entityID: $0, role: .whole) } + [axisRef]
        case let (.line(_, p, q), .line(_, r, s)):
            guard simd_distance(p, q) > 1e-8, simd_distance(r, s) > 1e-8 else { return }
            let direction = simd_normalize(b - a)
            func reflected(_ point: SIMD2<Double>) -> SIMD2<Double> {
                let foot = a + direction * simd_dot(point - a, direction)
                return 2 * foot - point
            }
            let direct = simd_distance_squared(reflected(p), r) + simd_distance_squared(reflected(q), s)
            let reversed = simd_distance_squared(reflected(p), s) + simd_distance_squared(reflected(q), r)
            // Persist the closest endpoint correspondence, not a solve-time heuristic.
            // Five refs encode two point pairs sharing the axis in one relationship.
            let reverse = reversed < direct
            refs = [ConstraintRef(entityID: ids[0], role: .endpointA),
                    ConstraintRef(entityID: ids[1], role: reverse ? .endpointB : .endpointA), axisRef,
                    ConstraintRef(entityID: ids[0], role: .endpointB),
                    ConstraintRef(entityID: ids[1], role: reverse ? .endpointA : .endpointB)]
        default: return
        }
        let constraint = SketchConstraint(kind: .symmetric, refs: refs)
        if commitAppliedConstraints(.symmetric, constraints: [constraint],
                                    operandOrder: ids, axisAnchor: axisID) {
            cancelSymmetryAxisPick()
            selectedSketchEntityIDs.removeAll()
            selectedSketchPoints.removeAll()
            selectedDimensionID = nil
            selectedConstraintID = nil
        }
    }

    /// Full circles support both contact branches. Paired separated and shallow-
    /// overlap arc/circle contact uses the supporting circle, including off-span.
    private var circleTangentOperands: [SketchEntity]? {
        let selected = selectedRadiusEntities
        guard selected.count == 2 else { return nil }
        if case .circle = selected[0], case .circle = selected[1] { return selected }
        guard let arc = selected.first(where: { if case .arc = $0 { return true }; return false }),
              let circle = selected.first(where: { if case .circle = $0 { return true }; return false }),
              case let .arc(_, a, ra, _, _) = arc,
              case let .circle(_, b, rb) = circle else { return nil }
        let delta = b - a
        // Native shallow overlap separates externally; a larger arc with a
        // deeply intersecting or fully nested smaller circle uses internal
        // contact. Coincident centers and exact branch boundaries remain unverified.
        let distance = simd_length(delta)
        let external = distance > max(ra, rb)
        let internalOverlap = ra > rb && distance > ra - rb && distance < ra
        let internalNested = ra > rb && distance > 1e-9 && distance < ra - rb
        let smallerArcOverlap = ra < rb && distance > rb - ra && distance < rb
        let smallerArcNested = ra < rb && distance > 1e-9 && distance < rb - ra
        guard external || internalOverlap || internalNested || smallerArcOverlap || smallerArcNested else { return nil }
        return selected
    }

    func canApplyConstraint(_ kind: SketchConstraintKind) -> Bool {
        guard mode.isSketching, !isPickingSymmetryAxis else { return false }
        // Derived rectangle centers currently support only a local Lock.
        // Do not advertise point relationships the solver cannot yet lower.
        if kind != .fixed, let sketch = activeSketch,
           selectedSketchPoints.contains(where: { point in
               point.role == .center && sketch.entities.contains(where: {
                   if case .rect = $0 { return $0.id == point.entityID }; return false
               })
           }) { return false }
        let points = selectedSketchPoints.count
        let lines = selectedLineEntities.count
        let circles = selectedRadiusEntities.count
        switch kind {
        case .coincident:
            // A point can lie on the infinite extension of a distinct line.
            // Keep two-point and approximate shared-corner behavior unchanged.
            return points >= 2 || pointAndDistinctLineRefs != nil ||
                (lines == 2 && nearestEndpointPair(selectedLineEntities) != nil)
        case .horizontal, .vertical:
            return lines >= 1 || points == 2
        // Spec §3.2: Parallel takes "2+ lines" — parallelism is transitive, so a
        // run of lines chains pairwise. Perpendicular stays strictly 2 (three
        // mutually perpendicular lines are impossible in 2D), and Equal Length
        // keeps its documented pair form.
        case .parallel:
            return lines >= 2
        case .perpendicular, .equalLength:
            return lines == 2
        case .equalRadius, .concentric:
            return circles == 2
        case .tangent:
            return (lines == 1 && circles == 1) || circleTangentOperands != nil
        case .midpoint:
            return points == 1 && lines == 1
        case .symmetric:
            return (points == 2 && lines == 1) || selectedSymmetryEntities.count == 2
        case .fixed:
            return points >= 1 || !selectedSketchEntityIDs.isEmpty
        case .colinear:
            return lines == 2
        }
    }

    /// Points explicitly addressable by the constraint model. Primitive
    /// rectangles expose only their two stored diagonal corners here; this
    /// deliberately does not decompose them into edges or lose dimensions.
    private var disconnectOperands: [ConstraintRef] {
        guard mode.isSketching, mode.sketchTool == nil, let sketch = activeSketch else { return [] }
        if !selectedSketchPoints.isEmpty {
            return selectedSketchPoints.compactMap { point in
                guard let entity = sketch.entities.first(where: { $0.id == point.entityID }),
                      SketchHitTester.modelPoints(of: entity).contains(where: { $0.role == point.role })
                else { return nil }
                return ConstraintRef(entityID: point.entityID, role: point.role)
            }
        }
        return sketch.entities.filter { selectedSketchEntityIDs.contains($0.id) }.flatMap { entity in
            SketchHitTester.modelPoints(of: entity).map {
                ConstraintRef(entityID: entity.id, role: $0.role)
            }
        }
    }

    private func disconnects(_ constraint: SketchConstraint, operands: [ConstraintRef]) -> Bool {
        guard constraint.kind == .coincident || constraint.kind == .midpoint else { return false }
        return constraint.refs.contains { ref in
            operands.contains(ref) || (ref.role == .whole && selectedSketchPoints.isEmpty &&
                                      operands.contains(where: { $0.entityID == ref.entityID }))
        }
    }

    private func isImplicitConnectionEndpoint(_ ref: ConstraintRef, in sketch: Sketch) -> Bool {
        guard ref.role == .endpointA || ref.role == .endpointB,
              let entity = sketch.entities.first(where: { $0.id == ref.entityID }) else { return false }
        switch entity {
        case .line, .rect: return true
        case let .spline(_, points, closed): return !closed && points.count >= 2
        default: return false
        }
    }

    var canDisconnectSketchSelection: Bool {
        guard let sketch = activeSketch else { return false }
        let operands = disconnectOperands
        if sketch.constraints.contains(where: { disconnects($0, operands: operands) }) { return true }
        for ref in operands where isImplicitConnectionEndpoint(ref, in: sketch)
            && !sketch.disconnectedEndpoints.contains(ref) {
            guard let p = localPoint(ref, in: sketch) else { continue }
            for entity in sketch.entities where entity.id != ref.entityID {
                for (role, q) in SketchHitTester.modelPoints(of: entity)
                    where role == .endpointA || role == .endpointB {
                    let other = ConstraintRef(entityID: entity.id, role: role)
                    if !sketch.disconnectedEndpoints.contains(other), simd_distance(p, q) < 1e-6 { return true }
                }
            }
        }
        return false
    }

    func disconnectSketchSelection() {
        guard canDisconnectSketchSelection, let sketch = activeSketch else { return }
        let operands = disconnectOperands
        var endpoints = sketch.disconnectedEndpoints
        for ref in operands where isImplicitConnectionEndpoint(ref, in: sketch)
            && !endpoints.contains(ref) { endpoints.append(ref) }
        session.perform(DisconnectSketchEndpointsCommand(sketchID: sketch.id,
            beforeConstraints: sketch.constraints,
            afterConstraints: sketch.constraints.filter { !disconnects($0, operands: operands) },
            beforeEndpoints: sketch.disconnectedEndpoints, afterEndpoints: endpoints))
        selectedSketchEntityIDs = []
        selectedSketchPoints = []
        selectedAxisRectangleEdge = nil
        selectedConstraintID = nil
        selectedDimensionID = nil
        session.save()
    }

    /// Only explicit locks on the selected operands are removable here. A
    /// rectangle's other side (or an unrelated operand in a multi-ref Lock)
    /// must not be unlocked as a side effect.
    var canUnlockSketchSelection: Bool {
        guard let sketch = activeSketch,
              let refs = constraintRefs(for: .fixed, in: sketch), !refs.isEmpty else { return false }
        return refs.allSatisfy { ref in
            sketch.constraints.contains { $0.kind == .fixed && $0.refs.contains(ref) }
        }
    }

    func toggleSketchSelectionLock() {
        guard canUnlockSketchSelection else { applyConstraint(.fixed); return }
        guard let sketch = activeSketch,
              let refs = constraintRefs(for: .fixed, in: sketch) else { return }
        var commands: [DocumentCommand] = []
        for (index, constraint) in sketch.constraints.enumerated().reversed()
            where constraint.kind == .fixed && constraint.refs.contains(where: refs.contains) {
            commands.append(RemoveSketchConstraintCommand(sketchID: sketch.id,
                constraint: constraint, index: index))
            let remaining = constraint.refs.filter { !refs.contains($0) }
            if !remaining.isEmpty {
                commands.append(AddSketchConstraintCommand(sketchID: sketch.id,
                    constraint: SketchConstraint(id: constraint.id, kind: .fixed, refs: remaining)))
            }
        }
        guard !commands.isEmpty else { return }
        session.perform(CompositeCommand(title: "Unlock", commands: commands))
        session.save()
    }

    /// Apply `kind` to the current selection: build a `SketchConstraint` from
    /// the selected points/entities, append it, re-solve the sketch, and commit
    /// the constraint + any solver-moved geometry in ONE undoable command.
    func applyConstraint(_ kind: SketchConstraintKind) {
        guard canApplyConstraint(kind), let sketch = activeSketch else { return }
        if kind == .symmetric, selectedSymmetryEntities.count == 2 {
            pendingSymmetryEntityIDs = selectedSymmetryEntities
            editingDimension = nil
            selectedDimensionID = nil
            selectedConstraintID = nil
            if case .sketching(let id, _) = mode { mode = .sketching(id, tool: nil) }
            return
        }
        let orderedOperands = selectedSketchEntityOrder.filter { id in
            selectedSketchEntityIDs.contains(id) || selectedSketchPoints.contains { $0.entityID == id }
        }
        _ = commitAppliedConstraints(kind, constraints: constraintsToApply(kind, in: sketch),
                                     operandOrder: orderedOperands)
    }

    private func commitAppliedConstraints(
        _ kind: SketchConstraintKind, constraints newConstraints: [SketchConstraint],
        operandOrder orderedOperands: [UUID], axisAnchor: UUID? = nil
    ) -> Bool {
        guard case .sketching(let sketchID, _) = mode, let sketch = activeSketch,
              !newConstraints.isEmpty else { return false }

        // Solve the sketch with the new constraint in place; the bridge welds
        // coincident points and pulls under-defined geometry to satisfy it.
        var proposed = sketch
        proposed.constraints.append(contentsOf: newConstraints)

        // Over-constraint guard (spec §2.2): if the added constraint makes the
        // system unsatisfiable (conflicting), refuse it — never corrupt the
        // sketch. `.fixed` (Lock) only pins existing positions, so it can never
        // conflict and is exempt.
        if kind != .fixed,
           SketchSolverBridge.residualNorm(proposed) > Self.overConstraintTolerance {
            // Stage 3: name the partners of the clash, not just the fact of it.
            let partners = SketchSolverBridge.conflictPartners(
                in: proposed,
                excludingConstraints: Set(newConstraints.map(\.id)),
                tolerance: Self.overConstraintTolerance)
            errorMessage = Self.conflictRefusalMessage(
                adding: Self.constraintTitle(kind), partners: partners, in: proposed)
            return false
        }

        // Native fixed-circle Tangent keeps the free line's length and far
        // endpoint, rotating its other end toward the circle. These are only
        // application preferences: release endpoint, then length if a saved
        // relationship makes either incompatible. In particular, retry here
        // after an incompatible preferred whole-line anchor is removed.
        func solveWithTangentLinePreferences(_ candidate: Sketch) -> SketchSolverBridge.Outcome {
            if kind == .tangent {
                let ids = Set(newConstraints.flatMap(\.refs).map(\.entityID))
                let circles = sketch.entities.filter { entity in
                    switch entity {
                    case .circle, .arc: return ids.contains(entity.id)
                    default: return false
                    }
                }
                if circles.count == 2 {
                    var preferred = candidate
                    for circle in circles {
                        let radius: Double
                        switch circle {
                        case let .circle(_, _, r), let .arc(_, _, r, _, _): radius = r
                        default: continue
                        }
                        preferred.dimensions.append(.init(kind: .radius,
                            refs: [.init(entityID: circle.id, role: .center)], value: radius))
                    }
                    let result = SketchSolverBridge.solveOutcome(preferred, movingEntity: nil, dragTarget: nil)
                    if result.converged && result.structuralResidual <= Self.overConstraintTolerance { return result }
                    return SketchSolverBridge.solveOutcome(candidate, movingEntity: nil, dragTarget: nil)
                }
            }
            guard kind == .tangent,
                  let lineID = newConstraints.flatMap(\.refs).map(\.entityID).first(where: { id in
                      sketch.entities.contains { entity in
                          if case .line = entity { return entity.id == id }
                          return false
                      }
                  }),
                  case let .line(_, a, b)? = sketch.entities.first(where: { $0.id == lineID }),
                  simd_length(b - a) > 1e-9 else {
                return SketchSolverBridge.solveOutcome(candidate, movingEntity: nil, dragTarget: nil)
            }
            var lengthPreferred = candidate
            lengthPreferred.dimensions.append(SketchDimension(kind: .distance, refs: [
                .init(entityID: lineID, role: .endpointA), .init(entityID: lineID, role: .endpointB)
            ], value: simd_length(b - a)))
            var endpointPreferred = lengthPreferred
            endpointPreferred.constraints.append(.init(kind: .fixed,
                refs: [.init(entityID: lineID, role: .endpointB)]))
            for preferred in [endpointPreferred, lengthPreferred] {
                let outcome = SketchSolverBridge.solveOutcome(preferred, movingEntity: nil, dragTarget: nil)
                if outcome.converged && outcome.structuralResidual <= Self.overConstraintTolerance {
                    return outcome
                }
            }
            return SketchSolverBridge.solveOutcome(candidate, movingEntity: nil, dragTarget: nil)
        }

        // Paired point-first / line-second Midpoint is not a whole-entity
        // anchor. First Selected translates the source to the existing target
        // midpoint; Last Selected preserves the source direction and target's
        // far end, extending the near end about their intersection. These are
        // placement preferences, projected against the ORIGINAL saved system
        // so Locks, dimensions and connections always remain authoritative.
        let midpointPlacement: [SketchEntity]? = {
            guard kind == .midpoint, newConstraints.count == 1,
                  newConstraints[0].refs.count == 2 else { return nil }
            let point = newConstraints[0].refs[0]
            let targetRef = newConstraints[0].refs[1]
            guard point.role == .endpointA || point.role == .endpointB,
                  targetRef.role == .whole,
                  orderedOperands == [point.entityID, targetRef.entityID],
                  case let .line(sourceID, sa, sb)? = sketch.entities.first(where: { $0.id == point.entityID }),
                  case let .line(targetID, ta, tb)? = sketch.entities.first(where: { $0.id == targetRef.entityID })
            else { return nil }
            let selected = point.role == .endpointA ? sa : sb
            let sourceDirection = sb - sa
            let targetDirection = tb - ta
            guard simd_length(sourceDirection) > 1e-9,
                  simd_length(targetDirection) > 1e-9 else { return nil }
            let targets: [SketchEntity]
            if CADPreferences.shared.anchoredSketchEntity == .firstSelected {
                let delta = (ta + tb) / 2 - selected
                targets = [.line(id: sourceID, a: sa + delta, b: sb + delta),
                           .line(id: targetID, a: ta, b: tb)]
            } else {
                let determinant = sourceDirection.x * targetDirection.y - sourceDirection.y * targetDirection.x
                guard abs(determinant) > 1e-9 * simd_length(sourceDirection) * simd_length(targetDirection)
                else { return nil } // Parallel/degenerate variants are not paired.
                let offset = ta - selected
                let t = (offset.x * targetDirection.y - offset.y * targetDirection.x) / determinant
                let contact = selected + t * sourceDirection
                let nearA = simd_distance(selected, ta) <= simd_distance(selected, tb)
                targets = [.line(id: sourceID, a: point.role == .endpointA ? contact : sa,
                                 b: point.role == .endpointB ? contact : sb),
                           .line(id: targetID, a: nearA ? 2 * contact - tb : ta,
                                 b: nearA ? tb : 2 * contact - ta)]
            }
            return SketchSolverBridge.solvePointTransform(proposed, targets: targets)
        }()

        // Paired single-line H/V rotates about its first endpoint without
        // shortening the line. Project this placement against the original saved
        // system: existing Locks/drivers override preferences, never get replaced.
        let axisAlignmentPlacement: [SketchEntity]? = {
            guard kind == .horizontal || kind == .vertical, newConstraints.count == 1,
                  newConstraints[0].refs.count == 1,
                  let ref = newConstraints[0].refs.first, ref.role == .whole,
                  case let .line(id, a, b)? = sketch.entities.first(where: { $0.id == ref.entityID }),
                  simd_length(b - a) > 1e-9 else { return nil }
            let length = simd_length(b - a)
            let offset = kind == .horizontal
                ? SIMD2<Double>(b.x < a.x ? -length : length, 0)
                : SIMD2<Double>(0, b.y < a.y ? -length : length)
            let end = a + offset
            return SketchSolverBridge.solvePointTransform(proposed,
                targets: [.line(id: id, a: a, b: end)])
        }()

        // Paired First/Last Selected two-line Parallel rotates the unanchored
        // operand about endpoint A, preserving its length and the chosen anchor.
        // Project against saved relationships rather than persisting preferences.
        let parallelPlacement: [SketchEntity]? = {
            guard kind == .parallel, newConstraints.count == 1,
                  orderedOperands.count == 2 else { return nil }
            var anchorIndex = CADPreferences.shared.anchoredSketchEntity == .firstSelected ? 0 : 1
            func isWholeLocked(_ index: Int) -> Bool {
                sketch.constraints.contains { constraint in
                    constraint.kind == .fixed && constraint.refs.contains {
                        $0.entityID == orderedOperands[index] && $0.role == .whole
                    }
                }
            }
            // A saved whole-line Lock outranks First/Last selection. Seed the
            // other line's length-preserving rotation around that actual anchor;
            // projecting the locked line toward the free one would shorten it.
            if !isWholeLocked(anchorIndex), isWholeLocked(1 - anchorIndex) {
                anchorIndex = 1 - anchorIndex
            }
            let movingIndex = 1 - anchorIndex
            guard case let .line(id, a, b)? = sketch.entities.first(where: { $0.id == orderedOperands[movingIndex] }),
                  case let .line(anchorID, anchorA, anchorB)? = sketch.entities.first(where: { $0.id == orderedOperands[anchorIndex] }),
                  simd_length(b - a) > 1e-9, simd_length(anchorB - anchorA) > 1e-9
            else { return nil }
            var direction = simd_normalize(anchorB - anchorA)
            if simd_dot(direction, b - a) < 0 { direction = -direction }
            return SketchSolverBridge.solvePointTransform(proposed, targets: [
                .line(id: id, a: a, b: a + direction * simd_length(b - a)),
                .line(id: anchorID, a: anchorA, b: anchorB)
            ], preservingLineID: anchorID)
        }()

        // For the paired nonparallel free-line case, native Perpendicular
        // rotates about the intersection of the supporting lines, not the
        // moving segment's midpoint. Saved constraints remain authoritative.
        let perpendicularPlacement: [SketchEntity]? = {
            guard kind == .perpendicular, newConstraints.count == 1,
                  orderedOperands.count == 2,
                  CADPreferences.shared.anchoredSketchEntity == .lastSelected,
                  case let .line(id, a, b)? = sketch.entities.first(where: { $0.id == orderedOperands[0] }),
                  case let .line(anchorID, c, d)? = sketch.entities.first(where: { $0.id == orderedOperands[1] })
            else { return nil }
            let moving = b - a, fixed = d - c
            let movingLength = simd_length(moving), fixedLength = simd_length(fixed)
            guard movingLength > 1e-9, fixedLength > 1e-9 else { return nil }
            let determinant = moving.x * fixed.y - moving.y * fixed.x
            guard abs(determinant) > 1e-9 * movingLength * fixedLength else { return nil }
            let offset = c - a
            let pivot = a + moving * ((offset.x * fixed.y - offset.y * fixed.x) / determinant)
            let originalDirection = moving / movingLength
            var targetDirection = SIMD2<Double>(fixed.y, -fixed.x) / fixedLength
            if simd_dot(originalDirection, targetDirection) < 0 { targetDirection = -targetDirection }
            let cosine = simd_dot(originalDirection, targetDirection)
            let sine = originalDirection.x * targetDirection.y - originalDirection.y * targetDirection.x
            func rotate(_ point: SIMD2<Double>) -> SIMD2<Double> {
                let v = point - pivot
                return pivot + SIMD2(cosine * v.x - sine * v.y, sine * v.x + cosine * v.y)
            }
            return SketchSolverBridge.solvePointTransform(proposed, targets: [
                .line(id: id, a: rotate(a), b: rotate(b)), .line(id: anchorID, a: c, b: d)
            ], preservingLineID: anchorID)
        }()

        let preferredAnchor = CADPreferences.shared.anchoredSketchEntity == .firstSelected
            ? orderedOperands.first : orderedOperands.last
        // A point-to-point weld averages its input positions before temporary
        // Locks are applied. For the paired shape-to-free-line recipe, seed the
        // free endpoint at the selected shape point first; otherwise the Lock
        // freezes an already-moved circle/rectangle. Do not bypass any saved
        // relationship or dimension on the line, or alter general welding.
        let shapePointPlacement: [SketchEntity]? = {
            guard kind == .coincident, newConstraints.count == 1,
                  let preferredAnchor,
                  let shape = sketch.entities.first(where: { $0.id == preferredAnchor }),
                  { switch shape { case .circle, .rect: return true; default: return false } }(),
                  let shapeRef = newConstraints[0].refs.first(where: { $0.entityID == preferredAnchor }),
                  let anchorPoint = localPoint(shapeRef, in: sketch),
                  let movingRef = newConstraints[0].refs.first(where: { $0.entityID != preferredAnchor }),
                  movingRef.role == .endpointA || movingRef.role == .endpointB,
                  let index = sketch.entities.firstIndex(where: { $0.id == movingRef.entityID }),
                  case let .line(id, a, b) = sketch.entities[index],
                  !sketch.constraints.contains(where: { $0.refs.contains { $0.entityID == id } }),
                  !sketch.dimensions.contains(where: { $0.refs.contains { $0.entityID == id } })
            else { return nil }
            var seeded = proposed
            seeded.entities[index] = .line(id: id,
                a: movingRef.role == .endpointA ? anchorPoint : a,
                b: movingRef.role == .endpointB ? anchorPoint : b)
            seeded.constraints.append(.init(kind: .fixed,
                refs: [.init(entityID: preferredAnchor, role: .whole)]))
            let result = SketchSolverBridge.solveOutcome(seeded, movingEntity: nil, dragTarget: nil)
            guard result.converged, result.structuralResidual <= Self.overConstraintTolerance else { return nil }
            return result.entities
        }()
        var solvedEntities: [SketchEntity]
        if let shapePointPlacement {
            solvedEntities = shapePointPlacement
        } else if let perpendicularPlacement {
            solvedEntities = perpendicularPlacement
        } else if let parallelPlacement {
            solvedEntities = parallelPlacement
        } else if let axisAlignmentPlacement {
            solvedEntities = axisAlignmentPlacement
        } else if let midpointPlacement {
            solvedEntities = midpointPlacement
        } else if kind != .fixed, let preferredAnchor {
            var anchored = proposed
            anchored.constraints.append(.init(kind: .fixed,
                refs: [.init(entityID: preferredAnchor, role: .whole)]))
            if let axisAnchor {
                anchored.constraints.append(.init(kind: .fixed,
                    refs: [.init(entityID: axisAnchor, role: .whole)]))
            }
            // Equal changes size, not a free line's direction. The preferred
            // operand is already fixed; preserve the other line's direction
            // transiently, just as for a numeric length edit. Never save an
            // angle constraint, and let existing relationships override this.
            let directionID = kind == .equalLength ? orderedOperands.first { id in
                id != preferredAnchor && sketch.entities.contains {
                    if case .line = $0 { return $0.id == id }
                    return false
                }
            } : nil
            // Native Perpendicular rotates a free line without resizing it.
            // This is a solve preference only, never a persisted dimension;
            // existing point/geometry constraints still take precedence.
            let anchoredWithoutLengthPreference = anchored
            if kind == .perpendicular {
                for id in orderedOperands where id != preferredAnchor {
                    guard let entity = sketch.entities.first(where: { $0.id == id }),
                          case let .line(_, a, b) = entity,
                          simd_length(b - a) > 1e-9 else { continue }
                    anchored.dimensions.append(SketchDimension(kind: .distance, refs: [
                        .init(entityID: id, role: .endpointA),
                        .init(entityID: id, role: .endpointB)
                    ], value: simd_length(b - a)))
                }
            }
            let tangentCircle: (circle: UUID, line: UUID)? = {
                guard kind == .tangent,
                      sketch.entities.contains(where: { entity in
                          if case .line = entity { return entity.id == preferredAnchor }
                          return false
                      }),
                      let circle = orderedOperands.first(where: { id in
                          sketch.entities.contains { entity in
                              if case .circle = entity { return entity.id == id }
                              return false
                          }
                      }) else { return nil }
                return (circle, preferredAnchor)
            }()
            var outcome = kind == .tangent && tangentCircle == nil
                ? solveWithTangentLinePreferences(anchored)
                : SketchSolverBridge.solveOutcome(
                    anchored, movingEntity: nil, dragTarget: nil,
                    preservingLineDirection: directionID, preservingTangentCircle: tangentCircle)
            if directionID != nil || tangentCircle != nil || anchored.dimensions.count != anchoredWithoutLengthPreference.dimensions.count,
               !outcome.converged || outcome.structuralResidual > Self.overConstraintTolerance {
                outcome = SketchSolverBridge.solveOutcome(
                    anchoredWithoutLengthPreference, movingEntity: nil, dragTarget: nil)
            }
            if outcome.converged && outcome.structuralResidual <= Self.overConstraintTolerance {
                solvedEntities = outcome.entities
            } else {
                // A saved relationship is stronger than this transient
                // preference. Retry without the temporary anchor.
                solvedEntities = solveWithTangentLinePreferences(proposed).entities
            }
        } else {
            solvedEntities = solveWithTangentLinePreferences(proposed).entities
        }

        var commands: [DocumentCommand] = newConstraints.map {
            AddSketchConstraintCommand(sketchID: sketchID, constraint: $0)
        }
        for (before, after) in zip(sketch.entities, solvedEntities) where before != after {
            commands.append(UpdateSketchEntityCommand(
                sketchID: sketchID, before: before, after: after
            ))
        }
        let title = Self.constraintTitle(kind)
        // Phase D: a constraint can re-solve entity positions — the
        // dependent-feature rebuild lands in the SAME undo step (S6).
        session.performWithSketchRebuild(commands.count == 1
            ? commands[0]
            : CompositeCommand(title: title, commands: commands), sketchID: sketchID)
        session.save()
        // Paired Perpendicular, Midpoint, Tangent and point-on-line Coincident clear
        // operands/readouts. Keep this scoped to observed forms; refusal returns
        // earlier and must retain the user's selection.
        if newConstraints.contains(where: clearsSelectionAfterApplying) { clearAppliedRelationSelection() }
        return true
    }

    /// Human name of a dimension, value included ("Distance 120.00 mm") —
    /// the items panel row and the stage-3 refusal message share it.
    nonisolated static func dimensionTitle(_ d: SketchDimension) -> String {
        switch d.kind {
        case .distance: "Distance " + String(format: "%.2f mm", d.value)
        case .radius: "Radius " + String(format: "%.2f mm", d.value)
        case .diameter: "Diameter " + String(format: "%.2f mm", d.value)
        case .angle: "Angle " + String(format: "%.1f°", d.value * 180 / .pi)
        case .horizontal: "Width " + String(format: "%.2f mm", d.value)
        case .vertical: "Height " + String(format: "%.2f mm", d.value)
        }
    }

    /// Stage-3 refusal message: name the partners of the clash the refused
    /// add would create, in document order ("Vertical conflicts with
    /// Horizontal, Distance 100.00 mm — not added."). Falls back to the
    /// generic wording when diagnosis produced no partners.
    nonisolated static func conflictRefusalMessage(
        adding title: String,
        partners: SketchSolverBridge.ConflictAttribution,
        in sketch: Sketch
    ) -> String {
        var names: [String] = []
        for c in sketch.constraints where partners.constraintIDs.contains(c.id) {
            names.append(constraintTitle(c.kind))
        }
        for d in sketch.dimensions where partners.dimensionIDs.contains(d.id) {
            names.append(dimensionTitle(d))
        }
        guard !names.isEmpty else {
            return "\(title) conflicts with the existing constraints — not added."
        }
        return "\(title) conflicts with \(names.joined(separator: ", ")) — not added."
    }

    nonisolated static func constraintTitle(_ kind: SketchConstraintKind) -> String {
        switch kind {
        case .coincident: "Coincident"
        case .horizontal: "Horizontal"
        case .vertical: "Vertical"
        case .parallel: "Parallel"
        case .perpendicular: "Perpendicular"
        case .equalLength: "Equal Length"
        case .equalRadius: "Equal Radius"
        case .concentric: "Concentric"
        case .midpoint: "Midpoint"
        case .symmetric: "Symmetric"
        case .tangent: "Tangent"
        case .colinear: "Colinear"
        case .fixed: "Lock"
        }
    }

    /// The constraint(s) the current selection produces. Every kind yields
    /// exactly one, EXCEPT Parallel with more than two lines (spec §3.2 allows
    /// "2+"): those chain pairwise — line0∥line1, line1∥line2, … — which is
    /// equivalent to all-parallel because parallelism is transitive, and keeps
    /// each stored constraint in the two-operand form the solver expects.
    private func constraintsToApply(
        _ kind: SketchConstraintKind, in sketch: Sketch
    ) -> [SketchConstraint] {
        if kind == .parallel {
            let lines = selectedLineEntities
            if lines.count > 2 {
                return (0..<(lines.count - 1)).map { i in
                    SketchConstraint(kind: .parallel, refs: [
                        ConstraintRef(entityID: lines[i].id, role: .whole),
                        ConstraintRef(entityID: lines[i + 1].id, role: .whole),
                    ])
                }
            }
        }
        guard let refs = constraintRefs(for: kind, in: sketch) else { return [] }
        var constraint = SketchConstraint(kind: kind, refs: refs)
        if kind == .tangent, let pair = circleTangentOperands,
           case let .circle(_, a, ra) = pair[0], case let .circle(_, b, rb) = pair[1] {
            // The midpoint between radius difference and sum is the larger radius.
            // Native deep overlap chooses internal contact; shallow overlap external.
            constraint.circleTangency = simd_length(b - a) < max(ra, rb)
                ? .internalContact : .externalContact
        } else if kind == .tangent, let pair = circleTangentOperands,
                  let arc = pair.first(where: { if case .arc = $0 { return true }; return false }),
                  let circle = pair.first(where: { if case .circle = $0 { return true }; return false }),
                  case let .arc(_, a, ra, _, _) = arc,
                  case let .circle(_, b, rb) = circle {
            constraint.circleTangency = simd_length(b - a) < max(ra, rb)
                ? .internalContact : .externalContact
        }
        return [constraint]
    }

    private var pointAndDistinctLineRefs: [ConstraintRef]? {
        guard selectedSketchPoints.count == 1, let point = selectedSketchPoints.first,
              selectedLineEntities.count == 1, let line = selectedLineEntities.first,
              point.entityID != line.id else { return nil }
        return [.init(entityID: point.entityID, role: point.role),
                .init(entityID: line.id, role: .whole)]
    }

    /// Map the selection to the ref layout each constraint kind expects
    /// (documented in `SketchSolverBridge`). Returns nil when the selection
    /// does not form the operands for `kind`.
    private func constraintRefs(
        for kind: SketchConstraintKind, in sketch: Sketch
    ) -> [ConstraintRef]? {
        let pts = Array(selectedSketchPoints)
        let lines = selectedLineEntities
        let circles = selectedRadiusEntities
        func ref(_ p: SketchPointSelection) -> ConstraintRef {
            ConstraintRef(entityID: p.entityID, role: p.role)
        }
        func whole(_ e: SketchEntity) -> ConstraintRef {
            ConstraintRef(entityID: e.id, role: .whole)
        }
        switch kind {
        case .coincident:
            if pts.count >= 2 { return [ref(pts[0]), ref(pts[1])] }
            if let refs = pointAndDistinctLineRefs { return refs }
            return nearestEndpointPair(lines)
        case .horizontal, .vertical:
            if let line = lines.first { return [whole(line)] }
            if pts.count == 2 { return [ref(pts[0]), ref(pts[1])] }
            return nil
        case .parallel, .perpendicular, .equalLength, .colinear:
            guard lines.count == 2 else { return nil }
            return [whole(lines[0]), whole(lines[1])]
        case .equalRadius, .concentric:
            guard circles.count == 2 else { return nil }
            return [
                ConstraintRef(entityID: circles[0].id, role: .center),
                ConstraintRef(entityID: circles[1].id, role: .center),
            ]
        case .tangent:
            if let pair = circleTangentOperands { return pair.map(whole) }
            guard let line = lines.first, let circle = circles.first else { return nil }
            return [whole(line), whole(circle)]
        case .midpoint:
            guard pts.count == 1, let line = lines.first else { return nil }
            return [ref(pts[0]), whole(line)]
        case .symmetric:
            guard pts.count == 2, let line = lines.first else { return nil }
            return [ref(pts[0]), ref(pts[1]), whole(line)]
        case .fixed:
            var refs = pts.map(ref)
            let pointed = Set(pts.map(\.entityID))
            for e in selectedSketchEntities where !pointed.contains(e.id) {
                if let edge = selectedAxisRectangleEdge, edge.id == e.id,
                   selectedSketchEntityIDs == [e.id] {
                    refs.append(ConstraintRef(entityID: e.id, role: .whole, rectangleEdge: edge.index))
                } else {
                    refs.append(whole(e))
                }
            }
            return refs.isEmpty ? nil : refs
        }
    }

    /// The closest endpoint pair between two lines, as coincident refs — lets
    /// Coincident weld a shared corner when whole lines are selected.
    private func nearestEndpointPair(_ lines: [SketchEntity]) -> [ConstraintRef]? {
        guard lines.count == 2,
              case let .line(id0, a0, b0) = lines[0],
              case let .line(id1, a1, b1) = lines[1]
        else { return nil }
        let candidates: [(PointRole, PointRole, Double)] = [
            (.endpointA, .endpointA, simd_distance(a0, a1)),
            (.endpointA, .endpointB, simd_distance(a0, b1)),
            (.endpointB, .endpointA, simd_distance(b0, a1)),
            (.endpointB, .endpointB, simd_distance(b0, b1)),
        ]
        guard let best = candidates.min(by: { $0.2 < $1.2 }) else { return nil }
        return [
            ConstraintRef(entityID: id0, role: best.0),
            ConstraintRef(entityID: id1, role: best.1),
        ]
    }

    // MARK: - Constraint glyphs + delete (plan §C3)

    /// A constraint's on-canvas glyph: a short code badge at the relationship's
    /// location. World-space anchor so the overlay reprojects each camera move;
    /// `slot` fans out glyphs that share an anchor so each stays tappable.
    struct SketchConstraintGlyph: Identifiable {
        let id: UUID           // the constraint's id
        /// The sketch this glyph belongs to (see `SketchDimensionLabel`).
        let sketchID: SketchID
        let kind: SketchConstraintKind
        let code: String
        let worldAnchor: SIMD3<Double>
        let slot: Int
        var isRectangleCenterLock = false
        var isCircleCenterConnection = false
    }

    /// Compact badge text per constraint kind.
    static func constraintCode(_ kind: SketchConstraintKind) -> String {
        switch kind {
        case .coincident: "⌖"
        case .horizontal: "H"
        case .vertical: "V"
        case .parallel: "∥"
        case .perpendicular: "⊥"
        case .equalLength: "="
        case .equalRadius: "=R"
        case .concentric: "◎"
        case .midpoint: "M"
        case .symmetric: "⧓"
        case .tangent: "T"
        case .colinear: "L"
        case .fixed: "🔒"
        }
    }

    /// Local-plane anchor of a constraint: the average of its operands' points
    /// (whole-line operands contribute their midpoint via `localPoint`).
    private func constraintAnchorLocal(_ c: SketchConstraint, in sketch: Sketch) -> SIMD2<Double>? {
        var sum = SIMD2<Double>(0, 0)
        var n = 0
        for ref in c.refs {
            if let p = localPoint(ref, in: sketch) { sum += p; n += 1 }
        }
        guard n > 0 else { return nil }
        return sum / Double(n)
    }

    /// Constraint glyphs to render in the sketch overlay.
    var sketchConstraintGlyphs: [SketchConstraintGlyph] {
        _ = session.changeCount
        var out: [SketchConstraintGlyph] = []
        var slotAt: [String: Int] = [:] // stack glyphs sharing an anchor
        for sketch in annotatedSketches(alwaysShow: CADPreferences.shared.alwaysShowConstraints) {
            let migratedEdges = migratedRectangleEdgeIDs(in: sketch)
            for c in sketch.constraints {
                // Native migrated rectangle corner Locks read through hollow
                // green corners and contextual Unlock, not an overlaid badge.
                // Explicit Items selection/conflict diagnosis remain accessible.
                if c.kind == .fixed, c.refs.count == 1,
                   migratedEdges.contains(c.refs[0].entityID),
                   c.refs[0].role == .endpointA || c.refs[0].role == .endpointB,
                   selectedConstraintID != c.id,
                   !sketchConflictAttribution.constraintIDs.contains(c.id) { continue }
                // Rotation preserves the primitive's structural rules in the
                // solver, without exposing a new cluster of implicit badges.
                // Items selection and conflict diagnosis still expose a rule.
                if selectedConstraintID != c.id,
                   !sketchConflictAttribution.constraintIDs.contains(c.id),
                   RectangleConstruction.isStructuralRelation(c, in: sketch) { continue }
                // Native axis-rectangle side Locks read through their green
                // corners/edges and contextual Unlock, not a midpoint badge.
                if c.kind == .fixed, c.refs.count == 1,
                   let edge = c.refs[0].rectangleEdge, (0..<4).contains(edge),
                   sketch.entities.contains(where: {
                       if case .rect = $0 { return $0.id == c.refs[0].entityID }
                       return false
                   }) { continue }
                guard annotationIsVisible(refs: c.refs,
                    alwaysShow: CADPreferences.shared.alwaysShowConstraints,
                    explicitlySelected: selectedConstraintID == c.id) else { continue }
                guard let local = constraintAnchorLocal(c, in: sketch) else { continue }
                // Key by sketch too: two sketches on different planes can share
                // plane-local coordinates without their glyphs overlapping.
                let key = "\(sketch.id)-\((local.x * 100).rounded())-\((local.y * 100).rounded())"
                let slot = slotAt[key, default: 0]
                slotAt[key] = slot + 1
                out.append(SketchConstraintGlyph(
                    id: c.id, sketchID: sketch.id, kind: c.kind,
                    code: Self.constraintCode(c.kind),
                    worldAnchor: sketch.plane.toWorld(local), slot: slot,
                    isRectangleCenterLock: c.kind == .fixed && c.refs.count == 1 &&
                        c.refs[0].role == .center && sketch.entities.contains(where: {
                            switch $0 {
                            case .rect, .circle: return $0.id == c.refs[0].entityID
                            default: return false
                            }
                        }) || (c.kind == .fixed && c.refs.count == 1 && c.refs[0].role == .center &&
                               RectangleConstruction.centerDiagonalReferences(c.refs[0].entityID, in: sketch) != nil),
                    isCircleCenterConnection: c.kind == .coincident && c.refs.count == 2 &&
                        c.refs.allSatisfy { ref in
                            ref.role == .center && sketch.entities.contains {
                                if case .circle = $0 { return $0.id == ref.entityID }
                                return false
                            }
                        }
                ))
            }
        }
        return out
    }

    /// True when a constraint or dimension glyph is selected (enables Delete).
    var hasSketchGlyphSelection: Bool {
        selectedConstraintID != nil || selectedDimensionID != nil
    }

    /// Tap-select a constraint glyph (clears geometry + dimension selection).
    /// As with `beginDimensionEdit`, a glyph from another sketch opens that
    /// sketch first — `deleteConstraint` only acts on the active one.
    func selectConstraint(_ id: UUID, in sketchID: SketchID? = nil) {
        if let sketchID, activeSketch?.id != sketchID {
            openItemSketch(sketchID)
            guard activeSketch?.id == sketchID else { return }
        }
        editingDimension = nil
        selectedConstraintID = (selectedConstraintID == id) ? nil : id
        selectedDimensionID = nil
        selectedSketchEntityIDs.removeAll()
        selectedSketchPoints.removeAll()
    }

    /// Select a dimension (from the Items panel) for delete.
    func selectDimension(_ id: UUID) {
        editingDimension = nil
        selectedDimensionID = (selectedDimensionID == id) ? nil : id
        selectedConstraintID = nil
        selectedSketchEntityIDs.removeAll()
        selectedSketchPoints.removeAll()
    }

    /// Remove a constraint (undoable) and re-solve the relaxed sketch so any
    /// geometry it was holding settles.
    func deleteConstraint(_ id: UUID) {
        guard case .sketching(let sketchID, _) = mode,
              let sketch = activeSketch,
              let index = sketch.constraints.firstIndex(where: { $0.id == id }) else { return }
        let constraint = sketch.constraints[index]
        if selectedConstraintID == id { selectedConstraintID = nil }
        session.perform(RemoveSketchConstraintCommand(
            sketchID: sketchID, constraint: constraint, index: index
        ))
        session.save()
    }

    /// Delete the currently selected constraint glyph (contract D): palette /
    /// keyboard Delete route here. `deleteConstraint` clears the selection and
    /// re-solves the relaxed sketch.
    func deleteSelectedConstraint() {
        guard let id = selectedConstraintID else { return }
        deleteConstraint(id)
    }

    // MARK: - Sketch mirror (plan §B, contract D)

    /// The single selected `.line` that can serve as a mirror axis plus the
    /// other selected entities to reflect across it, or nil when the selection
    /// has no unambiguous axis (zero or ≥2 lines) or nothing to mirror.
    private var sketchMirrorAxisAndSources: (axis: UUID, sources: [UUID])? {
        guard mode.isSketching, let sketch = activeSketch else { return nil }
        let selected = sketch.entities.filter { selectedSketchEntityIDs.contains($0.id) }
        let lines = selected.filter { if case .line = $0 { return true } else { return false } }
        guard lines.count == 1 else { return nil } // need exactly one axis line
        let axis = lines[0].id
        let sources = selected.map(\.id).filter { $0 != axis }
        guard !sources.isEmpty else { return nil }  // need something to mirror
        return (axis, sources)
    }

    /// True when the sketch selection has a single line axis and ≥1 other
    /// entity to mirror across it (contract D).
    var canMirrorSketchSelection: Bool { sketchMirrorAxisAndSources != nil }

    /// Mirror the selected entities across the single selected line, linking
    /// each original point to its mirror with a `.symmetric` constraint
    /// (contract D). One undoable `MirrorSketchEntitiesCommand`.
    func mirrorSketchSelection() {
        guard case .sketching(let sketchID, _) = mode,
              let sketch = activeSketch,
              let sel = sketchMirrorAxisAndSources,
              let command = MirrorSketchEntitiesCommand(
                  sketchID: sketchID, sourceEntityIDs: sel.sources,
                  axisEntityID: sel.axis, sketch: sketch
              )
        else { return }
        session.perform(command)
        session.save()
    }

    /// Remove a dimension (undoable).
    func deleteDimension(_ id: UUID) {
        guard case .sketching(let sketchID, _) = mode,
              let sketch = activeSketch,
              let index = sketch.dimensions.firstIndex(where: { $0.id == id }) else { return }
        let dimension = sketch.dimensions[index]
        if selectedDimensionID == id { selectedDimensionID = nil }
        session.perform(RemoveSketchDimensionCommand(
            sketchID: sketchID, dimension: dimension, index: index
        ))
        session.save()
    }

    /// Items-panel rows for the active sketch's constraints.
    var activeSketchConstraintRows: [(id: UUID, code: String, title: String)] {
        _ = session.changeCount
        guard let sketch = activeSketch else { return [] }
        return sketch.constraints.map {
            (id: $0.id, code: Self.constraintCode($0.kind), title: Self.constraintTitle($0.kind))
        }
    }

    /// Items-panel rows for the active sketch's dimensions.
    var activeSketchDimensionRows: [(id: UUID, code: String, title: String)] {
        _ = session.changeCount
        guard let sketch = activeSketch else { return [] }
        return sketch.dimensions.map { d in
            let title = Self.dimensionTitle(d)
            let code: String
            switch d.kind {
            case .distance: code = "↔"
            case .radius: code = "R"
            case .diameter: code = "⌀"
            case .angle: code = "∠"
            case .horizontal: code = "↔"
            case .vertical: code = "↕"
            }
            return (id: d.id, code: code, title: title)
        }
    }

    // MARK: - Sketch dimensions (plan §C2, spec §2.2)

    /// A dimension label to draw in the sketch overlay: a driving dimension, or
    /// the live candidate for the current selection (`dimensionID == nil`).
    /// Positions are WORLD-space so the overlay reprojects them each camera move.
    private var temporaryDiameterLabelOffsets: [UUID: SIMD2<Double>] = [:]

    /// Native free readout placement lasts for the selection; driving dimension
    /// placement is a separate undoable, saved presentation edit. Paired
    /// 2026-09-13 for linear labels too: a measured line's dragged label
    /// returns to its default on reselect, a driving one keeps the drag and
    /// Undo reverts it.
    func moveDimensionLabel(_ label: SketchDimensionLabel, offset: SIMD2<Double>) {
        guard label.kind == .diameter || label.isStandaloneLineLength || label.isRectangleSize,
              offset.x.isFinite, offset.y.isFinite,
              let entityID = label.refs.first?.entityID,
              let sketch = session.document.sketches.first(where: { $0.id == label.sketchID })
        else { return }
        if let dimensionID = label.dimensionID,
           let before = sketch.dimensions.first(where: { $0.id == dimensionID }) {
            var after = before
            after.labelOffset = offset
            guard before != after else { return }
            session.perform(UpdateSketchDimensionCommand(sketchID: sketch.id, before: before, after: after))
        } else {
            temporaryDiameterLabelOffsets[entityID] = offset
        }
    }

    struct SketchDimensionLabel: Identifiable {
        let id: String
        /// The sketch this label annotates. Outside sketch mode the overlay
        /// uses it to open the right sketch before editing.
        let sketchID: SketchID
        let dimensionID: UUID?
        let kind: DimensionKind
        let refs: [ConstraintRef]
        /// Display value (degrees for `.angle`, sketch units otherwise).
        let displayValue: Double
        let text: String
        let worldAnchor: SIMD3<Double>
        let worldStart: SIMD3<Double>
        let worldEnd: SIMD3<Double>
        // Arc sweep annotations follow the actual sweep, including major arcs.
        // World points keep the leader aligned when the camera/plane changes.
        var worldDiameterLabelAnchor: SIMD3<Double>? = nil
        /// Where a dragged linear label's text sits (nil = the default leader).
        var worldLinearLabelAnchor: SIMD3<Double>? = nil
        var isPolygonSideCount = false
        var hasExpression = false
        var isStandaloneLineLength = false
        var isProjectedLineLength = false
        var worldLineStart: SIMD3<Double>? = nil
        var worldLineEnd: SIMD3<Double>? = nil
        var isRectangleSize = false
        var axisRectangleEdge: Int? = nil
        var worldRectangleCenter: SIMD3<Double>? = nil
        var isArcRadius = false
        var isCircleRadius = false
        var hasCircleRadiusDirection = false
        var worldArcCenter: SIMD3<Double>? = nil
        var worldArcPoints: [SIMD3<Double>] = []
    }

    /// In-flight inline edit of a dimension field (the candidate or an existing
    /// dimension). Non-nil while the numeric field is open in the overlay.
    struct DimensionEdit: Equatable {
        var sessionID = UUID()
        var labelID: String
        var dimensionID: UUID?
        var kind: DimensionKind
        var refs: [ConstraintRef]
        var text: String
        // Exact measured mm (degrees for angles), separate from rounded UI text.
        // Retained expressions are evaluated instead and never use this seed.
        var measuredSeed: Double? = nil
        var validationMessage: String? = nil
        var isPolygonSideCount = false
        var axisRectangleEdge: Int? = nil
        var isPendingRectangleBaseline = false
        var hardwareInitiated = false
    }
    // Input-mode preference survives individual dimension edit sessions.
    var dimensionUsesSystemKeyboard = CADPreferences.prefersSystemKeyboard
    var editingDimension: DimensionEdit?

    // The field keeps its own SwiftUI text state. Mirror drafts without
    // observable writes on the TextField binding/render path (which previously
    // caused a render loop). Session identity prevents stale drafts being used
    // for a different badge or a reopened editor.
    @ObservationIgnored private var dimensionDraft: (sessionID: UUID, text: String, changed: Bool)?

    func updateDimensionDraft(_ text: String, sessionID: UUID) {
        guard let edit = editingDimension, edit.sessionID == sessionID else { return }
        let changed = text != edit.text ||
            (dimensionDraft?.sessionID == sessionID && dimensionDraft?.changed == true)
        dimensionDraft = (sessionID, text, changed)
        if editingDimension?.validationMessage != nil {
            editingDimension?.validationMessage = nil
        }
    }

    private func finishDimensionEditOnClickAway() {
        guard let edit = editingDimension else { return }
        let text = dimensionDraft?.sessionID == edit.sessionID
            ? dimensionDraft!.text : edit.text
        // Merely inspecting a badge must not create an extra history step.
        guard text != edit.text else {
            cancelDimensionEdit()
            return
        }
        commitDimensionEdit(text)
        if editingDimension?.validationMessage != nil {
            cancelDimensionEdit()
            showNotice("Invalid expression.")
        }
    }

    /// Numeric commits normally leave a driving dimension. The unlocked solve
    /// path remains available to callers, but the keypad lock key independently
    /// adds/removes the unchanged measured dimension through toggleDimensionLock.
    var dimensionCommitLocked = true

    /// Radius of a circular entity (circle/arc/polygon); nil otherwise.
    private static func entityRadius(_ e: SketchEntity) -> Double? {
        switch e {
        case let .circle(_, _, r), let .arc(_, _, r, _, _), let .polygon(_, _, r, _, _): return r
        default: return nil
        }
    }

    private func sketchEntity(_ id: UUID, in sketch: Sketch) -> SketchEntity? {
        sketch.entities.first { $0.id == id }
    }

    /// Plane-local position of a constraint ref's point on its entity.
    private func localPoint(_ ref: ConstraintRef, in sketch: Sketch) -> SIMD2<Double>? {
        if ref.role == .center,
           let (a, b) = RectangleConstruction.centerDiagonalReferences(ref.entityID, in: sketch),
           let first = localPoint(a, in: sketch), let opposite = localPoint(b, in: sketch) {
            return (first + opposite) / 2
        }
        guard let e = sketchEntity(ref.entityID, in: sketch) else { return nil }
        if ref.role == .whole, let index = ref.rectangleEdge,
           let edge = RectangleConstruction.axisEdge(e, index: index) {
            return (edge.a + edge.b) / 2
        }
        switch (e, ref.role) {
        case let (.line(_, a, _), .endpointA): return a
        case let (.line(_, _, b), .endpointB): return b
        case let (.rect(_, mn, _), .endpointA): return mn
        case let (.rect(_, _, mx), .endpointB): return mx
        case let (.rect(_, lo, hi), .center): return (lo + hi) / 2
        case let (.line(_, a, b), .whole): return (a + b) / 2
        default:
            switch e {
            case let .circle(_, c, _), let .arc(_, c, _, _, _),
                 let .ellipse(_, c, _, _, _), let .polygon(_, c, _, _, _):
                return c
            default: return nil
            }
        }
    }

    private func lineEndpoints(_ id: UUID, in sketch: Sketch) -> (SIMD2<Double>, SIMD2<Double>)? {
        guard case let .line(_, a, b)? = sketchEntity(id, in: sketch) else { return nil }
        return (a, b)
    }

    /// Local-space geometry for a dimension: (label anchor, annotation line
    /// endpoints). Kind-specific; falls back to the anchor for degenerate refs.
    private func dimensionGeometry(
        kind: DimensionKind, refs: [ConstraintRef], in sketch: Sketch
    ) -> (anchor: SIMD2<Double>, start: SIMD2<Double>, end: SIMD2<Double>)? {
        switch kind {
        case .distance:
            guard refs.count == 2 else { return nil }
            // point-to-line if exactly one ref is a whole line.
            let wholes = refs.filter { $0.role == .whole }
            if wholes.count == 1, let lineRef = wholes.first,
               let pointRef = refs.first(where: { $0.role != .whole }),
               let p = localPoint(pointRef, in: sketch),
               let (la, lb) = lineEndpoints(lineRef.entityID, in: sketch) {
                let proj = closestPointOnSegment(p, la, lb)
                return (( p + proj) / 2, p, proj)
            }
            guard let a = localPoint(refs[0], in: sketch),
                  let b = localPoint(refs[1], in: sketch) else { return nil }
            return ((a + b) / 2, a, b)
        case .horizontal, .vertical:
            // Explicit edge selection takes priority over creation-side defaults.
            guard refs.count == 2, let a = localPoint(refs[0], in: sketch),
                  let b = localPoint(refs[1], in: sketch) else { return nil }
            let lo = SIMD2(min(a.x, b.x), min(a.y, b.y)), hi = SIMD2(max(a.x, b.x), max(a.y, b.y))
            let retainedSize = selectedSketchEntityIDs.isEmpty && selectedSketchPoints.isEmpty &&
                sketch.dimensions.contains { $0.id == selectedDimensionID && $0.kind == kind && $0.refs == refs }
            if let pick = selectedAxisRectangleEdge,
               (selectedSketchEntityIDs == [pick.id] || retainedSize),
               refs.allSatisfy({ $0.entityID == pick.id }),
               let entity = sketchEntity(pick.id, in: sketch),
               let edge = RectangleConstruction.axisEdge(entity, index:
                    (kind == .horizontal) == (pick.index % 2 == 0)
                        ? pick.index : (pick.index + 3) % 4) {
                return ((edge.a + edge.b) / 2, edge.a, edge.b)
            }
            // Creation direction determines default leader sides, independently
            // of the solver's center/lower-left sizing policy. Legacy center
            // rectangles without direction metadata keep their old defaults.
            if refs[0].entityID == refs[1].entityID,
               case .rect? = sketchEntity(refs[0].entityID, in: sketch),
               let corner = sketch.rectangleSizingAnchors[refs[0].entityID]?.annotationCornerUsesMax {
                let s: SIMD2<Double>, e: SIMD2<Double>
                if kind == .horizontal {
                    let y = corner.x ? hi.y : lo.y
                    s = SIMD2(lo.x, y); e = SIMD2(hi.x, y)
                } else {
                    let x = corner.y ? lo.x : hi.x
                    s = SIMD2(x, lo.y); e = SIMD2(x, hi.y)
                }
                return ((s + e) / 2, s, e)
            }
            if kind == .horizontal {
                let s = lo, e = SIMD2(hi.x, lo.y)
                return ((s + e) / 2, s, e)
            }
            if refs[0].entityID == refs[1].entityID,
               case .rect? = sketchEntity(refs[0].entityID, in: sketch) {
                let s = lo, e = SIMD2(lo.x, hi.y)
                return ((s + e) / 2, s, e)
            }
            let s = SIMD2(hi.x, lo.y), e = hi
            return ((s + e) / 2, s, e)
        case .radius, .diameter:
            guard let ref = refs.first,
                  let e = sketchEntity(ref.entityID, in: sketch),
                  let r = Self.entityRadius(e),
                  let c = localPoint(ConstraintRef(entityID: ref.entityID, role: .center), in: sketch)
            else { return nil }
            if kind == .radius, case let .polygon(_, _, _, _, angle) = e {
                let end = c + SIMD2(cos(angle), sin(angle)) * r
                return ((c + end) / 2, c, end)
            }
            if kind == .radius, case let .arc(_, _, _, angle, _) = e {
                let end = c + SIMD2(cos(angle), sin(angle)) * r
                return ((c + end) / 2, c, end)
            }
            let end = c + SIMD2(r, 0)
            let start = kind == .diameter ? c - SIMD2(r, 0) : c
            return (c + SIMD2(r * 0.5, 0), start, end)
        case .angle:
            if refs.count == 1, let ref = refs.first,
               case let .arc(_, c, r, start, end)? = sketchEntity(ref.entityID, in: sketch) {
                let mid = start + SketchEntity.arcSweep(startAngle: start, endAngle: end) / 2
                let direction = SIMD2(cos(mid), sin(mid))
                return (c + direction * r * 1.7,
                        c + SIMD2(cos(start), sin(start)) * r,
                        c + SIMD2(cos(end), sin(end)) * r)
            }
            guard refs.count == 2,
                  let (a1, b1) = lineEndpoints(refs[0].entityID, in: sketch),
                  let (a2, b2) = lineEndpoints(refs[1].entityID, in: sketch) else { return nil }
            let anchor = (a1 + b1 + a2 + b2) / 4
            return (anchor, (a1 + b1) / 2, (a2 + b2) / 2)
        }
    }

    private func closestPointOnSegment(
        _ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>
    ) -> SIMD2<Double> {
        let ab = b - a
        let len2 = simd_length_squared(ab)
        guard len2 > 1e-12 else { return a }
        let t = simd_dot(p - a, ab) / len2
        return a + ab * t
    }

    /// Measured value of a dimension in DISPLAY units (degrees for angle).
    private func measuredValue(kind: DimensionKind, refs: [ConstraintRef], in sketch: Sketch) -> Double? {
        switch kind {
        case .distance:
            guard let g = dimensionGeometry(kind: kind, refs: refs, in: sketch) else { return nil }
            return simd_distance(g.start, g.end)
        case .horizontal, .vertical:
            guard refs.count == 2, let a = localPoint(refs[0], in: sketch),
                  let b = localPoint(refs[1], in: sketch) else { return nil }
            return kind == .horizontal ? abs(b.x - a.x) : abs(b.y - a.y)
        case .radius:
            guard let ref = refs.first, let e = sketchEntity(ref.entityID, in: sketch) else { return nil }
            return Self.entityRadius(e)
        case .diameter:
            guard let ref = refs.first, let e = sketchEntity(ref.entityID, in: sketch) else { return nil }
            return Self.entityRadius(e).map { $0 * 2 }
        case .angle:
            if refs.count == 1, let ref = refs.first,
               case let .arc(_, _, _, start, end)? = sketchEntity(ref.entityID, in: sketch) {
                return SketchEntity.arcSweep(startAngle: start, endAngle: end) * 180 / .pi
            }
            guard refs.count == 2,
                  let (a1, b1) = lineEndpoints(refs[0].entityID, in: sketch),
                  let (a2, b2) = lineEndpoints(refs[1].entityID, in: sketch) else { return nil }
            let d1 = b1 - a1, d2 = b2 - a2
            let n1 = simd_length(d1), n2 = simd_length(d2)
            guard n1 > 1e-9, n2 > 1e-9 else { return nil }
            let cosA = min(max(simd_dot(d1, d2) / (n1 * n2), -1), 1)
            return acos(cosA) * 180 / .pi
        }
    }

    private var selectedRectangleDimensionEdges: [UUID]? {
        let releasedCenter = mode.sketchTool == .rect && rectangleType == .threePoint &&
            selectedSketchPoints.count == 1 && selectedSketchPoints.first?.role == .center &&
            selectedSketchEntityIDs.contains(selectedSketchPoints.first!.entityID)
        guard selectedSketchPoints.isEmpty || releasedCenter else { return nil }
        guard let sketch = activeSketch,
              let first = selectedSketchEntities.first,
              let loop = RectangleConstruction.dimensionEdges(containing: first.id, in: sketch),
              Set(loop) == selectedSketchEntityIDs else { return nil }
        return loop
    }

    /// A single side still belongs to its saved migrated center rectangle.
    /// Keep this distinct from arbitrary connected lines and point selection.
    private var selectedMigratedRectangleEdges: [UUID]? {
        guard selectedSketchPoints.isEmpty, selectedSketchEntityIDs.count == 1,
              let id = selectedSketchEntityIDs.first, let sketch = activeSketch else { return nil }
        return sketch.rotatedRectangleEdges.values.first { ids in
            ids.count == 4 && Set(ids).count == 4 && ids.contains(id) &&
            ids.allSatisfy { edgeID in sketch.entities.contains {
                if case .line = $0 { return $0.id == edgeID }; return false
            } }
        }
    }

    private var selectedMigratedRectangleCornerEdges: [UUID]? {
        guard selectedSketchEntityIDs.isEmpty, selectedSketchPoints.count == 1,
              let point = selectedSketchPoints.first,
              point.role == .endpointA || point.role == .endpointB,
              let sketch = activeSketch else { return nil }
        return sketch.rotatedRectangleEdges.values.first { ids in
            ids.count == 4 && Set(ids).count == 4 && ids.contains(point.entityID) &&
            ids.allSatisfy { id in
                if case .line? = sketchEntity(id, in: sketch) { return true }
                return false
            }
        }
    }

    var selectedMigratedRectangleCornerMarker: SketchPointMarker? {
        guard selectedMigratedRectangleCornerEdges != nil,
              let point = selectedSketchPoints.first, let sketch = activeSketch,
              let local = localPoint(.init(entityID: point.entityID, role: point.role), in: sketch) else { return nil }
        return SketchPointMarker(id: "selectedMigratedCorner",
            world: SIMD3<Float>(sketch.plane.toWorld(local)), state: .free,
            isRectangleCorner: true, isSelected: true)
    }

    private static func lineLengthRefs(_ id: UUID) -> [ConstraintRef] {
        [.init(entityID: id, role: .endpointA), .init(entityID: id, role: .endpointB)]
    }

    /// The dimension the current selection would create (auto-shown as an
    /// editable candidate label; also what the palette Dimension action edits).
    private var dimensionCandidate: (kind: DimensionKind, refs: [ConstraintRef])? {
        guard mode.isSketching else { return nil }
        if selectedSketchEntityIDs.isEmpty, selectedSketchPoints.isEmpty,
           let id = retainedCircleCenterReadoutID, let sketch = activeSketch,
           case .circle? = sketchEntity(id, in: sketch) {
            return (CADPreferences.shared.circularAnnotations == .alwaysRadius ? .radius : .diameter,
                    [.init(entityID: id, role: .whole)])
        }
        if let edges = selectedRectangleDimensionEdges {
            return (.distance, Self.lineLengthRefs(edges[0]))
        }
        let lines = selectedLineEntities
        let radii = selectedRadiusEntities
        let pts = Array(selectedSketchPoints)
        func pRef(_ p: SketchPointSelection) -> ConstraintRef {
            ConstraintRef(entityID: p.entityID, role: p.role)
        }
        // Two lines → angle.
        if lines.count == 2, radii.isEmpty, pts.isEmpty {
            return (.angle, [ConstraintRef(entityID: lines[0].id, role: .whole),
                             ConstraintRef(entityID: lines[1].id, role: .whole)])
        }
        // Two points → distance.
        if pts.count == 2 {
            return (.distance, [pRef(pts[0]), pRef(pts[1])])
        }
        // One point + one line → point-to-line distance.
        if pts.count == 1, lines.count == 1 {
            return (.distance, [pRef(pts[0]), ConstraintRef(entityID: lines[0].id, role: .whole)])
        }
        // Single line → length.
        if lines.count == 1, radii.isEmpty, pts.isEmpty {
            let id = lines[0].id
            return (.distance, [ConstraintRef(entityID: id, role: .endpointA),
                                ConstraintRef(entityID: id, role: .endpointB)])
        }
        // Single circle → diameter; arc / polygon → radius. A FULL circle reads
        // Ø everywhere else in the app — `LiveDimensionKit` draws Ø while you
        // drag one out — so offering R on release meant the same circle showed
        // two different numbers seconds apart. An arc's radius is the useful
        // value (and what its centre-and-sweep is defined by), so it keeps R.
        if radii.count == 1, lines.isEmpty, pts.isEmpty ||
            (pts == [.init(entityID: radii[0].id, role: .center)] &&
             selectedCircleCenterID == radii[0].id) {
            let entity = radii[0]
            let isFullCircle: Bool
            if case .circle = entity { isFullCircle = true } else { isFullCircle = false }
            return (isFullCircle && CADPreferences.shared.circularAnnotations != .alwaysRadius ? .diameter : .radius,
                    [ConstraintRef(entityID: entity.id, role: .whole)])
        }
        // Single rectangle → width (its height is offered as a second label;
        // see `sketchDimensionLabels`). A rect's solver points are its two
        // corners, so width/height are axis distances between them, not the
        // corner-to-corner `.distance` — that would dimension the diagonal.
        if let rect = selectedRectEntities.first, selectedRectEntities.count == 1,
           lines.isEmpty, radii.isEmpty,
           pts.isEmpty || (mode.sketchTool == .rect && rectangleType == .center &&
                selectedSketchPoints == [.init(entityID: rect.id, role: .center)]) {
            return (.horizontal, Self.rectCornerRefs(rect.id))
        }
        return nil
    }

    static func rectCornerRefs(_ id: UUID) -> [ConstraintRef] {
        [ConstraintRef(entityID: id, role: .endpointA), ConstraintRef(entityID: id, role: .endpointB)]
    }

    /// True when the palette Dimension action can act on the selection.
    var canDimensionSelection: Bool { dimensionCandidate != nil }

    /// The dimension kinds offered by the adaptive Dimension action. A sloped
    /// line has three useful measurements in Shapr3D: its true length plus its
    /// horizontal and vertical projections. Axis-aligned lines keep the single
    /// unambiguous length action rather than showing duplicate values.
    var dimensionKindChoices: [DimensionKind] {
        guard let candidate = dimensionCandidate else { return [] }
        guard candidate.kind == .distance,
              selectedSketchPoints.isEmpty,
              selectedLineEntities.count == 1,
              selectedSketchEntityIDs.count == 1,
              case let .line(_, a, b) = selectedLineEntities[0] else {
            return [candidate.kind]
        }
        let delta = b - a
        guard abs(delta.x) > 1e-9, abs(delta.y) > 1e-9 else {
            return [candidate.kind]
        }
        return [.distance, .horizontal, .vertical]
    }

    /// The native badge preserves geometry and, for a plain numeric driver,
    /// replaces its type/value in place rather than adding another driver.
    func canChooseLineDimensionKind(_ label: SketchDimensionLabel) -> Bool {
        guard label.isStandaloneLineLength,
              editingDimension == nil, !sketchTransformActive,
              let sketch = activeSketch, let candidate = dimensionCandidate else { return false }
        let dimensions = sketch.dimensions.filter {
            $0.refs.count == label.refs.count && $0.refs.allSatisfy(label.refs.contains)
        }
        if let id = label.dimensionID {
            guard dimensions.count == 1, dimensions[0].id == id,
                  dimensions[0].formula == nil else { return false }
        } else if !dimensions.isEmpty { return false }
        return label.refs == candidate.refs && dimensionKindChoices.count == 3
    }

    func chooseLineDimensionKind(_ kind: DimensionKind, label: SketchDimensionLabel) {
        guard canChooseLineDimensionKind(label), dimensionKindChoices.contains(kind),
              let before = activeSketch, before.id == label.sketchID,
              let id = label.refs.first?.entityID, label.kind != kind,
              let value = measuredValue(kind: kind, refs: label.refs, in: before) else { return }
        let oldDimension = label.dimensionID.flatMap { dimensionID in
            before.dimensions.first { $0.id == dimensionID }
        }
        var newDimension = oldDimension
        newDimension?.kind = kind
        newDimension?.value = value
        newDimension?.displayExpression = nil
        let command = SetLineDimensionKindCommand(sketchID: before.id, entityID: id,
            before: before.lineDimensionKinds[id], after: kind == .distance ? nil : kind,
            beforeDimension: oldDimension, afterDimension: newDimension)
        session.perform(command)
        clearLineDimensionSelection(for: command)
    }

    /// A keypad unit token as a `DisplayUnit`. "deg" is an angle unit and has
    /// no length meaning, so it maps to nil and the value is left alone.
    nonisolated static func lengthUnit(forSuffix suffix: String?) -> DisplayUnit? {
        switch suffix {
        case "mm": .millimeters
        case "cm": .centimeters
        case "m": .meters
        case "in": .inches
        case "ft": .feet
        default: nil
        }
    }

    /// Number → clean editable string (drops trailing zeros).
    private static func dimensionFieldText(_ value: Double, lengthUnit: DisplayUnit? = nil) -> String {
        if abs(value - value.rounded()) < 1e-6 {
            return String(Int(value.rounded()))
        }
        let scale = lengthUnit == .millimeters || lengthUnit == .inches || lengthUnit == .feet
            ? 10000.0 : 1000.0
        return String(format: "%g", (value * scale).rounded() / scale)
    }

    /// Dimension labels to render in the sketch overlay: existing driving
    /// dimensions plus the live selection candidate (if any and not already an
    /// existing dimension over the same refs).
    /// Sketches whose annotations (dimensions, constraint glyphs) should draw.
    /// Dimensions use the active sketch during editing; otherwise visible sketches
    /// may contribute when the user has
    /// asked annotations to persist — Shapr3D's "Constraint & Locked Dimension
    /// Visibility". Without that, leaving a sketch hides the very dimensions
    /// that define it, and a second sketch's dimensions are never visible at all.
    /// The active sketch is included even when hidden, because `openItemSketch`
    /// renders a hidden sketch while it is being edited.
    private func annotatedSketches(alwaysShow: Bool,
                                   restrictDimensionsToActiveSketch: Bool = false) -> [Sketch] {
        let active = activeSketch
        if alwaysShow {
            return session.document.sketches.filter { sketch in
                guard !sketch.isHidden || sketch.id == active?.id else { return false }
                // Native suppresses other sketches' locked dimensions while
                // editing, including independent coplanar reference geometry.
                // Outside sketch editing, Always Show still includes all visible
                // sketches. Constraint glyph policy is intentionally unchanged.
                if restrictDimensionsToActiveSketch, let active {
                    return sketch.id == active.id
                }
                return true
            }
        }
        // Keep the active sketch as a candidate; each annotation is filtered
        // below, including a selected glyph or an open dimension editor.
        let entityIDs = selectedSketchEntityIDs.union(selectedSketchPoints.map(\.entityID))
        return session.document.sketches.filter {
            $0.id == active?.id || (!$0.isHidden && $0.entities.contains { entityIDs.contains($0.id) })
        }
    }

    private func annotationIsVisible(refs: [ConstraintRef], alwaysShow: Bool,
                                     explicitlySelected: Bool) -> Bool {
        SketchAnnotationVisibility.shows(refs: refs, alwaysShow: alwaysShow,
            selectedEntities: selectedSketchEntityIDs,
            selectedPoints: selectedSketchPoints.map {
                ConstraintRef(entityID: $0.entityID, role: $0.role)
            }, explicitlySelected: explicitlySelected)
    }

    var sketchDimensionLabels: [SketchDimensionLabel] {
        _ = session.changeCount
        // Native Trim suppresses numeric readouts: the selected boundary must
        // receive the tap, even where a polygon count or length badge sits.
        // Keep the selection and saved annotations intact for leaving Trim.
        if mode.sketchTool == .trim { return [] }
        let unit = CADPreferences.shared.unit
        var labels: [SketchDimensionLabel] = []

        func makeLabel(id: String, in sketch: Sketch, dimensionID: UUID?, kind: DimensionKind,
                       refs: [ConstraintRef], value: Double, presentationEdgeID: UUID? = nil,
                       axisPresentationEdge: Int? = nil) -> SketchDimensionLabel? {
            var kind = kind
            var value = value
            if (kind == .radius || kind == .diameter), refs.count == 1,
               case .circle? = sketchEntity(refs[0].entityID, in: sketch) {
                let displayed: DimensionKind = CADPreferences.shared.circularAnnotations == .alwaysRadius ? .radius : .diameter
                if kind != displayed {
                    value *= displayed == .radius ? 0.5 : 2
                    kind = displayed
                }
            }
            guard var g = dimensionGeometry(kind: kind, refs: refs, in: sketch) else { return nil }
            var projectedLine: (SIMD2<Double>, SIMD2<Double>)?
            if (kind == .horizontal || kind == .vertical), refs.count == 2,
               refs[0].entityID == refs[1].entityID,
               Set(refs.map(\.role)) == Set([PointRole.endpointA, .endpointB]),
               case let .line(_, a, b)? = sketchEntity(refs[0].entityID, in: sketch),
               RectangleConstruction.dimensionEdges(containing: refs[0].entityID, in: sketch) == nil {
                let mid = (a + b) / 2
                g = kind == .horizontal
                    ? (mid, SIMD2(a.x, mid.y), SIMD2(b.x, mid.y))
                    : (mid, SIMD2(mid.x, a.y), SIMD2(mid.x, b.y))
                projectedLine = (a, b)
            }
            if kind == .radius, let id = refs.first?.entityID,
               case let .circle(_, center, radius)? = sketchEntity(id, in: sketch),
               let direction = sketch.circleRadiusDirections[id],
               direction.x.isFinite, direction.y.isFinite, simd_length(direction) > 1e-9 {
                g.start = center
                g.end = center + simd_normalize(direction) * radius
                g.anchor = (g.start + g.end) / 2
            }
            if kind == .distance, refs.count == 2, refs[0].entityID == refs[1].entityID,
               Set(refs.map(\.role)) == Set([PointRole.endpointA, .endpointB]),
               let group = selectedMigratedRectangleEdges ?? selectedMigratedRectangleCornerEdges,
               let dimensionIndex = group.firstIndex(of: refs[0].entityID) {
                var presentationID: UUID?
                if let selectedID = selectedSketchEntityIDs.first,
                   let selectedIndex = group.firstIndex(of: selectedID),
                   selectedIndex % 2 == dimensionIndex % 2 {
                    presentationID = selectedID
                } else if let point = selectedSketchPoints.first,
                          let index = group.firstIndex(of: point.entityID) {
                    let adjacent = (index + (point.role == .endpointA ? 3 : 1)) % 4
                    presentationID = group[index % 2 == dimensionIndex % 2 ? index : adjacent]
                }
                if let presentationID, case let .line(_, a, b)? = sketchEntity(presentationID, in: sketch) {
                    // Reposition the saved annotation, never its driving refs.
                    g.start = a
                    g.end = b
                    g.anchor = (a + b) / 2
                }
            }
            if let presentationEdgeID,
               case let .line(_, a, b)? = sketchEntity(presentationEdgeID, in: sketch) {
                g.start = a
                g.end = b
                g.anchor = (a + b) / 2
            }
            var axisEdgeIndex: Int?
            if kind == .horizontal || kind == .vertical, refs.count == 2,
               refs[0].entityID == refs[1].entityID,
               let entity = sketchEntity(refs[0].entityID, in: sketch), case .rect = entity {
                let storedEdge = dimensionID.flatMap { id in
                    sketch.dimensions.first(where: { $0.id == id })?.rectangleLabelEdges?.last
                }
                let selectedSide = selectedAxisRectangleEdge?.id == entity.id &&
                    selectedSketchEntityIDs == [entity.id]
                if let edgeIndex = axisPresentationEdge ?? (selectedSide ? nil : storedEdge),
                   (kind == .horizontal) == (edgeIndex % 2 == 0),
                   let edge = RectangleConstruction.axisEdge(entity, index: edgeIndex) {
                    g.start = edge.a; g.end = edge.b; g.anchor = (edge.a + edge.b) / 2
                }
                axisEdgeIndex = (0..<4).first { index in
                    guard (kind == .horizontal) == (index % 2 == 0),
                          let edge = RectangleConstruction.axisEdge(entity, index: index) else { return false }
                    return simd_distance((edge.a + edge.b) / 2, g.anchor) < 1e-9
                }
            }
            // Angles are unitless; lengths follow the display unit. The
            // document itself always stores millimetres — `value` is mm here.
            // Radius and diameter carry the CAD leader (R / Ø, the same
            // `LiveDimensionKit.Kind.prefix` the drag readout uses): a bare
            // "20 mm" on a circle says nothing about which one it is.
            let text: String
            switch kind {
            case .angle:
                text = String(format: "%.2f", value) + "°"
            case .radius:
                text = LiveDimensionKit.Kind.radius.prefix
                    + unit.compactLengthString(fromMM: value)
            case .diameter:
                text = LiveDimensionKit.Kind.diameter.prefix
                    + unit.compactLengthString(fromMM: value)
            default:
                text = unit.compactLengthString(fromMM: value)
            }
            var label = SketchDimensionLabel(
                id: id, sketchID: sketch.id, dimensionID: dimensionID, kind: kind, refs: refs,
                displayValue: value, text: text,
                worldAnchor: sketch.plane.toWorld(g.anchor),
                worldStart: sketch.plane.toWorld(g.start),
                worldEnd: sketch.plane.toWorld(g.end)
            )
            label.axisRectangleEdge = axisEdgeIndex
            if let (a, b) = projectedLine {
                label.isStandaloneLineLength = true
                label.isProjectedLineLength = true
                label.worldLineStart = sketch.plane.toWorld(a)
                label.worldLineEnd = sketch.plane.toWorld(b)
            }
            if let dimensionID, let dimension = sketch.dimensions.first(where: { $0.id == dimensionID }) {
                label.hasExpression = dimension.formula != nil || dimension.displayExpression != nil
            }
            if kind == .diameter, let entityID = refs.first?.entityID {
                let stored = dimensionID.flatMap { id in
                    sketch.dimensions.first(where: { $0.id == id })?.labelOffset
                }
                if let offset = stored ?? temporaryDiameterLabelOffsets[entityID] {
                    let center = (g.start + g.end) / 2
                    label.worldDiameterLabelAnchor = sketch.plane.toWorld(center + offset)
                }
            }
            // A dragged linear label: the saved (driving) or selection-lived
            // (measured) offset of its text from the line's midpoint.
            if kind == .distance, let entityID = refs.first?.entityID, refs.count == 2,
               refs.allSatisfy({ $0.entityID == entityID }) {
                let stored = dimensionID.flatMap { id in
                    sketch.dimensions.first(where: { $0.id == id })?.labelOffset
                }
                if let offset = stored ?? temporaryDiameterLabelOffsets[entityID] {
                    label.worldLinearLabelAnchor = sketch.plane.toWorld((g.start + g.end) / 2 + offset)
                }
            }
            if kind == .distance, let first = refs.first,
               refs.count == 2, refs.allSatisfy({ $0.entityID == first.entityID }),
               case .line? = sketchEntity(first.entityID, in: sketch) {
                if let edges = RectangleConstruction.dimensionEdges(containing: first.entityID, in: sketch) {
                    let centers = edges.compactMap { sketchEntity($0, in: sketch) }.map(Self.entityCenter)
                    if centers.count == 4 {
                        label.isRectangleSize = true
                        label.worldRectangleCenter = sketch.plane.toWorld(centers.reduce(.zero, +) / 4)
                    }
                } else {
                    label.isStandaloneLineLength = true
                }
            }
            if (kind == .horizontal || kind == .vertical), refs.count == 2,
               refs[0].entityID == refs[1].entityID,
               case let .rect(_, lo, hi)? = sketchEntity(refs[0].entityID, in: sketch) {
                label.isRectangleSize = true
                label.worldRectangleCenter = sketch.plane.toWorld((lo + hi) / 2)
            }
            if kind == .radius, let ref = refs.first,
               let entity = sketchEntity(ref.entityID, in: sketch) {
                switch entity {
                case .arc, .polygon: label.isArcRadius = true
                case .circle:
                    label.isArcRadius = true
                    label.isCircleRadius = true
                    label.hasCircleRadiusDirection = sketch.circleRadiusDirections[ref.entityID] != nil
                default: break
                }
            }
            if kind == .angle, refs.count == 1,
               case let .arc(_, center, radius, start, end)? =
                    sketchEntity(refs[0].entityID, in: sketch) {
                let sweep = SketchEntity.arcSweep(startAngle: start, endAngle: end)
                let count = max(8, Int(ceil(sweep / (.pi / 64))))
                label.worldArcCenter = sketch.plane.toWorld(center)
                label.worldArcPoints = (0...count).map { index in
                    let angle = start + sweep * Double(index) / Double(count)
                    return sketch.plane.toWorld(center + SIMD2(cos(angle), sin(angle)) * radius)
                }
            }
            return label
        }

        for sketch in annotatedSketches(alwaysShow: CADPreferences.shared.alwaysShowDimensions,
                                       restrictDimensionsToActiveSketch: true) {
            for d in sketch.dimensions {
                guard annotationIsVisible(refs: d.refs,
                    alwaysShow: CADPreferences.shared.alwaysShowDimensions,
                    explicitlySelected: selectedDimensionID == d.id
                        || editingDimension?.dimensionID == d.id
                        || (sketch.id == activeSketch?.id && d.kind == .distance &&
                            d.refs.count == 2 && d.refs[0].entityID == d.refs[1].entityID &&
                            Set(d.refs.map(\.role)) == Set([PointRole.endpointA, .endpointB]) &&
                            (selectedMigratedRectangleEdges?.contains(d.refs[0].entityID) == true ||
                             selectedMigratedRectangleCornerEdges?.contains(d.refs[0].entityID) == true))) else { continue }
                // Keep genuine geometry differences visible, but do not let a
                // negligible solver residual move a satisfied driving dimension
                // across a decimal rounding tie after editing another size.
                let stored = d.kind == .angle ? d.value * 180 / .pi : d.value
                let measured = measuredValue(kind: d.kind, refs: d.refs, in: sketch) ?? stored
                let display = abs(measured - stored) <= max(1, abs(stored)) * 1e-10
                    ? stored : measured
                if let label = makeLabel(id: d.id.uuidString, in: sketch, dimensionID: d.id,
                                         kind: d.kind, refs: d.refs, value: display) {
                    labels.append(label)
                    // Saved sides remain visible beside a perpendicular edge's
                    // adjacent readout, or after a successful size commit. All
                    // aliases share one driving dimension and identical refs.
                    if sketch.id == activeSketch?.id, let primary = label.axisRectangleEdge,
                       let saved = d.rectangleLabelEdges {
                        let perpendicularSelection = selectedAxisRectangleEdge.map { pick in
                            selectedSketchEntityIDs == [pick.id] && d.refs.allSatisfy { $0.entityID == pick.id } &&
                                (pick.index % 2 == 0) != (d.kind == .horizontal)
                        } == true
                        let retained = selectedSketchEntityIDs.isEmpty && selectedSketchPoints.isEmpty && selectedDimensionID == d.id
                        if perpendicularSelection || retained {
                            for side in Set(saved).sorted() where side != primary {
                                guard (0..<4).contains(side), (side % 2 == 0) == (d.kind == .horizontal) else { continue }
                                if let alias = makeLabel(id: d.id.uuidString + "-axis-side-\(side)",
                                    in: sketch, dimensionID: d.id, kind: d.kind, refs: d.refs,
                                    value: display, axisPresentationEdge: side) { labels.append(alias) }
                            }
                        }
                    }
                    // A committed selected size remains as two parallel
                    // readouts after native drops its edge/handle selection.
                    if sketch.id == activeSketch?.id, selectedDimensionID == d.id,
                       selectedSketchEntityIDs.isEmpty, selectedSketchPoints.isEmpty,
                       d.kind == .distance, d.refs.count == 2,
                       d.refs[0].entityID == d.refs[1].entityID,
                       Set(d.refs.map(\.role)) == Set([PointRole.endpointA, .endpointB]),
                       let group = sketch.rotatedRectangleEdges.values.first(where: { ids in
                           ids.count == 4 && Set(ids).count == 4 && ids.contains(d.refs[0].entityID) &&
                           ids.allSatisfy { if case .line? = sketchEntity($0, in: sketch) { return true }; return false }
                       }), let groupID = group.first, sketch.rectangleSizingAnchors[groupID] != nil,
                       let index = group.firstIndex(of: d.refs[0].entityID) {
                        let oppositeID = group[(index + 2) % 4]
                        if let opposite = makeLabel(id: d.id.uuidString + "-side-" + oppositeID.uuidString,
                            in: sketch, dimensionID: d.id, kind: d.kind, refs: d.refs,
                            value: display, presentationEdgeID: oppositeID) {
                            labels.append(opposite)
                        }
                    }
                    // One selected side exposes both adjacent sides. The extra
                    // readout is another presentation of the same driving size,
                    // not another dimension or a new solver reference.
                    if sketch.id == activeSketch?.id, d.kind == .distance,
                       d.refs.count == 2, d.refs[0].entityID == d.refs[1].entityID,
                       Set(d.refs.map(\.role)) == Set([PointRole.endpointA, .endpointB]),
                       let group = selectedMigratedRectangleEdges,
                       let groupID = group.first, sketch.rectangleSizingAnchors[groupID] != nil,
                       let selectedID = selectedSketchEntityIDs.first,
                       let selectedIndex = group.firstIndex(of: selectedID),
                       let drivingIndex = group.firstIndex(of: d.refs[0].entityID),
                       selectedIndex % 2 != drivingIndex % 2 {
                        let oppositeID = group[(drivingIndex + 2) % 4]
                        if let opposite = makeLabel(id: d.id.uuidString + "-side-" + oppositeID.uuidString,
                            in: sketch, dimensionID: d.id, kind: d.kind, refs: d.refs,
                            value: display, presentationEdgeID: oppositeID) {
                            labels.append(opposite)
                        }
                    }
                }
            }
        }

        // The live candidate belongs to the selection, which only exists in the
        // sketch being edited — so it stays active-sketch-only.
        guard let sketch = activeSketch else { return labels }

        // Live candidate — skip if an existing dimension already covers the
        // same refs+kind (so we don't double-draw once it's committed).
        func appendCandidate(id: String, kind: DimensionKind, refs: [ConstraintRef]) {
            // Native hides temporary circle/arc size readouts in Move/Rotate,
            // but saved driving dimensions above remain visible and editable.
            if sketchTransformActive, editingDimension == nil, refs.count == 1,
               let ref = refs.first, let entity = sketchEntity(ref.entityID, in: sketch) {
                switch entity {
                case .circle, .arc: return
                default: break
                }
            }
            // An opposite side shares the rectangle's saved driving size;
            // don't add a third temporary label over the same size family.
            if kind == .distance, refs.count == 2, refs[0].entityID == refs[1].entityID,
               let edges = selectedMigratedRectangleEdges,
               let index = edges.firstIndex(of: refs[0].entityID),
               sketch.dimensions.contains(where: { dimension in
                   guard dimension.kind == .distance, dimension.refs.count == 2,
                         dimension.refs[0].entityID == dimension.refs[1].entityID,
                         Set(dimension.refs.map(\.role)) == Set([PointRole.endpointA, .endpointB]),
                         let other = edges.firstIndex(of: dimension.refs[0].entityID) else { return false }
                   return index % 2 == other % 2
               }) { return }
            let refSet = Set(refs.map { "\($0.entityID)-\($0.role.rawValue)" })
            let existing = sketch.dimensions.contains { d in
                (d.kind == kind || ((d.kind == .radius || d.kind == .diameter)
                    && (kind == .radius || kind == .diameter))) &&
                Set(d.refs.map { "\($0.entityID)-\($0.role.rawValue)" }) == refSet
            }
            if !existing, let value = measuredValue(kind: kind, refs: refs, in: sketch),
               let label = makeLabel(id: id, in: sketch, dimensionID: nil,
                                     kind: kind, refs: refs, value: value) {
                labels.append(label)
            }
        }
        if let cand = dimensionCandidate {
            let displayKind: DimensionKind
            if dimensionKindChoices.count == 3, let id = cand.refs.first?.entityID,
               let preferred = sketch.lineDimensionKinds[id],
               dimensionKindChoices.contains(preferred) {
                displayKind = preferred
            } else { displayKind = cand.kind }
            appendCandidate(id: "candidate", kind: displayKind, refs: cand.refs)
            // A selected rectangle offers both its width (the palette's
            // candidate) and its height, each an editable label on its side.
            if cand.kind == .radius, cand.refs.count == 1,
               let ref = cand.refs.first,
               case .arc? = sketchEntity(ref.entityID, in: sketch) {
                appendCandidate(id: "candidate-arc-angle", kind: .angle, refs: cand.refs)
            } else if cand.kind == .horizontal {
                appendCandidate(id: "candidate-vertical", kind: .vertical, refs: cand.refs)
            } else if let edges = selectedRectangleDimensionEdges {
                appendCandidate(id: "candidate-height", kind: .distance,
                                refs: Self.lineLengthRefs(edges[1]))
            }
        }
        // Side count is a construction property, not a driving radius dimension.
        // Keep it available even when the polygon already has a saved radius.
        if selectedSketchEntityIDs.count == 1, !sketchTransformActive,
           let id = selectedSketchEntityIDs.first,
           case let .polygon(_, center, radius, sides, rotation)? = sketchEntity(id, in: sketch) {
            let extent = sides.isMultiple(of: 2) ? radius : radius * cos(.pi / Double(sides))
            let opposite = center - SIMD2(cos(rotation), sin(rotation)) * extent
            var count = SketchDimensionLabel(
                id: "polygon-count-\(id)", sketchID: sketch.id, dimensionID: nil,
                kind: .radius, refs: [ConstraintRef(entityID: id, role: .whole)],
                displayValue: Double(sides), text: "\(sides) sides",
                worldAnchor: sketch.plane.toWorld(opposite),
                worldStart: sketch.plane.toWorld(center), worldEnd: sketch.plane.toWorld(opposite))
            count.isPolygonSideCount = true
            labels.append(count)
        }
        return labels
    }

    var canTypeRectangleBaseline: Bool {
        mode.sketchTool == .rect && rectangleType == .threePoint &&
        rectangleBaseline != nil && rectanglePreview.count == 1 && editingDimension == nil
    }

    var pendingRectangleEditorAnchor: SIMD3<Double>? {
        guard editingDimension?.isPendingRectangleBaseline == true else { return nil }
        return liveDimensionLabels.first?.worldLabel
    }

    func beginRectangleBaselineEdit(firstCharacter: String) {
        guard canTypeRectangleBaseline else { return }
        dimensionCommitLocked = true
        editingDimension = DimensionEdit(labelID: "pending-rectangle-baseline",
            dimensionID: nil, kind: .distance,
            refs: [.init(entityID: rectangleIDs[0], role: .endpointA),
                   .init(entityID: rectangleIDs[0], role: .endpointB)],
            text: firstCharacter, isPendingRectangleBaseline: true, hardwareInitiated: true)
        // The first typed character is already a draft, not a measured seed.
        // Subsequent hardware keys append rather than selecting/replacing it.
    }

    /// Open the inline numeric field for a label (tap on a dimension label).
    /// A label belonging to another sketch is a readout until that sketch is
    /// open — `commitDimensionEdit` and the solver both require it to be
    /// active — so enter it first, exactly as tapping the sketch in Items does.
    func beginDimensionEdit(_ label: SketchDimensionLabel) {
        if activeSketch?.id != label.sketchID {
            openItemSketch(label.sketchID)
            guard activeSketch?.id == label.sketchID else { return }
        }
        // Opening an external badge enters its sketch and keeps its defining
        // geometry selected, so committing does not immediately hide the badge.
        let definingIDs = Set(label.refs.map(\.entityID))
        // A rectangle's baseline/height editor should not discard the other
        // three selected sides (and its other size badge) when opened.
        var keepsSelectedRectangleSide = false
        if label.kind == .distance, label.refs.count == 2,
           label.refs[0].entityID == label.refs[1].entityID,
           Set(label.refs.map(\.role)) == Set([PointRole.endpointA, .endpointB]),
           let group = selectedMigratedRectangleEdges,
           group.contains(label.refs[0].entityID) {
            keepsSelectedRectangleSide = true
        }
        let keepsSelectedCorner = label.kind == .distance &&
            selectedMigratedRectangleCornerEdges.map { definingIDs.isSubset(of: Set($0)) } == true
        if !keepsSelectedRectangleSide && !keepsSelectedCorner &&
            (selectedRectangleDimensionEdges == nil || !definingIDs.isSubset(of: selectedSketchEntityIDs)) {
            selectedSketchEntityIDs = definingIDs
        }
        if !keepsSelectedCorner { selectedSketchPoints.removeAll() }
        selectedConstraintID = nil
        selectedDimensionID = label.dimensionID
        // Locked is the default for every fresh edit: a typed dimension is
        // normally meant to hold, and a sticky unlock would silently stop
        // recording them.
        dimensionCommitLocked = true
        let retainedExpression = label.dimensionID.flatMap { id in
            activeSketch?.dimensions.first(where: { $0.id == id && $0.kind == label.kind })?.displayExpression
        }
        editingDimension = DimensionEdit(
            labelID: label.id,
            dimensionID: label.dimensionID,
            kind: label.kind,
            refs: label.refs,
            // Seed in the display unit so what you edit matches what you read.
            // Angles are unitless. `commitDimensionEdit` converts back.
            text: retainedExpression ?? Self.dimensionFieldText(
                label.kind == .angle || label.isPolygonSideCount
                    ? label.displayValue
                    : CADPreferences.shared.unit.display(fromMM: label.displayValue),
                lengthUnit: label.kind == .angle || label.isPolygonSideCount ? nil : CADPreferences.shared.unit),
            measuredSeed: retainedExpression == nil && !label.isPolygonSideCount ? label.displayValue : nil,
            isPolygonSideCount: label.isPolygonSideCount,
            axisRectangleEdge: label.axisRectangleEdge
        )
    }

    /// Palette Dimension action uses the stored label when this size is already
    /// driven; otherwise it opens the new selection candidate.
    func beginDimensionForSelection(kind requestedKind: DimensionKind? = nil) {
        guard let cand = dimensionCandidate, let sketch = activeSketch,
              requestedKind.map({ dimensionKindChoices.contains($0) }) ?? true else { return }
        let kind = requestedKind ?? cand.kind
        guard let value = measuredValue(kind: kind, refs: cand.refs, in: sketch) else { return }
        let refs = Set(cand.refs.map { "\($0.entityID)-\($0.role.rawValue)" })
        if let storedLabel = sketchDimensionLabels.first(where: {
            $0.dimensionID != nil && $0.kind == kind &&
            Set($0.refs.map { "\($0.entityID)-\($0.role.rawValue)" }) == refs
        }) {
            beginDimensionEdit(storedLabel)
            return
        }
        // Locked is the default for every fresh edit: a typed dimension is
        // normally meant to hold, and a sticky unlock would silently stop
        // recording them.
        dimensionCommitLocked = true
        editingDimension = DimensionEdit(
            labelID: "candidate",
            dimensionID: nil,
            kind: kind,
            refs: cand.refs,
            // `measuredValue` already returns degrees for `.angle`; lengths are
            // millimetres and must be shown in the display unit, exactly as
            // `beginDimensionEdit` does — the two paths open the same field.
            text: Self.dimensionFieldText(
                kind == .angle
                    ? value
                    : CADPreferences.shared.unit.display(fromMM: value),
                lengthUnit: kind == .angle ? nil : CADPreferences.shared.unit),
            measuredSeed: value
        )
    }

    /// The native lock key acts on the current size, not an uncommitted draft.
    func canToggleDimensionLock(_ text: String) -> Bool {
        guard let edit = editingDimension else { return false }
        return !edit.isPolygonSideCount && text == edit.text
    }

    func toggleDimensionLock(_ text: String) {
        guard canToggleDimensionLock(text), let edit = editingDimension,
              let sketch = activeSketch else { return }
        if let id = edit.dimensionID {
            guard sketch.dimensions.contains(where: { $0.id == id }) else { return }
            deleteDimension(id)
        } else {
            guard let measured = measuredValue(kind: edit.kind, refs: edit.refs, in: sketch) else { return }
            let offset = edit.kind == .diameter
                ? edit.refs.first.flatMap { temporaryDiameterLabelOffsets[$0.entityID] } : nil
            let dimension = SketchDimension(kind: edit.kind, refs: edit.refs,
                value: edit.kind == .angle ? measured * .pi / 180 : measured,
                labelOffset: offset, rectangleDrivingEdge: edit.axisRectangleEdge)
            // Freeze the actual measured size without solving or moving geometry.
            session.perform(AddSketchDimensionCommand(sketchID: sketch.id, dimension: dimension))
            session.save()
        }
        cancelDimensionEdit()
        selectedDimensionID = nil
        selectedConstraintID = nil
        selectedSketchPoints.removeAll()
        selectedSketchEntityIDs.removeAll()
    }

    func cancelDimensionEdit() {
        dimensionDraft = nil
        editingDimension = nil
    }

    /// Commit the inline field: evaluate the (possibly arithmetic) text, set the
    /// driving value, re-solve, and push one undoable command. On over-defined
    /// refusal the geometry can't reach the value; we still record it and warn.
    func commitDimensionEdit(_ rawText: String) {
        guard let edit = editingDimension,
              case .sketching(let sketchID, _) = mode,
              let sketch = activeSketch else {
            editingDimension = nil
            return
        }
        // Phase D: evaluate against document variables so a dimension can read
        // e.g. "width/2"; store the raw text as the driving formula only when it
        // references a variable/function (a plain number keeps `formula: nil`).
        let additiveMM = edit.kind != .angle && !edit.isPolygonSideCount
            ? ExpressionEvaluator.additiveLengthMM(rawText) : nil
        let untouchedSeed = rawText == edit.text &&
            !(dimensionDraft?.sessionID == edit.sessionID && dimensionDraft?.changed == true)
            ? edit.measuredSeed : nil
        let seededDisplay = untouchedSeed.map {
            edit.kind == .angle ? $0 : CADPreferences.shared.unit.display(fromMM: $0)
        }
        guard let parsed = seededDisplay ?? additiveMM ?? ExpressionEvaluator.evaluate(rawText, variables: session.variableValues()) else {
            editingDimension?.validationMessage = ExpressionEvaluator.validationMessage(
                rawText, variables: session.variableValues())
            return
        }
        // An angle is not a length. The scalar evaluator deliberately ignores
        // suffixes, so reject this before dismissal or any geometry/history edit.
        if !edit.isPolygonSideCount, edit.kind != .angle,
           NumericParsing.trailingUnit(in: rawText) == "deg" {
            editingDimension?.validationMessage = "Cannot use angle in a length type parameter."
            return
        }
        if edit.kind == .angle,
           Self.lengthUnit(forSuffix: NumericParsing.trailingUnit(in: rawText)) != nil {
            editingDimension?.validationMessage = "Cannot use length in an angle type parameter."
            return
        }
        // Keep malformed expressions editable; valid out-of-range values dismiss.
        // Paired native 1/0 and 2+ retain the keypad, unlike zero/negative sizes.
        editingDimension = nil
        if edit.isPolygonSideCount {
            // Truncate positive fractional counts, matching the sampled native
            // 3.5 -> 3 edit. Bound before Int conversion/allocation.
            guard parsed.isFinite, parsed >= 3, parsed < 10_001 else {
                showNotice("Polygon side count must be between 3 and 10000.")
                return
            }
            guard let id = edit.refs.first?.entityID,
                  let before = sketchEntity(id, in: sketch),
                  case let .polygon(_, center, radius, sides, rotation) = before else { return }
            let count = Int(parsed)
            guard count != sides else { return }
            let after = SketchEntity.polygon(id: id, center: center, radius: radius,
                                            sides: count, rotation: rotation)
            // Existing solver references address the center/radius, neither of
            // which changes. Keep dependent profile rebuild in the same undo.
            session.performWithSketchRebuild(CompositeCommand(title: "Polygon Sides", commands: [
                UpdateSketchEntityCommand(sketchID: sketchID, before: before, after: after)
            ]), sketchID: sketchID)
            session.save()
            return
        }
        // A trailing unit is letters, so `identifiers(in:)` reads "20 cm" as the
        // variable `cm` — which made it a "formula", skipped the unit
        // conversion below, and stored nonsense in `formula`. Strip the unit
        // before asking what the text references.
        let typedUnitSymbol = NumericParsing.trailingUnit(in: rawText)
        let bodyText = typedUnitSymbol.map {
            String(rawText.trimmingCharacters(in: .whitespaces).dropLast($0.count))
        } ?? rawText
        let formula = additiveMM != nil || ExpressionEvaluator.identifiers(in: bodyText).isEmpty ? nil : rawText
        let isArcSweep = edit.kind == .angle && edit.refs.count == 1 && edit.refs.first.map {
            if case .arc? = sketchEntity($0.entityID, in: sketch) { return true }
            return false
        } == true
        let completesCircle = isArcSweep && parsed == 360
        // Linear dimensions are positive; a full arc turn converts to a circle.
        switch edit.kind {
        case .angle:
            let upperBound = isArcSweep ? 360.0 : 180.0
            guard parsed > 0, parsed < upperBound || completesCircle else {
                showNotice("Angle must be between 0° and \(Int(upperBound))°.")
                return
            }
        default:
            guard parsed > 0 else {
                showNotice("Dimension must be greater than zero.")
                return
            }
        }
        // Back to the document's units: radians for angles, millimetres for
        // lengths. A formula is NOT converted — its identifiers resolve against
        // document variables, which are already millimetres, so scaling the
        // result would double-convert.
        //
        // An explicit unit typed into the field ("20 cm", the keypad's unit
        // keys) beats the display unit: the evaluator drops the suffix before
        // parsing, so without this "20 cm" in an inches document meant 20
        // inches. `deg` is not a length and only makes sense on an angle.
        let typedUnit = Self.lengthUnit(forSuffix: typedUnitSymbol)
        let parsedMM: Double
        if let untouchedSeed {
            parsedMM = untouchedSeed
        } else if additiveMM != nil || edit.kind == .angle || formula != nil {
            parsedMM = parsed
        } else if let typedUnit {
            parsedMM = typedUnit.mm(fromDisplay: parsed)
        } else {
            parsedMM = CADPreferences.shared.unit.mm(fromDisplay: parsed)
        }
        let stored = edit.kind == .angle ? parsedMM * .pi / 180 : parsedMM
        var trimmedBody = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBody.hasPrefix("=") {
            trimmedBody = String(trimmedBody.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let expressionUnit = edit.kind == .angle ? "deg"
            : (typedUnit?.symbol ?? CADPreferences.shared.unit.symbol)
        let previousExpression = edit.dimensionID.flatMap { id in
            sketch.dimensions.first(where: { $0.id == id })?.displayExpression
        }
        let isArithmetic = Double(trimmedBody) == nil
        let retainedScalar = additiveMM != nil ? rawText : isArithmetic ? "(\(trimmedBody)) \(expressionUnit)"
            : "\(trimmedBody) \(expressionUnit)"
        let displayExpression = formula == nil && (isArithmetic || typedUnitSymbol != nil)
            ? (previousExpression == rawText ? rawText : retainedScalar) : nil

        if edit.isPendingRectangleBaseline {
            guard mode.sketchTool == .rect, let base = rectangleBaseline,
                  stored.isFinite, stored > 0 else { return }
            let direction = base.b - base.a
            let length = simd_length(direction)
            guard length > 1e-9 else { return }
            let end = base.a + direction / length * stored
            rectangleBaseline = (base.a, end)
            rectanglePreview = [.line(id: rectangleIDs[0], a: base.a, b: end)]
            rectangleBaselineDimension = dimensionCommitLocked
                ? SketchDimension(kind: .distance, refs: edit.refs, value: stored,
                                  formula: formula, displayExpression: displayExpression) : nil
            return
        }

        var proposed = sketch
        var setup: DocumentCommand
        let candidateDimensionID: UUID
        if let dimID = edit.dimensionID,
           let idx = proposed.dimensions.firstIndex(where: { $0.id == dimID }) {
            let before = proposed.dimensions[idx]
            var after = before
            if before.kind != edit.kind,
               (before.kind == .radius || before.kind == .diameter),
               (edit.kind == .radius || edit.kind == .diameter) {
                // Accepting a converted seed must not rewrite saved source or
                // history. Real edits adopt the displayed quantity and keep ID.
                if dimensionCommitLocked && untouchedSeed != nil { return }
                after.kind = edit.kind
            }
            after.value = stored
            after.formula = formula
            after.displayExpression = displayExpression
            // Accepting an unchanged driving value dismisses the editor, but
            // must not consume Undo or perturb geometry through another solve.
            // Unlocking and changes to the retained source remain real edits.
            if dimensionCommitLocked && after == before { return }
            if let side = edit.axisRectangleEdge {
                after.rectangleLabelEdges = Array(Set((before.rectangleLabelEdges ?? []) + [side])).sorted()
            }
            proposed.dimensions[idx] = after
            candidateDimensionID = dimID
            setup = UpdateSketchDimensionCommand(sketchID: sketchID, before: before, after: after)
        } else {
            let offset = edit.kind == .diameter
                ? edit.refs.first.flatMap { temporaryDiameterLabelOffsets[$0.entityID] } : nil
            let dim = SketchDimension(kind: edit.kind, refs: edit.refs, value: stored,
                                      formula: formula, labelOffset: offset,
                                      displayExpression: displayExpression,
                                      rectangleLabelEdges: edit.axisRectangleEdge.map { [$0] },
                                      rectangleDrivingEdge: edit.axisRectangleEdge)
            proposed.dimensions.append(dim)
            candidateDimensionID = dim.id
            setup = AddSketchDimensionCommand(sketchID: sketchID, dimension: dim)
        }

        // Over-constraint guard (spec §2.2): the solver refuses a dimension on
        // an already fully-solved region / one that conflicts with existing
        // dimensions. Refuse without applying or recording a history step.
        if SketchSolverBridge.residualNorm(proposed) > Self.overConstraintTolerance {
            // A rejected size is an expected sketch interaction, not a modal
            // application error. Native dismisses the editor and shows a notice.
            showNotice("This constraint would conflict with existing ones.")
            return
        }

        guard let candidate = proposed.dimensions.first(where: { $0.id == candidateDimensionID }) else { return }
        let editedIDs = Set(edit.refs.map(\.entityID))
        let preferredFarEdge: UUID?
        if edit.kind == .distance, editedIDs.count == 1, let editedID = editedIDs.first,
           let edges = RectangleConstruction.dimensionEdges(containing: editedID, in: sketch) {
            // Paired native workflows: baseline sizing keeps the lower side;
            // height sizing keeps the far baseline. Recover the component
            // even when its single edge was reselected after creation/reload.
            if editedID == edges[0] || editedID == edges[2] {
                preferredFarEdge = RectangleConstruction.baselineAnchor(
                    containing: editedID, in: sketch.entities)
            }
            else if editedID == edges[1] { preferredFarEdge = edges[2] }
            else { preferredFarEdge = nil }
        } else {
            preferredFarEdge = nil
        }
        // Only the first size of a freshly drawn, standalone line has live
        // evidence for a start-point preference. Reselection differs in native;
        // connected sketches and their existing rectangle intent remain untouched.
        let freshLinePoint: ConstraintRef?
        if edit.kind == .distance, edit.dimensionID == nil, mode.sketchTool == .line,
           editedIDs.count == 1, let id = editedIDs.first, id == freshLineSizingID,
           preferredFarEdge == nil,
           case .line? = sketch.entities.first(where: { $0.id == id }),
           sketch.constraints.contains(where: {
               ($0.kind == .horizontal || $0.kind == .vertical) &&
               $0.refs.contains(where: { $0.entityID == id })
           }),
           !sketch.constraints.contains(where: { constraint in
               constraint.refs.contains(where: { $0.entityID == id }) &&
               constraint.refs.contains(where: { $0.entityID != id })
           }),
           !sketch.dimensions.contains(where: { $0.refs.contains(where: { $0.entityID == id }) }) {
            freshLinePoint = .init(entityID: id, role: .endpointA)
        } else { freshLinePoint = nil }
        var solvedEntities = SketchSolverBridge.solveDimensionEdit(
            proposed, dimension: candidate, tolerance: Self.overConstraintTolerance,
            preservingLineID: preferredFarEdge, preservingPoint: freshLinePoint).entities
        // The lock key (Shapr3D's "locked dimension"). Locked — the default —
        // records the value as a driving dimension. Unlocked, the value still
        // drives the solve that runs above, so the geometry lands exactly where
        // it was asked to; it simply is not written down. Unlocking one that
        // already exists deletes it, which is what un-pinning a dimension means.
        var commands: [DocumentCommand] = []
        if completesCircle, let arcID = edit.refs.first?.entityID,
           let arcIndex = solvedEntities.firstIndex(where: { $0.id == arcID }),
           let conversion = ArcDimensionConversion.fullCircle(
                from: solvedEntities[arcIndex], dimensions: sketch.dimensions) {
            // The full-turn angle disappears with the arc. Keep entity and radius
            // dimension identities so other references and undo remain intact.
            solvedEntities[arcIndex] = conversion.circle
            for (index, dimension) in sketch.dimensions.enumerated().reversed()
                where conversion.removedAngleIDs.contains(dimension.id) {
                commands.append(RemoveSketchDimensionCommand(
                    sketchID: sketchID, dimension: dimension, index: index))
            }
            for after in conversion.updatedRadiusDimensions {
                if let before = sketch.dimensions.first(where: { $0.id == after.id }) {
                    commands.append(UpdateSketchDimensionCommand(sketchID: sketchID, before: before, after: after))
                }
            }
            selectedDimensionID = nil
        } else if dimensionCommitLocked {
            commands.append(setup)
        } else if let dimID = edit.dimensionID,
                  let idx = sketch.dimensions.firstIndex(where: { $0.id == dimID }) {
            commands.append(RemoveSketchDimensionCommand(
                sketchID: sketchID, dimension: sketch.dimensions[idx], index: idx))
        }
        for (before, after) in zip(sketch.entities, solvedEntities) where before != after {
            commands.append(UpdateSketchEntityCommand(
                sketchID: sketchID, before: before, after: after
            ))
        }
        guard !commands.isEmpty else { return }
        // Phase D: a dimension re-solves entity positions — the dependent-
        // feature rebuild lands in the SAME undo step (S6).
        session.performWithSketchRebuild(commands.count == 1
            ? commands[0]
            : CompositeCommand(title: "Dimension", commands: commands), sketchID: sketchID)
        if let id = freshLinePoint?.entityID { refreshChainAnchors(lastEntityID: id) }
        if mode.sketchTool == .circle, edit.kind == .radius,
           edit.refs.count == 1, let id = edit.refs.first?.entityID,
           case .circle? = sketchEntity(id, in: sketch) {
            selectedDimensionID = dimensionCommitLocked ? candidateDimensionID : nil
        }
        if mode.sketchTool == nil, !sketchTransformActive,
           edit.refs.count == 1, edit.kind == .radius || edit.kind == .diameter,
           let id = edit.refs.first?.entityID,
           case .circle? = sketchEntity(id, in: sketch) {
            clearCircleNumericSelection()
        }
        // A successful corner-size edit ends its point selection. Cancellation
        // and rejected values above retain the point, as in native sketching.
        if selectedMigratedRectangleCornerEdges != nil { selectedSketchPoints.removeAll() }
        if selectedMigratedRectangleEdges != nil { selectedSketchEntityIDs.removeAll() }
        if let pick = selectedAxisRectangleEdge, selectedSketchEntityIDs == [pick.id],
           selectedSketchPoints.isEmpty, edit.kind == .horizontal || edit.kind == .vertical,
           edit.refs.allSatisfy({ $0.entityID == pick.id }) {
            selectedSketchEntityIDs.removeAll()
            // Selection's observer clears its side; keep that presentation
            // metadata without restoring the entity or its manipulation handle.
            selectedAxisRectangleEdge = pick
            selectedDimensionID = dimensionCommitLocked ? candidateDimensionID : nil
        }
        session.save()
    }

    // MARK: - Make Construction / Make Regular (plan §B9, spec §3.3)

    /// True when every selected sketch entity is construction geometry
    /// (palette toggle state; the next toggle then makes them regular).
    var selectionIsConstruction: Bool {
        guard let sketch = activeSketch, !selectedSketchEntityIDs.isEmpty else { return false }
        return selectedSketchEntityIDs.allSatisfy { sketch.isConstruction($0) }
    }

    /// Bulk toggle on the selection: mixed/regular → all construction;
    /// all-construction → all regular.
    func toggleConstructionOnSelection() {
        guard case .sketching(let sketchID, _) = mode,
              let sketch = activeSketch,
              !selectedSketchEntityIDs.isEmpty
        else { return }
        session.perform(SetConstructionCommand(
            sketchID: sketchID,
            entityIDs: selectedSketchEntityIDs,
            isConstruction: !selectionIsConstruction,
            sketch: sketch
        ))
    }

    // MARK: - Measure tool (spec §16.3 v1: point-to-point)

    /// Notable points picked so far (0–2, world space). A third tap restarts.
    var measurePoints: [SIMD3<Double>] = []

    var measureResult: (distance: Double, deltas: SIMD3<Double>)? {
        guard measurePoints.count == 2 else { return nil }
        return MeasureKit.distance(a: measurePoints[0], b: measurePoints[1])
    }

    func toggleMeasure() {
        if case .measuring = mode {
            exitMeasure()
            return
        }
        if case .sketching = mode { finishSketch() }
        cancelTransientPicks()
        cancelTool()
        selection.removeAll()
        measurePoints.removeAll()
        mode = .measuring
    }

    func exitMeasure() {
        measurePoints.removeAll()
        if case .measuring = mode {
            mode = .idle
        }
    }

    private func handleMeasureTap(ray: Ray) {
        guard let point = nearestNotablePoint(to: ray) else { return }
        if measurePoints.count >= 2 {
            measurePoints.removeAll() // next tap restarts the measurement
        }
        measurePoints.append(point)
    }

    /// Nearest notable point to the pick ray within a screen-ish tolerance:
    /// sketch snap points (SnapEngine) plus body vertices (render positions).
    private func nearestNotablePoint(to ray: Ray) -> SIMD3<Double>? {
        let tolerance = max(0.5, 30 * worldPerPoint)
        var best: (point: SIMD3<Double>, distance: Double)?
        func consider(_ p: SIMD3<Double>) {
            let pf = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
            let t = simd_dot(pf - ray.origin, ray.direction)
            guard t > 0 else { return } // behind the camera
            let d = Double(simd_length(pf - ray.point(at: t)))
            if d <= tolerance, best == nil || d < best!.distance {
                best = (p, d)
            }
        }
        for sketch in session.document.sketches where !sketch.isHidden {
            for local in SnapEngine.snapPoints(of: sketch) {
                consider(sketch.plane.toWorld(local))
            }
        }
        for body in session.document.bodies where !body.isHidden {
            for position in body.render.positions {
                consider(body.transform.applying(to: SIMD3<Double>(position)))
            }
        }
        return best?.point
    }

    // MARK: - Selection info bar (spec §16.3: selection info at screen bottom)

    struct MeasurementRow: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    /// Measurements for the current selection, shown in the bottom info strip.
    var selectionMeasurements: [MeasurementRow] {
        _ = session.changeCount
        // An Items-selected construction plane reads "1 plane" (Shapr3D).
        if selectedPlane != nil {
            return [MeasurementRow(label: "Selected", value: "1 plane")]
        }
        switch mode {
        case .idle where selection.isEmpty && selectedImage == nil:
            // Items selection survives Exit. Resolve its IDs against their
            // owners rather than activeSketch (which is nil in model mode).
            let entities = session.document.sketches.flatMap(\.entities).filter {
                selectedSketchEntityIDs.contains($0.id)
            }
            guard !entities.isEmpty else { return [] }
            let edges = entities.reduce(0) { count, entity in
                switch entity {
                case .rect: return count + 4
                case .polygon(_, _, _, let sides, _): return count + sides
                default: return count + 1
                }
            }
            return [
                MeasurementRow(label: "Edges", value: "\(edges)"),
                MeasurementRow(label: entities.count == 1 ? "Length" : "Total Length",
                    value: Self.formattedLength(entities.reduce(0.0) { $0 + MeasureKit.length(of: $1) })),
            ]
        case .faceSelected(let id):
            guard let body = session.document.body(with: id),
                  let context = toolContext
            else { return [] }
            let area = MeasureKit.faceArea(
                body.render, triangles: context.faceTriangles, scale: body.transform.scale
            )
            // Profile loop is already in world scale (built with scale applied).
            let perimeter = MeasureKit.perimeter(of: context.profile.loop)
            return [
                MeasurementRow(label: "Area", value: Self.formattedArea(area)),
                MeasurementRow(label: "Perimeter", value: Self.formattedLength(perimeter)),
            ]
        case .selected(let id), .editingPrimitive(let id):
            if selection.count > 1 {
                // Multi-selection (plan §B13): count + combined world bounds.
                let bodies = selection.compactMap { session.document.body(with: $0) }
                guard let box = MeasureKit.boundingBox(bodies: bodies) else { return [] }
                let size = box.max - box.min
                return [
                    MeasurementRow(label: "Selected", value: "\(bodies.count) bodies"),
                    MeasurementRow(
                        label: "Bounds",
                        value: {
                            let u = CADPreferences.shared.unit
                            return String(
                                format: "%.2f × %.2f × %.2f %@",
                                u.display(fromMM: Double(size.x)),
                                u.display(fromMM: Double(size.y)),
                                u.display(fromMM: Double(size.z)), u.symbol)
                        }()
                    ),
                ]
            }
            guard let body = session.document.body(with: id),
                  let box = MeasureKit.boundingBox(bodies: [body])
            else { return [] }
            let volume = MeasureKit.volume(of: body)   // B-rep-exact when analytic
            let size = box.max - box.min
            return [
                MeasurementRow(label: "Volume", value: Self.formattedVolume(volume)),
                MeasurementRow(
                    label: "Bounds",
                    value: {
                            let u = CADPreferences.shared.unit
                            return String(
                                format: "%.2f × %.2f × %.2f %@",
                                u.display(fromMM: Double(size.x)),
                                u.display(fromMM: Double(size.y)),
                                u.display(fromMM: Double(size.z)), u.symbol)
                        }()
                ),
            ]
        case .sketching:
            let entities = activeSketch?.entities.filter {
                selectedSketchEntityIDs.contains($0.id)
            } ?? []
            guard !entities.isEmpty else { return [] }
            let total = entities.reduce(0.0) { $0 + MeasureKit.length(of: $1) }
            var rows = [MeasurementRow(
                label: entities.count == 1 ? "Length" : "Total Length",
                value: Self.formattedLength(total)
            )]
            if entities.count == 1, let radius = MeasureKit.radius(of: entities[0]) {
                rows.append(MeasurementRow(
                    label: "Radius", value: Self.formattedLength(radius)
                ))
            }
            // Two parallel lines: Shapr3D adds the distance between them
            // (observed 2026-09-13: "2 edges  279,925.293 mm  22,558.0444 mm").
            if let distance = Self.parallelLineDistance(entities) {
                rows.append(MeasurementRow(label: "Distance", value: Self.formattedLength(distance)))
            }
            return rows
        case .pickingBlendEdges:
            // Chamfer/Fillet pick (Phase E): edge count + total world length.
            guard !blendSelectedEdges.isEmpty else { return [] }
            let scale = blendBodyID
                .flatMap { session.document.body(with: $0)?.transform.scale } ?? 1
            let total = blendSelectedEdges.reduce(0.0) { $0 + Double($1.length) } * scale
            return [
                MeasurementRow(label: "Edges", value: "\(blendSelectedEdges.count)"),
                MeasurementRow(
                    label: blendSelectedEdges.count == 1 ? "Length" : "Total Length",
                    value: Self.formattedLength(total)
                ),
            ]
        case .pickingShellFaces:
            // Shell pick (Phase E): open-face count while faces are toggled.
            guard !shellSelectedFaces.isEmpty else { return [] }
            return [
                MeasurementRow(label: "Open Faces", value: "\(shellSelectedFaces.count)"),
            ]
        case .pickingDeleteFaces:
            guard !deleteFaceTargets.isEmpty else { return [] }
            return [
                MeasurementRow(label: "Faces", value: "\(deleteFaceTargets.count)"),
            ]
        case .pickingReplaceFace:
            guard let face = replaceSourceFace else { return [] }
            var area = abs(Profile.signedArea(face.outline))
            for hole in face.holes { area -= abs(Profile.signedArea(hole)) }
            return [
                MeasurementRow(label: "Face Area",
                               value: Self.formatted(max(area, 0), unit: "mm²")),
            ]
        default:
            return []
        }
    }

    static func formatted(_ value: Double, unit: String) -> String {
        String(format: "%.2f %@", value, unit)
    }

    // Unit-aware readouts (spec §17): the document stays mm; only display
    // converts. Reading `CADPreferences.shared.unit` inside a view body is
    // Observation-tracked, so switching units re-renders every readout.
    /// The perpendicular distance between exactly two parallel (within 0.5°)
    /// lines; nil for any other selection.
    nonisolated static func parallelLineDistance(_ entities: [SketchEntity]) -> Double? {
        guard entities.count == 2,
              case let .line(_, a1, b1) = entities[0],
              case let .line(_, a2, b2) = entities[1] else { return nil }
        let d1 = b1 - a1, d2 = b2 - a2
        let l1 = simd_length(d1), l2 = simd_length(d2)
        guard l1 > 1e-9, l2 > 1e-9 else { return nil }
        let u = d1 / l1
        let cross = abs(u.x * d2.y - u.y * d2.x) / l2
        guard cross < sin(0.5 * .pi / 180) else { return nil }
        let w = a2 - a1
        return abs(w.x * u.y - w.y * u.x)
    }

    static func formattedLength(_ mm: Double) -> String {
        CADPreferences.shared.unit.lengthString(fromMM: mm)
    }
    static func formattedArea(_ mm2: Double) -> String {
        CADPreferences.shared.unit.areaString(fromMM2: mm2)
    }
    static func formattedVolume(_ mm3: Double) -> String {
        CADPreferences.shared.unit.volumeString(fromMM3: mm3)
    }

    // MARK: - Insert Image (plan §B10, spec §6.3)

    /// Selected inserted image; shows the gizmo + image bar while idle.
    var selectedImageID: InsertedImageID?

    /// Picked image bytes awaiting a plane tap (`.pickingImagePlane`).
    var pendingImageData: Data?

    /// New images size to this max dimension (mm), preserving aspect.
    nonisolated static let insertedImageMaxDimension = 50.0

    /// The selected image, while the editor is idle (other modes hide the
    /// image gizmo/bar without dropping the selection).
    var selectedImage: InsertedImage? {
        guard mode == .idle, let id = selectedImageID else { return nil }
        _ = session.changeCount
        return session.document.images.first { $0.id == id }
    }

    /// Arm the plane pick for freshly picked image bytes (Photos or Files).
    func beginInsertImage(data: Data) {
        cancelTransientPicks()
        cancelTool()
        if case .sketching = mode { finishSketch() }
        selection.removeAll()
        selectedImageID = nil
        pendingImageData = data
        mode = .pickingImagePlane
    }

    func cancelImagePlanePick() {
        pendingImageData = nil
        if case .pickingImagePlane = mode {
            mode = .idle
        }
    }

    /// Tap routing while the image plane tiles are up: a tile hosts the
    /// image; anywhere else defaults to the ground plane.
    private func handleImagePlanePick(ray: Ray) {
        guard let data = pendingImageData else {
            mode = .idle
            return
        }
        let tiles = worldPlaneTiles + constructionPlaneTiles
        let plane = PlanePicking.pick(ray: ray, tiles: tiles)?.tile.plane ?? .ground
        pendingImageData = nil
        insertImage(data: data, on: plane)
    }

    /// Width × height (mm) for a picture of the given pixel size, scaled so
    /// the larger side is `maxDimension` with aspect preserved.
    nonisolated static func insertedImageSize(
        pixelWidth: Double, pixelHeight: Double,
        maxDimension: Double = EditorViewModel.insertedImageMaxDimension
    ) -> (width: Double, height: Double) {
        guard pixelWidth > 0, pixelHeight > 0 else {
            return (maxDimension, maxDimension)
        }
        let scale = maxDimension / max(pixelWidth, pixelHeight)
        return (pixelWidth * scale, pixelHeight * scale)
    }

    /// Pixel size decoded from the encoded bytes (ImageIO), or nil when the
    /// bytes are not a decodable picture.
    nonisolated static func imagePixelSize(of data: Data) -> (width: Double, height: Double)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double
        else { return nil }
        return (width, height)
    }

    /// Place the picture on `plane` as an InsertedImage (~50 mm max
    /// dimension, aspect preserved) and select it.
    func insertImage(data: Data, on plane: SketchPlane) {
        guard let pixels = Self.imagePixelSize(of: data) else {
            mode = .idle
            errorMessage = "Couldn't read the selected image."
            return
        }
        let size = Self.insertedImageSize(pixelWidth: pixels.width, pixelHeight: pixels.height)
        let image = InsertedImage(
            name: session.document.uniqueImageName(),
            plane: plane,
            width: size.width,
            height: size.height,
            imageData: data
        )
        session.perform(AddImageCommand(image: image))
        session.save()
        selectedImageID = image.id
        mode = .idle
        cameraControl?.fitTo(bounds: Self.imageBounds(image))
    }

    /// World AABB of an image quad (zoom-to and post-insert framing).
    nonisolated static func imageBounds(
        _ image: InsertedImage
    ) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        let hw = image.width / 2
        let hh = image.height / 2
        let corners = [
            SIMD2(-hw, -hh), SIMD2(hw, -hh), SIMD2(hw, hh), SIMD2(-hw, hh),
        ].map { image.plane.toWorld($0) }
        var lo = SIMD3<Float>(Float(corners[0].x), Float(corners[0].y), Float(corners[0].z))
        var hi = lo
        for corner in corners {
            let p = SIMD3<Float>(Float(corner.x), Float(corner.y), Float(corner.z))
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    /// Nearest visible image quad under the ray (tap routing).
    private func imageHit(ray: Ray) -> (id: InsertedImageID, distance: Float)? {
        var best: (id: InsertedImageID, distance: Float)?
        for image in session.document.images where !image.isHidden {
            let plane = image.plane
            let origin = SIMD3<Float>(
                Float(plane.origin.x), Float(plane.origin.y), Float(plane.origin.z)
            )
            let n = plane.normal
            let normal = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
            guard let t = ray.intersect(planePoint: origin, planeNormal: normal) else {
                continue
            }
            let world = ray.point(at: t)
            let local = plane.toLocal(SIMD3(Double(world.x), Double(world.y), Double(world.z)))
            guard abs(local.x) <= image.width / 2, abs(local.y) <= image.height / 2 else {
                continue
            }
            if best == nil || t < best!.distance {
                best = (image.id, t)
            }
        }
        return best
    }

    // MARK: Image editing (gizmo drag, size, opacity — UpdateImageCommand)

    /// Image snapshot at the start of a coalesced interaction (gizmo drag or
    /// opacity-slider scrub); the whole interaction is one undo step.
    private var imageInteractionBaseline: InsertedImage?
    /// True once the interaction pushed its command (later edits amend it).
    private var imageInteractionPerformed = false

    func beginImageInteraction() {
        imageInteractionBaseline = selectedImage
        imageInteractionPerformed = false
    }

    func endImageInteraction() {
        guard imageInteractionBaseline != nil else { return }
        imageInteractionBaseline = nil
        imageInteractionPerformed = false
        session.save()
    }

    /// Route an edited snapshot through UpdateImageCommand: inside an
    /// interaction the first change performs and the rest amend-coalesce;
    /// outside (typed field edits) each change is its own undo step.
    private func commitImageEdit(_ after: InsertedImage, title: String) {
        if let baseline = imageInteractionBaseline {
            guard after != baseline else { return }
            let command = UpdateImageCommand(before: baseline, after: after, title: title)
            if imageInteractionPerformed {
                session.amend(command)
            } else {
                session.perform(command)
                imageInteractionPerformed = true
            }
        } else if let current = selectedImage, after != current {
            session.perform(UpdateImageCommand(before: current, after: after, title: title))
            session.save()
        }
    }

    /// Gizmo drag: translate in-plane by the world delta's in-plane component.
    private func updateImageMove(delta: SIMD3<Float>) {
        guard let baseline = imageInteractionBaseline else { return }
        let worldDelta = SIMD3<Double>(Double(delta.x), Double(delta.y), Double(delta.z))
        let plane = baseline.plane
        let du = simd_dot(worldDelta, plane.xAxis)
        let dv = simd_dot(worldDelta, plane.yAxis)
        var after = baseline
        after.plane.origin = plane.origin + plane.xAxis * du + plane.yAxis * dv
        commitImageEdit(after, title: "Move Image")
    }

    /// Copy badge on an image (spec §5.1 convention): the drag moves a clone.
    private func duplicateSelectedImageForDrag() {
        guard let image = selectedImage else { return }
        let clone = InsertedImage(
            name: session.document.uniqueImageName(),
            plane: image.plane,
            width: image.width,
            height: image.height,
            opacity: image.opacity,
            imageData: image.imageData
        )
        session.perform(AddImageCommand(image: clone))
        selectedImageID = clone.id
    }

    /// Opacity slider (0…1); wrap scrubs in begin/endImageInteraction.
    func setImageOpacity(_ value: Double) {
        guard var after = imageInteractionBaseline ?? selectedImage else { return }
        after.opacity = min(max(value, 0), 1)
        commitImageEdit(after, title: "Image Opacity")
    }

    /// Size field: rescale so the larger side is `value` mm, keeping aspect.
    func setImageMaxDimension(_ value: Double) {
        guard let current = selectedImage, value > 0.01 else { return }
        let size = Self.insertedImageSize(
            pixelWidth: current.width, pixelHeight: current.height, maxDimension: value
        )
        var after = current
        after.width = size.width
        after.height = size.height
        commitImageEdit(after, title: "Resize Image")
    }

    /// Row tap in the Items panel: select the image (idle-mode gizmo + bar).
    func selectImageItem(_ id: InsertedImageID) {
        guard session.document.imageIndex(of: id) != nil else { return }
        if case .sketching = mode { finishSketch() }
        cancelTransientPicks()
        cancelTool()
        selection.removeAll()
        selectedPlaneID = nil
        selectedImageID = id
        mode = .idle
    }

    func setImageHidden(_ id: InsertedImageID, hidden: Bool) {
        session.perform(SetItemVisibilityCommand(imageID: id, isHidden: hidden))
    }

    func renameImage(_ id: InsertedImageID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = session.document.images.first(where: { $0.id == id })?.name,
              !trimmed.isEmpty, trimmed != current
        else { return }
        session.perform(RenameItemCommand(imageID: id, before: current, after: trimmed))
    }

    func deleteImage(_ id: InsertedImageID) {
        guard let command = RemoveImageCommand(id: id, document: session.document) else { return }
        endImageInteraction()
        session.perform(command)
        if selectedImageID == id {
            selectedImageID = nil
        }
        session.save()
    }

    func zoomToImage(_ id: InsertedImageID) {
        guard let image = session.document.images.first(where: { $0.id == id }) else { return }
        cameraControl?.fitTo(bounds: Self.imageBounds(image))
    }

    // MARK: - Items Manager folders (spec §11)

    var itemFolderTree: ItemFolderTree { ItemFolderTree(session.document.itemFolders) }

    /// New folder. With no explicit members it takes the current body
    /// selection (Shapr3D: "create folder from selection").
    @discardableResult
    func createItemFolder(named name: String? = nil, in parent: ItemFolderID? = nil,
                          containing keys: [DocumentItemKey]? = nil) -> ItemFolderID {
        let tree = itemFolderTree
        let members = keys ?? session.document.bodies
            .filter { selection.contains($0.id) }
            .map { DocumentItemKey.body($0.id) }
        let folder = ItemFolder(name: name ?? tree.uniqueName(), parentID: parent, members: members)
        session.perform(SetItemFoldersCommand(
            title: "New Folder", before: tree.folders, after: tree.adding(folder)))
        return folder.id
    }

    func renameItemFolder(_ id: ItemFolderID, to newName: String) {
        let tree = itemFolderTree
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = tree.folder(id)?.name, !trimmed.isEmpty, trimmed != current else { return }
        session.perform(SetItemFoldersCommand(
            title: "Rename Folder", before: tree.folders, after: tree.renaming(id, to: trimmed)))
    }

    /// Move items into a folder (`nil` = out of every folder).
    func moveItems(_ keys: [DocumentItemKey], toFolder destination: ItemFolderID?) {
        let tree = itemFolderTree
        let after = tree.moving(keys, to: destination)
        guard after != tree.folders else { return }
        let title = destination.flatMap { tree.folder($0)?.name }
            .map { "Move to \($0)" } ?? "Move out of Folder"
        session.perform(SetItemFoldersCommand(title: title, before: tree.folders, after: after))
    }

    func moveItemFolder(_ id: ItemFolderID, into parent: ItemFolderID?) {
        let tree = itemFolderTree
        guard tree.canMove(folder: id, into: parent), tree.parent(of: id) != parent else { return }
        session.perform(SetItemFoldersCommand(
            title: "Move Folder", before: tree.folders, after: tree.reparenting(id, to: parent)))
    }

    /// Remove the folder only; what it held moves up a level.
    func removeItemFolder(_ id: ItemFolderID) {
        let tree = itemFolderTree
        guard tree.folder(id) != nil else { return }
        session.perform(SetItemFoldersCommand(
            title: "Remove Folder", before: tree.folders, after: tree.removingKeepingContents(id)))
    }

    /// Delete the folder, its subfolders and every item inside — one undo
    /// step. Mode/tool cleanup mirrors `deleteItem` for each kind.
    func deleteItemFolderAndItems(_ id: ItemFolderID) {
        let tree = itemFolderTree
        guard tree.folder(id) != nil else { return }
        let keys = tree.keys(inSubtree: id)
        var bodyIDs = Set<BodyID>()
        // Leave any state that points at a doomed item BEFORE snapshotting
        // the document for the delete commands (finishing a sketch can edit it).
        for key in keys {
            switch key {
            case .body(let bodyID):
                bodyIDs.insert(bodyID)
            case .sketch(let sketchID):
                if toolContext?.sketchID == sketchID { cancelTool() }
                if case .sketching(let active, _) = mode, active == sketchID { finishSketch() }
            case .image(let imageID):
                endImageInteraction()
                if selectedImageID == imageID { selectedImageID = nil }
            case .plane, .axis:
                break
            }
        }
        if !bodyIDs.isEmpty {
            cancelTransientPicks()
            if let source = toolContext?.sourceBody, bodyIDs.contains(source) { cancelTool() }
            selection.subtract(bodyIDs)
            switch mode {
            case .editingPrimitive(let selected) where bodyIDs.contains(selected),
                 .selected(let selected) where bodyIDs.contains(selected),
                 .faceSelected(let selected) where bodyIDs.contains(selected):
                mode = .idle
            case .pickingBooleanTool(_, let target) where bodyIDs.contains(target):
                mode = .idle
            case .pickingSplitCutter(let target) where bodyIDs.contains(target):
                mode = .idle
            default:
                break
            }
        }
        let document = session.document
        var commands: [DocumentCommand] = [SetItemFoldersCommand(
            title: "Delete Folder", before: tree.folders, after: tree.removingSubtree(id))]
        for key in keys {
            switch key {
            case .body:
                break
            case .sketch(let sketchID):
                if let command = DeleteSketchCommand(id: sketchID, document: document) {
                    commands.append(command)
                }
            case .plane(let planeID):
                if let command = DeletePlaneCommand(id: planeID, document: document) {
                    commands.append(command)
                }
            case .axis(let axisID):
                if let command = DeleteAxisCommand(id: axisID, document: document) {
                    commands.append(command)
                }
            case .image(let imageID):
                if let command = RemoveImageCommand(id: imageID, document: document) {
                    commands.append(command)
                }
            }
        }
        let liveBodies = bodyIDs.filter { document.body(with: $0) != nil }
        if !liveBodies.isEmpty {
            commands.append(DeleteBodiesCommand(ids: liveBodies, document: document))
        }
        session.perform(CompositeCommand(title: "Delete Folder", commands: commands))
        session.save()
    }

    /// Whether a scene item is hidden; nil when the item no longer exists.
    func isItemHidden(_ key: DocumentItemKey) -> Bool? {
        let document = session.document
        switch key {
        case .body(let id): return document.body(with: id)?.isHidden
        case .sketch(let id): return document.sketches.first { $0.id == id }?.isHidden
        case .plane(let id): return document.planes.first { $0.id == id }?.isHidden
        case .axis(let id): return document.axes.first { $0.id == id }?.isHidden
        case .image(let id): return document.images.first { $0.id == id }?.isHidden
        }
    }

    /// A folder reads hidden when every item in its subtree is hidden.
    func itemFolderIsHidden(_ id: ItemFolderID) -> Bool {
        let states = itemFolderTree.keys(inSubtree: id).compactMap(isItemHidden)
        return !states.isEmpty && states.allSatisfy { $0 }
    }

    /// The folder eye: hide everything inside, or show everything inside,
    /// as one undo step.
    func setItemFolderHidden(_ id: ItemFolderID, hidden: Bool) {
        var commands: [DocumentCommand] = []
        for key in itemFolderTree.keys(inSubtree: id) {
            guard let current = isItemHidden(key), current != hidden else { continue }
            switch key {
            case .body(let bodyID):
                commands.append(SetItemVisibilityCommand(item: .body(bodyID), isHidden: hidden))
            case .sketch(let sketchID):
                commands.append(SetItemVisibilityCommand(item: .sketch(sketchID), isHidden: hidden))
            case .plane(let planeID):
                commands.append(SetItemVisibilityCommand(item: .plane(planeID), isHidden: hidden))
            case .axis(let axisID):
                commands.append(SetAxisHiddenCommand(id: axisID, hidden: hidden))
            case .image(let imageID):
                commands.append(SetItemVisibilityCommand(imageID: imageID, isHidden: hidden))
            }
        }
        guard !commands.isEmpty else { return }
        session.perform(CompositeCommand(
            title: hidden ? "Hide Folder" : "Show Folder", commands: commands))
    }

    // MARK: - Items Manager (spec §11)

    /// Body row tap: select the body (primitive rows open dimension editing).
    func selectItemBody(_ id: BodyID) {
        guard let body = session.document.body(with: id) else { return }
        if case .sketching = mode { finishSketch() }
        cancelTransientPicks()
        cancelTool()
        selectedImageID = nil
        selection = [id]
        mode = body.primitive != nil ? .editingPrimitive(id) : .selected(id)
    }

    /// Items entry is distinct from dimension/history-driven sketch reopening.
    func selectItemSketch(_ id: SketchID) {
        guard session.document.sketches.contains(where: { $0.id == id }) else { return }
        openItemSketch(id)
        guard let sketch = activeSketch, sketch.id == id else { return }
        selectedSketchPoints.removeAll()
        selectedSketchEntityIDs = Set(sketch.entities.map(\.id))
        itemSelectedSketchID = id
    }

    /// Construction plane selected from its Items row. Highlighted while
    /// idle; the next sketch tool starts on it (see `startSketch`).
    var selectedPlaneID: ConstructionPlaneID?

    /// The selected construction plane, while the editor is idle.
    var selectedPlane: ConstructionPlane? {
        guard mode == .idle, let id = selectedPlaneID else { return nil }
        _ = session.changeCount
        return session.document.planes.first { $0.id == id }
    }

    /// Plane row tap: select the plane (Shapr3D) rather than doing nothing;
    /// Sketch then enters a new sketch on it.
    func selectItemPlane(_ id: ConstructionPlaneID) {
        guard session.document.planes.contains(where: { $0.id == id }) else { return }
        if case .sketching = mode { finishSketch() }
        cancelTransientPicks()
        cancelTool()
        selection.removeAll()
        selectedImageID = nil
        selectedSketchEntityIDs.removeAll()
        mode = .idle
        selectedPlaneID = id
    }

    /// Sketch row tap: enter sketch mode on it (hidden sketches render while
    /// active).
    func openItemSketch(_ id: SketchID) {
        guard let sketch = session.document.sketches.first(where: { $0.id == id }) else { return }
        if case .sketching(let current, _) = mode, current == id { return }
        if case .sketching = mode { finishSketch() }
        itemSelectedSketchID = nil
        selectedSketchEntityIDs.removeAll()
        cancelTransientPicks()
        cancelTool()
        selectedImageID = nil
        selection.removeAll()
        // Re-opening an existing sketch starts with no tool armed (Shapr3D):
        // taps select, drags edit or orbit; arm a tool from the palette to draw.
        mode = .sketching(id, tool: nil)
        cameraControl?.moveCameraHeadOn(to: sketch.plane)
    }

    func setItemHidden(_ item: DocumentItemRef, hidden: Bool) {
        session.perform(SetItemVisibilityCommand(item: item, isHidden: hidden))
    }

    func renameItem(_ item: DocumentItemRef, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let current: String?
        switch item {
        case .body(let id):
            current = session.document.body(with: id)?.name
        case .sketch(let id):
            current = session.document.sketches.first { $0.id == id }?.name
        case .plane:
            current = nil // planes are unnamed in v1
        }
        guard let current, !trimmed.isEmpty, trimmed != current else { return }
        session.perform(RenameItemCommand(item: item, before: current, after: trimmed))
    }

    func deleteItem(_ item: DocumentItemRef) {
        switch item {
        case .body(let id):
            if toolContext?.sourceBody == id { cancelTool() }
            // Any transient pick may reference the body (rotate baseline,
            // pattern source, blend/shell preview, boolean/split target) —
            // cancel them ALL before deleting. The old conditional cancel
            // missed blend/shell and left a ghost preview of the deleted
            // body with the mode stuck (2026-08-25 review, S3); every
            // cancel is a no-op outside its own mode, so unconditional is
            // safe.
            cancelTransientPicks()
            session.perform(DeleteBodiesCommand(ids: [id], document: session.document))
            selection.remove(id)
            switch mode {
            case .editingPrimitive(let selected) where selected == id,
                 .selected(let selected) where selected == id,
                 .faceSelected(let selected) where selected == id:
                mode = .idle
            case .pickingBooleanTool(_, let target) where target == id:
                mode = .idle
            case .pickingSplitCutter(let target) where target == id:
                mode = .idle
            default:
                break
            }
        case .sketch(let id):
            if toolContext?.sketchID == id { cancelTool() }
            if case .sketching(let active, _) = mode, active == id { finishSketch() }
            guard let command = DeleteSketchCommand(id: id, document: session.document) else { return }
            session.perform(command)
        case .plane(let id):
            guard let command = DeletePlaneCommand(id: id, document: session.document) else { return }
            session.perform(command)
        }
        session.save()
    }

    /// "Zoom to": fit the camera to the item's world AABB.
    // MARK: Construction-axis item actions (spec §6.2)
    //
    // Axes stay OUT of `DocumentItemRef` on purpose, for the reason its own
    // comment gives about images: adding a case there ripples through every
    // exhaustive switch over it. Dedicated methods, like the image ones.

    func setAxisHidden(_ id: ConstructionAxisID, hidden: Bool) {
        session.perform(SetAxisHiddenCommand(id: id, hidden: hidden))
    }

    func renameAxis(_ id: ConstructionAxisID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let command = RenameAxisCommand(id: id, to: trimmed, document: session.document),
              command.before != trimmed
        else { return }
        session.perform(command)
    }

    func deleteAxis(_ id: ConstructionAxisID) {
        guard let command = DeleteAxisCommand(id: id, document: session.document) else { return }
        session.perform(command)
    }

    func zoomToAxis(_ id: ConstructionAxisID) {
        guard let axis = session.document.axes.first(where: { $0.id == id }) else { return }
        let (start, end) = axis.endpoints
        let lo = simd_min(start, end), hi = simd_max(start, end)
        cameraControl?.fitTo(bounds: (
            SIMD3(Float(lo.x), Float(lo.y), Float(lo.z)),
            SIMD3(Float(hi.x), Float(hi.y), Float(hi.z))
        ))
    }

    func zoomToItem(_ item: DocumentItemRef) {
        guard let bounds = itemBounds(item) else { return }
        cameraControl?.fitTo(bounds: bounds)
    }

    private func itemBounds(_ item: DocumentItemRef) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var points: [SIMD3<Float>] = []
        switch item {
        case .body(let id):
            guard let body = session.document.body(with: id) else { return nil }
            let bounds = Self.worldBounds(of: body)
            return (
                SIMD3(Float(bounds.min.x), Float(bounds.min.y), Float(bounds.min.z)),
                SIMD3(Float(bounds.max.x), Float(bounds.max.y), Float(bounds.max.z))
            )
        case .sketch(let id):
            guard let sketch = session.document.sketches.first(where: { $0.id == id }) else {
                return nil
            }
            points = SketchTessellator.segments(for: sketch.entities, on: sketch.plane)
        case .plane(let id):
            guard let plane = session.document.planes.first(where: { $0.id == id }) else {
                return nil
            }
            let h = plane.size / 2
            points = [SIMD2(-h, -h), SIMD2(h, -h), SIMD2(h, h), SIMD2(-h, h)].map {
                (corner: SIMD2<Double>) -> SIMD3<Float> in
                let world = plane.plane.toWorld(corner)
                return SIMD3(Float(world.x), Float(world.y), Float(world.z))
            }
        }
        guard var lo = points.first else { return nil }
        var hi = lo
        for p in points {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    /// 32×24 four-quadrant test PNG for the OS3D_DEBUG_SEED_IMAGE hook —
    /// generated bytes, decodable by ImageIO, tiny enough to inline.
    nonisolated static let debugSeedImagePNG = Data(base64Encoded: [
        "iVBORw0KGgoAAAANSUhEUgAAACAAAAAYCAIAAAAUMWhjAAAANElEQVR42mN4VqFBEtKoeEYSYhi1",
        "YNSCUQtGLSDCAo0tUSShDydsSEKjFoxaMGrBqAVEIABHmai9SdsP8AAAAABJRU5ErkJggg==",
    ].joined()) ?? Data()

    /// Debug hook (OS3D_DEBUG_SEED): seed and select a box so automated
    /// screenshots can exercise selection/gizmo states. Compiled out of
    /// Release — the seed paths and their assets must not ship (2026-08-25
    /// review / readiness audit §5).
    func debugSeedIfRequested() {
        #if DEBUG
        // OS3D_DEBUG_SEED_IMAGE (plan §B10 UI tests): seed a reference image
        // on the ground plane so the insert flow is testable without the
        // Photos/Files pickers. Left unselected — tests exercise tap-select.
        if ProcessInfo.processInfo.environment["OS3D_DEBUG_SEED_IMAGE"] != nil,
           session.document.images.isEmpty {
            insertImage(data: Self.debugSeedImagePNG, on: .ground)
            selectedImageID = nil
        }
        // OS3D_DEBUG_SEED_CYLINDER: seed a circle extrude so screenshots show the
        // OCCT B-rep render path (a true smooth cylinder). Mirrors evalExtrude.
        if ProcessInfo.processInfo.environment["OS3D_DEBUG_SEED_CYLINDER"] != nil,
           session.document.bodies.isEmpty {
            var seedDoc = session.document
            let radius = 3.0
            let loop = (0..<48).map { i -> SIMD2<Double> in
                let a = Double(i) / 48 * 2 * .pi
                return SIMD2(cos(a), sin(a)) * radius
            }
            let profile = Profile(loop: loop, kind: .circle(center: .zero, radius: radius),
                                  sourceEntityIDs: [])
            let plane = SketchPlane.ground
            let solid = KernelOps.extrude(profile: profile, holes: [], in: plane,
                                          distance: 5, symmetric: false)
            var body = Body(name: "Cylinder", transform: .identity, primitive: nil,
                            euclidMesh: solid, revision: seedDoc.nextRevision())
            let z = OCCTKernel.extrudeZRange(distance: 5, symmetric: false)
            // `adoptBRep`, not just a smooth render mesh. This hook used to
            // call `cylinderRenderMesh` and stop there, which LOOKED like the
            // real extrude — same round cylinder on screen — while leaving
            // `brep` nil. Anything that asks the body for its analytic solid
            // (STEP export, an OCCT fillet, a boolean staying round) then
            // behaved differently under the seed than in the app, which is
            // the one thing a debug seed must never do.
            if let handle = OCCTKernel.extrudeShape(
                outerLoop: profile.loop,
                outerConic: OCCTKernel.ConicSpec(center: .zero, radius: radius),
                holes: [], zMin: z.zMin, zMax: z.zMax,
                origin: plane.origin, xAxis: plane.xAxis,
                yAxis: plane.yAxis, normal: plane.normal) {
                body.adoptBRep(handle)
            }
            body.material = BodyMaterialSpec.default
            session.perform(AddBodyCommand(body: body))
            return
        }

        // OS3D_DEBUG_SEED_BOOLEAN: cylinder − offset cylinder, to show a BOOLEAN
        // result staying round through the OCCT source-of-truth path.
        if ProcessInfo.processInfo.environment["OS3D_DEBUG_SEED_BOOLEAN"] != nil,
           session.document.bodies.isEmpty {
            var seedDoc = session.document
            let plane = SketchPlane.ground
            func ring(_ r: Double, _ cx: Double) -> [SIMD2<Double>] {
                (0..<48).map { i in
                    let a = Double(i) / 48 * 2 * .pi
                    return SIMD2(cx + cos(a) * r, sin(a) * r)
                }
            }
            let za = OCCTKernel.extrudeZRange(distance: 5, symmetric: false)
            let bigProfile = Profile(loop: ring(3, 0), kind: .circle(center: .zero, radius: 3),
                                     sourceEntityIDs: [])
            let cutProfile = Profile(loop: ring(1.5, 2), kind: .circle(center: SIMD2(2, 0), radius: 1.5),
                                     sourceEntityIDs: [])
            let euclidBig = KernelOps.extrude(profile: bigProfile, holes: [], in: plane,
                                              distance: 5, symmetric: false)
            let euclidCut = KernelOps.extrude(profile: cutProfile, holes: [], in: plane,
                                              distance: 6, symmetric: false)
            let euclidResult = euclidBig.subtracting(euclidCut)
            if let a = OCCTKernel.extrudeShape(
                   outerLoop: bigProfile.loop,
                   outerConic: OCCTKernel.ConicSpec(center: .zero, radius: 3),
                   holes: [], zMin: za.zMin, zMax: za.zMax, origin: plane.origin,
                   xAxis: plane.xAxis, yAxis: plane.yAxis, normal: plane.normal),
               let b = OCCTKernel.extrudeShape(
                   outerLoop: cutProfile.loop,
                   outerConic: OCCTKernel.ConicSpec(center: SIMD2(2, 0), radius: 1.5),
                   holes: [], zMin: -0.5, zMax: 6, origin: plane.origin,
                   xAxis: plane.xAxis, yAxis: plane.yAxis, normal: plane.normal),
               let cut = OCCTKernel.boolean(a, b, op: 1) {
                var body = Body(name: "Boolean", transform: .identity, primitive: nil,
                                euclidMesh: euclidResult, revision: seedDoc.nextRevision())
                let m = OCCTKernel.renderMesh(from: cut)
                body.brep = cut
                body.render = RenderMesh(positions: m.positions, normals: m.normals, indices: m.indices)
                body.edges = FeatureEdgeExtractor.edges(from: body.render)
                body.material = BodyMaterialSpec.default
                session.perform(AddBodyCommand(body: body))
            }
            return
        }

        // OS3D_DEBUG_SEED_PRIMBOOL: cylinder PRIMITIVE − box PRIMITIVE, proving a
        // MIXED boolean (both operands analytic via primitive breps) stays round.
        if ProcessInfo.processInfo.environment["OS3D_DEBUG_SEED_PRIMBOOL"] != nil,
           session.document.bodies.isEmpty {
            var seedDoc = session.document
            let cylSpec = PrimitiveSpec.cylinder(radius: 3, height: 5)
            let boxSpec = PrimitiveSpec.box(width: 3, depth: 3, height: 7)
            let boxPlacement = Transform3D(translation: SIMD3(3, -1, 0))
            var ebox = Euclid.Mesh.primitive(boxSpec)
            ebox = ebox.transformed(by: boxPlacement.euclid)
            let euclidResult = Euclid.Mesh.primitive(cylSpec).subtracting(ebox)
            if let a = OCCTKernel.primitiveShape(cylSpec, placement: .identity),
               let b = OCCTKernel.primitiveShape(boxSpec, placement: boxPlacement),
               let cut = OCCTKernel.boolean(a, b, op: 1) {
                var body = Body(name: "PrimBoolean", transform: .identity, primitive: nil,
                                euclidMesh: euclidResult, revision: seedDoc.nextRevision())
                let m = OCCTKernel.renderMesh(from: cut)
                body.brep = cut
                body.render = RenderMesh(positions: m.positions, normals: m.normals, indices: m.indices)
                body.edges = FeatureEdgeExtractor.edges(from: body.render)
                body.material = BodyMaterialSpec.default
                session.perform(AddBodyCommand(body: body))
            }
            return
        }

        // OS3D_DEBUG_SEED_STEP: a stepped block — a low half (y ≤ 6) and a
        // high half (y ≤ 12). The canonical Replace Face subject (§4.12):
        // the low step's top face and the high step's top face are PARALLEL
        // and at different heights, which is exactly the pair the tool needs
        // and which no single-box seed can offer.
        if ProcessInfo.processInfo.environment["OS3D_DEBUG_SEED_STEP"] != nil,
           session.document.bodies.isEmpty {
            var seedDoc = session.document
            let lowSpec = PrimitiveSpec.box(width: 20, depth: 10, height: 6)
            let highSpec = PrimitiveSpec.box(width: 10, depth: 10, height: 12)
            let highPlacement = Transform3D(translation: SIMD3(5, 0, 0))
            var ehigh = Euclid.Mesh.primitive(highSpec)
            ehigh = ehigh.transformed(by: highPlacement.euclid)
            let euclidResult = Euclid.Mesh.primitive(lowSpec).union(ehigh)
            if let a = OCCTKernel.primitiveShape(lowSpec, placement: .identity),
               let b = OCCTKernel.primitiveShape(highSpec, placement: highPlacement),
               let fused = OCCTKernel.boolean(a, b, op: 0) {
                var body = Body(name: "Step", transform: .identity, primitive: nil,
                                euclidMesh: euclidResult, revision: seedDoc.nextRevision())
                // Unify, or the fuse's coplanar seams leave the block with
                // more faces than it has corners and the picks get confusing.
                body.adoptBRep(OCCTKernel.unified(fused))
                body.material = BodyMaterialSpec.default
                session.perform(AddBodyCommand(body: body))
            }
            return
        }

        // OS3D_DEBUG_SEED_HOLE: a box with a through-hole — the canonical
        // Delete Face subject (§4.16), because the face worth deleting is the
        // hole's CYLINDRICAL wall, and no other seed has one.
        if ProcessInfo.processInfo.environment["OS3D_DEBUG_SEED_HOLE"] != nil,
           session.document.bodies.isEmpty {
            var seedDoc = session.document
            let boxSpec = PrimitiveSpec.box(width: 10, depth: 10, height: 6)
            let drillSpec = PrimitiveSpec.cylinder(radius: 2, height: 12)
            // Below the box and taller than it, so it punches clean through
            // and leaves exactly ONE cylindrical face.
            let drillPlacement = Transform3D(translation: SIMD3(0, -3, 0))
            var edrill = Euclid.Mesh.primitive(drillSpec)
            edrill = edrill.transformed(by: drillPlacement.euclid)
            let euclidResult = Euclid.Mesh.primitive(boxSpec).subtracting(edrill)
            if let a = OCCTKernel.primitiveShape(boxSpec, placement: .identity),
               let b = OCCTKernel.primitiveShape(drillSpec, placement: drillPlacement),
               let drilled = OCCTKernel.boolean(a, b, op: 1) {
                var body = Body(name: "Drilled", transform: .identity, primitive: nil,
                                euclidMesh: euclidResult, revision: seedDoc.nextRevision())
                body.adoptBRep(drilled)
                body.material = BodyMaterialSpec.default
                session.perform(AddBodyCommand(body: body))
            }
            return
        }

        guard ProcessInfo.processInfo.environment["OS3D_DEBUG_SEED"] != nil,
              session.document.bodies.isEmpty
        else { return }
        var document = session.document
        var body = Body(
            name: document.uniqueBodyName(base: "Box"),
            transform: .identity,
            primitive: .box(width: 4, depth: 4, height: 4),
            euclidMesh: .primitive(.box(width: 4, depth: 4, height: 4)),
            revision: document.nextRevision()
        )
        // Seeded screenshots carry the default material explicitly (plan
        // §B15) — value-identical to the legacy look.
        body.material = .default
        session.perform(AddBodyCommand(body: body))
        selection = [body.id]
        mode = .editingPrimitive(body.id)
        #endif
    }

    // MARK: - Feature graph recording (Phase D, Task C2)

    /// The most recent feature node that produces `id` (last writer wins for a
    /// BodyID owned by several nodes, e.g. a boolean that modifies its target in
    /// place), or nil if `id` is a non-feature body (import / copy / seed).
    private func featureNode(owning id: BodyID) -> FeatureNode? {
        session.document.features.nodes.last { $0.outputBodyIDs.contains(id) }
    }

    /// A `ProfileRef` capturing the sketch loop (+ hole loops) so the extrude can
    /// re-detect the same region on rebuild; the centroid is the seed-point
    /// fallback when the entity ids don't uniquely match.
    private func profileRef(profile: Profile, holes: [Profile], sketchID: SketchID) -> ProfileRef {
        ProfileRef(
            sketchID: sketchID,
            entityIDs: Array(profile.sourceEntityIDs),
            holeEntityIDs: holes.map { Array($0.sourceEntityIDs) },
            // A point INSIDE the region, not the vertex average: the seed is
            // what tells apart two regions bounded by the same entities
            // (`resolveProfile`), and a ring's or a C's centroid is not in it.
            seedPoint: profile.interiorPoint
        )
    }

    /// Build an `.extrude` feature node from the committing tool context, or nil
    /// when this isn't a sketch-profile extrude (face push/pull, revolve, sweep,
    /// loft — the latter three are tranche-2 features).
    private func extrudeFeatureNode(
        context: ToolContext, boolean: BooleanIntent, outputBodyIDs: [BodyID]
    ) -> FeatureNode? {
        guard case .extrude(let distance) = context.kind,
              let sketchID = context.sketchID,
              !context.isFaceOperation
        else { return nil }
        let outer = profileRef(profile: context.profile, holes: context.holes, sketchID: sketchID)
        let extras = context.extraProfiles.map {
            profileRef(profile: $0.profile, holes: $0.holes, sketchID: sketchID)
        }
        return FeatureNode(
            name: "Extrude",
            kind: .extrude(
                profile: outer,
                plane: PlaneRef(source: .sketch(sketchID)),
                distance: Expr(value: distance),
                symmetric: context.symmetric,
                boolean: boolean,
                extraProfiles: extras
            ),
            outputBodyIDs: outputBodyIDs
        )
    }

    /// Build the history node for the committing tool, dispatching on
    /// `context.kind`: extrude (tranche 1) OR revolve / sweep / loft (tranche 2).
    /// Returns nil when the operation isn't a recordable sketch feature (face
    /// push/pull, offset plane, or a builder's preconditions aren't met) — the
    /// caller then records no node rather than a broken one.
    private func toolFeatureNode(
        context: ToolContext, boolean: BooleanIntent, outputBodyIDs: [BodyID]
    ) -> FeatureNode? {
        switch context.kind {
        case .extrude:
            return extrudeFeatureNode(
                context: context, boolean: boolean, outputBodyIDs: outputBodyIDs)
        case .revolve:
            return revolveFeatureNode(
                context: context, boolean: boolean, outputBodyIDs: outputBodyIDs)
        case .sweep:
            return sweepFeatureNode(
                context: context, boolean: boolean, outputBodyIDs: outputBodyIDs)
        case .loft:
            return loftFeatureNode(
                context: context, boolean: boolean, outputBodyIDs: outputBodyIDs)
        case .offsetPlane:
            return nil
        }
    }

    /// Build a `.revolve` feature node from the committing tool context. The
    /// axis is the `RevolveAxis` captured in `context.kind` (sketch-plane-local),
    /// recorded as an explicit axis so replay is deterministic; nil for a
    /// non-revolve context or a face operation with no sketch.
    private func revolveFeatureNode(
        context: ToolContext, boolean: BooleanIntent, outputBodyIDs: [BodyID]
    ) -> FeatureNode? {
        guard case .revolve(let axis, let angle) = context.kind,
              let sketchID = context.sketchID
        else { return nil }
        let outer = profileRef(profile: context.profile, holes: context.holes, sketchID: sketchID)
        return FeatureNode(
            name: "Revolve",
            kind: .revolve(
                profile: outer,
                plane: PlaneRef(source: .sketch(sketchID)),
                axis: AxisRef(source: .explicit(axis)),
                angle: Expr(value: angle),
                boolean: boolean
            ),
            outputBodyIDs: outputBodyIDs
        )
    }

    /// Build a `.sweep` feature node: the armed profile swept along the world-
    /// space polyline spine captured in `context.kind`. Nil for a non-sweep
    /// context or one lacking a sketch.
    private func sweepFeatureNode(
        context: ToolContext, boolean: BooleanIntent, outputBodyIDs: [BodyID]
    ) -> FeatureNode? {
        guard case .sweep(let spine) = context.kind,
              let sketchID = context.sketchID
        else { return nil }
        let outer = profileRef(profile: context.profile, holes: context.holes, sketchID: sketchID)
        return FeatureNode(
            name: "Sweep",
            kind: .sweep(
                profile: outer,
                plane: PlaneRef(source: .sketch(sketchID)),
                spine: spine.map { PointWrapper($0) },
                boolean: boolean,
                helix: nil          // the interactive tool sweeps a drawn polyline
            ),
            outputBodyIDs: outputBodyIDs
        )
    }

    /// Build a `.loft` feature node from the ordered loft sections, each pinned
    /// to its own sketch profile. Nil unless the context is a loft with the ≥2
    /// sections the evaluator requires.
    private func loftFeatureNode(
        context: ToolContext, boolean: BooleanIntent, outputBodyIDs: [BodyID]
    ) -> FeatureNode? {
        guard case .loft = context.kind, context.loftProfiles.count >= 2 else { return nil }
        let sections = context.loftProfiles.map {
            profileRef(profile: $0.profile, holes: $0.holes, sketchID: $0.sketchID)
        }
        return FeatureNode(
            name: "Loft",
            kind: .loft(sections: sections, boolean: boolean),
            outputBodyIDs: outputBodyIDs
        )
    }

    /// Translate the interactive `PatternState` into the persisted `PatternSpec`.
    /// `axis` is the world direction (linear) / rotation axis (circular);
    /// `count` is total instances incl. the original; `totalAngle` is stored in
    /// RADIANS (the state carries degrees); `rotateInstances` matches the live
    /// circular transform call (always true). Used both when recording a pattern
    /// commit and — via the panel edit API — when rebuilding a spec field-by-field.
    private func patternSpec(from state: PatternState) -> PatternSpec {
        // Resolve the construction axis HERE rather than storing its id: the
        // spec is replayed by the feature graph, which has no view model, and
        // baking the line keeps a rebuild working after the axis is deleted.
        let line = patternAxisLine(state)
        return PatternSpec(
            kind: state.kind == .linear ? .linear : .circular,
            axis: line.direction,
            center: line.center,
            count: state.count,
            spacing: state.spacing,
            totalAngle: state.totalAngle * .pi / 180,
            rotateInstances: true
        )
    }

    /// A `.boolean` node for an explicit target/tool CSG, or nil unless BOTH
    /// bodies are feature-produced (only then can replay reconstruct them).
    private func booleanFeatureNode(kind: BooleanKind, target: Body, tool: Body) -> FeatureNode? {
        guard let targetOwner = featureNode(owning: target.id),
              let toolOwner = featureNode(owning: tool.id)
        else { return nil }
        return FeatureNode(
            name: kind.rawValue.capitalized,
            kind: .boolean(
                kind: kind,
                target: BodyRef(producer: targetOwner.id, bodyID: target.id),
                tools: [BodyRef(producer: toolOwner.id, bodyID: tool.id)]
            ),
            outputBodyIDs: [target.id]
        )
    }

    /// A `FaceRef` pinning the pushed planar face by geometric signature, in the
    /// source body's LOCAL space (matching `SignatureNaming`, which resolves
    /// against `body.render`). Nil if the selected face isn't a recoverable
    /// planar patch.
    private func pushPullFaceRef(
        context: ToolContext, source: Body, creator: FeatureID
    ) -> FaceRef? {
        guard let seed = context.faceTriangles.first,
              let face = FaceTopology.planarFace(in: source.render, seedTriangle: seed)
        else { return nil }
        let n = SIMD3<Double>(Double(face.normal.x), Double(face.normal.y), Double(face.normal.z))
        let centroid = face.origin
        var area = abs(Profile.signedArea(face.outline))
        for hole in face.holes { area -= abs(Profile.signedArea(hole)) }
        let signature = FaceSignature(
            kind: .planar, normal: n, centroid: centroid,
            area: max(area, 0), planeOffset: simd_dot(n, centroid))
        // Role is only a resolve tiebreak; box faces get a precise role, others
        // fall back to derived (signature alone still resolves above threshold).
        let role: FaceRole
        if case .primitive(let spec, _)? = session.document.features.node(creator)?.kind,
           case .box = spec {
            role = .boxFace(Self.boxFace(for: n))
        } else {
            role = .derived(index: 0)
        }
        return FaceRef(
            body: BodyRef(producer: creator, bodyID: source.id),
            creator: creator, role: role, signature: signature,
            elementName: mintElementName(body: source, triangle: seed))
    }

    /// The kernel-history name of the face containing `triangle` on `body`,
    /// read from the last APPLIED rebuild's face tables
    /// (TOPO_NAMING_HISTORY_DESIGN step 4). Nil is normal — a fresh load, a
    /// mesh-path body, an unnamed face — and mints a legacy ref. The
    /// revision guard is what makes this safe: live tools replace bodies
    /// without re-evaluating, and a name looked up in a table describing an
    /// OLDER render would be WRONG, which is worse than none.
    private func mintElementName(body: Body, triangle: Int?) -> ElementName? {
        guard let triangle,
              session.lastNamingRevisions[body.id] == body.meshRevision
        else { return nil }
        return session.lastFaceTables[body.id]?.entries
            .first { $0.triangles.contains(triangle) }?.elementName
    }

    /// The kernel-history identity of the picked mesh edge on `body` — its
    /// adjacent-face name pair (step 4b). Same staleness guard; nil mints a
    /// legacy signature-only ref.
    private func mintEdgeName(body: Body, edge: SelectableEdge) -> EdgeName? {
        guard let brep = body.brep,
              session.lastNamingRevisions[body.id] == body.meshRevision,
              let names = session.lastKernelNames[body.id], !names.isEmpty
        else { return nil }
        let mid = edge.midpoint
        guard let index = OCCTKernel.nearestEdgeIndex(
            brep, to: SIMD3(Double(mid.x), Double(mid.y), Double(mid.z)),
            tolerance: OCCTKernel.matchTolerance(for: brep))
        else { return nil }
        return ElementNaming.edgeNames(
            adjacency: OCCTKernel.edgeFaceAdjacency(brep),
            names: names)[index]
    }

    /// The signed ±X/±Y/±Z box face a normal points most strongly along.
    private static func boxFace(for n: SIMD3<Double>) -> BoxFace {
        let ax = abs(n.x), ay = abs(n.y), az = abs(n.z)
        if ax >= ay && ax >= az { return n.x >= 0 ? .px : .nx }
        if ay >= az { return n.y >= 0 ? .py : .ny }
        return n.z >= 0 ? .pz : .nz
    }

    // MARK: - History panel API (Phase D, Task C2)

    /// One row in the History panel; a projection of a `FeatureNode` plus its
    /// most-recent evaluation error.
    struct FeatureRow: Identifiable {
        let id: FeatureID
        var name: String
        var kindLabel: String
        var suppressed: Bool
        var hasError: Bool
        var errorText: String?
        /// True when this node sits at/after the rollback marker, so it is not
        /// evaluated (its bodies are absent). The History panel dims these rows.
        var isRolledBack: Bool = false
        /// The node's `PatternSpec` when this is a `.pattern` row, else nil.
        /// The panel keys off this to show pattern-specific fields (count,
        /// spacing for linear, angle for circular). `angleDegrees` re-exposes
        /// `spec.totalAngle` (radians) in the panel's degree units.
        var patternSpec: PatternSpec?
        /// The node's editable scalar parameters in display order — distance,
        /// angle, radius, thickness, factor, draft — empty for kinds with none
        /// (G8: every scalar a feature has is editable in its History row).
        var scalars: [FeatureScalar] = []
        /// The node's editable options — Bool toggles (symmetric, keep
        /// original) and choices (a boolean's type) — empty when it has none.
        var options: [FeatureOption] = []

        /// True when this row edits a linear/circular pattern.
        var isPattern: Bool { patternSpec != nil }
        /// Total instance count (incl. original), or nil for non-pattern rows.
        var patternCount: Int? { patternSpec?.count }
        /// Adjacent-center spacing (linear patterns), or nil otherwise.
        var patternSpacing: Double? { patternSpec?.spacing }
        /// First→last sweep in DEGREES (circular patterns), or nil otherwise.
        var patternAngleDegrees: Double? {
            patternSpec.map { $0.totalAngle * 180 / .pi }
        }
        /// True when the pattern is circular (angle field applies), false linear
        /// (spacing field applies); nil for non-pattern rows.
        var patternIsCircular: Bool? {
            patternSpec.map { $0.kind == .circular }
        }
    }

    /// One editable scalar of a feature, as the History row shows it.
    struct FeatureScalar: Identifiable, Equatable, Sendable {
        let key: FeatureScalarKey
        let label: String
        /// "mm", "°" or "×" — display only; the stored `Expr` is unit-free.
        let unit: String
        let value: Double
        var id: FeatureScalarKey { key }
    }

    /// Which scalar of a node an edit addresses. `primary` is the one
    /// `kind(_:replacingExpr:)` replaces (distance / angle / radius /
    /// setback / thickness / factor); `taperAngle` is the draft extrude's
    /// second scalar.
    enum FeatureScalarKey: String, Hashable, Sendable {
        case primary
        case taperAngle
        /// Face rotate: shown in degrees, stored in radians (the kernel's unit).
        case rotateAngle
    }

    /// One editable option of a feature, as the History row shows it: a
    /// Bool toggle or a choice among named alternatives.
    struct FeatureOption: Identifiable, Equatable, Sendable {
        enum Value: Equatable, Sendable {
            case toggle(Bool)
            case choice(selected: String, choices: [String])
        }
        let key: FeatureOptionKey
        let label: String
        let value: Value
        var id: FeatureOptionKey { key }
    }

    enum FeatureOptionKey: String, Hashable, Sendable {
        case symmetric
        case keepOriginal
        case booleanKind
    }

    private static let booleanKindChoices: [(kind: BooleanKind, label: String)] = [
        (.union, "Union"), (.subtract, "Subtract"), (.intersect, "Intersect"),
    ]

    /// The editable options of a feature kind, in display order.
    static func options(of kind: FeatureKind) -> [FeatureOption] {
        switch kind {
        case let .extrude(_, _, _, symmetric, _, _), let .draftExtrude(_, _, _, _, symmetric, _):
            return [FeatureOption(key: .symmetric, label: "Symmetric", value: .toggle(symmetric))]
        case let .mirror(_, _, keepOriginal):
            return [FeatureOption(key: .keepOriginal, label: "Keep original", value: .toggle(keepOriginal))]
        case let .boolean(booleanKind, _, _):
            let selected = booleanKindChoices.first { $0.kind == booleanKind }?.label ?? "Union"
            return [FeatureOption(key: .booleanKind, label: "Type",
                                  value: .choice(selected: selected, choices: booleanKindChoices.map(\.label)))]
        default:
            return []
        }
    }

    /// The editable scalars of a feature kind, in display order.
    static func scalars(of kind: FeatureKind) -> [FeatureScalar] {
        switch kind {
        case let .extrude(_, _, distance, _, _, _):
            return [FeatureScalar(key: .primary, label: "Distance", unit: "mm", value: distance.value)]
        case let .pushPull(_, distance, _):
            return [FeatureScalar(key: .primary, label: "Distance", unit: "mm", value: distance.value)]
        case let .draftExtrude(_, _, distance, taperAngle, _, _):
            return [
                FeatureScalar(key: .primary, label: "Distance", unit: "mm", value: distance.value),
                FeatureScalar(key: .taperAngle, label: "Draft", unit: "°", value: taperAngle.value),
            ]
        case let .revolve(_, _, _, angle, _):
            return [FeatureScalar(key: .primary, label: "Angle", unit: "°", value: angle.value)]
        case let .chamfer(_, _, setback):
            return [FeatureScalar(key: .primary, label: "Setback", unit: "mm", value: setback.value)]
        case let .fillet(_, _, radius):
            return [FeatureScalar(key: .primary, label: "Radius", unit: "mm", value: radius.value)]
        case let .shell(_, _, thickness):
            return [FeatureScalar(key: .primary, label: "Thickness", unit: "mm", value: thickness.value)]
        case let .scaleFace(_, factor):
            return [FeatureScalar(key: .primary, label: "Factor", unit: "×", value: factor.value)]
        case let .rotateFace(_, angle, _):
            return [FeatureScalar(key: .rotateAngle, label: "Angle", unit: "°",
                                  value: angle.value * 180 / Double.pi)]
        default:
            return []
        }
    }

    // MARK: - Document variables (Phase D, Task B2 / spec §6.6)

    /// One row in the Variables panel: the variable's identity, editable
    /// name/expression, its resolved value, and any resolution error surfaced
    /// from `VariableTable.resolve`.
    struct VariableRow: Identifiable {
        let id: VariableID
        var name: String
        var expression: String
        var value: Double
        var hasError: Bool
        var errorText: String?
    }

    /// Whether the Variables panel is shown.
    var showVariablesPanel = false

    /// The ordered variable rows, derived from `document.variables` plus the
    /// per-variable errors from `VariableTable.resolve` (creation-order rule).
    var variableRows: [VariableRow] {
        _ = session.changeCount // re-derive when the document changes
        let errors = VariableTable.resolve(session.document.variables).errors
        return session.document.variables.map { v in
            let err = errors[v.id]
            return VariableRow(
                id: v.id,
                name: v.name,
                expression: v.expression,
                value: v.value,
                hasError: err != nil,
                errorText: err
            )
        }
    }

    /// Append a new document variable with a unique default name ("var1",
    /// "var2", …) and expression "0", then re-resolve + fan out to dependents.
    /// The dimension pad's "Create …" action (Shapr3D offers
    /// `Create "length1 = 440.1136"` right in the value field): mint a variable
    /// holding `expression` and hand back its name so the field can reference
    /// it. Returns nil if the expression will not evaluate.
    @discardableResult
    func createVariable(holding expression: String,
                        preferredName: String) -> String? {
        guard ExpressionEvaluator.evaluate(
            expression, variables: session.variableValues()) != nil else { return nil }
        let existing = Set(session.document.variables.map(\.name))
        var name = preferredName
        var index = 1
        while existing.contains(name) || !VariableTable.isValidName(name) {
            index += 1
            name = "\(preferredName)\(index)"
        }
        let variable = Variable(name: name, expression: expression, value: 0)
        session.perform(AddVariableCommand(variable: variable))
        prepareForHistoryChange()
        session.variablesDidChange()
        session.save()
        return name
    }

    /// Names of every document variable, for the pad's insert menu.
    var variableNames: [String] { session.document.variables.map(\.name) }

    func addVariable() {
        let existing = Set(session.document.variables.map { $0.name })
        var index = existing.count + 1
        var name = "var\(index)"
        while existing.contains(name) {
            index += 1
            name = "var\(index)"
        }
        let variable = Variable(name: name, expression: "0", value: 0)
        session.perform(AddVariableCommand(variable: variable))
        prepareForHistoryChange()
        session.variablesDidChange()
        session.save()
    }

    /// Edit a variable's name and/or expression. The name is validated via
    /// `VariableTable.isValidName`; an invalid name sets `errorMessage` and
    /// makes no change. On success re-resolves the table and rebuilds every
    /// dependent feature/sketch formula.
    func setVariable(_ id: VariableID, name: String, expression: String) {
        guard let before = session.document.variables.first(where: { $0.id == id }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard VariableTable.isValidName(trimmedName) else {
            errorMessage = "\"\(name)\" isn't a valid variable name."
            return
        }
        // Uniqueness was unchecked: renaming `b` onto an existing `a` was
        // accepted, `b` then resolved to 0 as a duplicate, and every formula
        // that said `b` silently started reading `a`'s value instead
        // (2026-08-25 review round 4).
        guard !session.document.variables.contains(where: {
            $0.id != id && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        }) else {
            errorMessage = "A variable named \"\(trimmedName)\" already exists."
            return
        }
        guard before.name != trimmedName || before.expression != expression else { return }
        var after = before
        after.name = trimmedName
        after.expression = expression
        session.perform(EditVariableCommand(before: before, after: after))
        prepareForHistoryChange()
        session.variablesDidChange()
        session.save()
    }

    /// Remove a variable, preserving its creation-order index for undo, then
    /// re-resolve + rebuild dependents (formulas that referenced it error to 0).
    func deleteVariable(_ id: VariableID) {
        guard let index = session.document.variables.firstIndex(where: { $0.id == id }) else { return }
        let variable = session.document.variables[index]
        session.perform(RemoveVariableCommand(index: index, variable: variable))
        prepareForHistoryChange()
        session.variablesDidChange()
        session.save()
    }

    /// Whether the History panel is shown beside the Items panel.
    var showHistoryPanel = false

    /// Hotkey / Command Search catalog (spec §8.4). Mutable because it tracks
    /// most-recently-used commands; `CommandShortcutsView` registers the
    /// chords and `runCommand(_:)` (CommandDispatch.swift) performs them.
    var commandRegistry = CommandRegistry()

    // MARK: - Command Search (spec §8.4)

    /// Whether the launcher panel is up. Set by `app.commandSearch` (X) and
    /// `app.commandSearchAlt` (⌘F) through `runCommand`.
    var commandSearchActive = false
    /// Seeds the launcher's field. Non-empty when a bare letter opened it
    /// under Single Key Action — the keystroke that opened the panel is also
    /// the first thing typed into it, which is the whole point of the setting.
    var commandSearchSeed = ""

    /// Fuzzy results for the launcher, drawn ONLY from commands `runCommand`
    /// can actually perform (see `CommandRegistry.launchableCommands`).
    func commandSearchResults(for query: String) -> [AppCommand] {
        commandRegistry.search(query, in: CommandRegistry.launchableCommands)
    }

    /// Open the launcher, optionally pre-typed with `seed`.
    func openCommandSearch(seed: String = "") {
        commandSearchSeed = seed
        commandSearchActive = true
    }

    func closeCommandSearch() {
        commandSearchActive = false
        commandSearchSeed = ""
    }

    /// Run a command chosen from the launcher.
    ///
    /// Returns false when the command is real but not applicable right now (a
    /// sketch tool with no sketch open, a boolean with nothing selected) — the
    /// launcher stays up and says so, rather than closing on a keystroke that
    /// did nothing.
    @discardableResult
    func runCommandFromSearch(_ id: String) -> Bool {
        // Picking a result is an explicit command, not another bare key.
        guard runCommand(id, honoringSingleKeyAction: false) else { return false }
        closeCommandSearch()
        return true
    }

    /// The ordered history rows, derived from the graph + last eval errors.
    var historyRows: [FeatureRow] {
        _ = session.changeCount // re-derive when the document changes
        let nodes = session.document.features.nodes
        let cut = session.document.features.rollbackIndex ?? nodes.count
        return nodes.enumerated().map { index, node in
            let error = session.lastEvalErrors[node.id]
            let patternSpec: PatternSpec?
            if case let .pattern(_, spec) = node.kind { patternSpec = spec } else { patternSpec = nil }
            return FeatureRow(
                id: node.id,
                name: node.name,
                kindLabel: Self.kindLabel(node.kind),
                suppressed: node.suppressed,
                hasError: error != nil,
                errorText: error.map(Self.errorText),
                isRolledBack: index >= cut,
                patternSpec: patternSpec,
                scalars: Self.scalars(of: node.kind),
                options: Self.options(of: node.kind)
            )
        }
    }

    /// The graph's rollback marker: the number of leading (active) nodes, or
    /// nil when every node is active (latest state). Nodes at/after this index
    /// are rolled back — not evaluated, their bodies removed.
    var rollbackIndex: Int? { session.document.features.rollbackIndex }

    /// Roll the history back to just after `id`, so the target node still
    /// evaluates but everything after it is suppressed. Rolled-back nodes'
    /// bodies disappear, so clean up selection/mode the same way undo/redo do.
    func rollbackToFeature(_ id: FeatureID) {
        guard let idx = session.document.features.index(of: id) else { return }
        prepareForHistoryChange()
        session.setRollback(idx + 1)
        sanitizeAfterHistoryChange()
        session.save()
    }

    /// Clear the rollback marker, returning the model to its latest state
    /// (all nodes active). Newly restored bodies don't invalidate selection,
    /// but sanitize anyway for symmetry/safety.
    func clearRollback() {
        prepareForHistoryChange()
        session.setRollback(nil)
        sanitizeAfterHistoryChange()
        session.save()
    }

    /// Select the bodies a feature owns, reusing the normal body-selection state.
    func selectFeature(_ id: FeatureID) {
        guard let node = session.document.features.node(id) else { return }
        let ids = node.outputBodyIDs.filter { session.document.body(with: $0) != nil }
        guard !ids.isEmpty else { return }
        cancelTool()
        selection = Set(ids)
        if ids.count == 1, let first = ids.first {
            mode = .selected(first)
        }
    }

    /// Rename a history node (and its output bodies, so the Items panel stays in
    /// sync) in one undo step.
    func renameFeature(_ id: FeatureID, to newName: String) {
        guard let node = session.document.features.node(id), node.name != newName else { return }
        var commands: [DocumentCommand] = [
            RenameFeatureCommand(featureID: id, before: node.name, after: newName)
        ]
        for bodyID in node.outputBodyIDs {
            guard let body = session.document.body(with: bodyID) else { continue }
            commands.append(RenameItemCommand(item: .body(bodyID), before: body.name, after: newName))
        }
        session.perform(commands.count == 1
            ? commands[0]
            : CompositeCommand(title: "Rename", commands: commands))
        session.save()
    }

    /// Delete a history node and rebuild everything downstream in one undo step.
    func deleteFeature(_ id: FeatureID) {
        prepareForHistoryChange()
        session.deleteFeature(id)
        // The deleted node's bodies are gone: a blend/shell pick or tool
        // context still holding one would keep drawing a ghost preview in a
        // stuck mode — the Items-panel bug, reachable from History too
        // (2026-08-25 review round 2).
        sanitizeAfterHistoryChange()
        session.save()
    }

    /// Suppress / un-suppress a history node and rebuild downstream.
    func setFeatureSuppressed(_ id: FeatureID, _ value: Bool) {
        prepareForHistoryChange()
        session.setSuppressed(id, value)
        sanitizeAfterHistoryChange()
        session.save()
    }

    /// Drag-reorder a history node to a new position and rebuild downstream.
    func moveFeature(_ id: FeatureID, to newIndex: Int) {
        prepareForHistoryChange()
        session.moveFeature(id, to: newIndex)
        sanitizeAfterHistoryChange()
        session.save()
    }

    /// Fit the camera to the world AABB of a feature's output bodies.
    func zoomToFeature(_ id: FeatureID) {
        guard let node = session.document.features.node(id) else { return }
        var lo = SIMD3<Float>(repeating: .infinity)
        var hi = -lo
        var found = false
        for bodyID in node.outputBodyIDs {
            guard let body = session.document.body(with: bodyID) else { continue }
            let bounds = Self.worldBounds(of: body)
            lo = simd_min(lo, SIMD3(Float(bounds.min.x), Float(bounds.min.y), Float(bounds.min.z)))
            hi = simd_max(hi, SIMD3(Float(bounds.max.x), Float(bounds.max.y), Float(bounds.max.z)))
            found = true
        }
        guard found else { return }
        cameraControl?.fitTo(bounds: (lo, hi))
    }

    /// Edit a feature's primary scalar (extrude/push-pull distance, revolve
    /// angle) and rebuild downstream via the session's `EditFeatureCommand` path.
    func editFeatureDistance(_ id: FeatureID, _ value: Double) {
        guard let node = session.document.features.node(id),
              let after = Self.kind(node.kind, replacingScalar: value)
        else { return }
        prepareForHistoryChange()
        session.editFeature(id, to: after)
        session.save()
    }

    /// Edit one of a feature's scalars by key (History row fields). The
    /// primary scalar is `editFeatureDistance`; the draft extrude's taper
    /// angle (degrees) is the one kind with a second scalar.
    func editFeatureScalar(_ id: FeatureID, key: FeatureScalarKey, value: Double) {
        switch key {
        case .primary:
            editFeatureDistance(id, value)
        case .taperAngle:
            guard let node = session.document.features.node(id),
                  case let .draftExtrude(profile, plane, distance, taperAngle, symmetric, boolean) = node.kind,
                  taperAngle.value != value
            else { return }
            prepareForHistoryChange()
            session.editFeature(id, to: .draftExtrude(
                profile: profile, plane: plane, distance: distance,
                taperAngle: Expr(value: value), symmetric: symmetric, boolean: boolean))
            session.save()
        case .rotateAngle:
            guard let node = session.document.features.node(id),
                  case let .rotateFace(face, angle, axis) = node.kind
            else { return }
            let radians = value * Double.pi / 180
            guard abs(radians - angle.value) > 1e-12 else { return }
            prepareForHistoryChange()
            session.editFeature(id, to: .rotateFace(face: face, angle: Expr(value: radians), axis: axis))
            session.save()
        }
    }

    /// Flip one of a feature's Bool options (History row toggles). A key the
    /// kind does not have, or a value it already has, changes nothing.
    func setFeatureOption(_ id: FeatureID, key: FeatureOptionKey, toggle on: Bool) {
        guard let node = session.document.features.node(id) else { return }
        let after: FeatureKind
        switch (key, node.kind) {
        case let (.symmetric, .extrude(profile, plane, distance, symmetric, boolean, extras)):
            guard symmetric != on else { return }
            after = .extrude(profile: profile, plane: plane, distance: distance,
                             symmetric: on, boolean: boolean, extraProfiles: extras)
        case let (.symmetric, .draftExtrude(profile, plane, distance, taperAngle, symmetric, boolean)):
            guard symmetric != on else { return }
            after = .draftExtrude(profile: profile, plane: plane, distance: distance,
                                  taperAngle: taperAngle, symmetric: on, boolean: boolean)
        case let (.keepOriginal, .mirror(body, plane, keepOriginal)):
            guard keepOriginal != on else { return }
            after = .mirror(body: body, plane: plane, keepOriginal: on)
        default:
            return
        }
        prepareForHistoryChange()
        session.editFeature(id, to: after)
        session.save()
    }

    /// Pick one of a feature's choice options by its label (History row
    /// menus). Today that is a boolean node's type; its operands are kept.
    func setFeatureOption(_ id: FeatureID, key: FeatureOptionKey, choice: String) {
        guard key == .booleanKind,
              let node = session.document.features.node(id),
              case let .boolean(current, target, tools) = node.kind,
              let picked = Self.booleanKindChoices.first(where: { $0.label == choice })?.kind,
              picked != current
        else { return }
        prepareForHistoryChange()
        session.editFeature(id, to: .boolean(kind: picked, target: target, tools: tools))
        session.save()
    }

    /// The same feature kind with its primary scalar replaced, or nil if it has
    /// none (primitive/boolean/etc. aren't distance-editable in the panel).
    private static func kind(_ kind: FeatureKind, replacingScalar value: Double) -> FeatureKind? {
        Self.kind(kind, replacingExpr: Expr(value: value))
    }

    /// The same feature kind with its primary scalar `Expr` (value + optional
    /// parametric `formula`) replaced, or nil if it has none. Phase D: lets a
    /// distance/angle carry a formula that re-evaluates when variables change.
    private static func kind(_ kind: FeatureKind, replacingExpr expr: Expr) -> FeatureKind? {
        switch kind {
        case let .extrude(profile, plane, _, symmetric, boolean, extras):
            return .extrude(
                profile: profile, plane: plane, distance: expr,
                symmetric: symmetric, boolean: boolean, extraProfiles: extras)
        case let .pushPull(face, _, mode):
            return .pushPull(face: face, distance: expr, mode: mode)
        case let .revolve(profile, plane, axis, _, boolean):
            return .revolve(
                profile: profile, plane: plane, axis: axis,
                angle: expr, boolean: boolean)
        case let .chamfer(body, edges, _):
            return .chamfer(body: body, edges: edges, setback: expr)
        case let .fillet(body, edges, _):
            return .fillet(body: body, edges: edges, radius: expr)
        case let .shell(body, openFaces, _):
            return .shell(body: body, openFaces: openFaces, thickness: expr)
        case let .draftExtrude(profile, plane, _, taperAngle, symmetric, boolean):
            return .draftExtrude(
                profile: profile, plane: plane, distance: expr,
                taperAngle: taperAngle, symmetric: symmetric, boolean: boolean)
        case let .scaleFace(face, _):
            return .scaleFace(face: face, factor: expr)
        // `.rotateFace` is deliberately absent: its Expr is radians while every
        // caller here speaks the user's units — `editFeatureScalar(.rotateAngle)`
        // converts from degrees.
        default:
            return nil
        }
    }

    /// Edit a feature's primary scalar from RAW TEXT that may reference document
    /// variables / functions (Phase D). Evaluates against the current variable
    /// values; on parse failure sets `errorMessage` and makes no change. The
    /// `formula` is stored only when the text references an identifier
    /// (variable or function) — a plain number stores `formula: nil` so it
    /// never re-evaluates. The evaluated value is stored directly (no unit
    /// conversion), matching `editFeatureDistance`.
    func editFeatureExpr(_ id: FeatureID, text: String) {
        guard let node = session.document.features.node(id) else { return }
        guard let value = ExpressionEvaluator.evaluate(text, variables: session.variableValues()) else {
            errorMessage = "Couldn't read \"\(text)\" as a number."
            return
        }
        let formula = ExpressionEvaluator.identifiers(in: text).isEmpty ? nil : text
        guard let after = Self.kind(node.kind, replacingExpr: Expr(value: value, formula: formula)) else { return }
        prepareForHistoryChange()
        session.editFeature(id, to: after)
        session.save()
    }

    /// The current `PatternSpec` of a `.pattern` node, or nil if `id` isn't a
    /// pattern (the three panel edit APIs all rebuild from this base spec).
    private func patternSpec(of id: FeatureID) -> PatternSpec? {
        guard let node = session.document.features.node(id),
              case let .pattern(_, spec) = node.kind else { return nil }
        return spec
    }

    /// History-panel edit: change a pattern's total instance count (incl. the
    /// original). Rebuilds the full spec with the one field changed and routes
    /// through `session.editPatternFeature`, which resizes the node's
    /// outputBodyIDs (grow/shrink) and rebuilds every downstream mesh in one
    /// undo step. No-op unless `id` is a pattern.
    func editPatternCount(_ id: FeatureID, _ count: Int) {
        guard var spec = patternSpec(of: id) else { return }
        let clamped = max(1, count)
        guard clamped != spec.count else { return }
        spec.count = clamped
        prepareForHistoryChange()
        session.editPatternFeature(id, spec: spec)
        session.save()
    }

    /// History-panel edit: change a linear pattern's adjacent-center spacing.
    /// No-op unless `id` is a pattern.
    func editPatternSpacing(_ id: FeatureID, _ v: Double) {
        guard var spec = patternSpec(of: id) else { return }
        guard v != spec.spacing else { return }
        spec.spacing = v
        prepareForHistoryChange()
        session.editPatternFeature(id, spec: spec)
        session.save()
    }

    /// History-panel edit: change a circular pattern's first→last sweep, given
    /// in DEGREES (converted to the radians the spec stores). No-op unless `id`
    /// is a pattern.
    func editPatternAngle(_ id: FeatureID, _ deg: Double) {
        guard var spec = patternSpec(of: id) else { return }
        let radians: Double = deg * Double.pi / 180
        guard radians != spec.totalAngle else { return }
        spec.totalAngle = radians
        prepareForHistoryChange()
        session.editPatternFeature(id, spec: spec)
        session.save()
    }

    /// Short label for a feature kind (History panel row subtitle).
    private static func kindLabel(_ kind: FeatureKind) -> String {
        switch kind {
        case let .primitive(spec, _):
            return spec.displayName
        case let .extrude(_, _, distance, _, boolean, _):
            let verb: String
            switch boolean.op {
            case .subtract: verb = "Cut"
            case .union: verb = "Extrude +"
            case .intersect: verb = "Extrude ∩"
            case .newBody: verb = "Extrude"
            }
            return "\(verb) \(fmt(distance.value)) mm"
        case let .draftExtrude(_, _, distance, taperAngle, _, _):
            return "Draft \(fmt(distance.value)) mm @ \(fmt(taperAngle.value))°"
        case let .boolean(op, _, _):
            return op.rawValue.capitalized
        case let .pushPull(_, distance, _):
            return "Push/Pull \(fmt(distance.value)) mm"
        case let .moveFace(_, delta):
            return "Move Face \(fmt(simd_length(delta.point))) mm"
        case let .scaleFace(_, factor):
            return "Scale Face ×\(fmt(factor.value))"
        case let .rotateFace(_, angle, _):
            return "Rotate Face \(fmt(angle.value * 180 / .pi))°"
        case let .draftFace(_, _, _, angle):
            return "Draft Face \(fmt(angle.value))°"
        case let .revolve(_, _, _, angle, _):
            return "Revolve \(fmt(angle.value))°"
        case .sweep: return "Sweep"
        case .loft: return "Loft"
        case .transform: return "Move"
        case .mirror: return "Mirror"
        case let .pattern(_, spec): return "Pattern ×\(spec.count)"
        case let .chamfer(_, edges, setback):
            return "Chamfer \(fmt(setback.value)) mm (\(edges.count) edge\(edges.count == 1 ? "" : "s"))"
        case let .fillet(_, edges, radius):
            return "Fillet \(fmt(radius.value)) mm (\(edges.count) edge\(edges.count == 1 ? "" : "s"))"
        case let .shell(_, openFaces, thickness):
            return openFaces.isEmpty
                ? "Shell \(fmt(thickness.value)) mm (hollow)"
                : "Shell \(fmt(thickness.value)) mm (\(openFaces.count) face\(openFaces.count == 1 ? "" : "s") open)"
        case let .deleteFace(_, faces):
            return "Delete Face (\(faces.count) face\(faces.count == 1 ? "" : "s"))"
        case let .replaceFace(_, _, _, flip):
            return flip ? "Replace Face (flipped)" : "Replace Face"
        }
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%g", (v * 1000).rounded() / 1000)
    }

    private static func errorText(_ error: FeatureError) -> String {
        switch error {
        case let .brokenRef(message): return "Broken reference: \(message)"
        case .emptyGeometry: return "Empty geometry"
        case let .kernelFailure(message): return message
        }
    }
}

// MARK: - Boolean intent mapping (Phase D, Task C2)

nonisolated extension BooleanKind {
    /// The parametric `BooleanIntent` op corresponding to this kernel boolean.
    var featureOp: BooleanIntent.Op {
        switch self {
        case .union: .union
        case .subtract: .subtract
        case .intersect: .intersect
        }
    }
}

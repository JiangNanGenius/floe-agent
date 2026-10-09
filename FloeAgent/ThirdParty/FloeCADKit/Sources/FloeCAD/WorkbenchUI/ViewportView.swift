//
//  ViewportView.swift
//  openshape3d
//
//  SwiftUI wrapper for the Metal viewport. On-demand rendering: the view is
//  paused and redraws on setNeedsDisplay (gestures + scene updates).
//

import SwiftUI
import MetalKit

struct ViewportView: UIViewRepresentable {
    let viewModel: EditorViewModel
    /// The tool palette's frame (global coordinates) when the viewport should
    /// keep clear of it — on a phone, where it covers a sixth of the width.
    /// Nil frames against the whole viewport.
    var paletteFrame: CGRect? = nil
    var paletteOnRight = false

    func makeCoordinator() -> ViewportCoordinator {
        ViewportCoordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.sceneDidChange()
        context.coordinator.setPalette(frame: paletteFrame, onRight: paletteOnRight)
    }
}

@MainActor
final class ViewportCoordinator: NSObject, ViewportGestureDelegate, ViewportCameraControl {
    let viewModel: EditorViewModel
    private(set) var renderer: Renderer?
    private let gestures = ViewportGestureController()
    private weak var view: MTKView?
    private var cameraAnimator: CameraAnimator?
    /// The camera the latest automatic opening fit produced. The attach-time
    /// fit runs before the view has a size or the palette has been measured,
    /// so each arriving re-fits — only while the camera is still exactly this
    /// one. Nil once the user moves it (or when no fit is owed).
    private var openingFit: TurntableCamera?
    /// The tool palette's frame (global coordinates, nil off a phone) and the
    /// safe area derived from it against the current bounds.
    private var paletteFrame: CGRect?
    private var paletteOnRight = false
    private var safeArea = ViewportSafeArea()

    init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
        super.init()
        viewModel.cameraControl = self
    }

    func attach(to view: MTKView) {
        guard let context = RenderContext() else {
            assertionFailure("Metal is unavailable")
            return
        }
        context.configure(view: view)
        #if DEBUG
        OpenTiming.mark("render context ready")
        #endif
        let renderer = Renderer(context: context)
        renderer.scene = viewModel.scene
        #if DEBUG
        OpenTiming.mark("renderer + scene built")
        #endif
        view.delegate = renderer
        self.renderer = renderer
        self.view = view
        cameraAnimator = CameraAnimator(renderer: renderer, view: view)
        gestures.attach(to: view, renderer: renderer)
        #if DEBUG
        OpenTiming.mark("viewport attached")
        #endif
        gestures.delegate = self

        // Keep the Look-at-Sketch affordance in sync with camera motion
        // (gestures and animated flights both move the camera).
        gestures.cameraChanged = { [weak self] in self?.cameraDidMove() }
        cameraAnimator?.cameraChanged = { [weak self] in self?.cameraDidMove() }
        renderer.camera.projection = viewModel.orthographicEnabled
            ? .orthographic
            : .perspective(fovY: TurntableCamera.defaultFovY)

        // Strong capture on purpose: the coordinator can be torn down before
        // the parent view's onDisappear, but the renderer stays usable for
        // offscreen thumbnail capture as long as the view model lives.
        viewModel.thumbnailProvider = { renderer.makeThumbnailPNG() }
        viewModel.screenshotProvider = { width, height, transparent, showGrid in
            renderer.makeThumbnailPNG(
                width: width,
                height: height,
                transparentBackground: transparent,
                showGrid: showGrid
            )
        }

        if let bounds = renderer.scene.worldBounds {
            renderer.camera.fit(boundsMin: bounds.min, boundsMax: bounds.max, aspect: fitAspect)
            // The view is usually still .zero here and the palette unmeasured,
            // so this fit knows neither; it is redone as they land.
            openingFit = renderer.camera
        }

        // Re-publish the camera whenever the viewport is laid out or resized.
        // The MTKView starts at .zero and is sized afterwards, so every SwiftUI
        // overlay that projects world points evaluates once against an EMPTY
        // viewport and would stay stale — silently drawing nothing — until the
        // user happened to move the camera. This also covers rotation and
        // split-view resizes.
        renderer.viewportSizeChanged = { [weak self] in
            self?.updateSafeArea()   // the palette's share of the width moved too
            self?.refitIfStillOpening()
            self?.cameraDidMove()
        }
        cameraDidMove()
    }

    func sceneDidChange() {
        renderer?.scene = viewModel.scene
        view?.setNeedsDisplay()
    }

    private func ray(at point: CGPoint) -> Ray? {
        guard let renderer, let view else { return nil }
        return renderer.camera.ray(through: point, viewportSize: view.bounds.size,
                                   centerOffset: renderer.centerOffset)
    }

    // MARK: - ViewportGestureDelegate

    private var gizmoDrag: GizmoDragSession?
    private var dragStartPoint: CGPoint = .zero

    /// World units per screen point at the camera target depth — converts
    /// screen drags for the head-on pull fallback and sketch pick tolerances
    /// (ViewportCameraControl.worldUnitsPerPoint).
    var worldUnitsPerPoint: Double { worldPerPoint }

    private var worldPerPoint: Double {
        guard let renderer, let view, view.bounds.height > 0 else { return 0.01 }
        let camera = renderer.camera
        return Double(2 * camera.distance * tan(camera.fovY * 0.5))
            / Double(view.bounds.height)
    }

    private var pullActive = false
    /// A drag scrubbing the Rotate-Around-Axis angle (5° steps).
    private var rotateAxisDragActive = false
    /// A drag moving the section plane along its normal (spec §16.1).
    private var sectionDragActive = false
    /// A drag scrubbing the chamfer/fillet size on the edge arrow (spec §4.3).
    private var blendDragActive = false
    /// A drag uniformly scaling a selected face (Scale tool). The factor is the
    /// grab's distance from the gizmo centre over its distance at drag start.
    private var faceScaleDragActive = false
    private var faceScaleCenter: CGPoint = .zero
    private var faceScaleInitialDist: CGFloat = 1
    /// A ring drag rotating a selected face (Rotate tool). The gizmo session
    /// yields the signed angle; `faceRotateAxis` is the grabbed ring's world axis.
    private var faceRotateDragActive = false
    private var faceRotateAxis = SIMD3<Double>(0, 0, 1)
    /// A drag on the orientation cube orbiting the camera (spec §7.2): the
    /// universal orbit control, except while numeric entry owns input.
    private var cubeOrbitActive = false
    private var numericEditorBlockedCubeDrag = false
    private var lastCubeDragPoint: CGPoint = .zero

    /// Pivot-reposition drag: moving the gizmo, not the model. The grab point
    /// and the camera-facing plane it slides on are captured at drag start.
    private var pivotDragActive = false
    /// The drag started away from the crosshair: the gizmo follows the
    /// model surface under the finger instead of sliding with a grab offset.
    private var pivotDragOnSurface = false
    /// Snap radius, in points, to a corner of the triangle under the finger.
    private static let pivotSnapPoints: CGFloat = 18
    private var pivotDragOrigin = SIMD3<Float>.zero
    private var pivotDragGrab = SIMD3<Float>.zero
    private var pivotDragNormal = SIMD3<Float>(0, 0, 1)

    func gestureTapped(at point: CGPoint) {
        // Orientation cube first: taps on it never reach the model.
        if let renderer, let view,
           let pose = OrientationCube.hitPose(
               at: point, camera: renderer.camera, viewSize: view.bounds.size
           ) {
            cameraAnimator?.animate(to: pose, duration: 0.4)
            return
        }
        if viewModel.isPickingSymmetryAxis, let ray = ray(at: point) {
            viewModel.handle(.tap(ray: ray))
            sceneDidChange()
            return
        }
        // Touch can arrive at Metal even when a projected SwiftUI control is
        // drawn above it. Dispatch the rectangle's scoped padlock before picks,
        // just as gizmo handles below dispatch before ordinary geometry.
        if viewModel.toggleRectangleCenterLock(at: point) {
            sceneDidChange()
            return
        }
        // Tapping the very centre arms the pivot: the dot becomes a crosshair
        // you drag to drop the whole control somewhere else (the model stays
        // put). Tapping it again puts the dot back.
        if hitsGizmoPivot(point) {
            viewModel.toggleGizmoReposition()
            sceneDidChange()
            return
        }
        // Armed pivot — "move the gizmo" mode: a tap anywhere drops the
        // gizmo there (on the model under the finger, snapped to a nearby
        // corner, else on the plane facing the camera). Dragging the small
        // crosshair alone was too hard on the iPad (Jason, 2026-09-14).
        if viewModel.gizmoRepositionArmed, let ray = ray(at: point),
           let world = gizmoPlacement(at: point, ray: ray) {
            viewModel.setGizmoPivot(world: world)
            sceneDidChange()
            return
        }
        // Tapping (not dragging) a gizmo handle opens exact numeric entry:
        // a distance on an arrow, an angle on a rotation ring.
        if let part = gizmoPart(at: point) {
            if part.isArrow {
                viewModel.beginAxisDistanceEntry(part)
                sceneDidChange()
                return
            }
            if part.isRing {
                viewModel.beginAngleEntry(part)
                sceneDidChange()
                return
            }
        }
        guard let ray = ray(at: point) else { return }
        viewModel.handle(.tap(ray: ray))
    }

    /// Project a gizmo-local offset to screen (local → world → screen), the
    /// same mapping `MoveGizmoOverlay` draws with. nil when no gizmo is up.
    private func gizmoProjector() -> ((SIMD3<Float>) -> CGPoint?)? {
        guard let renderer, let origin = viewModel.gizmoOrigin else { return nil }
        let scale = renderer.gizmoScale(origin: origin)
        return { [weak self] local in
            let world = origin + local * scale
            return self?.worldToScreenPoint(
                SIMD3(Double(world.x), Double(world.y), Double(world.z)))
        }
    }

    /// The gizmo handle under a screen tap — hit-tested against the SAME 2D
    /// anchors the overlay draws, so the flat handle a user sees is the target
    /// they grab (the old 3D-mesh capsule test no longer matched the visual).
    private func gizmoPart(at point: CGPoint) -> GizmoPart? {
        guard let project = gizmoProjector() else { return nil }
        // Rotate-a-face shows ONLY the rings: hit-test rings alone, so an
        // (invisible) axis/plane target near the centre can't win and suppress
        // the ring grab (which would drop the drag to a camera orbit).
        if viewModel.faceRotateActive {
            return GizmoScreenLayout.hitTest(at: point, project: project, ringsOnly: true)
        }
        let part = GizmoScreenLayout.hitTest(at: point, project: project)
        // A face translates, it doesn't rotate — ignore ring hits there so a
        // grab near the (hidden) arcs doesn't try to fold the solid.
        if let part, part.isRing, !viewModel.gizmoAllowsRotation { return nil }
        return part
    }

    /// Debug hook (OS3D_GIZMO_DEBUG=1): trace which gizmo handle a drag grabbed
    /// and the world delta it produces, so a "that didn't move the way the
    /// handle said it would" report can be checked against the actual part.
    private func gizmoDebug(_ message: @autoclosure () -> String) {
        #if DEBUG
        // Read the environment ONCE — `ProcessInfo.environment` rebuilds a
        // dictionary on every access, and this is called per drag frame.
        if Self.gizmoDebugEnabled { print("[gizmo] " + message()) }
        #endif
    }

    #if DEBUG
    private static let gizmoDebugEnabled =
        ProcessInfo.processInfo.environment["OS3D_GIZMO_DEBUG"] != nil
    #endif

    /// Where an armed gizmo goes for a touch at `point`: the model surface
    /// under it — snapped to the nearest corner of the hit triangle when one
    /// is within `pivotSnapPoints` on screen, so a box corner is easy to
    /// land on — else the plane facing the camera through the gizmo's
    /// current position.
    private func gizmoPlacement(at point: CGPoint, ray: Ray) -> SIMD3<Float>? {
        guard let renderer else { return nil }
        if let hit = HitTester.pickBody(ray: ray, in: renderer.scene),
           let drawable = renderer.scene.bodies.first(where: { $0.id == hit.bodyID }) {
            var best = hit.worldPoint
            var bestDistance = Self.pivotSnapPoints
            let mesh = drawable.renderMesh
            let base = hit.triangleIndex * 3
            if base >= 0, base + 2 < mesh.indices.count {
                for k in 0..<3 {
                    let index = Int(mesh.indices[base + k])
                    guard index < mesh.positions.count else { continue }
                    let w4 = drawable.modelMatrix * SIMD4(mesh.positions[index], 1)
                    let world = SIMD3(w4.x, w4.y, w4.z)
                    guard let s = worldToScreenPoint(
                        SIMD3(Double(world.x), Double(world.y), Double(world.z))) else { continue }
                    let d = hypot(s.x - point.x, s.y - point.y)
                    if d < bestDistance {
                        bestDistance = d
                        best = world
                    }
                }
            }
            return best
        }
        guard let origin = viewModel.gizmoOrigin else { return nil }
        let normal = simd_normalize(ray.direction)
        return ray.intersect(planePoint: origin, planeNormal: normal).map { ray.point(at: $0) }
    }

    /// True when `point` lands on the gizmo's centre pivot. The target grows
    /// once the pivot is armed — at that point dragging the control IS the
    /// gesture, so it should be easy to catch.
    private func hitsGizmoPivot(_ point: CGPoint) -> Bool {
        guard let project = gizmoProjector() else { return false }
        return GizmoScreenLayout.hitsPivot(
            at: point, armed: viewModel.gizmoRepositionArmed, project: project)
    }

    func gestureDoubleTapped(at point: CGPoint) {
        guard let ray = ray(at: point) else { return }
        viewModel.handle(.doubleTap(ray: ray))
    }

    /// A one-finger drag drawing the select-mode marquee (plan §B13).
    private var marqueeActive = false

    /// Screen offset (points) of the drawn SF Symbol handle off the projected
    /// cap, and the touch radius around it. MUST match `ExtrudeGizmoOverlay`'s
    /// `float` so the grab region sits exactly under the symbol the user sees.
    static let pullHandleScreenOffset: CGFloat = 30
    private static let pullHandleTouchRadius: CGFloat = 46

    /// True when the screen `point` lands within a touch-friendly radius of the
    /// drawn pull-arrow handle. The handle is a SwiftUI SF Symbol overlay at a
    /// fixed screen offset off the projected cap, so the grab test is done in
    /// screen space (not a world ray) to line up exactly with what's visible.
    private func hitsPullArrowScreen(point: CGPoint, arrow: PullArrowState) -> Bool {
        let o = SIMD3<Double>(Double(arrow.origin.x), Double(arrow.origin.y), Double(arrow.origin.z))
        guard let p0 = worldToScreenPoint(o) else { return false }
        let d = simd_normalize(SIMD3<Double>(Double(arrow.direction.x),
                                             Double(arrow.direction.y),
                                             Double(arrow.direction.z)))
        let p1 = worldToScreenPoint(o + d)
        var ux: CGFloat = 0, uy: CGFloat = -1
        if let p1 {
            let dx = p1.x - p0.x, dy = p1.y - p0.y
            let len = (dx * dx + dy * dy).squareRoot()
            if len > 0.5 { ux = dx / len; uy = dy / len }
        }
        let handle = CGPoint(x: p0.x + ux * Self.pullHandleScreenOffset,
                             y: p0.y + uy * Self.pullHandleScreenOffset)
        return hypot(point.x - handle.x, point.y - handle.y) <= Self.pullHandleTouchRadius
    }

    /// World-mm drag component along the blend arrow's on-screen direction —
    /// positive when dragging the way the arrow points (into the body).
    private func blendDragDelta(to point: CGPoint) -> Double {
        guard let arrow = viewModel.pullArrowState else { return 0 }
        let o = SIMD3<Double>(Double(arrow.origin.x), Double(arrow.origin.y), Double(arrow.origin.z))
        guard let p0 = worldToScreenPoint(o) else { return 0 }
        let d = simd_normalize(SIMD3<Double>(Double(arrow.direction.x),
                                             Double(arrow.direction.y),
                                             Double(arrow.direction.z)))
        var ux: CGFloat = 0, uy: CGFloat = -1
        if let p1 = worldToScreenPoint(o + d) {
            let dx = p1.x - p0.x, dy = p1.y - p0.y
            let len = (dx * dx + dy * dy).squareRoot()
            if len > 0.5 { ux = dx / len; uy = dy / len }
        }
        let dx = point.x - dragStartPoint.x
        let dy = point.y - dragStartPoint.y
        return Double(dx * ux + dy * uy) * worldPerPoint
    }

    func gestureDragBegan(at point: CGPoint, isPencil: Bool) -> Bool {
        dragStartPoint = point
        pullActive = false
        if isPencil { viewModel.sawApplePencil = true }

        // Orientation cube = universal orbit control (spec §7.2): a drag that
        // STARTS on the cube orbits the camera in drawing modes, so the user can
        // always reorient even when a tool owns the rest of the viewport. (A
        // tap on the cube still snaps to that standard view — taps and drags
        // are separate gestures.)
        if let view, OrientationCube.rect(in: view.bounds.size).contains(point) {
            // Native numeric entry blocks cube dragging without committing or
            // dismissing its draft. Claim the gesture so it cannot fall through
            // to canvas orbit or drawing; restore normal cube input on release.
            if viewModel.editingDimension != nil {
                numericEditorBlockedCubeDrag = true
                return true
            }
            cubeOrbitActive = true
            lastCubeDragPoint = point
            return true
        }

        guard let ray = ray(at: point) else { return false }

        // Armed pivot ("move the gizmo" mode): ANY one-finger drag moves the
        // gizmo, not the model or the camera. Starting on the crosshair
        // slides it with the grab offset kept (fine adjustment, no jump);
        // starting anywhere else brings the gizmo under the finger and it
        // follows the model surface from there (`gizmoPlacement`).
        if viewModel.gizmoRepositionArmed, let origin = viewModel.gizmoOrigin {
            pivotDragActive = true
            pivotDragOnSurface = !hitsGizmoPivot(point)
            pivotDragOrigin = origin
            // Slide the pivot on the plane facing the camera through where it
            // sits now — the plain "drag it around on screen" behaviour.
            pivotDragNormal = simd_normalize(ray.direction)
            pivotDragGrab = ray.intersect(planePoint: origin, planeNormal: pivotDragNormal)
                .map { ray.point(at: $0) } ?? origin
            if pivotDragOnSurface, let world = gizmoPlacement(at: point, ray: ray) {
                viewModel.setGizmoPivot(world: world)
                sceneDidChange()
            }
            return true
        }

        // Select mode: one-finger drags draw the marquee (spec §8.2).
        if viewModel.beginMarquee(at: SIMD2(Double(point.x), Double(point.y))) {
            marqueeActive = true
            return true
        }

        // Sketch mode: the Pencil draws, the finger navigates (Shapr3D). Once a
        // Pencil has been used this session, a FINGER drag orbits instead of
        // drawing — so you can reframe the sketch mid-stroke without switching
        // tools. Finger-only users (no Pencil seen) keep drawing with a finger.
        if viewModel.mode.isSketching {
            if !isPencil && viewModel.sawApplePencil {
                return false // let the finger orbit the camera
            }
            return viewModel.beginSketchStroke(ray: ray)
        }

        // Extruding: drags adjust the pull distance / revolve angle.
        if case .extruding = viewModel.mode {
            pullActive = viewModel.beginToolDrag(ray: ray)
            return pullActive
        }

        // Waiting for an axis tap: don't let a stray drag start a new pull.
        if case .pickingRevolveAxis = viewModel.mode {
            return false
        }

        // Waiting for sweep-path / loft-section taps: stray drags orbit.
        if case .pickingSweepPath = viewModel.mode {
            return false
        }
        if case .pickingLoftProfiles = viewModel.mode {
            return false
        }

        // Rotate Around Axis: once the axis is set, drags scrub the angle;
        // before that (and for Translate/Align picks) drags orbit.
        if case .rotatingAroundAxis = viewModel.mode {
            rotateAxisDragActive = viewModel.beginRotateAxisDrag()
            return rotateAxisDragActive
        }
        if case .translating = viewModel.mode {
            return false
        }
        if case .aligning = viewModel.mode {
            return false
        }

        // Choosing a sketch plane: taps pick, drags orbit.
        if case .pickingSketchPlane = viewModel.mode {
            return false
        }

        // Choosing a section plane: taps pick, drags orbit.
        if case .pickingSectionPlane = viewModel.mode {
            return false
        }

        // Section View active: a drag starting on the pull arrow moves the
        // plane along its normal (offset-plane pattern); elsewhere orbits.
        if viewModel.beginSectionDrag(ray: ray) {
            sectionDragActive = true
            return true
        }

        // Chamfer/Fillet pick: grabbing the edge arrow scrubs the blend size
        // (drag into the body = bigger, Shapr3D §4.3); anywhere else orbits.
        if case .pickingBlendEdges = viewModel.mode {
            if let arrow = viewModel.pullArrowState,
               hitsPullArrowScreen(point: point, arrow: arrow),
               viewModel.beginBlendDrag() {
                blendDragActive = true
                return true
            }
            return false
        }

        // Shell pick: taps toggle open faces, drags orbit.
        if case .pickingShellFaces = viewModel.mode {
            return false
        }

        // Delete Face pick: taps toggle faces, drags orbit.
        if case .pickingDeleteFaces = viewModel.mode {
            return false
        }

        // Replace Face pick: taps pick the two faces, drags orbit.
        if case .pickingReplaceFace = viewModel.mode {
            return false
        }

        // Face selected: the normal-direction pull-arrow push/pulls the face
        // (checked first, unchanged). With Move armed, grabbing a gizmo handle
        // MOVES the face (shear); with Scale armed, grabbing a handle SCALES the
        // face about its centre (taper). A drag anywhere else orbits.
        if case .faceSelected = viewModel.mode {
            if let arrow = viewModel.pullArrowState,
               hitsPullArrowScreen(point: point, arrow: arrow),
               viewModel.beginToolDrag(ray: ray) {
                pullActive = true
                return true
            }
            if let renderer, let origin = viewModel.gizmoOrigin,
               let part = gizmoPart(at: point) {
                // Rotate: grabbing a ring rotates the face about that world axis
                // through the centre (an in-plane ring tilts, the normal twists).
                if viewModel.faceRotateActive, part.isRing {
                    let gizmo = GizmoState(
                        origin: origin, scale: renderer.gizmoScale(origin: origin),
                        highlighted: nil)
                    if let session = GizmoDragSession(part: part, gizmo: gizmo, ray: ray),
                       viewModel.beginFaceRotate() {
                        gizmoDrag = session
                        faceRotateAxis = SIMD3<Double>(part.axisDirection)
                        faceRotateDragActive = true
                        viewModel.gizmoHighlight = part
                        viewModel.beginRingRotation(
                            part: part, startAngle: Double(session.ringStartAngle ?? 0))
                        return true
                    }
                    return false
                }
                // Scale: any handle grab starts a uniform scale keyed to the
                // grab's distance from the gizmo centre.
                if viewModel.gizmoIsScale {
                    if let center = worldToScreenPoint(
                        SIMD3(Double(origin.x), Double(origin.y), Double(origin.z))),
                       viewModel.beginFaceScale() {
                        faceScaleCenter = center
                        faceScaleInitialDist = max(
                            hypot(point.x - center.x, point.y - center.y), 12)
                        faceScaleDragActive = true
                        viewModel.gizmoHighlight = part   // light up the grabbed grip
                        return true
                    }
                    return false
                }
                let gizmo = GizmoState(
                    origin: origin,
                    scale: renderer.gizmoScale(origin: origin),
                    highlighted: nil
                )
                if let session = GizmoDragSession(part: part, gizmo: gizmo, ray: ray) {
                    gizmoDrag = session
                    viewModel.gizmoHighlight = part
                    viewModel.beginMove()
                    return true
                }
            }
            return false   // drags off the handles orbit; the face stays put
        }

        // Offer the drag to the gizmo when a body is selected. The part is
        // picked in SCREEN space (matching the 2D overlay); the drag math then
        // runs in 3D from that part.
        if let renderer, let origin = viewModel.gizmoOrigin,
           let part = gizmoPart(at: point) {
            let gizmo = GizmoState(
                origin: origin,
                scale: renderer.gizmoScale(origin: origin),
                highlighted: nil
            )
            if let session = GizmoDragSession(part: part, gizmo: gizmo, ray: ray) {
                gizmoDrag = session
                viewModel.gizmoHighlight = part
                viewModel.beginMove()
                if part.isRing {
                    viewModel.beginRingRotation(
                        part: part, startAngle: Double(session.ringStartAngle ?? 0))
                }
                gizmoDebug("grab \(part) at \(point)")
                return true
            }
        }

        // Shapr3D push/pull: a drag starting on a filled profile extrudes it.
        pullActive = viewModel.beginFillPull(ray: ray)
        return pullActive
    }

    func gestureDragChanged(at point: CGPoint) {
        if numericEditorBlockedCubeDrag { return }
        if pivotDragActive {
            if pivotDragOnSurface {
                if let ray = ray(at: point), let world = gizmoPlacement(at: point, ray: ray) {
                    viewModel.setGizmoPivot(world: world)
                    sceneDidChange()
                }
                return
            }
            if let ray = ray(at: point),
               let t = ray.intersect(planePoint: pivotDragOrigin, planeNormal: pivotDragNormal) {
                // Carry the grab offset so the crosshair doesn't jump to the
                // fingertip on the first frame.
                viewModel.setGizmoPivot(
                    world: pivotDragOrigin + (ray.point(at: t) - pivotDragGrab))
                sceneDidChange()
            }
            return
        }
        if faceRotateDragActive {
            // Mutate the STORED session (not a copy): rotationDelta
            // accumulates its unwrapped total across frames.
            if let ray = ray(at: point),
               let angle = gizmoDrag?.rotationDelta(for: ray) {
                viewModel.updateFaceRotate(angle: Double(angle), axis: faceRotateAxis)
                sceneDidChange()
            }
            return
        }
        if faceScaleDragActive {
            let d = max(hypot(point.x - faceScaleCenter.x, point.y - faceScaleCenter.y), 1)
            let factor = min(max(Double(d / faceScaleInitialDist), 0.05), 20)
            viewModel.updateFaceScale(factor: factor)
            sceneDidChange()
            return
        }
        if cubeOrbitActive {
            guard let renderer, let view else { return }
            let delta = CGSize(
                width: point.x - lastCubeDragPoint.x,
                height: point.y - lastCubeDragPoint.y
            )
            lastCubeDragPoint = point
            renderer.camera.orbit(deltaPixels: delta, viewportSize: view.bounds.size)
            cameraDidMove()
            view.setNeedsDisplay()
            return
        }
        if marqueeActive {
            // The marquee overlay is SwiftUI state — no Metal redraw needed.
            viewModel.updateMarquee(to: SIMD2(Double(point.x), Double(point.y)))
            return
        }
        guard let ray = ray(at: point) else { return }
        if viewModel.mode.isSketching {
            viewModel.updateSketchStroke(ray: ray)
            sceneDidChange()
            return
        }
        if rotateAxisDragActive {
            let screenDelta = Double(dragStartPoint.y - point.y) * worldPerPoint
            viewModel.updateRotateAxisDrag(screenDeltaWorld: screenDelta)
            sceneDidChange()
            return
        }
        if sectionDragActive {
            let screenDelta = Double(dragStartPoint.y - point.y) * worldPerPoint
            viewModel.updateSectionDrag(ray: ray, screenDeltaWorld: screenDelta)
            sceneDidChange()
            return
        }
        if blendDragActive {
            viewModel.updateBlendDrag(delta: blendDragDelta(to: point))
            sceneDidChange()
            return
        }
        if pullActive {
            let screenDelta = Double(dragStartPoint.y - point.y) * worldPerPoint
            viewModel.updateToolDrag(ray: ray, screenDeltaWorld: screenDelta)
            sceneDidChange()
            return
        }
        guard let session = gizmoDrag else { return }
        if session.part.isRing {
            // Mutate the STORED session (not a copy): rotationDelta
            // accumulates its unwrapped total across frames.
            if let angle = gizmoDrag?.rotationDelta(for: ray) {
                viewModel.updateRotation(part: session.part, deltaRadians: angle)
                gizmoDebug("rotate \(session.part) pill=\(viewModel.rotationAngleLabel?.text ?? "-")")
                sceneDidChange()
            }
            return
        }
        guard let delta = session.translationDelta(for: ray) else { return }
        gizmoDebug("move \(session.part) delta \(delta)")
        viewModel.updateMove(delta: delta)
        sceneDidChange()
    }

    func gestureDragEnded(at point: CGPoint) {
        if numericEditorBlockedCubeDrag {
            numericEditorBlockedCubeDrag = false
            return
        }
        if pivotDragActive {
            pivotDragActive = false
            sceneDidChange()
            return
        }
        if faceRotateDragActive {
            faceRotateDragActive = false
            gizmoDrag = nil
            viewModel.gizmoHighlight = nil
            viewModel.endFaceRotate()
            sceneDidChange()
            return
        }
        if faceScaleDragActive {
            faceScaleDragActive = false
            viewModel.gizmoHighlight = nil
            viewModel.endFaceScale()
            sceneDidChange()
            return
        }
        if cubeOrbitActive {
            cubeOrbitActive = false
            return
        }
        if marqueeActive {
            marqueeActive = false
            viewModel.updateMarquee(to: SIMD2(Double(point.x), Double(point.y)))
            viewModel.endMarquee { [weak self] world in
                self?.worldToScreen(world)
            }
            sceneDidChange()
            return
        }
        if viewModel.mode.isSketching, let ray = ray(at: point) {
            viewModel.endSketchStroke(ray: ray)
            sceneDidChange()
            return
        }
        if rotateAxisDragActive {
            // Angle already applied live; commit happens via Apply/empty tap.
            rotateAxisDragActive = false
            sceneDidChange()
            return
        }
        if sectionDragActive {
            sectionDragActive = false
            viewModel.endSectionDrag()
            sceneDidChange()
            return
        }
        if blendDragActive {
            blendDragActive = false
            viewModel.endBlendDrag()
            sceneDidChange()
            return
        }
        if pullActive {
            pullActive = false
            viewModel.endToolDrag()
            sceneDidChange()
            return
        }
        gizmoDrag = nil
        viewModel.gizmoHighlight = nil
        viewModel.endMove()
        sceneDidChange()
    }

    /// Long-press → Select Through popup (plan §B13, spec §8.3).
    func gestureLongPressed(at point: CGPoint) {
        guard let ray = ray(at: point) else { return }
        viewModel.presentSelectThrough(ray: ray)
    }

    /// Apple Pencil double-tap → undo the last action (a Shapr3D-style shortcut).
    func gesturePencilDoubleTapped() {
        viewModel.sawApplePencil = true
        if viewModel.session.undoStack.canUndo || viewModel.hasPendingRectangle {
            viewModel.undo()
            sceneDidChange()
        }
    }

    /// Pointer / Pencil hover → tap-built Line/Rectangle/Arc preview.
    func gestureHovered(at point: CGPoint?) {
        var hoverRay: Ray?
        if let point { hoverRay = ray(at: point) }
        viewModel.hoverRay = hoverRay
        if viewModel.updateLinePreview(ray: hoverRay) {
            sceneDidChange()
        }
    }

    /// World→screen projection for AreaSelect membership tests; nil for
    /// points behind the camera. Matches the renderer camera exactly (same
    /// view/projection matrices, ortho included — clip.w stays 1 there).
    private func worldToScreen(_ world: SIMD3<Float>) -> SIMD2<Double>? {
        guard let renderer, let view else { return nil }
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let camera = renderer.camera
        let viewPoint = camera.viewMatrix * SIMD4(world, 1)
        guard viewPoint.z < 0 else { return nil } // behind the camera
        let aspect = Float(size.width / size.height)
        let clip = camera.projectionMatrix(aspect: aspect, centerOffset: renderer.centerOffset) * viewPoint
        guard clip.w > 1e-9 else { return nil }
        let ndc = SIMD3(clip.x, clip.y, clip.z) / clip.w
        return SIMD2(
            (Double(ndc.x) + 1) / 2 * Double(size.width),
            (1 - Double(ndc.y)) / 2 * Double(size.height)
        )
    }

    // MARK: - ViewportCameraControl

    func fitScene() {
        guard let renderer else { return }
        var target = renderer.camera
        if let bounds = renderer.scene.worldBounds {
            target.fit(boundsMin: bounds.min, boundsMax: bounds.max, aspect: fitAspect)
        } else {
            target = TurntableCamera()
        }
        cameraAnimator?.animate(to: target)
    }

    func fitTo(bounds: (min: SIMD3<Float>, max: SIMD3<Float>)) {
        guard let renderer else { return }
        var target = renderer.camera
        target.fit(boundsMin: bounds.min, boundsMax: bounds.max, aspect: fitAspect)
        cameraAnimator?.animate(to: target)
    }

    /// Width / height of the strip the palette leaves visible (the whole
    /// viewport off a phone); nil before layout (the MTKView starts at
    /// .zero), where a fit falls back to the vertical FOV.
    private var fitAspect: Float? {
        guard let size = view?.bounds.size else { return nil }
        return safeArea.fitAspect(viewportSize: size)
    }

    /// Redo the opening fit with what it could not know at attach — the real
    /// size, then the palette's safe area — while the camera is still exactly
    /// where that fit left it. A camera the user has moved is never
    /// overridden; later resizes then keep the user's framing.
    private func refitIfStillOpening() {
        guard let opening = openingFit, let renderer, let aspect = fitAspect else { return }
        guard renderer.camera == opening, let bounds = renderer.scene.worldBounds else {
            openingFit = nil
            return
        }
        renderer.camera.fit(boundsMin: bounds.min, boundsMax: bounds.max, aspect: aspect)
        openingFit = renderer.camera
    }

    /// EditorView reports the palette's frame on every update (nil off a
    /// phone). The centre shift applies at once; the re-fit and the overlay
    /// re-publish wait a runloop turn, out of SwiftUI's view update.
    func setPalette(frame: CGRect?, onRight: Bool) {
        guard frame != paletteFrame || onRight != paletteOnRight else { return }
        paletteFrame = frame
        paletteOnRight = onRight
        guard updateSafeArea() else { return }
        DispatchQueue.main.async { [weak self] in
            self?.refitIfStillOpening()
            self?.cameraDidMove()
        }
    }

    /// Re-derive the safe area from the palette frame and the current bounds
    /// and hand its centre shift to the renderer — the one value drawing,
    /// picking (`ray(at:)`) and projecting (`worldToScreen`) all read, so
    /// they can never disagree. True when the shift changed.
    @discardableResult
    private func updateSafeArea() -> Bool {
        guard let renderer, let view else { return false }
        let size = view.bounds.size
        let local = paletteFrame.map { view.convert($0, from: nil) }
        safeArea = ViewportSafeArea.palette(at: local, onRight: paletteOnRight, viewportSize: size)
        let offset = safeArea.centerOffset(viewportSize: size)
        guard offset != renderer.centerOffset else { return false }
        renderer.centerOffset = offset
        view.setNeedsDisplay()
        return true
    }

    func animateToStandardView(_ standard: StandardView) {
        guard let renderer else { return }
        cameraAnimator?.animate(to: standard.applied(to: renderer.camera), duration: 0.4)
    }

    func setProjection(orthographic: Bool) {
        guard let renderer else { return }
        renderer.camera.projection = orthographic
            ? .orthographic
            : .perspective(fovY: TurntableCamera.defaultFovY)
        view?.setNeedsDisplay()
    }

    /// Degrees between the camera eye-line and the plane normal (either side).
    private func offAngleDegrees(to plane: SketchPlane) -> Double {
        guard let renderer else { return 0 }
        let camera = renderer.camera
        let eyeOffset = camera.position - camera.target
        guard simd_length(eyeOffset) > 1e-6 else { return 0 }
        let eye = simd_normalize(eyeOffset)
        let n = plane.normal
        let normal = simd_normalize(SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z)))
        let alignment = min(abs(simd_dot(eye, normal)), 1)
        return Double(acos(alignment)) * 180 / .pi
    }

    /// Show Look-at-Sketch while sketching with the camera >10° off head-on.
    private func cameraDidMove() {
        let available: Bool
        if let plane = viewModel.activeSketch?.plane {
            available = offAngleDegrees(to: plane) > EditorViewModel.lookAtSketchThresholdDegrees
        } else {
            available = false
        }
        if viewModel.lookAtSketchAvailable != available {
            viewModel.lookAtSketchAvailable = available
        }
        // Let SwiftUI overlays that reproject world points (dimension labels,
        // plan §C2) re-run their layout as the camera moves.
        viewModel.cameraEpoch &+= 1
    }

    /// Degrees between the camera eye-line and `plane`'s normal — 0 head-on,
    /// 90 edge-on. Used by sketch entry to decide whether the current view is
    /// usable to draw in, and by the Look at Sketch button's visibility.
    func offAxisDegrees(to plane: SketchPlane) -> Double {
        offAngleDegrees(to: plane)
    }

    func orientationCubeLabels() -> [OrientationCube.FaceLabel] {
        guard let renderer, let view else { return [] }
        return OrientationCube.faceLabels(
            camera: renderer.camera, viewSize: view.bounds.size)
    }

    /// World→screen projection for SwiftUI overlays (dimension labels).
    /// Mirrors the private `worldToScreen`, taking Double world coordinates.
    func worldToScreenPoint(_ world: SIMD3<Double>) -> CGPoint? {
        guard let p = worldToScreen(SIMD3<Float>(Float(world.x), Float(world.y), Float(world.z)))
        else { return nil }
        return CGPoint(x: p.x, y: p.y)
    }

    func gizmoWorldScale(at origin: SIMD3<Float>) -> Float {
        renderer?.gizmoScale(origin: origin) ?? 1
    }

    func moveCameraHeadOn(to plane: SketchPlane) {
        guard let renderer else { return }
        var target = renderer.camera
        let origin = plane.origin
        let originF = SIMD3<Float>(Float(origin.x), Float(origin.y), Float(origin.z))
        let n = plane.normal
        var normal = simd_normalize(SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z)))
        // Keep the camera on its current side of the plane.
        if simd_dot(normal, renderer.camera.position - originF) < 0 {
            normal = -normal
        }
        // Turntable angles that put the eye along the plane normal; vertical
        // planes clamp at the elevation limit (top/bottom-down views).
        target.elevation = min(
            max(asin(min(max(normal.y, -1), 1)), -TurntableCamera.elevationLimit),
            TurntableCamera.elevationLimit
        )
        target.azimuth = (abs(normal.x) + abs(normal.z)) > 1e-5 ? atan2(normal.x, normal.z) : 0
        target.target = originF
        target.distance = max(renderer.camera.distance, 14)
        cameraAnimator?.animate(to: target, duration: 0.4)
    }
}

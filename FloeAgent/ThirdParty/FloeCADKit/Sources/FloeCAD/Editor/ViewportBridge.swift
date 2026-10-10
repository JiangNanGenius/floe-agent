//
//  ViewportBridge.swift
//  openshape3d
//
//  The contract between the editor (model side) and the Metal viewport
//  (render side). The viewport consumes ViewportScene and never mutates the
//  document; it reports events back through ViewportEventHandler.
//

import OCCTShim
import Foundation
import simd
#if canImport(MetalKit)
import MetalKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Visualization-lite material (plan §B15): nil on a BodyDrawable keeps the
/// legacy shaded look exactly (metallic 0, legacy fixed highlight).
struct BodyMaterial: Equatable {
    var baseColor: SIMD4<Float>
    var metallic: Float = 0
    var roughness: Float = 0
    /// Encoded image bytes sampled as the albedo when the mesh has texcoords.
    /// Decoded into an MTLTexture keyed by (body id, textureRevision).
    var textureData: Data? = nil
    var textureRevision: UInt64 = 0
}

extension BodyMaterial {
    /// The render-side form of a body's persisted appearance — the one
    /// mapping, shared by the body and by every live preview that stands in
    /// for it (push/pull, blend, shell, delete/replace face), which otherwise
    /// drew the default grey. The texture rides along only when the mesh can
    /// sample it: a rebuilt (boolean'd, blended, previewed) mesh has no
    /// texcoords, so it keeps the colour and drops the image.
    init(spec: BodyMaterialSpec, meshHasTexcoords: Bool, revision: UInt64) {
        self.init(
            baseColor: SIMD4<Float>(spec.baseColor),
            metallic: Float(spec.metallic),
            roughness: Float(spec.roughness),
            textureData: meshHasTexcoords ? spec.baseColorTexture : nil,
            textureRevision: revision
        )
    }
}

/// Everything the renderer needs to draw one body.
struct BodyDrawable: Identifiable {
    let id: BodyID
    var renderMesh: RenderMesh
    var edges: FeatureEdgeSet?
    /// Cache key: buffers are rebuilt only when (id, meshRevision) changes.
    var meshRevision: UInt64
    var modelMatrix: simd_float4x4
    var baseColor: SIMD4<Float>
    var selectionState: UInt32 = 0 // SelectionState raw value
    var isTranslucent: Bool = false
    /// Optional appearance override; when set its baseColor/metallic/roughness
    /// replace `baseColor` and the default shading response.
    var material: BodyMaterial?
    /// Set when this drawable is an ASSEMBLY INSTANCE placement rather than a
    /// document body: the shared source body's mesh is referenced (never
    /// duplicated) and `modelMatrix` carries the instance transform composed
    /// with the source placement. Taps and selection route to the instance id.
    var assemblyInstanceID: UUID? = nil
}

/// A snapshot of what the viewport should draw. Value type, rebuilt cheaply
/// by the editor on any model change (mesh arrays are CoW references).
/// A batch of world-space line segments drawn in one color (sketch entities,
/// pending rubber-band, profile highlights).
struct SketchLineBatch {
    /// Pairs: [a0,b0, a1,b1, ...]
    var segments: [SIMD3<Float>]
    var color: SIMD4<Float>
}

/// Translucent triangles filling closed sketch profiles (Shapr3D-style fill).
struct SketchFillBatch {
    /// Triangle list: 3 vertices per triangle, world space.
    var triangles: [SIMD3<Float>]
    var color: SIMD4<Float>
}

/// Viewport display mode (spec §16.4). `.shaded` is the pre-mode renderer
/// exactly: lit fill + feature edges.
enum DisplayMode: String, CaseIterable, Equatable {
    /// Lit fill + feature edges (default).
    case shaded
    /// Lit fill only.
    case shadedNoEdges
    /// Feature edges over a depth-only prepass — hidden lines stay hidden,
    /// no fill.
    case wireframe
    /// Translucent fill (depth read, no write) + feature edges.
    case xray
}

/// Section view clip plane (spec §16.1). Fragments on the side the normal
/// points AWAY from — dot(p - point, normal) < 0 — are discarded in the lit,
/// edge, fill, and sketch-line shaders. Cut faces are left open (no caps).
struct SectionPlaneState: Equatable {
    var point: SIMD3<Float>
    var normal: SIMD3<Float>
    var enabled: Bool = true

    /// Shader-ready plane: xyz unit normal, w offset (dot(p, xyz) + w >= 0
    /// is kept). Zero when the normal is degenerate.
    var clipVector: SIMD4<Float> {
        let length = simd_length(normal)
        guard length > 1e-6 else { return .zero }
        let n = normal / length
        return SIMD4(n, -simd_dot(n, point))
    }
}

/// A reference image placed in the world (Insert Image, plan §B10). `origin`
/// is the quad CENTER; xAxis/yAxis are unit world directions spanning
/// width × height. Nonisolated so the texture cache can stay actor-free.
nonisolated struct ImageQuadDrawable: Identifiable, Sendable {
    let id: UUID
    var origin: SIMD3<Float>
    var xAxis: SIMD3<Float>
    var yAxis: SIMD3<Float>
    var width: Float
    var height: Float
    var opacity: Float = 1
    /// Encoded image bytes (PNG/JPEG). Decoded into an MTLTexture keyed by
    /// (id, textureRevision) — bump the revision to force a reload.
    var textureData: Data
    var textureRevision: UInt64 = 0
}

/// The extrude pull arrow ("the arrows are the interface for creating an
/// extrude"). Drawn in the overlay pass at the pull cap.
struct PullArrowState: Equatable {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float> // unit
    /// Operation-validity feedback (spec §18): false renders the arrow red
    /// because committing the pending result would fail.
    var isValid: Bool = true
}

struct ViewportScene {
    var bodies: [BodyDrawable] = []
    /// Active sketch grid; nil keeps the modeling view's ground grid.
    var gridPlane: SketchPlane?
    /// Move gizmo, when a body is selected. `scale` is finalized by the
    /// renderer each frame for constant screen size.
    var gizmo: GizmoState?
    /// Sketch overlay lines, drawn after the grid with edge depth bias.
    var sketchLines: [SketchLineBatch] = []
    /// Closed-profile fills, drawn between the grid and the sketch lines.
    var profileFills: [SketchFillBatch] = []
    /// Extrude pull arrow, drawn in the overlay pass.
    var pullArrow: PullArrowState?
    /// Plane picker tiles (origin planes + construction planes) shown while a
    /// sketch tool waits for a plane; drawn in the overlay pass.
    var planePickers: [PlanePickerTile] = []
    /// Section view (spec §16.1); nil (or `enabled == false`) clips nothing.
    var sectionPlane: SectionPlaneState?
    /// Display mode (spec §16.4); `.shaded` matches the pre-mode output.
    var displayMode: DisplayMode = .shaded
    /// Extra low-alpha edge pass with a reversed depth test (spec §16.4
    /// "Show Hidden Edges").
    var showHiddenEdges: Bool = false
    /// Reference images, drawn after the grid and before profile fills.
    var imageQuads: [ImageQuadDrawable] = []
    /// Cheap planar blob shadows under body AABBs (visualization v1).
    var groundShadow: Bool = false

    /// World-space AABB of everything drawn — bodies AND sketches — for
    /// fit-view. Nil when empty.
    ///
    /// Sketches count: a sketch on an empty document used to leave Zoom to
    /// Fit with nothing to frame, so it fell back to the DEFAULT camera — the
    /// drawing you were looking at head-on snapped to an isometric view with
    /// the 950 mm sketch off-screen (gotcha 38). The sketch overlay batches
    /// are already in world space, so folding them in costs one pass.
    var worldBounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var result: (min: SIMD3<Float>, max: SIMD3<Float>)?
        func fold(_ world: SIMD3<Float>) {
            if let current = result {
                result = (simd_min(current.min, world), simd_max(current.max, world))
            } else {
                result = (world, world)
            }
        }
        for body in bodies {
            let aabb = body.renderMesh.localAABB
            // Transform the 8 corners; cheap and correct for TRS.
            for i in 0..<8 {
                let corner = SIMD3<Float>(
                    (i & 1) == 0 ? aabb.min.x : aabb.max.x,
                    (i & 2) == 0 ? aabb.min.y : aabb.max.y,
                    (i & 4) == 0 ? aabb.min.z : aabb.max.z
                )
                let world4 = body.modelMatrix * SIMD4(corner, 1)
                fold(SIMD3(world4.x, world4.y, world4.z))
            }
        }
        for batch in sketchLines {
            for point in batch.segments { fold(point) }
        }
        for batch in profileFills {
            for point in batch.triangles { fold(point) }
        }
        return result
    }
}

// MARK: - Canvas preview (viewport, independent of drawings)

#if canImport(MetalKit)
public extension FloeCADDocument {
    /// Offscreen VIEWPORT thumbnail of the live document scene (bodies, grid,
    /// assembly instances) — a Canvas node preview must never depend on an
    /// engineering DRAWING page existing. Returns nil when Metal is
    /// unavailable; callers may then use `CADCanvasPreview.placeholderPNG()`.
    ///
    /// ISOLATION (canvas-apply CUA regression): the snapshot is rendered by a
    /// DETACHED `Renderer` over a value-type copy of `viewModel.scene`, fitted
    /// with its own local camera. It deliberately does NOT go through
    /// `ViewportCoordinator.attach`, which would (a) install the transient
    /// coordinator as the shared view model's `cameraControl` and overwrite
    /// its `thumbnailProvider`/`screenshotProvider`, and (b) fit ITS camera to
    /// the scene. The editor's live renderer callbacks, camera, selection and
    /// orientation cube are therefore untouched — closing the tools panel
    /// after "Apply to canvas" can no longer re-frame or blank the live
    /// viewport.
    @MainActor
    func viewportThumbnailPNG(width: Int = 640, height: Int = 480) -> Data? {
        guard width > 0, height > 0 else { return nil }
        guard let context = RenderContext() else { return nil }
        // Read the current scene ONCE (a value type with CoW mesh references);
        // the snapshot renderer never observes or mutates the editor.
        let snapshot = viewModel().scene
        let snapshotRenderer = Renderer(context: context)
        return snapshotRenderer.makeSceneSnapshotPNG(
            snapshot, width: width, height: height)
    }
}
#endif

/// Explicit preview placeholder, used ONLY when the viewport renderer is
/// unavailable on this device: the canvas node still binds the editable
/// `.floecad` package instead of failing the creation. The image is deliberately
/// NOT a blank grey rectangle (which read as "an undecodable image") — it draws
/// an explicit cube glyph and a CAD label so a human can tell a real render is
/// unavailable from a genuine preview of an empty/unrenderable scene.
public enum CADCanvasPreview {
    public static func placeholderPNG(width: Int = 640, height: Int = 480) -> Data? {
        #if canImport(UIKit)
        let size = CGSize(width: max(width, 1), height: max(height, 1))
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            UIColor.secondarySystemFill.setFill()
            context.fill(rect)
            let stroke = UIColor.secondaryLabel.withAlphaComponent(0.55)
            // Rounded border keeps it distinct from a rasterized photo.
            let inset = rect.insetBy(dx: size.width * 0.08, dy: size.height * 0.10)
            let border = UIBezierPath(roundedRect: inset, cornerRadius: size.height * 0.06)
            border.lineWidth = max(2, size.height * 0.008)
            stroke.setStroke()
            border.stroke()
            // Explicit cube glyph, drawn as a wireframe isometric cube so the
            // placeholder reads as "3D CAD" without depending on SF Symbols in
            // an offscreen graphics context.
            let cx = rect.midX
            let glyphH = size.height * 0.30
            let glyphW = glyphH
            let topY = inset.minY + size.height * 0.10
            let s = glyphW * 0.5
            let front = CGRect(x: cx - s, y: topY + s * 0.6, width: s * 2, height: s * 2)
            let dx = s * 0.6, dy = -s * 0.6
            let glyph = UIBezierPath()
            glyph.lineWidth = max(2, size.height * 0.010)
            stroke.setStroke()
            // Front face
            glyph.move(to: front.origin)
            glyph.addLine(to: CGPoint(x: front.maxX, y: front.minY))
            glyph.addLine(to: CGPoint(x: front.maxX, y: front.maxY))
            glyph.addLine(to: CGPoint(x: front.minX, y: front.maxY))
            glyph.close()
            // Top + side edges
            let shifted = front.offsetBy(dx: dx, dy: dy)
            glyph.move(to: front.origin)
            glyph.addLine(to: shifted.origin)
            glyph.move(to: CGPoint(x: front.maxX, y: front.minY))
            glyph.addLine(to: CGPoint(x: shifted.maxX, y: shifted.minY))
            glyph.move(to: CGPoint(x: front.maxX, y: front.maxY))
            glyph.addLine(to: CGPoint(x: shifted.maxX, y: shifted.maxY))
            glyph.append(UIBezierPath(rect: shifted))
            glyph.stroke()
            // Explicit label.
            let label = "CAD"
            let font = UIFont.systemFont(ofSize: size.height * 0.11, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.secondaryLabel,
            ]
            let textSize = label.size(withAttributes: attrs)
            let textPoint = CGPoint(x: cx - textSize.width / 2,
                                    y: front.maxY + size.height * 0.06)
            label.draw(at: textPoint, withAttributes: attrs)
        }.pngData()
        #else
        return nil
        #endif
    }
}

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

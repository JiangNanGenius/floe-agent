//
//  PlanePicking.swift
//  openshape3d
//
//  Tappable plane tiles: the three origin plane pickers shown when a sketch
//  tool is waiting for a plane (spec §2.3), plus construction-plane quads.
//  Hit-testing mirrors HitTester's ray casting.
//

import Foundation
import simd

/// One tappable plane tile, drawn in the gizmo overlay pass.
nonisolated struct PlanePickerTile {
    /// Construction plane id; nil for the three world-plane tiles.
    var planeID: ConstructionPlaneID?
    var plane: SketchPlane
    /// Tile rectangle in plane-local coordinates.
    var localMin: SIMD2<Double>
    var localMax: SIMD2<Double>
    var color: SIMD4<Float>
    /// Origin tiles keep a constant on-screen size (Shapr3D's plane picker):
    /// `localMin`/`localMax` are then fractions of the outer edge, and the
    /// renderer (per frame) and the hit test (per tap) both resolve them with
    /// `scaled(by:)` at the camera's world-per-gizmo-unit at the origin.
    var screenProportional = false

    func scaled(by scale: Double) -> PlanePickerTile {
        var tile = self
        tile.localMin *= scale
        tile.localMax *= scale
        return tile
    }

    /// Quad corners in world space (CCW in plane space), for rendering.
    var worldCorners: [SIMD3<Float>] {
        [
            SIMD2(localMin.x, localMin.y),
            SIMD2(localMax.x, localMin.y),
            SIMD2(localMax.x, localMax.y),
            SIMD2(localMin.x, localMax.y),
        ].map { corner in
            let world = plane.toWorld(corner)
            return SIMD3(Float(world.x), Float(world.y), Float(world.z))
        }
    }
}

nonisolated enum PlanePicking {
    /// World tiles sit corner-to-origin so the three quads don't overlap.
    static let worldTileMin = 0.3
    static let worldTileMax = 2.3

    /// Outer edge of an origin tile in gizmo units (`gizmoWorldScale(at:)`,
    /// the scale that keeps the gizmo the same size on screen), so the
    /// picker reads the same zoomed way out or in — on the iPad it was a
    /// speck when zoomed out and a wall when zoomed in (2026-09-14). 1.5
    /// gizmo units is about a third of the view's half height per tile.
    static let originTileGizmoUnits = 1.5

    /// The three origin plane pickers (colors keyed like the gizmo axes by
    /// normal: +Y green, +Z blue, +X red) as fractions of the outer edge —
    /// see `PlanePickerTile.screenProportional`. The inner corner gap keeps
    /// the three quads from overlapping.
    static let originTiles: [PlanePickerTile] = {
        let lo = SIMD2(worldTileMin / worldTileMax, worldTileMin / worldTileMax)
        let hi = SIMD2(1.0, 1.0)
        return [
            PlanePickerTile(
                planeID: nil, plane: .ground, localMin: lo, localMax: hi,
                color: SIMD4(0.35, 0.72, 0.28, 0.35), screenProportional: true
            ),
            PlanePickerTile(
                planeID: nil, plane: .worldXY, localMin: lo, localMax: hi,
                color: SIMD4(0.26, 0.47, 0.90, 0.35), screenProportional: true
            ),
            PlanePickerTile(
                planeID: nil, plane: .worldYZ, localMin: lo, localMax: hi,
                color: SIMD4(0.88, 0.26, 0.26, 0.35), screenProportional: true
            ),
        ]
    }()

    /// The origin tiles at their camera-less size — the 2.3 mm default a
    /// unit test without a viewport sees.
    static let worldTiles: [PlanePickerTile] = originTiles.map { $0.scaled(by: worldTileMax) }

    /// World units of an origin tile's outer edge for a gizmo unit.
    static func originTileScale(gizmoUnit: Double) -> Double {
        max(gizmoUnit, 1e-9) * originTileGizmoUnits
    }

    /// Nearest tile hit by the ray, with its world-space distance.
    static func pick(
        ray: Ray, tiles: [PlanePickerTile]
    ) -> (tile: PlanePickerTile, distance: Float)? {
        var best: (tile: PlanePickerTile, distance: Float)?
        for tile in tiles {
            let plane = tile.plane
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
            guard local.x >= tile.localMin.x, local.x <= tile.localMax.x,
                  local.y >= tile.localMin.y, local.y <= tile.localMax.y
            else { continue }
            if best == nil || t < best!.distance {
                best = (tile, t)
            }
        }
        return best
    }
}

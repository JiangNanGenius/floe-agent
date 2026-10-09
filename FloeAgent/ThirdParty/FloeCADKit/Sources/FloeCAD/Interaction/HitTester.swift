//
//  HitTester.swift
//  openshape3d
//
//  CPU ray casting: AABB slab rejection then Möller–Trumbore over triangles.
//  Synchronous — used inside gesture callbacks to route interactions.
//

import Foundation
import simd

nonisolated struct PickHit {
    var bodyID: BodyID
    var distance: Float
    var worldPoint: SIMD3<Float>
    /// Index of the hit triangle in the body's RenderMesh (face picking).
    var triangleIndex: Int
}

nonisolated enum HitTester {

    static func pickBody(ray: Ray, in scene: ViewportScene) -> PickHit? {
        var best: PickHit?
        for drawable in scene.bodies where !drawable.isTranslucent {
            let inverse = simd_inverse(drawable.modelMatrix)
            let localRay = ray.transformed(by: inverse)
            let aabb = drawable.renderMesh.localAABB
            guard slabTest(ray: localRay, min: aabb.min, max: aabb.max) else { continue }

            let mesh = drawable.renderMesh
            var triangle = 0
            while triangle < mesh.triangleCount {
                let index = triangle
                let i0 = Int(mesh.indices[triangle * 3])
                let i1 = Int(mesh.indices[triangle * 3 + 1])
                let i2 = Int(mesh.indices[triangle * 3 + 2])
                triangle += 1
                if let tLocal = intersectTriangle(
                    ray: localRay,
                    v0: mesh.positions[i0], v1: mesh.positions[i1], v2: mesh.positions[i2]
                ) {
                    // Convert hit to world space to compare distances across
                    // bodies with different transforms.
                    let localPoint = localRay.point(at: tLocal)
                    let world4 = drawable.modelMatrix * SIMD4(localPoint, 1)
                    let worldPoint = SIMD3(world4.x, world4.y, world4.z)
                    let distance = simd_length(worldPoint - ray.origin)
                    if best == nil || distance < best!.distance {
                        best = PickHit(
                            bodyID: drawable.id,
                            distance: distance,
                            worldPoint: worldPoint,
                            triangleIndex: index
                        )
                    }
                }
            }
        }
        return best
    }

    /// Select Through (plan §B13, spec §8.3): every body under the ray —
    /// the nearest hit per body — sorted front→back by world distance.
    static func pickAllBodies(ray: Ray, in scene: ViewportScene) -> [PickHit] {
        var hits: [PickHit] = []
        for drawable in scene.bodies where !drawable.isTranslucent {
            let inverse = simd_inverse(drawable.modelMatrix)
            let localRay = ray.transformed(by: inverse)
            let aabb = drawable.renderMesh.localAABB
            guard slabTest(ray: localRay, min: aabb.min, max: aabb.max) else { continue }

            let mesh = drawable.renderMesh
            var best: PickHit?
            for triangle in 0..<mesh.triangleCount {
                let i0 = Int(mesh.indices[triangle * 3])
                let i1 = Int(mesh.indices[triangle * 3 + 1])
                let i2 = Int(mesh.indices[triangle * 3 + 2])
                if let tLocal = intersectTriangle(
                    ray: localRay,
                    v0: mesh.positions[i0], v1: mesh.positions[i1], v2: mesh.positions[i2]
                ) {
                    let localPoint = localRay.point(at: tLocal)
                    let world4 = drawable.modelMatrix * SIMD4(localPoint, 1)
                    let worldPoint = SIMD3(world4.x, world4.y, world4.z)
                    let distance = simd_length(worldPoint - ray.origin)
                    if best == nil || distance < best!.distance {
                        best = PickHit(
                            bodyID: drawable.id,
                            distance: distance,
                            worldPoint: worldPoint,
                            triangleIndex: triangle
                        )
                    }
                }
            }
            if let best {
                hits.append(best)
            }
        }
        return hits.sorted { $0.distance < $1.distance }
    }

    /// Every surface intersection, including the far side of the same body.
    /// Callers group triangles into topology faces before presenting choices.
    static func pickAllSurfaces(ray: Ray, in scene: ViewportScene) -> [PickHit] {
        var hits: [PickHit] = []
        for drawable in scene.bodies where !drawable.isTranslucent {
            let localRay = ray.transformed(by: simd_inverse(drawable.modelMatrix))
            let mesh = drawable.renderMesh
            let bounds = mesh.localAABB
            guard slabTest(ray: localRay, min: bounds.min, max: bounds.max) else { continue }
            for triangle in 0..<mesh.triangleCount {
                let indices = (0..<3).map { Int(mesh.indices[triangle * 3 + $0]) }
                guard let distance = intersectTriangle(ray: localRay,
                    v0: mesh.positions[indices[0]], v1: mesh.positions[indices[1]],
                    v2: mesh.positions[indices[2]]) else { continue }
                let world = drawable.modelMatrix * SIMD4(localRay.point(at: distance), 1)
                let point = SIMD3(world.x, world.y, world.z)
                hits.append(PickHit(bodyID: drawable.id,
                    distance: simd_length(point - ray.origin), worldPoint: point,
                    triangleIndex: triangle))
            }
        }
        return hits.sorted { $0.distance < $1.distance }
    }

    // MARK: - Primitives

    static func slabTest(ray: Ray, min lo: SIMD3<Float>, max hi: SIMD3<Float>) -> Bool {
        var tMin: Float = 0
        var tMax: Float = .greatestFiniteMagnitude
        for axis in 0..<3 {
            let origin = ray.origin[axis]
            let direction = ray.direction[axis]
            if abs(direction) < 1e-9 {
                if origin < lo[axis] || origin > hi[axis] { return false }
            } else {
                var t0 = (lo[axis] - origin) / direction
                var t1 = (hi[axis] - origin) / direction
                if t0 > t1 { swap(&t0, &t1) }
                tMin = max(tMin, t0)
                tMax = min(tMax, t1)
                if tMin > tMax { return false }
            }
        }
        return true
    }

    /// Möller–Trumbore; returns ray parameter t, or nil. Double-sided.
    static func intersectTriangle(
        ray: Ray,
        v0: SIMD3<Float>, v1: SIMD3<Float>, v2: SIMD3<Float>
    ) -> Float? {
        let edge1 = v1 - v0
        let edge2 = v2 - v0
        let h = simd_cross(ray.direction, edge2)
        let a = simd_dot(edge1, h)
        guard abs(a) > 1e-9 else { return nil }
        let f = 1 / a
        let s = ray.origin - v0
        let u = f * simd_dot(s, h)
        guard u >= -1e-6, u <= 1 + 1e-6 else { return nil }
        let q = simd_cross(s, edge1)
        let v = f * simd_dot(ray.direction, q)
        guard v >= -1e-6, u + v <= 1 + 1e-6 else { return nil }
        let t = f * simd_dot(edge2, q)
        return t > 1e-5 ? t : nil
    }
}

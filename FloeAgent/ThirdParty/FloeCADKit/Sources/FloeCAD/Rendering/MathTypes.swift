//
//  MathTypes.swift
//  openshape3d
//
//  Small geometry helpers for the viewport: rays, planes, projection matrices.
//  Rendering-side math is Float; kernel math is Double (see GeometryTypes).
//

import Foundation
import simd

nonisolated struct Ray: Sendable {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float> // normalized

    /// Transform into another space (e.g. body-local via inverse model matrix).
    func transformed(by matrix: simd_float4x4) -> Ray {
        let o = matrix * SIMD4(origin, 1)
        let d = matrix * SIMD4(direction, 0)
        return Ray(origin: SIMD3(o.x, o.y, o.z), direction: simd_normalize(SIMD3(d.x, d.y, d.z)))
    }

    /// Intersection parameter with plane (point p, normal n), nil if parallel
    /// or behind the origin.
    func intersect(planePoint: SIMD3<Float>, planeNormal: SIMD3<Float>) -> Float? {
        let denom = simd_dot(direction, planeNormal)
        guard abs(denom) > 1e-8 else { return nil }
        let t = simd_dot(planePoint - origin, planeNormal) / denom
        return t >= 0 ? t : nil
    }

    func point(at t: Float) -> SIMD3<Float> {
        origin + direction * t
    }
}

nonisolated enum LineMath {
    /// Parameter along the line (origin + t·direction) of the point nearest to
    /// the ray; nil when nearly parallel.
    static func closestParamOnLine(
        origin: SIMD3<Float>, direction: SIMD3<Float>, to ray: Ray
    ) -> Float? {
        let w0 = ray.origin - origin
        let a = simd_dot(ray.direction, ray.direction)
        let b = simd_dot(ray.direction, direction)
        let c = simd_dot(direction, direction)
        let d = simd_dot(ray.direction, w0)
        let e = simd_dot(direction, w0)
        let denom = a * c - b * b
        guard abs(denom) > 1e-6 else { return nil }
        return (a * e - b * d) / denom
    }
}

nonisolated enum Matrices {
    /// Right-handed perspective projection, depth range [0, 1] (Metal).
    static func perspective(fovYRadians: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tan(fovYRadians * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return simd_float4x4(
            SIMD4(xs, 0, 0, 0),
            SIMD4(0, ys, 0, 0),
            SIMD4(0, 0, zs, -1),
            SIMD4(0, 0, zs * near, 0)
        )
    }

    /// Right-handed orthographic projection centered on the view axis, depth
    /// range [0, 1] (Metal). `near`/`far` are distances along -Z (near may be
    /// negative to include geometry behind the eye plane).
    static func orthographic(halfWidth: Float, halfHeight: Float, near: Float, far: Float) -> simd_float4x4 {
        let zs = 1 / (near - far)
        return simd_float4x4(
            SIMD4(1 / halfWidth, 0, 0, 0),
            SIMD4(0, 1 / halfHeight, 0, 0),
            SIMD4(0, 0, zs, 0),
            SIMD4(0, 0, zs * near, 1)
        )
    }

    /// Right-handed look-at view matrix.
    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - target)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        return simd_float4x4(
            SIMD4(x.x, y.x, z.x, 0),
            SIMD4(x.y, y.y, z.y, 0),
            SIMD4(x.z, y.z, z.z, 0),
            SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)
        )
    }
}

//
//  TransformAxis.swift
//  openshape3d
//
//  Rigid rotation of a body transform about an arbitrary world axis line
//  (plan §B6, spec §5.3). Rotating about an axis that does not pass through
//  the body's pivot changes the translation too: the pivot orbits the axis.
//

import Foundation
import simd

nonisolated extension Transform3D {
    /// The transform after rotating rigidly by `radians` (right-handed) about
    /// the world line through `point` along `direction`. A degenerate
    /// direction returns `self` unchanged.
    func rotated(
        byRadians radians: Double,
        aboutAxisThrough point: SIMD3<Double>,
        direction: SIMD3<Double>
    ) -> Transform3D {
        let length = simd_length(direction)
        guard length > 1e-12 else { return self }
        let q = simd_quatd(angle: radians, axis: direction / length)
        var result = self
        result.rotation = simd_normalize(q * rotation)
        result.translation = q.act(translation - point) + point
        return result
    }
}

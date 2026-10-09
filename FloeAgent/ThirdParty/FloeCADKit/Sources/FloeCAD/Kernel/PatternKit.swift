//
//  PatternKit.swift
//  openshape3d
//
//  Pattern math (spec §1.11 sketch patterns, §5.7 3D patterns): pure
//  instance-transform generation for linear and circular patterns. The first
//  instance is always the ORIGINAL (identity) — spec §1.11 says to constrain
//  the first copy, never the last, so instance 0 must stay put.
//

import Foundation
import simd

/// Rigid 2D transform in sketch-plane coordinates: rotate by `rotation`
/// (radians, CCW) about `pivot`, then translate.
nonisolated struct SketchPatternTransform: Equatable, Sendable {
    var translation: SIMD2<Double> = .zero
    var rotation: Double = 0
    var pivot: SIMD2<Double> = .zero

    static let identity = SketchPatternTransform()

    func apply(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        let d = p - pivot
        let rotated = SIMD2(d.x * cosR - d.y * sinR, d.x * sinR + d.y * cosR)
        return pivot + rotated + translation
    }
}

nonisolated enum PatternKit {

    // MARK: - 3D transforms

    /// Linear pattern deltas along one, two, or three axes (spec §5.7).
    /// `spacing` is the adjacent-center distance along the (normalized)
    /// direction. Instance order varies the first direction fastest; the
    /// first element is always `.identity`.
    static func linearTransforms(
        direction: SIMD3<Double>,
        spacing: Double,
        count: Int,
        secondDirection: SIMD3<Double>? = nil,
        secondSpacing: Double = 0,
        secondCount: Int = 1,
        thirdDirection: SIMD3<Double>? = nil,
        thirdSpacing: Double = 0,
        thirdCount: Int = 1
    ) -> [Transform3D] {
        let step1 = unitOrZero(direction) * spacing
        let step2 = unitOrZero(secondDirection ?? .zero) * secondSpacing
        let step3 = unitOrZero(thirdDirection ?? .zero) * thirdSpacing
        var result: [Transform3D] = []
        for k in 0..<max(1, thirdCount) {
            for j in 0..<max(1, secondCount) {
                for i in 0..<max(1, count) {
                    var t = Transform3D.identity
                    t.translation = step1 * Double(i) + step2 * Double(j) + step3 * Double(k)
                    result.append(t)
                }
            }
        }
        return result
    }

    /// Circular pattern about `axis` through `center` (spec §5.7). If
    /// `totalAngle` is a full turn the step is `totalAngle / count` so the
    /// last instance doesn't coincide with the first; otherwise `totalAngle`
    /// is the first→last center-to-center sweep (`totalAngle / (count - 1)`).
    /// `rotateInstances` (Rotated) spins each copy about the axis; Uniform
    /// keeps orientation, moving `referencePoint` along the circle instead.
    /// The first element is always `.identity`.
    static func circularTransforms(
        center: SIMD3<Double>,
        axis: SIMD3<Double>,
        count: Int,
        totalAngle: Double,
        rotateInstances: Bool,
        referencePoint: SIMD3<Double> = .zero
    ) -> [Transform3D] {
        let n = max(1, count)
        let step = angularStep(totalAngle: totalAngle, count: n)
        let unitAxis = unitOrZero(axis)
        guard simd_length(unitAxis) > 0.5 else {
            return Array(repeating: .identity, count: n)
        }
        return (0..<n).map { i in
            let q = simd_quatd(angle: step * Double(i), axis: unitAxis)
            var t = Transform3D.identity
            if rotateInstances {
                t.rotation = q
                t.translation = center - q.act(center)
            } else {
                t.translation = center + q.act(referencePoint - center) - referencePoint
            }
            return t
        }
    }

    // MARK: - Sketch-space (2D) transforms

    /// In-plane linear pattern (spec §1.11). Same conventions as the 3D
    /// variant: normalized directions, first instance identity, first
    /// direction varies fastest.
    static func linearSketchTransforms(
        direction: SIMD2<Double>,
        spacing: Double,
        count: Int,
        secondDirection: SIMD2<Double>? = nil,
        secondSpacing: Double = 0,
        secondCount: Int = 1
    ) -> [SketchPatternTransform] {
        let step1 = unitOrZero(direction) * spacing
        let step2 = unitOrZero(secondDirection ?? .zero) * secondSpacing
        var result: [SketchPatternTransform] = []
        for j in 0..<max(1, secondCount) {
            for i in 0..<max(1, count) {
                var t = SketchPatternTransform.identity
                t.translation = step1 * Double(i) + step2 * Double(j)
                result.append(t)
            }
        }
        return result
    }

    /// In-plane circular pattern about `center` (spec §1.11). Rotated spins
    /// each copy about `center`; Uniform keeps orientation and moves
    /// `referencePoint` along the circle. The first element is `.identity`.
    static func circularSketchTransforms(
        center: SIMD2<Double>,
        count: Int,
        totalAngle: Double,
        rotateInstances: Bool,
        referencePoint: SIMD2<Double> = .zero
    ) -> [SketchPatternTransform] {
        let n = max(1, count)
        let step = angularStep(totalAngle: totalAngle, count: n)
        return (0..<n).map { i in
            let angle = step * Double(i)
            var t = SketchPatternTransform.identity
            if rotateInstances {
                t.rotation = angle
                t.pivot = center
            } else {
                let cosA = cos(angle)
                let sinA = sin(angle)
                let d = referencePoint - center
                let rotated = SIMD2(d.x * cosA - d.y * sinA, d.x * sinA + d.y * cosA)
                t.translation = center + rotated - referencePoint
            }
            return t
        }
    }

    // MARK: - Entity instancing

    /// A transformed copy of `entity` with fresh IDs. Most entities map 1:1;
    /// an axis-aligned rect under a real rotation explodes into four lines
    /// (there is no rotated-rect case in `SketchEntity`).
    static func transformed(_ entity: SketchEntity, by t: SketchPatternTransform) -> [SketchEntity] {
        switch entity {
        case let .line(_, a, b):
            return [.line(id: UUID(), a: t.apply(a), b: t.apply(b))]
        case let .rect(_, lo, hi):
            if isPureTranslation(t) {
                return [.rect(id: UUID(), min: t.apply(lo), max: t.apply(hi))]
            }
            let corners = [
                lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y),
            ].map { t.apply($0) }
            return corners.indices.map { i in
                .line(id: UUID(), a: corners[i], b: corners[(i + 1) % corners.count])
            }
        case let .circle(_, center, radius):
            return [.circle(id: UUID(), center: t.apply(center), radius: radius)]
        case let .arc(_, center, radius, startAngle, endAngle):
            return [.arc(
                id: UUID(), center: t.apply(center), radius: radius,
                startAngle: startAngle + t.rotation, endAngle: endAngle + t.rotation
            )]
        case let .ellipse(_, center, radiusX, radiusY, rotation):
            return [.ellipse(
                id: UUID(), center: t.apply(center), radiusX: radiusX,
                radiusY: radiusY, rotation: rotation + t.rotation
            )]
        case let .polygon(_, center, radius, sides, rotation):
            return [.polygon(
                id: UUID(), center: t.apply(center), radius: radius,
                sides: sides, rotation: rotation + t.rotation
            )]
        case let .spline(_, points, closed):
            // Transforming the fit points transforms the curve exactly, for
            // rotation as well as translation — no explode needed.
            return [.spline(id: UUID(), points: points.map(t.apply), closed: closed)]
        }
    }

    // MARK: - Helpers

    /// Angular step between adjacent instances. A full ±360° total closes the
    /// ring (`totalAngle / count`, spec §1.11 "snapping to 360° near full
    /// turn"); anything else spreads first→last over `totalAngle`.
    private static func angularStep(totalAngle: Double, count: Int) -> Double {
        guard count > 1 else { return 0 }
        let fullTurn = abs(abs(totalAngle) - 2 * .pi) < 1e-9
        return fullTurn ? totalAngle / Double(count) : totalAngle / Double(count - 1)
    }

    private static func unitOrZero(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let length = simd_length(v)
        return length > 1e-12 ? v / length : .zero
    }

    private static func unitOrZero(_ v: SIMD2<Double>) -> SIMD2<Double> {
        let length = simd_length(v)
        return length > 1e-12 ? v / length : .zero
    }

    private static func isPureTranslation(_ t: SketchPatternTransform) -> Bool {
        abs(sin(t.rotation)) < 1e-12 && cos(t.rotation) > 0
    }
}

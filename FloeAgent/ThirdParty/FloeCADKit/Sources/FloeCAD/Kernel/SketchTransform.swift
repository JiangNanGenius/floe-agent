//
//  SketchTransform.swift
//  openshape3d
//
//  Pure 2D transforms over sketch entities (plan §B6). All functions return
//  new entities preserving the input IDs so amend-coalesced move/rotate/scale
//  commands can repeatedly re-derive from the original entities. The one
//  exception: a rect rotated by a non-right angle cannot stay a rect (the
//  case has no rotation field) and decomposes into 4 lines — the first line
//  inherits the rect's ID, the rest get fresh IDs.
//

import Foundation
import simd

nonisolated enum SketchTransform {

    // MARK: Translate

    static func translate(entities: [SketchEntity], by delta: SIMD2<Double>) -> [SketchEntity] {
        entities.map { entity in
            switch entity {
            case let .line(id, a, b):
                .line(id: id, a: a + delta, b: b + delta)
            case let .rect(id, lo, hi):
                .rect(id: id, min: lo + delta, max: hi + delta)
            case let .circle(id, center, radius):
                .circle(id: id, center: center + delta, radius: radius)
            case let .arc(id, center, radius, start, end):
                .arc(id: id, center: center + delta, radius: radius,
                     startAngle: start, endAngle: end)
            case let .ellipse(id, center, rx, ry, rotation):
                .ellipse(id: id, center: center + delta, radiusX: rx, radiusY: ry,
                         rotation: rotation)
            case let .polygon(id, center, radius, sides, rotation):
                .polygon(id: id, center: center + delta, radius: radius, sides: sides,
                         rotation: rotation)
            case let .spline(id, points, closed):
                .spline(id: id, points: points.map { $0 + delta }, closed: closed)
            }
        }
    }

    // MARK: Rotate

    /// Rotates CCW by `angle` (radians) about `pivot`. Arc start/end angles
    /// and ellipse/polygon rotation fields shift by `angle`; rects survive
    /// right-angle rotations as rects and otherwise decompose into 4 lines.
    static func rotate(
        entities: [SketchEntity], about pivot: SIMD2<Double>, angle: Double
    ) -> [SketchEntity] {
        let cosA = cos(angle)
        let sinA = sin(angle)
        func rotated(_ p: SIMD2<Double>) -> SIMD2<Double> {
            let d = p - pivot
            return pivot + SIMD2(d.x * cosA - d.y * sinA, d.x * sinA + d.y * cosA)
        }

        // Multiples of 90° keep axis-aligned rects axis-aligned.
        let quarterTurns = angle / (.pi / 2)
        let isRightAngle = abs(quarterTurns - quarterTurns.rounded()) < 1e-9

        var result: [SketchEntity] = []
        result.reserveCapacity(entities.count)
        for entity in entities {
            switch entity {
            case let .line(id, a, b):
                result.append(.line(id: id, a: rotated(a), b: rotated(b)))
            case let .rect(id, lo, hi):
                if isRightAngle {
                    let a = rotated(lo)
                    let b = rotated(hi)
                    result.append(.rect(id: id, min: simd_min(a, b), max: simd_max(a, b)))
                } else {
                    let corners = [lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y)].map(rotated)
                    for i in 0..<4 {
                        result.append(.line(
                            id: i == 0 ? id : UUID(),
                            a: corners[i], b: corners[(i + 1) % 4]
                        ))
                    }
                }
            case let .circle(id, center, radius):
                result.append(.circle(id: id, center: rotated(center), radius: radius))
            case let .arc(id, center, radius, start, end):
                result.append(.arc(
                    id: id, center: rotated(center), radius: radius,
                    startAngle: start + angle, endAngle: end + angle
                ))
            case let .ellipse(id, center, rx, ry, rotation):
                result.append(.ellipse(
                    id: id, center: rotated(center), radiusX: rx, radiusY: ry,
                    rotation: rotation + angle
                ))
            case let .polygon(id, center, radius, sides, rotation):
                result.append(.polygon(
                    id: id, center: rotated(center), radius: radius, sides: sides,
                    rotation: rotation + angle
                ))
            case let .spline(id, points, closed):
                // A fit spline is defined purely by its points, so rotating
                // them rotates the curve exactly — no angle parameter needed.
                result.append(.spline(id: id, points: points.map(rotated), closed: closed))
            }
        }
        return result
    }

    // MARK: Scale

    /// Uniform scale about `pivot`. A negative factor is a point reflection:
    /// radii use |factor| and angular fields turn by 180°.
    static func scale(
        entities: [SketchEntity], about pivot: SIMD2<Double>, factor: Double
    ) -> [SketchEntity] {
        func scaled(_ p: SIMD2<Double>) -> SIMD2<Double> {
            pivot + (p - pivot) * factor
        }
        let radiusFactor = abs(factor)
        let angleShift: Double = factor < 0 ? .pi : 0

        return entities.map { entity in
            switch entity {
            case let .line(id, a, b):
                .line(id: id, a: scaled(a), b: scaled(b))
            case let .rect(id, lo, hi):
                {
                    let a = scaled(lo)
                    let b = scaled(hi)
                    return .rect(id: id, min: simd_min(a, b), max: simd_max(a, b))
                }()
            case let .circle(id, center, radius):
                .circle(id: id, center: scaled(center), radius: radius * radiusFactor)
            case let .arc(id, center, radius, start, end):
                .arc(id: id, center: scaled(center), radius: radius * radiusFactor,
                     startAngle: start + angleShift, endAngle: end + angleShift)
            case let .ellipse(id, center, rx, ry, rotation):
                .ellipse(id: id, center: scaled(center),
                         radiusX: rx * radiusFactor, radiusY: ry * radiusFactor,
                         rotation: rotation + angleShift)
            case let .polygon(id, center, radius, sides, rotation):
                .polygon(id: id, center: scaled(center), radius: radius * radiusFactor,
                         sides: sides, rotation: rotation + angleShift)
            case let .spline(id, points, closed):
                .spline(id: id, points: points.map(scaled), closed: closed)
            }
        }
    }
}

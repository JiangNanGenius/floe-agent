import Foundation
import simd

/// Authored reference frames belong to the constraint, not to a rendered
/// animation. A nil drive value leaves the one permitted coordinate free.
public nonisolated struct CADAssemblyJoint: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var lowerLimit: Double?
    public var upperLimit: Double?
    public var phaseA: SIMD3<Double>
    public var phaseB: SIMD3<Double>
    public var relativeRotation: SIMD4<Double>

    public init(lowerLimit: Double? = nil, upperLimit: Double? = nil,
                phaseA: SIMD3<Double>, phaseB: SIMD3<Double>,
                relativeRotation: SIMD4<Double>) {
        self.lowerLimit = lowerLimit
        self.upperLimit = upperLimit
        self.phaseA = phaseA
        self.phaseB = phaseB
        self.relativeRotation = relativeRotation
    }
}

/// Pure joint math used by the existing bounded assembly solver. It never
/// writes the document or manufactures per-part animation keys.
nonisolated enum CADAssemblyJointMath {
    static func rotation(_ transform: CADTransform) -> simd_quatd {
        simd_normalize(simd_quatd(vector: transform.rotation))
    }

    static func alignment(_ from: SIMD3<Double>, _ to: SIMD3<Double>) -> simd_quatd {
        let a = simd_normalize(from), b = simd_normalize(to)
        let dot = max(-1.0, min(1.0, simd_dot(a, b)))
        if dot > 1 - 1e-14 { return simd_quatd(angle: 0, axis: SIMD3(0, 0, 1)) }
        if dot < -1 + 1e-14 {
            let helper = abs(a.x) < 0.8 ? SIMD3<Double>(1, 0, 0) : SIMD3(0, 1, 0)
            return simd_quatd(angle: .pi, axis: simd_normalize(simd_cross(a, helper)))
        }
        return simd_quatd(angle: acos(dot), axis: simd_normalize(simd_cross(a, b)))
    }

    static func make(a: CADTransform, b: CADTransform,
                     axisA: SIMD3<Double>, axisB: SIMD3<Double>,
                     lower: Double?, upper: Double?) -> CADAssemblyJoint {
        let qa = rotation(a), qb = rotation(b)
        let wa = simd_normalize(qa.act(axisA)), wb = simd_normalize(qb.act(axisB))
        let align = alignment(wb, wa)
        let helper = abs(wa.x) < 0.8 ? SIMD3<Double>(1, 0, 0) : SIMD3(0, 1, 0)
        let tangent = simd_normalize(simd_cross(wa, helper))
        let relative = simd_normalize(qa.inverse * align * qb)
        return CADAssemblyJoint(lowerLimit: lower, upperLimit: upper,
                                phaseA: qa.inverse.act(tangent),
                                phaseB: qb.inverse.act(align.inverse.act(tangent)),
                                relativeRotation: relative.vector)
    }

    static func valid(_ constraint: CADAssemblyConstraint) -> Bool {
        guard let joint = constraint.joint, joint.version == 1,
              constraint.kind == .hinge || constraint.kind == .slider,
              joint.phaseA.allFinite, joint.phaseB.allFinite,
              joint.relativeRotation.allFinite,
              simd_length(joint.relativeRotation) > 1e-12,
              simd_length(joint.phaseA) > 1e-12,
              simd_length(joint.phaseB) > 1e-12,
              let axisB = constraint.directionB,
              constraint.directionA.allFinite, axisB.allFinite,
              simd_length(constraint.directionA) > 1e-12,
              simd_length(axisB) > 1e-12 else { return false }
        if abs(simd_dot(simd_normalize(joint.phaseA), simd_normalize(constraint.directionA))) > 1e-8
            || abs(simd_dot(simd_normalize(joint.phaseB), simd_normalize(axisB))) > 1e-8 { return false }
        let lower = joint.lowerLimit, upper = joint.upperLimit
        if let lower, !lower.isFinite { return false }
        if let upper, !upper.isFinite { return false }
        if let lower, let upper, lower > upper { return false }
        if constraint.kind == .hinge {
            if let lower, lower < -180 || lower > 180 { return false }
            if let upper, upper < -180 || upper > 180 { return false }
        }
        if let value = constraint.value {
            guard value.isFinite else { return false }
            if constraint.kind == .hinge, abs(value) > 180 { return false }
            if let lower, value < lower { return false }
            if let upper, value > upper { return false }
        }
        return true
    }

    static func point(_ local: SIMD3<Double>, _ transform: CADTransform) -> SIMD3<Double> {
        transform.position + rotation(transform).act(local * transform.scale)
    }

    static func coordinate(_ c: CADAssemblyConstraint, a: CADTransform, b: CADTransform) -> Double {
        guard let j = c.joint else { return .nan }
        let qa = rotation(a), qb = rotation(b)
        let axis = simd_normalize(qa.act(c.directionA))
        if c.kind == .slider {
            return simd_dot(point(c.pointB ?? .zero, b) - point(c.pointA, a), axis)
        }
        let align = alignment(qb.act(c.directionB ?? .zero), axis)
        let ta = simd_normalize(qa.act(j.phaseA))
        let tb = simd_normalize(align.act(qb.act(j.phaseB)))
        let angle = atan2(simd_dot(axis, simd_cross(ta, tb)), simd_dot(ta, tb)) * 180 / .pi
        if abs(abs(angle) - 180) < 1e-9 {
            return (c.value ?? j.upperLimit ?? 180) < 0 ? -180 : 180
        }
        return angle
    }

    static func target(_ c: CADAssemblyConstraint, current: Double) -> Double {
        if let value = c.value { return value }
        guard let j = c.joint else { return .nan }
        return min(j.upperLimit ?? .infinity, max(j.lowerLimit ?? -.infinity, current))
    }

    static func residual(_ c: CADAssemblyConstraint, a: CADTransform,
                         b: CADTransform, scale: Double) -> Double {
        guard valid(c), let j = c.joint else { return .infinity }
        let qa = rotation(a), qb = rotation(b)
        let axis = simd_normalize(qa.act(c.directionA))
        let offset = point(c.pointB ?? .zero, b) - point(c.pointA, a)
        let current = coordinate(c, a: a, b: b)
        let drive = abs(current - target(c, current: current))
        if c.kind == .hinge {
            let axisError = simd_length(simd_cross(axis, simd_normalize(qb.act(c.directionB!))))
            let directionError = max(axisError, max(0, 1 - simd_dot(axis, simd_normalize(qb.act(c.directionB!)))))
            return max(simd_length(offset), max(directionError * scale, drive * .pi / 180 * scale))
        }
        let wanted = simd_normalize(qa * simd_quatd(vector: j.relativeRotation))
        // Quaternion chord is stable near zero, unlike acos(dot).
        let angular = min(simd_length(wanted.vector - qb.vector), simd_length(wanted.vector + qb.vector)) * 2
        return max(simd_length(offset - simd_dot(offset, axis) * axis), max(angular * scale, drive))
    }

    static func project(_ c: CADAssemblyConstraint, a: CADTransform,
                        b: CADTransform, moveB: Bool) -> CADTransform? {
        guard valid(c), let j = c.joint else { return nil }
        var moving = moveB ? b : a
        let qa = rotation(a), qb = rotation(b)
        let axis = simd_normalize(qa.act(c.directionA))
        let localPoint = moveB ? (c.pointB ?? .zero) : c.pointA
        let anchor = point(localPoint, moving)
        let current = coordinate(c, a: a, b: b)
        let wanted = target(c, current: current)
        let q: simd_quatd
        if c.kind == .slider {
            let relative = simd_normalize(simd_quatd(vector: j.relativeRotation))
            q = moveB ? simd_normalize(qa * relative) : simd_normalize(qb * relative.inverse)
        } else {
            let movingAxis = moveB ? qb.act(c.directionB!) : qa.act(c.directionA)
            let fixedAxis = moveB ? axis : simd_normalize(qb.act(c.directionB!))
            let align = alignment(movingAxis, fixedAxis)
            let aligned = simd_normalize(align * rotation(moving))
            let twist = simd_quatd(angle: (wanted - current) * .pi / 180 * (moveB ? 1 : -1), axis: fixedAxis)
            q = simd_normalize(twist * aligned)
        }
        moving.rotation = q.vector
        moving.position = anchor - q.act(localPoint * moving.scale)
        let aa = moveB ? a : moving, bb = moveB ? moving : b
        let newAxis = simd_normalize(rotation(aa).act(c.directionA))
        let offset = point(c.pointB ?? .zero, bb) - point(c.pointA, aa)
        let desired = c.kind == .hinge ? SIMD3<Double>.zero : newAxis * wanted
        moving.position += (desired - offset) * (moveB ? 1 : -1)
        return moving
    }
}

private nonisolated extension SIMD3 where Scalar == Double {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}
private nonisolated extension SIMD4 where Scalar == Double {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite && w.isFinite }
}

// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Rigid transform shared by the R5 cell program/planner. Value type in
/// millimetres; angles are degrees elsewhere, but this type is translation +
/// rotation only. Rotation is stored row-major (9 values) so archives stay
/// plain JSON arrays compatible with the rest of the manufacturing core.
///
/// A valid transform is finite, orthonormal and right-handed (det = +1).
/// Left-handed or mirrored frames are rejected: a mirrored "transform" would
/// silently flip material removal geometry during a spindle transfer.
public struct CellRigidTransform: Codable, Equatable, Sendable {
    /// Row-major 3x3 rotation matrix, 9 finite values.
    public var rotation: [Double]
    /// World translation [x, y, z] in mm.
    public var translationMM: [Double]

    public init(rotation: [Double], translationMM: [Double]) {
        self.rotation = rotation; self.translationMM = translationMM
    }
    public static let identity = CellRigidTransform(rotation: [1,0,0, 0,1,0, 0,0,1], translationMM: [0,0,0])

    private static let tolerance = 1e-9

    public func validate() throws {
        func require(_ condition: Bool, _ reason: String) throws {
            if !condition { throw ManufacturingError.invalid("cell transform: \(reason)") }
        }
        try require(rotation.count == 9 && translationMM.count == 3, "rotation requires 9 values and translation 3")
        try require((rotation + translationMM).allSatisfy { $0.isFinite && abs($0) <= 100_000 }, "non-finite or out-of-range value")
        // Columns must be unit and mutually perpendicular (R^T R = I).
        for c in 0..<3 {
            var normSquared = 0.0
            for r in 0..<3 { normSquared += rotation[r*3+c] * rotation[r*3+c] }
            try require(abs(normSquared - 1) <= Self.tolerance * 10, "rotation column \(c) is not unit length")
            for d in (c+1)..<3 {
                var dot = 0.0
                for r in 0..<3 { dot += rotation[r*3+c] * rotation[r*3+d] }
                try require(abs(dot) <= Self.tolerance * 10, "rotation columns \(c) and \(d) are not perpendicular")
            }
        }
        // Right-handedness: det(R) = +1. A mirror (det = -1) is never accepted.
        let det =
            rotation[0]*(rotation[4]*rotation[8]-rotation[5]*rotation[7]) -
            rotation[3]*(rotation[1]*rotation[8]-rotation[2]*rotation[7]) +
            rotation[6]*(rotation[1]*rotation[5]-rotation[2]*rotation[4])
        try require(abs(det - 1) <= Self.tolerance * 100, "rotation must be right-handed (det = +1), got \(det)")
    }

    /// Apply to a point [x, y, z] in mm.
    public func applied(to point: [Double]) -> [Double] {
        let (x, y, z) = (point[0], point[1], point[2])
        return [
            rotation[0]*x + rotation[1]*y + rotation[2]*z + translationMM[0],
            rotation[3]*x + rotation[4]*y + rotation[5]*z + translationMM[1],
            rotation[6]*x + rotation[7]*y + rotation[8]*z + translationMM[2],
        ]
    }
    /// self ∘ other: apply `other` first, then `self`.
    public func composed(with other: CellRigidTransform) -> CellRigidTransform {
        var product = [Double](repeating: 0, count: 9)
        for r in 0..<3 {
            for c in 0..<3 {
                product[r*3+c] = (0..<3).reduce(0.0) { $0 + rotation[r*3+$1] * other.rotation[$1*3+c] }
            }
        }
        let moved = applied(to: other.translationMM)
        return CellRigidTransform(rotation: product, translationMM: moved)
    }
    /// Exact inverse of a validated rigid transform (R^T, -R^T t).
    public var inverse: CellRigidTransform {
        var transpose = [Double](repeating: 0, count: 9)
        for r in 0..<3 { for c in 0..<3 { transpose[r*3+c] = rotation[c*3+r] } }
        let (tx, ty, tz) = (translationMM[0], translationMM[1], translationMM[2])
        let back = [
            -(transpose[0]*tx + transpose[1]*ty + transpose[2]*tz),
            -(transpose[3]*tx + transpose[4]*ty + transpose[5]*tz),
            -(transpose[6]*tx + transpose[7]*ty + transpose[8]*tz),
        ]
        return CellRigidTransform(rotation: transpose, translationMM: back)
    }
}

/// Right-handed orthonormal frame: origin + unit axis (local Z) + unit
/// xDirection, with y derived as axis × xDirection. Spindle frames put the
/// origin at the chuck mouth (workholding reference plane) and +Z pointing
/// away from the chuck into the held part. Opposing spindles therefore have
/// near-anti-parallel axes, which the transfer math handles explicitly.
public struct CellFrame: Codable, Equatable, Sendable {
    public var originMM: [Double]
    public var axis: [Double]
    public var xDirection: [Double]

    public init(originMM: [Double], axis: [Double], xDirection: [Double]) {
        self.originMM = originMM; self.axis = axis; self.xDirection = xDirection
    }
    public func validate() throws {
        func require(_ condition: Bool, _ reason: String) throws {
            if !condition { throw ManufacturingError.invalid("cell frame: \(reason)") }
        }
        try require(originMM.count == 3 && axis.count == 3 && xDirection.count == 3, "origin/axis/x each require 3 values")
        try require((originMM + axis + xDirection).allSatisfy { $0.isFinite && abs($0) <= 100_000 }, "non-finite or out-of-range coordinate")
        let axisNorm = CellFrame.norm(axis)
        let xNorm = CellFrame.norm(xDirection)
        try require(abs(axisNorm - 1) <= 1e-9 && abs(xNorm - 1) <= 1e-9, "axis and xDirection must be unit length")
        let dot = zip(axis, xDirection).reduce(0.0) { $0 + $1.0*$1.1 }
        try require(abs(dot) <= 1e-9, "axis and xDirection must be perpendicular")
    }
    public static func norm(_ a: [Double]) -> Double { sqrt(a.reduce(0) { $0 + $1*$1 }) }
    /// Right-handed Y = Z × X.
    public var yDirection: [Double] {
        [axis[1]*xDirection[2]-axis[2]*xDirection[1],
         axis[2]*xDirection[0]-axis[0]*xDirection[2],
         axis[0]*xDirection[1]-axis[1]*xDirection[0]]
    }
    /// Rotation columns are X, Y, Z in world coordinates.
    public var transform: CellRigidTransform {
        let y = yDirection
        return CellRigidTransform(rotation: [
            xDirection[0], y[0], axis[0],
            xDirection[1], y[1], axis[1],
            xDirection[2], y[2], axis[2],
        ], translationMM: originMM)
    }
}

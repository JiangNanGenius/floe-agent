// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Minimal 3D vector used throughout the solver. Components are plain `Double` in
/// millimetres where the vector denotes a position; otherwise unit-free.
public struct Vector3: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vector3(0, 0, 0)

    public static func + (a: Vector3, b: Vector3) -> Vector3 { Vector3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vector3, b: Vector3) -> Vector3 { Vector3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vector3, s: Double) -> Vector3 { Vector3(a.x * s, a.y * s, a.z * s) }

    public func dot(_ o: Vector3) -> Double { x * o.x + y * o.y + z * o.z }
    public func cross(_ o: Vector3) -> Vector3 {
        Vector3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    }
    public var magnitude: Double { (x * x + y * y + z * z).squareRoot() }

    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

/// Internal 3x3 matrix helpers (column-major storage of three basis vectors).
enum Mat3 {
    /// Inverse of the Jacobian J = [a b c] (columns) via the cofactor/adjugate
    /// expansion. `det` receives det(J) = a . (b x c). Returns row-major inverse
    /// rows: row0 = cross(b,c)/det, row1 = cross(c,a)/det, row2 = cross(a,b)/det,
    /// which is exactly what TetrahedronMesh uses as shape-function gradients.
    static func inverse(columns a: Vector3, _ b: Vector3, _ c: Vector3, det: inout Double) -> [Double]? {
        // Cofactor matrix C of J, true indices: inverse = C^T / det.
        let c11 = b.y * c.z - b.z * c.y
        let c12 = a.z * c.y - a.y * c.z
        let c13 = a.y * b.z - a.z * b.y
        let c21 = b.z * c.x - b.x * c.z
        let c22 = a.x * c.z - a.z * c.x
        let c23 = a.z * b.x - a.x * b.z
        let c31 = b.x * c.y - b.y * c.x
        let c32 = a.y * c.x - a.x * c.y
        let c33 = a.x * b.y - a.y * b.x
        let d = a.x * c11 + a.y * c21 + a.z * c31
        det = d
        guard d.isFinite, abs(d) > 0 else { return nil }
        let inv = 1.0 / d
        return [
            c11 * inv, c21 * inv, c31 * inv,
            c12 * inv, c22 * inv, c32 * inv,
            c13 * inv, c23 * inv, c33 * inv,
        ]
    }

    /// inverse[i][j] with row-major 3x3 flattened array.
    static func row(_ m: [Double], _ i: Int) -> Vector3 {
        Vector3(m[i * 3], m[i * 3 + 1], m[i * 3 + 2])
    }
}

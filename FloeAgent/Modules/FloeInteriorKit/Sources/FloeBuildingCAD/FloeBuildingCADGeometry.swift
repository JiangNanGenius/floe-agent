// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import CoreFoundation
import FloeCAD
import FloeInteriorCore
import CryptoKit
import simd

/// Small, deterministic value helpers shared by the bridge. They do not add a
/// second geometry kernel: every mutation still goes through FloeCAD.
nonisolated enum FloeBuildingCADGeometry {
    static let linearToleranceMM = 0.01
    static let volumeToleranceMM3 = 0.1
    static let angleTolerance = 1e-7

    static func nativePoint(domain: [Double]) -> SIMD3<Double> {
        SIMD3(domain[0], domain[2], -domain[1])
    }

    static func domainPoint(native: SIMD3<Double>) -> [Double] {
        [native.x, -native.z, native.y]
    }

    static func nativeVector(_ values: [Double]) -> SIMD3<Double> {
        SIMD3(values[0], values[2], -values[1])
    }

    static func values(_ vector: SIMD3<Double>) -> [Double] {
        [vector.x, vector.y, vector.z]
    }

    static func length(_ v: SIMD3<Double>) -> Double { simd_length(v) }

    static func normalized(_ v: SIMD3<Double>, fallback: SIMD3<Double> = SIMD3(1, 0, 0)) -> SIMD3<Double> {
        let length = simd_length(v)
        guard length.isFinite, length > 1e-12 else { return fallback }
        return v / length
    }

    static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { simd_dot(a, b) }

    static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> { simd_cross(a, b) }

    /// The same in-plane frame convention as the native drawing service:
    /// `xAxisHint` is projected into the plane, `yAxis = normal × xAxis`.
    static func drawingFrame(normal: SIMD3<Double>,
                             xAxisHint: SIMD3<Double>) -> (xAxis: SIMD3<Double>, yAxis: SIMD3<Double>) {
        let n = normalized(normal)
        var hint = xAxisHint - simd_dot(xAxisHint, n) * n
        if simd_length(hint) < 1e-9 {
            let pick: SIMD3<Double> = abs(n.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
            hint = pick - simd_dot(pick, n) * n
        }
        let x = normalized(hint)
        return (x, normalized(cross(n, x)))
    }

    static func projectedLocal(nativePoint: SIMD3<Double>,
                               xAxis: SIMD3<Double>,
                               yAxis: SIMD3<Double>,
                               scale: Double) -> [Double] {
        [simd_dot(nativePoint, xAxis) * scale, simd_dot(nativePoint, yAxis) * scale]
    }

    static func bounds(of points: [[Double]]) -> (minimum: [Double], maximum: [Double])? {
        guard let first = points.first, first.count == 3, first.allSatisfy(\.isFinite) else { return nil }
        var minimum = first
        var maximum = first
        for point in points.dropFirst() {
            guard point.count == 3, point.allSatisfy(\.isFinite) else { return nil }
            for axis in 0..<3 {
                minimum[axis] = min(minimum[axis], point[axis])
                maximum[axis] = max(maximum[axis], point[axis])
            }
        }
        return (minimum, maximum)
    }

    static func union(_ bounds: [(minimum: [Double], maximum: [Double])])
        -> (minimum: [Double], maximum: [Double])? {
        guard let first = bounds.first else { return nil }
        var minimum = first.minimum
        var maximum = first.maximum
        for item in bounds.dropFirst() {
            for axis in 0..<3 {
                minimum[axis] = min(minimum[axis], item.minimum[axis])
                maximum[axis] = max(maximum[axis], item.maximum[axis])
            }
        }
        return (minimum, maximum)
    }

    static func corners(minimum: [Double], maximum: [Double]) -> [[Double]] {
        [minimum[0], maximum[0]].flatMap { x in
            [minimum[1], maximum[1]].flatMap { y in
                [minimum[2], maximum[2]].map { z in [x, y, z] }
            }
        }
    }

    static func apply(matrix: [Double], point: [Double]) -> [Double] {
        let m = matrix
        return [
            m[0] * point[0] + m[4] * point[1] + m[8] * point[2] + m[12],
            m[1] * point[0] + m[5] * point[1] + m[9] * point[2] + m[13],
            m[2] * point[0] + m[6] * point[1] + m[10] * point[2] + m[14],
        ]
    }

    struct UniformPlacement {
        var translation: [Double]
        var rotation: [Double]
        var scale: Double
        var columnScales: [Double]
        var nonUniformRelativeResidual: Double
    }

    /// Decompose the Core placement matrix into the only placement the native
    /// assembly supports: one proper rotation, one uniform scale, translation.
    /// A catalog fit whose per-axis scales differ beyond a small residual is
    /// refused rather than silently distorted.
    static func uniformPlacement(fromColumnMajor matrix: [Double],
                                 importUnitScale: Double,
                                 maximumRelativeSpread: Double = 0.005) -> UniformPlacement? {
        guard matrix.count == 16, matrix.allSatisfy(\.isFinite),
              importUnitScale.isFinite, importUnitScale > 0 else { return nil }
        let rawColumns = [
            SIMD3(matrix[0], matrix[1], matrix[2]),
            SIMD3(matrix[4], matrix[5], matrix[6]),
            SIMD3(matrix[8], matrix[9], matrix[10]),
        ]
        let lengths = rawColumns.map { simd_length($0) }
        guard lengths.allSatisfy({ $0.isFinite && $0 > 1e-12 }) else { return nil }
        let average = lengths.reduce(0, +) / 3
        let spread = (lengths.max()! - lengths.min()!) / average
        let columns = rawColumns.map { $0 / simd_length($0) }
        let det = simd_dot(columns[0], simd_cross(columns[1], columns[2]))
        guard det > 1 - 1e-6, det < 1 + 1e-6 else { return nil }
        guard let quaternion = quaternion(columns: columns) else { return nil }
        return UniformPlacement(
            translation: [matrix[12], matrix[13], matrix[14]],
            rotation: quaternion,
            scale: average / importUnitScale,
            columnScales: lengths.map { $0 / importUnitScale },
            nonUniformRelativeResidual: spread)
    }

    static func quaternion(columns: [SIMD3<Double>]) -> [Double]? {
        guard columns.count == 3 else { return nil }
        let c0 = columns[0], c1 = columns[1], c2 = columns[2]
        let m00 = c0.x, m10 = c0.y, m20 = c0.z
        let m01 = c1.x, m11 = c1.y, m21 = c1.z
        let m02 = c2.x, m12 = c2.y, m22 = c2.z
        let trace = m00 + m11 + m22
        var x = 0.0, y = 0.0, z = 0.0, w = 1.0
        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            w = 0.25 * s
            x = (m21 - m12) / s
            y = (m02 - m20) / s
            z = (m10 - m01) / s
        } else if m00 > m11 && m00 > m22 {
            let s = (1 + m00 - m11 - m22).squareRoot() * 2
            w = (m21 - m12) / s
            x = 0.25 * s
            y = (m01 + m10) / s
            z = (m02 + m20) / s
        } else if m11 > m22 {
            let s = (1 + m11 - m00 - m22).squareRoot() * 2
            w = (m02 - m20) / s
            x = (m01 + m10) / s
            y = 0.25 * s
            z = (m12 + m21) / s
        } else {
            let s = (1 + m22 - m00 - m11).squareRoot() * 2
            w = (m10 - m01) / s
            x = (m02 + m20) / s
            y = (m12 + m21) / s
            z = 0.25 * s
        }
        let length = (x * x + y * y + z * z + w * w).squareRoot()
        guard length.isFinite, length > 1e-12 else { return nil }
        x /= length; y /= length; z /= length; w /= length
        if w < 0 { x = -x; y = -y; z = -z; w = -w }
        return [x, y, z, w]
    }

    static func orientedPoint(_ orientation: FurnitureSourceOrientation,
                              _ point: [Double]) -> [Double] {
        switch orientation {
        case .cadYUp:
            return point
        case let .rotation3x3(matrix):
            guard matrix.count == 9, point.count == 3 else { return point }
            return [
                matrix[0] * point[0] + matrix[3] * point[1] + matrix[6] * point[2],
                matrix[1] * point[0] + matrix[4] * point[1] + matrix[7] * point[2],
                matrix[2] * point[0] + matrix[5] * point[1] + matrix[8] * point[2],
            ]
        }
    }

    static func rotate(_ quaternion: [Double], _ point: SIMD3<Double>) -> SIMD3<Double> {
        guard quaternion.count == 4 else { return point }
        let q = simd_quatd(ix: quaternion[0], iy: quaternion[1],
                           iz: quaternion[2], r: quaternion[3])
        return q.act(point)
    }

    static func quaternionDot(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == 4, b.count == 4 else { return -1 }
        return abs(a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3])
    }

    static func stableUUID(_ text: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("floe.building.cad.\(text)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: bytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) })
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sortedJSONData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func encodeSorted<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func iso8601Now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    // MARK: JSON helpers

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func object(_ outcome: CADCommandOutcome) -> [String: Any]? {
        object(outcome.payload)
    }

    static func number(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        if let double = value as? Double { return double.isFinite ? double : nil }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String, let double = Double(string), double.isFinite { return double }
        return nil
    }

    static func integer(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue else { return nil }
            return number.intValue
        }
        if let int = value as? Int { return int }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func uuid(_ value: Any?) -> UUID? {
        guard let string = value as? String else { return nil }
        return UUID(uuidString: string)
    }

    static func uuidStrings(_ value: Any?) -> [UUID] {
        (value as? [String] ?? []).compactMap(UUID.init(uuidString:))
    }

    static func doubleArray(_ value: Any?) -> [Double]? {
        guard let rows = value as? [Any] else { return nil }
        let result = rows.compactMap { number($0) }
        return result.count == rows.count ? result : nil
    }

    static func doubleMatrix(_ value: Any?) -> [[Double]]? {
        guard let rows = value as? [Any] else { return nil }
        var result: [[Double]] = []
        for row in rows {
            guard let values = doubleArray(row) else { return nil }
            result.append(values)
        }
        return result
    }

    static func maxDifference(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return .infinity }
        return zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }

    static func approxEqual(_ a: [Double], _ b: [Double], tolerance: Double) -> Bool {
        maxDifference(a, b) <= tolerance
    }
}
#endif

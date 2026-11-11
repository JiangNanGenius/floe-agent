import Foundation
import simd

/// Measurement units for spatial results. Conversions are exact and values
/// are always stored in meters internally.
public enum SpatialMeasurementUnit: String, CaseIterable, Codable, Sendable {
    case millimeter, centimeter, meter, inch, foot

    public var metersPerUnit: Double {
        switch self {
        case .millimeter: 0.001
        case .centimeter: 0.01
        case .meter: 1
        case .inch: 0.0254
        case .foot: 0.3048
        }
    }

    public var symbol: String {
        switch self {
        case .millimeter: "mm"
        case .centimeter: "cm"
        case .meter: "m"
        case .inch: "″"
        case .foot: "′"
        }
    }

    public static func `default`(metric: Bool) -> SpatialMeasurementUnit { metric ? .meter : .inch }

    /// Converts meters into this unit.
    public func convert(_ meters: Double) -> Double { meters / metersPerUnit }

    /// Human readable value with adaptive precision: large values get fewer
    /// fraction digits so the instrument readout stays compact and readable.
    public func format(_ meters: Double) -> String {
        let value = convert(meters)
        let digits: Int
        let magnitude = abs(value)
        if magnitude >= 100 { digits = 0 }
        else if magnitude >= 10 { digits = 1 }
        else if magnitude >= 1 { digits = 2 }
        else { digits = 3 }
        return value.formatted(.number.precision(.fractionLength(digits)).grouping(.never)) + " " + symbol
    }

    /// Accessible readout that avoids relying on symbols alone.
    public func accessibilityFormat(_ meters: Double) -> String {
        let value = convert(meters)
        let name: String
        switch self {
        case .millimeter: name = "millimeters"
        case .centimeter: name = "centimeters"
        case .meter: name = "meters"
        case .inch: name = "inches"
        case .foot: name = "feet"
        }
        return String(format: "%.2f %@", locale: Locale(identifier: "en_US_POSIX"), value, name)
    }

    private var squareFactor: Double {
        // Converts square meters into the squared counterpart of this unit.
        1 / (metersPerUnit * metersPerUnit)
    }

    private var squareSymbol: String {
        switch self {
        case .millimeter: "mm²"
        case .centimeter: "cm²"
        case .meter: "m²"
        case .inch: "in²"
        case .foot: "ft²"
        }
    }

    /// Formats a planar area using the squared unit that keeps the number
    /// in a readable range (for example 9500 mm² becomes 95 cm²).
    public func areaFormat(_ squareMeters: Double) -> String {
        let value = squareMeters * squareFactor
        let digits: Int
        let magnitude = abs(value)
        if magnitude >= 1000 { digits = 0 }
        else if magnitude >= 100 { digits = 1 }
        else if magnitude >= 1 { digits = 2 }
        else { digits = 3 }
        return value.formatted(.number.precision(.fractionLength(digits)).grouping(.never)) + " " + squareSymbol
    }

    public func areaAccessibilityFormat(_ squareMeters: Double) -> String {
        let value = squareMeters * squareFactor
        let name: String
        switch self {
        case .millimeter: name = "square millimeters"
        case .centimeter: name = "square centimeters"
        case .meter: name = "square meters"
        case .inch: name = "square inches"
        case .foot: name = "square feet"
        }
        return String(format: "%.2f %@", locale: Locale(identifier: "en_US_POSIX"), value, name)
    }
}

public enum SpatialMeasurementMathError: Error, Equatable, Sendable {
    case insufficientPoints, duplicatePoints, degeneratePolygon, notCoplanar, selfIntersecting, invalidCoordinate
}

/// Pure geometry for the spatial measurement instruments. All inputs are in
/// meters. Nothing here invents sensor values; callers supply only real
/// raycast-derived points.
public enum SpatialMeasurementMath {
    /// Threshold below which two consecutive samples count as the same point.
    public static let duplicateTolerance: Double = 0.0005
    /// Default tolerance for "still the same physical plane" checks.
    public static let defaultCoplanarTolerance: Double = 0.02
    /// Areas below this are treated as noise from an unreliable tap.
    public static let minimumPolygonArea: Double = 0.0001

    public static func isFinite(_ point: SIMD3<Double>) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
    }

    /// Detected anchors may merge or change identifiers. They still describe
    /// one surface only when both their normals and measured offsets agree.
    public static func isSameSurface(
        referencePoint: SIMD3<Double>, referenceNormal: SIMD3<Double>,
        point: SIMD3<Double>, normal: SIMD3<Double>,
        tolerance: Double = defaultCoplanarTolerance
    ) -> Bool {
        guard [referencePoint, referenceNormal, point, normal].allSatisfy(isFinite),
              tolerance.isFinite, tolerance >= 0 else { return false }
        let referenceLength = simd_length(referenceNormal), length = simd_length(normal)
        guard referenceLength.isFinite, length.isFinite, referenceLength > 1e-9, length > 1e-9 else { return false }
        let first = referenceNormal / referenceLength, second = normal / length
        let deviation = abs(simd_dot(point - referencePoint, first))
        return abs(simd_dot(first, second)) >= 0.98 && deviation.isFinite && deviation <= tolerance
    }

    /// Safe for empty/one-point editing states. Closing adds exactly one final
    /// edge, after the polygon has been explicitly completed by the user.
    public static func segmentLengths(_ points: [SIMD3<Double>], closed: Bool = false) -> [Double] {
        guard points.count >= 2 else { return [] }
        var lengths = zip(points, points.dropFirst()).map { distance($0.0, $0.1) }
        if closed, points.count >= 3 { lengths.append(distance(points[points.count - 1], points[0])) }
        return lengths
    }

    public static func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let delta = a - b
        return (delta.x * delta.x + delta.y * delta.y + delta.z * delta.z).squareRoot()
    }

    /// Total length along a polyline. Fewer than two points measure zero.
    public static func polylineLength(_ points: [SIMD3<Double>]) -> Double {
        segmentLengths(points).reduce(0, +)
    }

    /// Least-squares-style plane fit using Newell's method, which stays
    /// stable for non-convex polygons. Self-intersecting shapes can cancel
    /// to a near-zero Newell normal even though they span a real plane, so a
    /// non-collinear triple is used as a fallback. Returns a unit normal and
    /// in-plane basis, or nil only when the points are truly collinear or
    /// duplicated.
    public static func planeBasis(for points: [SIMD3<Double>])
        -> (origin: SIMD3<Double>, normal: SIMD3<Double>, u: SIMD3<Double>, v: SIMD3<Double>)? {
        guard points.count >= 3, points.allSatisfy(isFinite) else { return nil }
        var normal = SIMD3<Double>(0, 0, 0)
        for index in 0..<points.count {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            normal.x += (current.y - next.y) * (current.z + next.z)
            normal.y += (current.z - next.z) * (current.x + next.x)
            normal.z += (current.x - next.x) * (current.y + next.y)
        }
        if simd_length(normal) <= 1e-9 {
            // Fall back to the cross product of the first non-collinear
            // triple so validation can still reject self-intersection.
            normal = .zero
            outer: for middle in 1..<(points.count - 1) {
                for last in (middle + 1)..<points.count {
                    let candidate = simd_cross(points[middle] - points[0], points[last] - points[0])
                    if simd_length(candidate) > 1e-9 {
                        normal = candidate
                        break outer
                    }
                }
            }
        }
        let length = simd_length(normal)
        guard length.isFinite, length > 1e-9 else { return nil }
        normal /= length
        let origin = points[0]
        let reference = abs(normal.y) < 0.9 ? SIMD3<Double>(0, 1, 0) : SIMD3<Double>(1, 0, 0)
        let u = simd_normalize(simd_cross(normal, reference))
        let v = simd_cross(normal, u)
        return (origin, normal, u, v)
    }

    /// Largest absolute point-to-plane distance. Real surfaces are imperfect;
    /// callers decide the tolerance that still counts as one plane.
    public static func maxDeviationFromPlane(_ points: [SIMD3<Double>],
                                             planeNormal: SIMD3<Double>,
                                             through origin: SIMD3<Double>) -> Double {
        points.reduce(0) { partial, point in
            max(partial, abs(simd_dot(point - origin, planeNormal)))
        }
    }

    /// Projects a 3D point onto the 2D basis of a plane.
    public static func project(_ point: SIMD3<Double>,
                               onto basis: (origin: SIMD3<Double>, normal: SIMD3<Double>, u: SIMD3<Double>, v: SIMD3<Double>))
        -> SIMD2<Double> {
        let delta = point - basis.origin
        return SIMD2<Double>(simd_dot(delta, basis.u), simd_dot(delta, basis.v))
    }

    /// Planar polygon area in square meters. Rejects degenerate, non-coplanar
    /// and self-intersecting input so area is never computed across unrelated
    /// depth surfaces.
    public static func polygonArea(_ points: [SIMD3<Double>],
                                   coplanarTolerance: Double = SpatialMeasurementMath.defaultCoplanarTolerance) throws -> Double {
        guard points.count >= 3 else { throw SpatialMeasurementMathError.insufficientPoints }
        guard points.allSatisfy(isFinite), coplanarTolerance.isFinite, coplanarTolerance >= 0 else {
            throw SpatialMeasurementMathError.invalidCoordinate
        }
        for index in 0..<points.count {
            if distance(points[index], points[(index + 1) % points.count]) < duplicateTolerance {
                throw SpatialMeasurementMathError.duplicatePoints
            }
        }
        guard let basis = planeBasis(for: points) else { throw SpatialMeasurementMathError.degeneratePolygon }
        let deviation = maxDeviationFromPlane(points, planeNormal: basis.normal, through: basis.origin)
        guard deviation.isFinite, deviation <= coplanarTolerance else { throw SpatialMeasurementMathError.notCoplanar }
        let projected = points.map { project($0, onto: basis) }
        guard !hasSelfIntersection(projected) else { throw SpatialMeasurementMathError.selfIntersecting }
        let area = abs(shoelaceArea(projected))
        guard area.isFinite, area >= minimumPolygonArea else { throw SpatialMeasurementMathError.degeneratePolygon }
        return area
    }

    /// Signed shoelace area of a simple 2D polygon.
    public static func shoelaceArea(_ polygon: [SIMD2<Double>]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        var sum = 0.0
        for index in 0..<polygon.count {
            let current = polygon[index]
            let next = polygon[(index + 1) % polygon.count]
            sum += current.x * next.y - next.x * current.y
        }
        return sum / 2
    }

    /// True when any two non-adjacent edges properly intersect or overlap.
    /// Adjacent edges are expected to share a vertex and are excluded.
    public static func hasSelfIntersection(_ polygon: [SIMD2<Double>]) -> Bool {
        guard polygon.count >= 4 else { return false }
        let count = polygon.count
        for first in 0..<count {
            for second in (first + 1)..<count {
                let adjacent = second == first + 1 || (first == 0 && second == count - 1)
                if adjacent { continue }
                if segmentsIntersect(polygon[first], polygon[(first + 1) % count],
                                     polygon[second], polygon[(second + 1) % count]) {
                    return true
                }
            }
        }
        return false
    }

    /// Closed-segment intersection including collinear overlap.
    public static func segmentsIntersect(_ p1: SIMD2<Double>, _ p2: SIMD2<Double>,
                                         _ q1: SIMD2<Double>, _ q2: SIMD2<Double>) -> Bool {
        func orientation(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        func onSegment(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ point: SIMD2<Double>) -> Bool {
            min(a.x, b.x) <= point.x && point.x <= max(a.x, b.x)
                && min(a.y, b.y) <= point.y && point.y <= max(a.y, b.y)
        }
        let d1 = orientation(q1, q2, p1)
        let d2 = orientation(q1, q2, p2)
        let d3 = orientation(p1, p2, q1)
        let d4 = orientation(p1, p2, q2)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) {
            return true
        }
        let epsilon = 1e-12
        if abs(d1) <= epsilon && onSegment(q1, q2, p1) { return true }
        if abs(d2) <= epsilon && onSegment(q1, q2, p2) { return true }
        if abs(d3) <= epsilon && onSegment(p1, p2, q1) { return true }
        if abs(d4) <= epsilon && onSegment(p1, p2, q2) { return true }
        return false
    }

    /// Ear-clipping triangulation of a simple 2D polygon (convex or concave).
    /// Returns triples of vertex indices wound counter-clockwise, or nil when
    /// no ear can be clipped. Callers must run the simplicity validation in
    /// polygonArea first; this never invents fill for crossing shapes and
    /// does not itself detect self-intersection.
    public static func triangulate(_ polygon: [SIMD2<Double>]) -> [SIMD3<UInt32>]? {
        guard polygon.count >= 3, polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        var order = Array(0..<polygon.count)
        if shoelaceArea(polygon) < 0 { order.reverse() }
        var ears: [SIMD3<UInt32>] = []
        var iterations = 0
        let maximumIterations = polygon.count * polygon.count + 16
        while order.count > 3 {
            iterations += 1
            guard iterations <= maximumIterations else { return nil }
            var clipped = false
            for index in 0..<order.count {
                let previous = order[(index - 1 + order.count) % order.count]
                let current = order[index]
                let next = order[(index + 1) % order.count]
                let a = polygon[previous]
                let b = polygon[current]
                let c = polygon[next]
                let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
                guard cross > 1e-12 else { continue } // reflex or degenerate corner
                var containsOther = false
                for candidate in order where candidate != previous && candidate != current && candidate != next {
                    if pointStrictlyInsideTriangle(polygon[candidate], a, b, c) {
                        containsOther = true
                        break
                    }
                }
                guard !containsOther else { continue }
                ears.append(SIMD3<UInt32>(UInt32(previous), UInt32(current), UInt32(next)))
                order.remove(at: index)
                clipped = true
                break
            }
            guard clipped else { return nil }
        }
        ears.append(SIMD3<UInt32>(UInt32(order[0]), UInt32(order[1]), UInt32(order[2])))
        return ears
    }

    /// Strict interior test: boundary and edge points do not count as inside.
    /// Ear triangles are counter-clockwise, so interior points are strictly
    /// on the positive side of every edge.
    public static func pointStrictlyInsideTriangle(_ point: SIMD2<Double>, _ a: SIMD2<Double>,
                                                   _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Bool {
        func edge(_ p: SIMD2<Double>, _ q: SIMD2<Double>) -> Double {
            (q.x - p.x) * (point.y - p.y) - (q.y - p.y) * (point.x - p.x)
        }
        let epsilon = 1e-12
        return edge(a, b) > epsilon && edge(b, c) > epsilon && edge(c, a) > epsilon
    }
}

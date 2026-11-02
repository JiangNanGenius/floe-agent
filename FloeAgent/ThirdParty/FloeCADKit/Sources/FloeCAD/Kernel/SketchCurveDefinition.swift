// SPDX-License-Identifier: MPL-2.0
// Exact supports and VERSIONED parameter intervals. A display polyline is
// never a curve definition. General ellipse/spline bases remain intact here;
// materialization refuses a range the current SketchEntity cannot represent.
import Foundation
import simd

nonisolated struct SketchCurveEditFailure: Error, LocalizedError, Equatable, Sendable {
    var code: String
    var message: String
    var entityIDs: [UUID] = []
    var constraintIDs: [UUID] = []
    var dimensionIDs: [UUID] = []
    var linkIDs: [UUID] = []
    var errorDescription: String? { message }
}

nonisolated struct SketchCurveParameterInterval: Codable, Equatable, Sendable {
    let version: Int
    var lower: Double
    var upper: Double
    var periodic: Bool

    init(lower: Double, upper: Double, periodic: Bool = false) throws {
        version = 1; self.lower = lower; self.upper = upper; self.periodic = periodic
        try validate()
    }
    func validate() throws {
        guard version == 1 else {
            throw SketchCurveEditFailure(code: "unsupported_curve_interval_version", message: "This curve interval needs a newer version.")
        }
        guard lower.isFinite, upper.isFinite, abs(lower) <= 1e12, abs(upper) <= 1e12, upper - lower > 1e-9 else {
            throw SketchCurveEditFailure(code: "invalid_curve_interval", message: "The curve interval is empty or invalid.")
        }
    }
    private enum CodingKeys: String, CodingKey { case version, lower, upper, periodic }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        lower = try c.decode(Double.self, forKey: .lower)
        upper = try c.decode(Double.self, forKey: .upper)
        periodic = try c.decode(Bool.self, forKey: .periodic)
        try validate()
    }
}

nonisolated struct SketchCurveDefinition: Codable, Equatable, Sendable {
    enum SourceKind: String, Codable, Equatable, Sendable { case line, circle, arc, ellipse, spline }
    enum Support: Codable, Equatable, Sendable {
        case line(a: SIMD2<Double>, b: SIMD2<Double>)
        case conic(center: SIMD2<Double>, radiusX: Double, radiusY: Double, rotation: Double)
        case fitSpline(points: [SIMD2<Double>], closed: Bool)
    }
    let version: Int
    var sourceKind: SourceKind
    var support: Support
    var interval: SketchCurveParameterInterval
    static let epsilon = 1e-8
    static let tau = 2 * Double.pi

    init(_ entity: SketchEntity) throws {
        version = 1
        switch entity {
        case let .line(_, a, b):
            sourceKind = .line; support = .line(a: a, b: b)
            interval = try .init(lower: 0, upper: 1)
        case let .circle(_, center, radius):
            sourceKind = .circle; support = .conic(center: center, radiusX: radius, radiusY: radius, rotation: 0)
            interval = try .init(lower: 0, upper: Self.tau, periodic: true)
        case let .arc(_, center, radius, start, end):
            sourceKind = .arc; support = .conic(center: center, radiusX: radius, radiusY: radius, rotation: 0)
            interval = try .init(lower: start, upper: start + SketchEntity.arcSweep(startAngle: start, endAngle: end))
        case let .ellipse(_, center, rx, ry, rotation):
            sourceKind = .ellipse; support = .conic(center: center, radiusX: rx, radiusY: ry, rotation: rotation)
            interval = try .init(lower: 0, upper: Self.tau, periodic: true)
        case let .spline(_, points, closed):
            sourceKind = .spline
            if points.count == 2 && !closed { support = .line(a: points[0], b: points[1]) }
            else { support = .fitSpline(points: points, closed: closed) }
            interval = try .init(lower: 0, upper: 1, periodic: closed)
        default:
            throw SketchCurveEditFailure(code: "unsupported_curve", message: "Choose a line or curve.", entityIDs: [entity.id])
        }
        try validate()
    }

    private enum CodingKeys: String, CodingKey { case version, sourceKind, support, interval }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        sourceKind = try c.decode(SourceKind.self, forKey: .sourceKind)
        support = try c.decode(Support.self, forKey: .support)
        interval = try c.decode(SketchCurveParameterInterval.self, forKey: .interval)
        try validate()
    }
    func validate() throws {
        guard version == 1 else {
            throw SketchCurveEditFailure(code: "unsupported_curve_definition_version", message: "This curve definition needs a newer version.")
        }
        try interval.validate()
        func valid(_ p: SIMD2<Double>) -> Bool { p.x.isFinite && p.y.isFinite && abs(p.x) <= 1e12 && abs(p.y) <= 1e12 }
        switch support {
        case let .line(a, b):
            guard valid(a), valid(b), simd_length(b - a) > Self.epsilon,
                  !interval.periodic, sourceKind == .line || sourceKind == .spline else { throw invalid() }
        case let .conic(center, rx, ry, rotation):
            guard valid(center), rx.isFinite, ry.isFinite, rx > Self.epsilon, ry > Self.epsilon,
                  max(rx, ry) <= 1e12, rotation.isFinite,
                  interval.upper - interval.lower <= Self.tau + Self.epsilon,
                  !interval.periodic || abs(interval.upper - interval.lower - Self.tau) <= Self.epsilon,
                  sourceKind == .circle || sourceKind == .arc || sourceKind == .ellipse else { throw invalid() }
        case let .fitSpline(points, closed):
            guard sourceKind == .spline, (3...256).contains(points.count), points.allSatisfy(valid),
                  interval.lower >= 0, interval.upper <= 1,
                  !interval.periodic || (closed && interval.lower == 0 && interval.upper == 1) else { throw invalid() }
        }
    }
    private func invalid() -> SketchCurveEditFailure {
        .init(code: "invalid_curve", message: "The curve contains invalid or collapsed geometry.")
    }
    var canMaterializeInterval: Bool {
        switch support {
        case .line: true
        case let .conic(_, rx, ry, _): rx == ry // exact equality: a near-circle is still an ellipse
        case .fitSpline: false
        }
    }
    var normalOffsetConvention: String {
        if case .line = support { return "left_of_travel" }
        return "outward_conic"
    }
    func requiringMaterializableInterval() throws {
        guard canMaterializeInterval else {
            throw SketchCurveEditFailure(code: "exact_curve_representation_required",
                message: "This curve needs an exact trimmed or offset representation before it can be edited. The original is unchanged.")
        }
    }
    func replacingInterval(_ interval: SketchCurveParameterInterval) throws -> Self {
        var value = self; value.interval = interval; try value.validate(); return value
    }
    func point(at parameter: Double) throws -> SIMD2<Double> {
        switch support {
        case let .line(a, b): return a + (b - a) * parameter
        case let .conic(center, rx, ry, rotation):
            let p = SIMD2(rx * cos(parameter), ry * sin(parameter))
            return center + SIMD2(p.x * cos(rotation) - p.y * sin(rotation), p.x * sin(rotation) + p.y * cos(rotation))
        case .fitSpline:
            throw SketchCurveEditFailure(code: "exact_curve_representation_required", message: "This spline needs a persisted exact parameter range.")
        }
    }
    /// The parameter of a picked/intersection point, unwrapped to this range.
    /// General spline projection belongs to the future exact curve backend.
    func parameter(of point: SIMD2<Double>, extended: Bool = false) throws -> Double {
        switch support {
        case let .line(a, b): return simd_dot(point - a, b - a) / simd_length_squared(b - a)
        case let .conic(center, rx, ry, rotation):
            guard rx == ry, simd_length(point - center) > Self.epsilon else { throw invalid() }
            let p = point - center
            let angle = atan2(-p.x * sin(rotation) + p.y * cos(rotation), p.x * cos(rotation) + p.y * sin(rotation))
            let normalized = (angle.truncatingRemainder(dividingBy: Self.tau) + Self.tau).truncatingRemainder(dividingBy: Self.tau)
            if interval.periodic { return interval.lower + (normalized - interval.lower + Self.tau).truncatingRemainder(dividingBy: Self.tau) }
            let k = floor((interval.lower - normalized) / Self.tau)
            let values = (-1...2).map { normalized + (k + Double($0)) * Self.tau }
            return values.min { a, b in
                let da = max(max(interval.lower - a, a - interval.upper), 0)
                let db = max(max(interval.lower - b, b - interval.upper), 0)
                return da == db ? abs(a - (interval.lower + interval.upper) / 2) < abs(b - (interval.lower + interval.upper) / 2) : da < db
            }!
        case .fitSpline: throw invalid()
        }
    }
    func materialized(id: UUID) throws -> SketchEntity {
        try requiringMaterializableInterval()
        switch support {
        case .line:
            let a = try point(at: interval.lower), b = try point(at: interval.upper)
            if sourceKind == .spline { return .spline(id: id, points: [a, b], closed: false) }
            return .line(id: id, a: a, b: b)
        case let .conic(center, radius, _, rotation):
            if interval.periodic {
                if sourceKind == .ellipse { return .ellipse(id: id, center: center, radiusX: radius, radiusY: radius, rotation: rotation) }
                return .circle(id: id, center: center, radius: radius)
            }
            return .arc(id: id, center: center, radius: radius,
                        startAngle: interval.lower + rotation, endAngle: interval.upper + rotation)
        case .fitSpline: throw invalid()
        }
    }
    func normalOffset(by distance: Double) throws -> Self {
        try requiringMaterializableInterval()
        guard distance.isFinite, abs(distance) > Self.epsilon, abs(distance) <= 1e12 else { throw invalid() }
        var result = self
        switch support {
        case let .line(a, b):
            let d = simd_normalize(b - a); let shift = SIMD2(-d.y, d.x) * distance
            result.support = .line(a: a + shift, b: b + shift)
        case let .conic(center, radius, _, rotation):
            let r = radius + distance
            guard r > Self.epsilon else {
                throw SketchCurveEditFailure(code: "curve_offset_collapse", message: "The offset collapses the curve. Reduce the inward distance.")
            }
            result.support = .conic(center: center, radiusX: r, radiusY: r, rotation: rotation)
        case .fitSpline: throw invalid()
        }
        try result.validate(); return result
    }
    /// Versioned native ABI: v1, kind(0 line/1 conic/2 fit spline), lower,
    /// upper, flags(bit0 periodic range / bit1 closed spline basis), then
    /// exact support values. Never sampled vertices.
    var nativeRecord: Data {
        var values = [Double(version), 0, interval.lower, interval.upper, interval.periodic ? 1 : 0]
        switch support {
        case let .line(a, b): values += [a.x, a.y, b.x, b.y]
        case let .conic(c, rx, ry, rotation): values[1] = 1; values += [c.x, c.y, rx, ry, rotation]
        case let .fitSpline(points, closed):
            values[1] = 2; values[4] = (interval.periodic ? 1 : 0) + (closed ? 2 : 0); values.append(Double(points.count))
            for p in points { values += [p.x, p.y] }
        }
        return values.withUnsafeBytes { Data($0) }
    }
}

nonisolated enum SketchCurveEditKind: String, CaseIterable, Hashable, Sendable { case trim, extend }

nonisolated enum SketchCurveEditKernel {
    struct Result: Equatable, Sendable {
        var definitions: [SketchCurveDefinition]
        var entities: [SketchEntity]
        var sourceID: UUID
        var boundaryID: UUID
    }
    static func edit(_ entity: SketchEntity, boundary: SketchEntity, pick: SIMD2<Double>, kind: SketchCurveEditKind) throws -> Result {
        let source = try SketchCurveDefinition(entity)
        try source.requiringMaterializableInterval()
        guard pick.x.isFinite, pick.y.isFinite, abs(pick.x) <= 1e12, abs(pick.y) <= 1e12, entity.id != boundary.id else {
            throw SketchCurveEditFailure(code: "invalid_curve_pick", message: "Choose a different boundary and a point on the target.", entityIDs: [entity.id, boundary.id])
        }
        let boundaryDefinition = try SketchCurveDefinition(boundary)
        if kind == .extend && source.interval.periodic {
            throw SketchCurveEditFailure(code: "closed_curve_cannot_extend", message: "A closed curve has no endpoint to extend.", entityIDs: [entity.id])
        }
        let points = try OCCTKernel.sketchCurveIntersections(source, boundary: boundaryDefinition, extendTarget: kind == .extend)
        var parameters = try points.map { try source.parameter(of: $0, extended: kind == .extend) }
        let lo = source.interval.lower, hi = source.interval.upper, epsilon = SketchCurveDefinition.epsilon
        if kind == .trim { parameters = parameters.filter { $0 > lo + epsilon && $0 < hi - epsilon || source.interval.periodic } }
        parameters.sort(); parameters = parameters.reduce(into: []) { result, value in
            if result.last.map({ abs($0 - value) > epsilon }) ?? true { result.append(value) }
        }
        guard !parameters.isEmpty else {
            throw SketchCurveEditFailure(code: "no_curve_intersection", message: "The selected boundary does not intersect the requested part.", entityIDs: [entity.id, boundary.id])
        }
        let pickParameter = try source.parameter(of: pick)
        var intervals: [SketchCurveParameterInterval] = []
        if kind == .extend {
            let extendStart = abs(pickParameter - lo) <= abs(pickParameter - hi)
            let candidates: [Double]
            if case .conic = source.support {
                candidates = parameters.flatMap { p in [-SketchCurveDefinition.tau, 0, SketchCurveDefinition.tau].map { p + $0 } }
            } else { candidates = parameters }
            let target = extendStart ? candidates.filter { $0 < lo - epsilon }.max() : candidates.filter { $0 > hi + epsilon }.min()
            guard let target else {
                throw SketchCurveEditFailure(code: "no_extension_intersection", message: "There is no boundary intersection beyond that endpoint.", entityIDs: [entity.id, boundary.id])
            }
            intervals = [try .init(lower: extendStart ? target : lo, upper: extendStart ? hi : target)]
        } else {
            guard !parameters.contains(where: { abs($0 - pickParameter) <= epsilon }) else {
                throw SketchCurveEditFailure(code: "pick_on_boundary", message: "Pick away from the boundary intersection.", entityIDs: [entity.id])
            }
            if source.interval.periodic {
                guard parameters.count >= 2 else {
                    throw SketchCurveEditFailure(code: "insufficient_curve_intersections", message: "A closed curve needs two distinct boundary intersections.", entityIDs: [entity.id, boundary.id])
                }
                let next = parameters.first(where: { $0 > pickParameter }) ?? parameters[0] + SketchCurveDefinition.tau
                let previous = parameters.last(where: { $0 < pickParameter }) ?? parameters.last! - SketchCurveDefinition.tau
                intervals = [try .init(lower: next, upper: previous + SketchCurveDefinition.tau)]
            } else {
                let p = min(max(pickParameter, lo), hi)
                let previous = parameters.last(where: { $0 < p }) ?? lo
                let next = parameters.first(where: { $0 > p }) ?? hi
                if previous > lo + epsilon { intervals.append(try .init(lower: lo, upper: previous)) }
                if next < hi - epsilon { intervals.append(try .init(lower: next, upper: hi)) }
            }
        }
        guard !intervals.isEmpty else {
            throw SketchCurveEditFailure(code: "curve_would_be_removed", message: "This edit would remove the entire curve.", entityIDs: [entity.id])
        }
        let definitions = try intervals.map { try source.replacingInterval($0) }
        let entities = try definitions.enumerated().map { try $0.element.materialized(id: $0.offset == 0 ? entity.id : UUID()) }
        return Result(definitions: definitions, entities: entities, sourceID: entity.id, boundaryID: boundary.id)
    }
}

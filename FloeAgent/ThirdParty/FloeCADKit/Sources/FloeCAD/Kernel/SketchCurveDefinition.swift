// SPDX-License-Identifier: MPL-2.0
// Exact supports, VERSIONED parameter intervals and exact normal-offset bases.
// Display samples are never a curve definition or a persisted offset fit.
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
    indirect enum Support: Codable, Equatable, Sendable {
        case line(a: SIMD2<Double>, b: SIMD2<Double>)
        case conic(center: SIMD2<Double>, radiusX: Double, radiusY: Double, rotation: Double)
        case fitSpline(points: [SIMD2<Double>], closed: Bool)
        /// Exact OCCT normal offset. The basis keeps its own original support
        /// and interval; the outer interval may subsequently trim/extend it.
        case normalOffset(base: SketchCurveDefinition, distance: Double, convention: String)
    }
    private(set) var version: Int
    var sourceKind: SourceKind
    var support: Support
    var interval: SketchCurveParameterInterval
    static let epsilon = 1e-8
    static let tau = 2 * Double.pi
    static let currentVersion = 2

    init(_ entity: SketchEntity) throws {
        if case let .exactCurve(_, definition) = entity {
            self = definition
            try validate()
            return
        }
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

    private init(version: Int, sourceKind: SourceKind, support: Support,
                 interval: SketchCurveParameterInterval) {
        self.version = version; self.sourceKind = sourceKind
        self.support = support; self.interval = interval
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
    func validate() throws { try validate(depth: 0) }
    private func validate(depth: Int) throws {
        guard depth < 32 else {
            throw SketchCurveEditFailure(code: "curve_definition_depth", message: "The curve definition is nested too deeply.")
        }
        guard version == 1 || version == Self.currentVersion else {
            throw SketchCurveEditFailure(code: "unsupported_curve_definition_version", message: "This curve definition needs a newer version.")
        }
        try interval.validate()
        func valid(_ p: SIMD2<Double>) -> Bool { p.x.isFinite && p.y.isFinite && abs(p.x) <= 1e12 && abs(p.y) <= 1e12 }
        switch support {
        case let .line(a, b):
            guard version == 1, valid(a), valid(b), simd_length(b - a) > Self.epsilon,
                  !interval.periodic, sourceKind == .line || sourceKind == .spline else { throw invalid() }
        case let .conic(center, rx, ry, rotation):
            guard version == 1, valid(center), rx.isFinite, ry.isFinite, rx > Self.epsilon, ry > Self.epsilon,
                  max(rx, ry) <= 1e12, rotation.isFinite,
                  interval.upper - interval.lower <= Self.tau + Self.epsilon,
                  !interval.periodic || abs(interval.upper - interval.lower - Self.tau) <= Self.epsilon,
                  sourceKind == .circle || sourceKind == .arc || sourceKind == .ellipse else { throw invalid() }
        case let .fitSpline(points, closed):
            guard version == 1, sourceKind == .spline, (3...256).contains(points.count), points.allSatisfy(valid),
                  !interval.periodic || (closed && interval.lower == 0 && interval.upper == 1) else { throw invalid() }
        case let .normalOffset(base, distance, convention):
            guard version == Self.currentVersion, base.sourceKind == sourceKind,
                  convention == base.normalOffsetConvention,
                  ["left_of_travel", "outward_conic"].contains(convention),
                  distance.isFinite, abs(distance) > Self.epsilon, abs(distance) <= 1e12,
                  !interval.periodic || base.interval.periodic else { throw invalid() }
            try base.validate(depth: depth + 1)
        }
    }
    private func invalid() -> SketchCurveEditFailure {
        .init(code: "invalid_curve", message: "The curve contains invalid or collapsed geometry.")
    }

    /// Every admitted definition now has an exact native materializer. This
    /// property remains the query/UI gate used by the preceding M03/M04 packet.
    var canMaterializeInterval: Bool { true }
    var isDerivedNormalOffset: Bool {
        if case .normalOffset = support { return true }
        return false
    }
    var parameterPeriod: Double {
        switch support {
        case .conic: return Self.tau
        case .fitSpline: return 1
        case let .normalOffset(base, _, _): return base.parameterPeriod
        case .line: return 1 // never periodic; a finite value keeps callers total
        }
    }
    var normalOffsetConvention: String {
        switch support {
        case .line, .fitSpline: return "left_of_travel"
        case .conic: return "outward_conic"
        case let .normalOffset(_, _, convention): return convention
        }
    }
    func requiringMaterializableInterval() throws { try validate() }
    func replacingInterval(_ interval: SketchCurveParameterInterval) throws -> Self {
        var value = self; value.interval = interval; try value.validate(); return value
    }
    func replacingSupport(_ support: Support) throws -> Self {
        var value = self; value.support = support; try value.validate(); return value
    }
    func replacingSupportAndInterval(_ support: Support,
                                     interval: SketchCurveParameterInterval) throws -> Self {
        var value = self; value.support = support; value.interval = interval; try value.validate(); return value
    }

    func point(at parameter: Double) throws -> SIMD2<Double> {
        guard parameter.isFinite, abs(parameter) <= 1e12 else { throw invalid() }
        switch support {
        case let .line(a, b): return a + (b - a) * parameter
        case let .conic(center, rx, ry, rotation):
            let p = SIMD2(rx * cos(parameter), ry * sin(parameter))
            return center + SIMD2(p.x * cos(rotation) - p.y * sin(rotation), p.x * sin(rotation) + p.y * cos(rotation))
        case .fitSpline, .normalOffset:
            return try OCCTKernel.sketchCurvePoints(self, parameters: [parameter])[0]
        }
    }

    /// Parameter of a picked/projected point in the common definition domain.
    /// Conics retain their analytic parameter; spline/offset projection is OCCT.
    func parameter(of point: SIMD2<Double>, extended: Bool = false) throws -> Double {
        switch support {
        case let .line(a, b): return simd_dot(point - a, b - a) / simd_length_squared(b - a)
        case let .conic(center, rx, ry, rotation):
            guard simd_length(point - center) > Self.epsilon else { throw invalid() }
            let p = point - center
            let angle = atan2((-p.x * sin(rotation) + p.y * cos(rotation)) / ry,
                              (p.x * cos(rotation) + p.y * sin(rotation)) / rx)
            let normalized = (angle.truncatingRemainder(dividingBy: Self.tau) + Self.tau).truncatingRemainder(dividingBy: Self.tau)
            if interval.periodic { return interval.lower + (normalized - interval.lower + Self.tau).truncatingRemainder(dividingBy: Self.tau) }
            let k = floor((interval.lower - normalized) / Self.tau)
            let values = (-1...2).map { normalized + (k + Double($0)) * Self.tau }
            return values.min { a, b in
                let da = max(max(interval.lower - a, a - interval.upper), 0)
                let db = max(max(interval.lower - b, b - interval.upper), 0)
                return da == db ? abs(a - (interval.lower + interval.upper) / 2) < abs(b - (interval.lower + interval.upper) / 2) : da < db
            }!
        case .fitSpline, .normalOffset:
            return try OCCTKernel.sketchCurveParameter(of: point, on: self, extended: extended)
        }
    }

    func materialized(id: UUID) throws -> SketchEntity {
        try requiringMaterializableInterval()
        switch support {
        case .line:
            let a = try point(at: interval.lower), b = try point(at: interval.upper)
            if sourceKind == .spline { return .spline(id: id, points: [a, b], closed: false) }
            return .line(id: id, a: a, b: b)
        case let .conic(center, rx, ry, rotation):
            if interval.periodic {
                if sourceKind == .ellipse { return .ellipse(id: id, center: center, radiusX: rx, radiusY: ry, rotation: rotation) }
                return .circle(id: id, center: center, radius: rx)
            }
            if rx == ry {
                return .arc(id: id, center: center, radius: rx,
                            startAngle: interval.lower + rotation, endAngle: interval.upper + rotation)
            }
            return .exactCurve(id: id, definition: self)
        case let .fitSpline(points, closed):
            if interval.lower == 0, interval.upper == 1, interval.periodic == closed {
                return .spline(id: id, points: points, closed: closed)
            }
            return .exactCurve(id: id, definition: self)
        case .normalOffset:
            return .exactCurve(id: id, definition: self)
        }
    }

    func normalOffset(by distance: Double) throws -> Self {
        try validate()
        guard distance.isFinite, abs(distance) > Self.epsilon, abs(distance) <= 1e12 else { throw invalid() }
        var result = self
        switch support {
        case let .line(a, b):
            let d = simd_normalize(b - a); let shift = SIMD2(-d.y, d.x) * distance
            result.support = .line(a: a + shift, b: b + shift)
            try result.validate(); return result
        case let .conic(center, rx, ry, rotation) where rx == ry:
            let r = rx + distance
            guard r > Self.epsilon else {
                throw SketchCurveEditFailure(code: "curve_offset_collapse", message: "The offset collapses the curve. Reduce the inward distance.")
            }
            result.support = .conic(center: center, radiusX: r, radiusY: r, rotation: rotation)
            try result.validate(); return result
        case .conic, .fitSpline, .normalOffset:
            result = Self(version: Self.currentVersion, sourceKind: sourceKind,
                          support: .normalOffset(base: self, distance: distance,
                                                 convention: normalOffsetConvention), interval: interval)
            try result.validate()
            try OCCTKernel.validateSketchNormalOffset(result)
            return result
        }
    }

    /// Display-only samples evaluated from the exact native curve. They are
    /// deliberately absent from Codable/nativeRecord and never become a fit.
    func tessellatedPoints(sampleCount: Int = 128) throws -> [SIMD2<Double>] {
        guard (2...4096).contains(sampleCount) else { throw invalid() }
        let parameters: [Double]
        if interval.periodic {
            parameters = (0..<sampleCount).map {
                interval.lower + (interval.upper - interval.lower) * Double($0) / Double(sampleCount)
            }
        } else {
            parameters = (0...sampleCount).map {
                interval.lower + (interval.upper - interval.lower) * Double($0) / Double(sampleCount)
            }
        }
        return try OCCTKernel.sketchCurvePoints(self, parameters: parameters)
    }

    /// v1 is byte-compatible with the preceding packet. v2 kind 3 stores a
    /// signed normal offset as convention, distance and a length-delimited
    /// recursive exact basis record. No sampled vertices are present.
    var nativeRecord: Data {
        if case let .normalOffset(base, distance, convention) = support {
            let basis = base.nativeRecord.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
            var values = [Double(version), 3, interval.lower, interval.upper,
                          interval.periodic ? 1 : 0, convention == "outward_conic" ? 1 : 0,
                          distance, Double(basis.count)]
            values.append(contentsOf: basis)
            return values.withUnsafeBytes { Data($0) }
        }
        var values = [Double(version), 0, interval.lower, interval.upper, interval.periodic ? 1 : 0]
        switch support {
        case let .line(a, b): values += [a.x, a.y, b.x, b.y]
        case let .conic(c, rx, ry, rotation): values[1] = 1; values += [c.x, c.y, rx, ry, rotation]
        case let .fitSpline(points, closed):
            values[1] = 2; values[4] = (interval.periodic ? 1 : 0) + (closed ? 2 : 0); values.append(Double(points.count))
            for p in points { values += [p.x, p.y] }
        case .normalOffset: break
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
        let pickParameter = try source.parameter(of: pick)
        let extendStart = abs(pickParameter - source.interval.lower) <= abs(pickParameter - source.interval.upper)
        let intersections = try OCCTKernel.sketchCurveIntersections(
            source, boundary: boundaryDefinition,
            extensionDirection: kind == .extend ? (extendStart ? -1 : 1) : 0)
        var parameters = intersections.map(\.targetParameter)
        let lo = source.interval.lower, hi = source.interval.upper, epsilon = SketchCurveDefinition.epsilon
        if kind == .trim { parameters = parameters.filter { $0 > lo + epsilon && $0 < hi - epsilon || source.interval.periodic } }
        parameters.sort(); parameters = parameters.reduce(into: []) { result, value in
            if result.last.map({ abs($0 - value) > epsilon }) ?? true { result.append(value) }
        }
        if source.interval.periodic, parameters.count >= 2,
           abs(parameters[0] + source.parameterPeriod - parameters[parameters.count - 1]) <= epsilon {
            parameters.removeLast() // one geometric seam intersection, not two cuts
        }
        guard !parameters.isEmpty else {
            throw SketchCurveEditFailure(code: "no_curve_intersection", message: "The selected boundary does not intersect the requested part.", entityIDs: [entity.id, boundary.id])
        }
        var intervals: [SketchCurveParameterInterval] = []
        if kind == .extend {
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
                let period = source.parameterPeriod
                let next = parameters.first(where: { $0 > pickParameter }) ?? parameters[0] + period
                let previous = parameters.last(where: { $0 < pickParameter }) ?? parameters.last! - period
                intervals = [try .init(lower: next, upper: previous + period)]
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

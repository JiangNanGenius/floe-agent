import Foundation
import simd

/// Identity-bound, ordered sketch edges. Replaying never searches for a
/// nearby replacement when an edge is removed or a chain is disconnected.
nonisolated struct SweepPathDefinition: Codable, Hashable, Sendable {
    static let supportedVersion = 1
    static let maximumSegments = 1024
    static let maximumPoints = 100_001
    var version: Int
    var segments: [Segment]

    nonisolated struct Segment: Codable, Hashable, Sendable {
        var sketchID: SketchID
        var entityID: UUID
        var reversed: Bool
        init(sketchID: SketchID, entityID: UUID, reversed: Bool = false) {
            self.sketchID = sketchID; self.entityID = entityID; self.reversed = reversed
        }
        private enum CodingKeys: String, CodingKey { case sketchID, entityID, reversed }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sketchID = SketchID(raw: try c.decode(UUID.self, forKey: .sketchID))
            entityID = try c.decode(UUID.self, forKey: .entityID)
            reversed = try c.decodeIfPresent(Bool.self, forKey: .reversed) ?? false
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(sketchID.raw, forKey: .sketchID)
            try c.encode(entityID, forKey: .entityID)
            try c.encode(reversed, forKey: .reversed)
        }
    }

    nonisolated struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    init(segments: [Segment]) { version = Self.supportedVersion; self.segments = segments }
    private enum CodingKeys: String, CodingKey { case version, segments }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version == Self.supportedVersion else {
            throw Failure(message: "Unsupported sweep path version \(version).")
        }
        segments = try c.decode([Segment].self, forKey: .segments)
        try validate()
    }

    func validate() throws {
        guard version == Self.supportedVersion, !segments.isEmpty,
              segments.count <= Self.maximumSegments else {
            throw Failure(message: "A sweep path needs 1–\(Self.maximumSegments) ordered edges.")
        }
        let keys = segments.map { "\($0.sketchID.raw)/\($0.entityID)" }
        guard Set(keys).count == keys.count else {
            throw Failure(message: "A sweep path cannot repeat the same sketch edge.")
        }
    }

    func resolvedSpine(sketch: (SketchID) -> Sketch?) throws -> [SIMD3<Double>] {
        try validate()
        var spine: [SIMD3<Double>] = []
        for segment in segments {
            guard let source = sketch(segment.sketchID),
                  let entity = source.entities.first(where: { $0.id == segment.entityID }),
                  let local = Self.polyline(of: entity), local.count >= 2 else {
                throw Failure(message: "A sweep path edge is missing, closed or unsupported. Select its replacement explicitly.")
            }
            var points = local.map { source.plane.toWorld($0) }
            if segment.reversed { points.reverse() }
            guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
                  points.count <= Self.maximumPoints - spine.count else {
                throw Failure(message: "The sweep path is non-finite or too large to rebuild.")
            }
            if let end = spine.last {
                // This is the same chain tolerance used by the native picker;
                // orientation is stored, never re-guessed after an edit.
                guard let first = points.first, simd_length(first - end) <= 0.75 else {
                    throw Failure(message: "The selected sweep path edges no longer connect.")
                }
                spine.append(contentsOf: points.dropFirst())
            } else { spine = points }
        }
        guard spine.count >= 2,
              zip(spine, spine.dropFirst()).allSatisfy({ a, b in
                  let distance = simd_length(b - a)
                  return distance.isFinite && distance > 1e-9
              }) else {
            throw Failure(message: "A sweep path contains a collapsed or invalid edge.")
        }
        return spine
    }

    static func polyline(of entity: SketchEntity) -> [SIMD2<Double>]? {
        switch entity {
        case let .line(_, a, b): return [a, b]
        case let .arc(_, center, radius, startAngle, endAngle):
            return SketchEntity.arcPoints(center: center, radius: radius,
                startAngle: startAngle, endAngle: endAngle,
                segmentsPerTurn: SketchTessellator.circleSegments)
        case let .spline(_, points, closed):
            return closed ? nil : SketchEntity.splinePoints(points, closed: false)
        case .rect, .circle, .ellipse, .polygon: return nil
        }
    }
}

/// Exact arc-length placements on identity-bound lines, circular arcs and
/// circles. Spline tessellation is intentionally not promoted to exact input.
nonisolated struct CurvePatternPathDefinition: Codable, Hashable, Sendable {
    static var supportedVersion: Int { 1 }
    var version: Int = 1
    var segments: [SweepPathDefinition.Segment]
    init(segments: [SweepPathDefinition.Segment]) { self.segments = segments }

    func validate() throws {
        guard version == Self.supportedVersion else {
            throw AssociativeGeometryError.unsupportedSemanticVersion(version)
        }
        try SweepPathDefinition(segments: segments).validate()
    }

    private nonisolated enum Geometry {
        case line(SIMD3<Double>, SIMD3<Double>)
        case arc(center: SIMD3<Double>, u: SIMD3<Double>, v: SIMD3<Double>, radius: Double, start: Double, sweep: Double)
        var length: Double {
            switch self {
            case let .line(a, b): return simd_length(b - a)
            case let .arc(_, _, _, radius, _, sweep): return radius * abs(sweep)
            }
        }
        func at(_ fraction: Double) -> (point: SIMD3<Double>, tangent: SIMD3<Double>) {
            switch self {
            case let .line(a, b): return (a + (b - a) * fraction, simd_normalize(b - a))
            case let .arc(center, u, v, radius, start, sweep):
                let angle = start + sweep * fraction
                return (center + radius * (cos(angle) * u + sin(angle) * v),
                    (sweep < 0 ? -1.0 : 1.0) * (-sin(angle) * u + cos(angle) * v))
            }
        }
    }

    func transforms(count: Int, spacing: Double, rotate: Bool,
                    sketch: (SketchID) -> Sketch?) throws -> [Transform3D] {
        try validate()
        func failure(_ text: String) -> SweepPathDefinition.Failure { .init(message: text) }
        guard (1...10_000).contains(count), spacing.isFinite, spacing >= 0 else {
            throw failure("A curve pattern needs 1–10000 instances and nonnegative spacing.")
        }
        var geometry: [Geometry] = []
        for segment in segments {
            guard let source = sketch(segment.sketchID),
                  let entity = source.entities.first(where: { $0.id == segment.entityID }) else {
                throw failure("The pattern's original path edge is missing. Select its replacement explicitly.")
            }
            let item: Geometry
            switch entity {
            case let .line(_, a, b):
                let first = source.plane.toWorld(a), last = source.plane.toWorld(b)
                item = segment.reversed ? .line(last, first) : .line(first, last)
            case .arc, .circle:
                let center: SIMD2<Double>, radius: Double, start: Double, sweep: Double
                switch entity {
                case let .arc(_, c, r, a, b):
                    center = c; radius = r
                    let delta = SketchEntity.arcSweep(startAngle: a, endAngle: b)
                    start = segment.reversed ? a + delta : a
                    sweep = segment.reversed ? -delta : delta
                case let .circle(_, c, r):
                    center = c; radius = r; start = 0
                    sweep = segment.reversed ? -2 * .pi : 2 * .pi
                default: throw failure("Unsupported path edge.")
                }
                let u = source.plane.xAxis, v = source.plane.yAxis, scale = simd_length(u)
                guard scale.isFinite, scale > 1e-9,
                      abs(simd_length(v) - scale) <= scale * 1e-8,
                      abs(simd_dot(u, v)) <= scale * scale * 1e-8 else {
                    throw failure("A circular path needs an orthogonal plane with equal axis scale.")
                }
                item = .arc(center: source.plane.toWorld(center), u: u / scale, v: v / scale,
                    radius: radius * scale, start: start, sweep: sweep)
            default:
                throw failure("Curve patterns currently use lines, circular arcs or circles; the selected edge is unsupported.")
            }
            let a = item.at(0), b = item.at(1)
            guard item.length.isFinite, item.length > 1e-9,
                  [a.point, b.point, a.tangent, b.tangent].allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
                throw failure("The curve pattern path contains a collapsed or invalid edge.")
            }
            if let previous = geometry.last,
               simd_length(previous.at(1).point - a.point) > max(1, item.length) * 1e-8 {
                throw failure("The selected pattern path edges no longer connect.")
            }
            geometry.append(item)
        }
        guard let first = geometry.first, let last = geometry.last else { throw failure("Select a pattern path.") }
        let length = geometry.reduce(0) { $0 + $1.length }
        guard length.isFinite else { throw failure("The curve path length is invalid.") }
        let closed = simd_length(first.at(0).point - last.at(1).point) <= max(1, length) * 1e-8
        let step = spacing > 0 ? spacing : length / Double(max(1, closed ? count : count - 1))
        let finalDistance = step * Double(count - 1), tolerance = max(1, length) * 1e-9
        guard finalDistance <= length + tolerance, !closed || count == 1 || finalDistance < length - tolerance else {
            throw failure("The requested spacing extends beyond the pattern path or repeats its closed seam.")
        }
        let origin = first.at(0)
        var result: [Transform3D] = [.identity]
        var segmentIndex = 0, segmentStart = 0.0
        for i in 1..<count {
            let distance = min(length, step * Double(i))
            while segmentIndex + 1 < geometry.count && distance >= segmentStart + geometry[segmentIndex].length {
                segmentStart += geometry[segmentIndex].length; segmentIndex += 1
            }
            let item = geometry[segmentIndex], frame = item.at((distance - segmentStart) / item.length)
            var transform = Transform3D.identity
            if rotate { transform.rotation = simd_quatd(from: origin.tangent, to: frame.tangent) }
            transform.translation = frame.point - transform.rotation.act(origin.point)
            result.append(transform)
        }
        return result
    }
}

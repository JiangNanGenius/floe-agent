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

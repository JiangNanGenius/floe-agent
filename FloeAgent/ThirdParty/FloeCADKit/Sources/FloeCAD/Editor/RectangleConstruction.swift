import Foundation
import simd

nonisolated enum RectangleType: String, CaseIterable, Sendable {
    case diagonal, center, threePoint
    var title: String {
        switch self {
        case .diagonal: "Diagonal"
        case .center: "Center"
        case .threePoint: "Three-Point"
        }
    }
}

/// Pure construction math. Rotated rectangles use four ordinary constrained
/// lines, so existing dimensions, trim, projection, persistence and profiles work.
nonisolated enum RectangleConstruction {
    /// Restore control identity in older files, never sizing intent or geometry.
    /// Require the complete directed construction signature and an isolated loop.
    static func recoverLegacyGroups(in sketch: inout Sketch) {
        var visited = Set(sketch.rotatedRectangleEdges.values.flatMap { $0 })
        for entity in sketch.entities where !visited.contains(entity.id) {
            guard let ids = dimensionEdges(containing: entity.id, in: sketch.entities) else { continue }
            guard Set(ids).isDisjoint(with: visited) else { continue }
            visited.formUnion(ids)
            let members = Set(ids)
            guard ids.allSatisfy({ sketch.rectangleSizingAnchors[$0] == nil }),
                  !sketch.patternLinks.contains(where: {
                      !members.isDisjoint(with: $0.seedIDs)
                      || !members.isDisjoint(with: $0.allInstanceIDs)
                  }),
                  !sketch.disconnectedEndpoints.contains(where: { members.contains($0.entityID) }),
                  !sketch.constraints.contains(where: { relation in
                      relation.refs.contains { members.contains($0.entityID) }
                      && relation.refs.contains { !members.contains($0.entityID) }
                  }),
                  !sketch.dimensions.contains(where: { dimension in
                      dimension.refs.contains { members.contains($0.entityID) }
                      && dimension.refs.contains { !members.contains($0.entityID) }
                  }) else { continue }
            let edges = ids.compactMap { id in sketch.entities.first { $0.id == id } }
            // Endpoint connectivity above catches corner branches. Also decline
            // a T-junction at an edge interior, even without a saved relation.
            let hasInteriorBranch = sketch.entities.contains { other in
                guard !members.contains(other.id), case let .line(_, p, q) = other else { return false }
                return edges.contains { edge in
                    guard case let .line(_, a, b) = edge else { return false }
                    let delta = b - a, lengthSquared = simd_length_squared(delta)
                    guard lengthSquared > 1e-12 else { return false }
                    return [p, q].contains { point in
                        let t = simd_dot(point - a, delta) / lengthSquared
                        return t >= 0 && t <= 1 && simd_distance(point, a + t * delta) < 1e-5
                    }
                }
            }
            guard !hasInteriorBranch else { continue }
            let signature = constraints(for: edges)
            guard signature.count == 7, signature.allSatisfy({ expected in
                sketch.constraints.contains { actual in
                    actual.kind == expected.kind && actual.refs == expected.refs
                }
            }) else { continue }
            sketch.rotatedRectangleEdges[ids[0]] = ids
        }
    }

    /// The old primitive ID belongs to the first edge after safe preparation.
    /// Its center remains the midpoint of opposite vertices, not that edge's
    /// midpoint. Persisted edge identity survives later attached geometry.
    static func centerDiagonalReferences(_ id: UUID, in sketch: Sketch) -> (ConstraintRef, ConstraintRef)? {
        guard sketch.rectangleSizingAnchors[id]?.cornerUsesMax == nil,
              let edges = sketch.rotatedRectangleEdges[id], edges.count == 4, edges.first == id,
              Set(edges).count == 4, edges.allSatisfy({ edge in
                  sketch.entities.contains { if case .line = $0 { return $0.id == edge }; return false }
              }),
              case let .line(_, a, _)? = sketch.entities.first(where: { $0.id == id }),
              case let .line(_, c, d)? = sketch.entities.first(where: { $0.id == edges[2] }) else { return nil }
        let oppositeRole: PointRole = simd_distance(a, c) > simd_distance(a, d) ? .endpointA : .endpointB
        return (.init(entityID: id, role: .endpointA), .init(entityID: edges[2], role: oppositeRole))
    }

    /// Prepare an isolated center rectangle for rotation without removing its
    /// saved dimension/constraint identities and an explicit group center.
    static func prepareCenterRotation(_ sketch: Sketch, id: UUID, edgeIDs: [UUID]) -> Sketch? {
        let hasCenterLock = sketch.constraints.contains {
            $0.kind == .fixed && $0.refs == [.init(entityID: id, role: .center)]
        }
        let centerIntent = sketch.rectangleSizingAnchors[id] ?? (hasCenterLock ? .center : nil)
        guard edgeIDs.count == 4, edgeIDs.first == id, Set(edgeIDs).count == 4,
              sketch.patternLinks.isEmpty,
              !sketch.disconnectedEndpoints.contains(where: { $0.entityID == id }),
              let anchor = centerIntent, anchor.cornerUsesMax == nil,
              let index = sketch.entities.firstIndex(where: { $0.id == id }),
              case let .rect(_, lo, hi) = sketch.entities[index],
              edgeIDs.dropFirst().allSatisfy({ newID in !sketch.entities.contains { $0.id == newID } }) else { return nil }
        for constraint in sketch.constraints where constraint.refs.contains(where: { $0.entityID == id }) {
            guard constraint.kind == .fixed, constraint.refs == [.init(entityID: id, role: .center)] else { return nil }
        }
        for dimension in sketch.dimensions where dimension.refs.contains(where: { $0.entityID == id }) {
            guard dimension.kind == .horizontal || dimension.kind == .vertical,
                  dimension.refs == [.init(entityID: id, role: .endpointA), .init(entityID: id, role: .endpointB)] else { return nil }
        }
        let corners = [lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y)]
        let lines: [SketchEntity] = (0..<4).map {
            .line(id: edgeIDs[$0], a: corners[$0], b: corners[($0 + 1) % 4])
        }
        var result = sketch
        result.rectangleSizingAnchors[id] = anchor
        result.rotatedRectangleEdges[id] = edgeIDs
        result.entities.replaceSubrange(index...index, with: lines)
        result.constraints += constraints(for: lines)
        for i in result.dimensions.indices where result.dimensions[i].refs.contains(where: { $0.entityID == id }) {
            let edgeID = edgeIDs[result.dimensions[i].kind == .horizontal ? 0 : 1]
            result.dimensions[i].kind = .distance
            result.dimensions[i].refs = [.init(entityID: edgeID, role: .endpointA),
                                         .init(entityID: edgeID, role: .endpointB)]
        }
        if result.constructionEntityIDs.contains(id) {
            result.constructionEntityIDs.formUnion(edgeIDs)
        }
        // A branched component cannot safely serve as this rectangle's center.
        guard dimensionEdges(containing: id, in: result) == edgeIDs else { return nil }
        return result
    }

    /// Geometric coincidence alone is not a rectangular connection after an
    /// explicit Disconnect. A later explicit Coincident reconnects the endpoint.
    static func dimensionEdges(containing id: UUID, in sketch: Sketch) -> [UUID]? {
        guard let loop = dimensionEdges(containing: id, in: sketch.entities) else { return nil }
        for ref in sketch.disconnectedEndpoints where loop.contains(ref.entityID) {
            guard sketch.constraints.contains(where: {
                $0.kind == .coincident && $0.refs.contains(ref) &&
                $0.refs.contains(where: { $0.entityID != ref.entityID && loop.contains($0.entityID) })
            }) else { return nil }
        }
        return loop
    }

    static func axisAligned(from anchor: SIMD2<Double>, to corner: SIMD2<Double>,
                            centered: Bool, id: UUID = UUID()) -> SketchEntity? {
        let other = centered ? 2 * anchor - corner : anchor
        guard abs(corner.x - other.x) > 1e-3, abs(corner.y - other.y) > 1e-3 else { return nil }
        return .rect(id: id, min: simd_min(other, corner), max: simd_max(other, corner))
    }

    /// Counter-clockwise edges: bottom, right, top, left in sketch coordinates.
    static func axisEdge(_ entity: SketchEntity, index: Int) -> (a: SIMD2<Double>, b: SIMD2<Double>, normal: SIMD2<Double>)? {
        guard case let .rect(_, lo, hi) = entity, (0..<4).contains(index) else { return nil }
        let corners = [lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y)]
        let normals: [SIMD2<Double>] = [SIMD2(0, -1), SIMD2(1, 0), SIMD2(0, 1), SIMD2(-1, 0)]
        return (corners[index], corners[(index + 1) % 4], normals[index])
    }

    static func nearestAxisEdge(_ entity: SketchEntity, to point: SIMD2<Double>) -> Int? {
        (0..<4).min { i, j in
            func distance(_ index: Int) -> Double {
                guard let e = axisEdge(entity, index: index) else { return .infinity }
                let v = e.b - e.a
                let t = min(1, max(0, simd_dot(point - e.a, v) / simd_length_squared(v)))
                return simd_distance(point, e.a + t * v)
            }
            return distance(i) < distance(j)
        }
    }

    static func threePoint(a: SIMD2<Double>, b: SIMD2<Double>, heightPoint: SIMD2<Double>,
                           ids: [UUID]) -> [SketchEntity] {
        guard ids.count == 4 else { return [] }
        let base = b - a, length = simd_length(base)
        guard length > 1e-3 else { return [] }
        let normal = SIMD2(-base.y, base.x) / length
        let height = simd_dot(heightPoint - b, normal)
        guard abs(height) > 1e-3 else { return [] }
        let corners = [a, b, b + normal * height, a + normal * height]
        return (0..<4).map { .line(id: ids[$0], a: corners[$0], b: corners[($0 + 1) % 4]) }
    }

    /// Recognize four selected ordinary lines as one closed rectangular loop.
    /// This recovers an ordered loop and its adjacent dimension edges without storing a second
    /// shape representation or relying on UUID/order/orientation conventions.
    static func dimensionEdges(in entities: [SketchEntity]) -> [UUID]? {
        guard entities.count == 4 else { return nil }
        var lines: [(id: UUID, a: SIMD2<Double>, b: SIMD2<Double>)] = []
        for entity in entities {
            guard case let .line(id, a, b) = entity else { return nil }
            lines.append((id, a, b))
        }
        let tolerance = 1e-5
        let first = lines.removeFirst()
        var loop = [first]
        while !lines.isEmpty {
            let end = loop.last!.b
            guard let index = lines.firstIndex(where: {
                simd_distance($0.a, end) < tolerance || simd_distance($0.b, end) < tolerance
            }) else { return nil }
            let next = lines.remove(at: index)
            loop.append(simd_distance(next.a, end) < tolerance ? next : (next.id, next.b, next.a))
        }
        guard simd_distance(loop.last!.b, first.a) < tolerance else { return nil }
        let vectors = loop.map { $0.b - $0.a }
        guard vectors.allSatisfy({ simd_length($0) > 1e-3 }) else { return nil }
        for i in 0..<4 {
            guard abs(simd_dot(simd_normalize(vectors[i]),
                               simd_normalize(vectors[(i + 1) % 4]))) < tolerance else { return nil }
        }
        return loop.map(\.id)
    }

    /// Recover an isolated rectangular line component after selecting one
    /// edge (including save/reload), retaining document order. Branching or
    /// larger connected components are deliberately not guessed as rectangles.
    static func dimensionEdges(containing id: UUID, in entities: [SketchEntity]) -> [UUID]? {
        let lines = entities.filter { if case .line = $0 { return true }; return false }
        guard let seed = lines.first(where: { $0.id == id }) else { return nil }
        var connected = [seed]
        var ids: Set<UUID> = [id]
        var changed = true
        func touches(_ lhs: SketchEntity, _ rhs: SketchEntity) -> Bool {
            guard case let .line(_, a, b) = lhs, case let .line(_, c, d) = rhs else { return false }
            return [simd_distance(a, c), simd_distance(a, d),
                    simd_distance(b, c), simd_distance(b, d)].min()! < 1e-5
        }
        while changed {
            changed = false
            for line in lines where !ids.contains(line.id) {
                if connected.contains(where: { touches(line, $0) }) {
                    connected.append(line); ids.insert(line.id); changed = true
                    if ids.count > 4 { return nil }
                }
            }
        }
        return dimensionEdges(in: lines.filter { ids.contains($0.id) })
    }

    /// Baseline sizing preserves the lower adjacent side in sketch coordinates,
    /// independent of construction direction. Horizontal ties keep the left side.
    /// This is a transient solve preference, never a saved fixed constraint.
    static func baselineAnchor(containing id: UUID, in entities: [SketchEntity]) -> UUID? {
        guard let loop = dimensionEdges(containing: id, in: entities),
              id == loop[0] || id == loop[2] else { return nil }
        let sides = [loop[1], loop[3]].compactMap { sideID -> (UUID, SIMD2<Double>)? in
            guard let entity = entities.first(where: { $0.id == sideID }),
                  case let .line(_, a, b) = entity else { return nil }
            return (sideID, (a + b) / 2)
        }
        return sides.min {
            abs($0.1.y - $1.1.y) > 1e-7 ? $0.1.y < $1.1.y : $0.1.x < $1.1.x
        }?.0
    }

    /// Structural relations replacing the implicit rules of a rotated primitive.
    /// Match only the saved ordered group, not arbitrary connected sketch lines.
    static func isStructuralRelation(_ constraint: SketchConstraint, in sketch: Sketch) -> Bool {
        guard constraint.refs.count == 2 else { return false }
        func matches(_ a: ConstraintRef, _ b: ConstraintRef) -> Bool {
            constraint.refs == [a, b] || constraint.refs == [b, a]
        }
        return sketch.rotatedRectangleEdges.values.contains { ids in
            guard ids.count == 4, Set(ids).count == 4,
                  ids.allSatisfy({ id in sketch.entities.contains {
                      if case .line = $0 { return $0.id == id }; return false
                  } }) else { return false }
            func whole(_ i: Int) -> ConstraintRef { .init(entityID: ids[i], role: .whole) }
            switch constraint.kind {
            case .parallel:
                return matches(whole(0), whole(2)) || matches(whole(1), whole(3))
            case .perpendicular:
                return matches(whole(0), whole(1))
            case .coincident:
                return (0..<4).contains { i in
                    matches(ConstraintRef(entityID: ids[i], role: .endpointB),
                            ConstraintRef(entityID: ids[(i + 1) % 4], role: .endpointA))
                }
            default: return false
            }
        }
    }

    static func constraints(for edges: [SketchEntity]) -> [SketchConstraint] {
        guard edges.count == 4 else { return [] }
        func whole(_ i: Int) -> ConstraintRef { .init(entityID: edges[i].id, role: .whole) }
        var result = [
            SketchConstraint(kind: .parallel, refs: [whole(0), whole(2)]),
            SketchConstraint(kind: .parallel, refs: [whole(1), whole(3)]),
            SketchConstraint(kind: .perpendicular, refs: [whole(0), whole(1)])
        ]
        for i in 0..<4 {
            result.append(SketchConstraint(kind: .coincident, refs: [
                .init(entityID: edges[i].id, role: .endpointB),
                .init(entityID: edges[(i + 1) % 4].id, role: .endpointA)]))
        }
        return result
    }
}

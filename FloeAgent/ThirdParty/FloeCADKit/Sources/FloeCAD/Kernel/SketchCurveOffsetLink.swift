// SPDX-License-Identifier: MPL-2.0
import Foundation
import simd

/// An explicit normal-offset relation. Geometry in entities is its validated
/// cache, never the definition. Source intervals follow their source; future
/// exact general-curve materializers can share this identity/lifecycle layer.
nonisolated struct SketchCurveOffsetLink: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let version: Int
    let sourceDefinitionVersion: Int
    let intervalPolicy: String
    let sourceID: UUID
    let targetID: UUID
    let distance: Double
    let sourceKind: SketchCurveDefinition.SourceKind
    let convention: String

    init(id: UUID = UUID(), sourceID: UUID, targetID: UUID, distance: Double,
         definition: SketchCurveDefinition) throws {
        self.id = id; version = 1; sourceDefinitionVersion = definition.version
        intervalPolicy = "followSource"
        self.sourceID = sourceID; self.targetID = targetID; self.distance = distance
        sourceKind = definition.sourceKind; convention = definition.normalOffsetConvention
        try validate()
    }
    func validate() throws {
        guard version == 1, sourceDefinitionVersion == 1, intervalPolicy == "followSource",
              ["left_of_travel", "outward_conic"].contains(convention) else {
            throw SketchCurveEditFailure(code: "unsupported_curve_offset_version", message: "This offset relation needs a newer version.", linkIDs: [id])
        }
        guard sourceID != targetID, distance.isFinite, abs(distance) > SketchCurveDefinition.epsilon, abs(distance) <= 1e12 else {
            throw SketchCurveEditFailure(code: "invalid_curve_offset", message: "The offset relation is invalid.", entityIDs: [sourceID, targetID], linkIDs: [id])
        }
    }
    private enum CodingKeys: String, CodingKey {
        case id, version, sourceDefinitionVersion, intervalPolicy, sourceID, targetID, distance, sourceKind, convention
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); version = try c.decode(Int.self, forKey: .version)
        sourceDefinitionVersion = try c.decode(Int.self, forKey: .sourceDefinitionVersion)
        intervalPolicy = try c.decode(String.self, forKey: .intervalPolicy)
        sourceID = try c.decode(UUID.self, forKey: .sourceID); targetID = try c.decode(UUID.self, forKey: .targetID)
        distance = try c.decode(Double.self, forKey: .distance)
        sourceKind = try c.decode(SketchCurveDefinition.SourceKind.self, forKey: .sourceKind)
        convention = try c.decode(String.self, forKey: .convention)
        try validate()
    }
    private init(remapping original: Self, sourceID: UUID, targetID: UUID) {
        id = UUID(); version = original.version
        sourceDefinitionVersion = original.sourceDefinitionVersion
        intervalPolicy = original.intervalPolicy
        self.sourceID = sourceID; self.targetID = targetID
        distance = original.distance; sourceKind = original.sourceKind; convention = original.convention
    }
    static func remappingValidated(_ original: Self, sourceID: UUID, targetID: UUID) -> Self {
        Self(remapping: original, sourceID: sourceID, targetID: targetID)
    }

}

nonisolated enum SketchCurveOffsetKit {
    static func validatePlane(_ plane: SketchPlane) throws {
        let values = [plane.origin.x, plane.origin.y, plane.origin.z,
                      plane.xAxis.x, plane.xAxis.y, plane.xAxis.z,
                      plane.yAxis.x, plane.yAxis.y, plane.yAxis.z]
        guard values.allSatisfy({ $0.isFinite && abs($0) <= 1e12 }),
              abs(simd_length_squared(plane.xAxis) - 1) <= 1e-8,
              abs(simd_length_squared(plane.yAxis) - 1) <= 1e-8,
              abs(simd_dot(plane.xAxis, plane.yAxis)) <= 1e-8 else {
            throw SketchCurveEditFailure(code: "invalid_curve_plane", message: "The sketch plane cannot preserve exact distances.")
        }
    }
    /// Until body -> projection -> general curve offsets share one qualified
    /// dependency replay, refuse a source connected to external geometry.
    /// Disjoint local curves in the same sketch remain usable. Hyperedge BFS
    /// is linear in stored reference entries; no pairwise expansion.
    static func externalDependencies(of source: UUID, in sketch: Sketch) -> Set<UUID> {
        guard sketch.hasExternalReferences else { return [] }
        var groups = sketch.constraints.map { $0.refs.map(\.entityID) }
            + sketch.dimensions.map { $0.refs.map(\.entityID) }
        groups += sketch.patternLinks.map { $0.seedIDs + $0.instanceIDs.flatMap { $0 } }
        groups += sketch.curveOffsetLinks.map { [$0.sourceID, $0.targetID] }
        var byEntity: [UUID: [Int]] = [:]
        for (index, group) in groups.enumerated() { for id in group { byEntity[id, default: []].append(index) } }
        var queue = [source], cursor = 0, seen: Set<UUID> = [source], visited = Set<Int>()
        while cursor < queue.count {
            let id = queue[cursor]; cursor += 1
            for index in byEntity[id] ?? [] where visited.insert(index).inserted {
                for next in groups[index] where seen.insert(next).inserted { queue.append(next) }
            }
        }
        return seen.intersection(Set((sketch.externalReferences ?? []).map(\.entity)))
    }
    static func relatedLinks(to id: UUID, in sketch: Sketch) -> [SketchCurveOffsetLink] {
        sketch.curveOffsetLinks.filter { $0.sourceID == id || $0.targetID == id }
    }
    static func validateTransition(before: Sketch, after: Sketch) throws {
        for link in after.curveOffsetLinks {
            guard before.curveOffsetLinks.contains(link),
                  let oldSource = before.entities.first(where: { $0.id == link.sourceID }),
                  let newSource = after.entities.first(where: { $0.id == link.sourceID }), oldSource == newSource,
                  let oldTarget = before.entities.first(where: { $0.id == link.targetID }) else { continue }
            guard let newTarget = after.entities.first(where: { $0.id == link.targetID }), newTarget == oldTarget else {
                throw SketchCurveEditFailure(code: "linked_curve_target", message: "Make this offset independent before editing or deleting it.",
                    entityIDs: [link.sourceID, link.targetID], linkIDs: [link.id])
            }
        }
    }
    /// Resolve all links in dependency order. Failure returns no partial
    /// sketch and never removes a broken link or its user's constraints.
    static func resolve(_ sketch: Sketch) throws -> Sketch {
        guard !sketch.curveOffsetLinks.isEmpty else { return sketch }
        try validatePlane(sketch.plane)
        guard sketch.curveOffsetLinks.count <= 256 else {
            throw SketchCurveEditFailure(code: "curve_offset_limit", message: "This sketch has too many linked offsets.")
        }
        var byID: [UUID: SketchEntity] = [:]
        for entity in sketch.entities {
            guard byID.updateValue(entity, forKey: entity.id) == nil else {
                throw SketchCurveEditFailure(code: "duplicate_curve_identity", message: "The sketch contains duplicate curve identities.", entityIDs: [entity.id])
            }
        }
        var targets = Set<UUID>(), linkIDs = Set<UUID>()
        for link in sketch.curveOffsetLinks {
            try link.validate()
            let external = externalDependencies(of: link.sourceID, in: sketch)
            guard external.isEmpty, sketch.externalReference(forEntityID: link.targetID) == nil else {
                throw SketchCurveEditFailure(code: "external_reference", message: "Detach the projected curve before linking a normal offset.",
                    entityIDs: [link.sourceID, link.targetID] + external.sorted { $0.uuidString < $1.uuidString }, linkIDs: [link.id])
            }
            guard targets.insert(link.targetID).inserted, linkIDs.insert(link.id).inserted,
                  byID[link.sourceID] != nil, byID[link.targetID] != nil else {
                throw SketchCurveEditFailure(code: "broken_curve_offset", message: "A linked offset has a missing or ambiguous source.",
                    entityIDs: [link.sourceID, link.targetID], linkIDs: [link.id])
            }
            let constraints = sketch.constraints.filter { $0.refs.contains(where: { $0.entityID == link.targetID }) }.map(\.id)
            let dimensions = sketch.dimensions.filter { $0.refs.contains(where: { $0.entityID == link.targetID }) }.map(\.id)
            if !constraints.isEmpty || !dimensions.isEmpty || sketch.patternLinks.contains(where: { $0.seedIDs.contains(link.targetID) || $0.allInstanceIDs.contains(link.targetID) }) {
                throw SketchCurveEditFailure(code: "constrained_curve_offset_target", message: "Make the offset independent before constraining or patterning it.",
                    entityIDs: [link.targetID], constraintIDs: constraints, dimensionIDs: dimensions, linkIDs: [link.id])
            }
        }
        var pending = sketch.curveOffsetLinks
        while !pending.isEmpty {
            let pendingTargets = Set(pending.map(\.targetID)); var remaining: [SketchCurveOffsetLink] = []
            var progressed = false
            for link in pending {
                if pendingTargets.contains(link.sourceID) { remaining.append(link); continue }
                do {
                    let source = try SketchCurveDefinition(byID[link.sourceID]!)
                    guard source.sourceKind == link.sourceKind, source.normalOffsetConvention == link.convention else {
                        throw SketchCurveEditFailure(code: "changed_curve_support", message: "The source curve no longer has the offset's original kind.")
                    }
                    byID[link.targetID] = try source.normalOffset(by: link.distance).materialized(id: link.targetID)
                } catch var failure as SketchCurveEditFailure {
                    failure.entityIDs = [link.sourceID, link.targetID]; failure.linkIDs = [link.id]; throw failure
                }
                progressed = true
            }
            guard progressed else {
                throw SketchCurveEditFailure(code: "cyclic_curve_offsets", message: "The linked offsets contain a dependency cycle.",
                    entityIDs: remaining.flatMap { [$0.sourceID, $0.targetID] }, linkIDs: remaining.map(\.id))
            }
            pending = remaining
        }
        var result = sketch; result.entities = sketch.entities.map { byID[$0.id]! }; return result
    }
    static func validateStored(_ sketch: Sketch) throws {
        let resolved = try resolve(sketch)
        guard resolved.entities == sketch.entities else {
            throw SketchCurveEditFailure(code: "stale_curve_offset_cache", message: "The stored linked offset does not match its source.",
                entityIDs: sketch.curveOffsetLinks.map(\.targetID))
        }
    }
}

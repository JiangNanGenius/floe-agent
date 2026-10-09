//
//  SketchPatternLink.swift
//  openshape3d
//
//  Spec §2.5 — the sketch PATTERN CONSTRAINT. The Pattern tool copies entities,
//  but a plain copy goes stale the moment the user edits the original. A link
//  keeps the instances slaved to their seed: edit the seed (or the pattern's
//  count/spacing) and the instances re-generate.
//
//  The link is auto-created by the Pattern tool, never by hand, and deleting it
//  leaves the instances behind as ordinary independent entities — exactly the
//  "Delete Constraints" behaviour the spec describes.
//

import Foundation
import simd

/// A live link between a pattern's seed entities and the copies it produced.
///
/// `instanceIDs[i]` holds the entity IDs of copy `i + 1` (the seed itself is
/// copy 0 and is not repeated), in the same order as `seedIDs`, so regeneration
/// can rewrite each instance IN PLACE and keep its identity — which is what
/// lets selections, constraints and history references survive an edit.
nonisolated struct SketchPatternLink: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var seedIDs: [UUID]
    var instanceIDs: [[UUID]]
    var spec: PatternSpec

    init(id: UUID = UUID(), seedIDs: [UUID], instanceIDs: [[UUID]], spec: PatternSpec) {
        self.id = id
        self.seedIDs = seedIDs
        self.instanceIDs = instanceIDs
        self.spec = spec
    }

    /// Every entity this link owns — used to decide what a delete removes.
    var allInstanceIDs: Set<UUID> { Set(instanceIDs.flatMap { $0 }) }
}

nonisolated enum SketchPatternKit {

    /// Build a link plus the entities for its copies. `count` in `spec` is the
    /// TOTAL including the seed, so this emits `count - 1` copies.
    ///
    /// Returns nil when the pattern would be a no-op (fewer than two total, or
    /// no seed), so callers do not create an empty link.
    static func makePattern(
        seeds: [SketchEntity], spec: PatternSpec
    ) -> (link: SketchPatternLink, instances: [SketchEntity])? {
        guard !seeds.isEmpty, spec.count >= 2 else { return nil }
        let transforms = instanceTransforms(spec)
        guard !transforms.isEmpty else { return nil }

        var instances: [SketchEntity] = []
        var ids: [[UUID]] = []
        for t in transforms {
            var row: [UUID] = []
            for seed in seeds {
                // `transformed` can explode one entity into several (a rotated
                // rect becomes lines); the link tracks the FIRST, which is the
                // entity a user would select, and the rest ride along.
                let produced = PatternKit.transformed(seed, by: t)
                instances.append(contentsOf: produced)
                row.append(produced.first?.id ?? UUID())
            }
            ids.append(row)
        }
        let link = SketchPatternLink(
            seedIDs: seeds.map(\.id), instanceIDs: ids, spec: spec)
        return (link, instances)
    }

    /// Re-generate every linked instance in `sketch` from its current seed.
    ///
    /// Instance IDs are PRESERVED so selections and references survive. A link
    /// whose seed has been deleted is dropped (its instances stay as ordinary
    /// entities) rather than regenerating from nothing.
    static func regenerate(_ sketch: Sketch) -> Sketch {
        guard !sketch.patternLinks.isEmpty else { return sketch }
        var result = sketch
        var byID = Dictionary(uniqueKeysWithValues: sketch.entities.map { ($0.id, $0) })
        var survivingLinks: [SketchPatternLink] = []

        for link in sketch.patternLinks {
            let seeds = link.seedIDs.compactMap { byID[$0] }
            guard seeds.count == link.seedIDs.count else { continue }  // seed gone → drop link
            let transforms = instanceTransforms(link.spec)
            guard transforms.count == link.instanceIDs.count else {
                survivingLinks.append(link)
                continue
            }
            for (row, t) in zip(link.instanceIDs, transforms) {
                for (instanceID, seed) in zip(row, seeds) {
                    guard let fresh = PatternKit.transformed(seed, by: t).first else { continue }
                    byID[instanceID] = withID(fresh, instanceID)
                }
            }
            survivingLinks.append(link)
        }

        // Rewrite in place, preserving document order.
        result.entities = sketch.entities.map { byID[$0.id] ?? $0 }
        result.patternLinks = survivingLinks
        return result
    }

    /// Break a link (spec §2.5 "Delete Constraints"): the instances remain as
    /// individual entities, they simply stop following the seed.
    static func unlink(_ linkID: UUID, in sketch: Sketch) -> Sketch {
        var result = sketch
        result.patternLinks.removeAll { $0.id == linkID }
        return result
    }

    /// The link that owns `entityID`, whether as a seed or an instance — this is
    /// what lets re-selecting ANY member re-activate the pattern badges.
    static func link(owning entityID: UUID, in sketch: Sketch) -> SketchPatternLink? {
        sketch.patternLinks.first {
            $0.seedIDs.contains(entityID) || $0.allInstanceIDs.contains(entityID)
        }
    }

    // MARK: - Helpers

    /// Transforms for the COPIES only.
    ///
    /// `PatternKit`'s sketch transforms start with `.identity` — that slot is
    /// the seed, which already exists in the sketch. Including it would stamp a
    /// duplicate directly on top of the original, so it is dropped here. Both
    /// creation and regeneration go through this, keeping `instanceIDs` and the
    /// transform list index-aligned.
    private static func instanceTransforms(_ spec: PatternSpec) -> [SketchPatternTransform] {
        let all: [SketchPatternTransform]
        switch spec.kind {
        case .linear:
            all = PatternKit.linearSketchTransforms(
                direction: SIMD2(spec.axis.x, spec.axis.z),
                spacing: spec.spacing, count: spec.count)
        case .circular:
            all = PatternKit.circularSketchTransforms(
                center: .zero, count: spec.count,
                totalAngle: spec.totalAngle, rotateInstances: spec.rotateInstances)
        }
        return Array(all.dropFirst())
    }

    /// Re-stamp an entity with a specific ID (regeneration mints fresh ones).
    private static func withID(_ entity: SketchEntity, _ id: UUID) -> SketchEntity {
        switch entity {
        case let .line(_, a, b): .line(id: id, a: a, b: b)
        case let .rect(_, lo, hi): .rect(id: id, min: lo, max: hi)
        case let .circle(_, c, r): .circle(id: id, center: c, radius: r)
        case let .arc(_, c, r, s, e): .arc(id: id, center: c, radius: r, startAngle: s, endAngle: e)
        case let .ellipse(_, c, rx, ry, rot):
            .ellipse(id: id, center: c, radiusX: rx, radiusY: ry, rotation: rot)
        case let .polygon(_, c, r, n, rot):
            .polygon(id: id, center: c, radius: r, sides: n, rotation: rot)
        case let .spline(_, pts, closed): .spline(id: id, points: pts, closed: closed)
        }
    }
}

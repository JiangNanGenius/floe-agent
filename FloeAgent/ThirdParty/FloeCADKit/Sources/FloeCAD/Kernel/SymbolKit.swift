//
//  SymbolKit.swift
//  openshape3d
//
//  Symbol sketch objects (plan §B16, spec §1.16): a named group of sketch
//  entities holding their relative shape, placed/reused as a unit. Entities
//  are stored in symbol-local coordinates (normalized so the group centroid
//  sits at the origin); instantiation stamps a transformed copy with fresh
//  IDs into a sketch.
//

import Foundation
import simd

nonisolated struct SymbolID: Hashable, Codable, Sendable {
    let raw: UUID
    init() { self.raw = UUID() }
    init(raw: UUID) { self.raw = raw }
}

/// A reusable group of sketch entities in symbol-local coordinates.
nonisolated struct Symbol: Identifiable, Codable, Equatable, Sendable {
    let id: SymbolID
    var name: String
    /// Normalized about the group centroid (see `SymbolKit.capture`).
    var entities: [SketchEntity]

    init(id: SymbolID = SymbolID(), name: String = "Symbol", entities: [SketchEntity]) {
        self.id = id
        self.name = name
        self.entities = entities
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, entities
    }

    /// `name` is optional on decode, matching the other persisted types.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SymbolID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Symbol"
        entities = try container.decode([SketchEntity].self, forKey: .entities)
    }
}

nonisolated enum SymbolKit {

    /// Representative group centroid: mean of one anchor point per entity
    /// (line midpoint, rect center, center of the circular entities). Stable
    /// under ID reminting, so `centroid(of: symbol.entities) ≈ .zero` after
    /// capture and `≈ point` after instantiate (rotation-invariant).
    static func centroid(of entities: [SketchEntity]) -> SIMD2<Double> {
        guard !entities.isEmpty else { return .zero }
        var sum = SIMD2<Double>.zero
        for entity in entities {
            switch entity {
            case let .line(_, a, b):
                sum += (a + b) / 2
            case let .rect(_, lo, hi):
                sum += (lo + hi) / 2
            case let .circle(_, center, _), let .arc(_, center, _, _, _),
                 let .ellipse(_, center, _, _, _), let .polygon(_, center, _, _, _):
                sum += center
            case let .spline(_, points, _):
                // Mean of the control points — the spline's own centre of mass.
                sum += points.isEmpty
                    ? .zero
                    : points.reduce(SIMD2<Double>.zero, +) / Double(points.count)
            }
        }
        return sum / Double(entities.count)
    }

    /// Snapshot `entities` as a symbol: translated so their centroid lands on
    /// the origin, with fresh IDs so the symbol never aliases live sketch
    /// entities.
    static func capture(name: String, entities: [SketchEntity]) -> Symbol {
        let normalized = SketchTransform.translate(entities: entities, by: -centroid(of: entities))
        return Symbol(name: name, entities: normalized.map(withFreshID))
    }

    /// A placed instance: rotated CCW by `rotation` (radians) about the
    /// symbol origin, translated so the symbol origin lands on `point`, and
    /// reminted with fresh IDs so repeated placement never collides. Add to a
    /// sketch via `AddSketchEntitiesCommand`.
    static func instantiate(
        _ symbol: Symbol, at point: SIMD2<Double>, rotation: Double = 0
    ) -> [SketchEntity] {
        var placed = symbol.entities
        if rotation != 0 {
            placed = SketchTransform.rotate(entities: placed, about: .zero, angle: rotation)
        }
        placed = SketchTransform.translate(entities: placed, by: point)
        return placed.map(withFreshID)
    }

    private static func withFreshID(_ entity: SketchEntity) -> SketchEntity {
        switch entity {
        case let .line(_, a, b):
            .line(id: UUID(), a: a, b: b)
        case let .rect(_, lo, hi):
            .rect(id: UUID(), min: lo, max: hi)
        case let .circle(_, center, radius):
            .circle(id: UUID(), center: center, radius: radius)
        case let .arc(_, center, radius, start, end):
            .arc(id: UUID(), center: center, radius: radius, startAngle: start, endAngle: end)
        case let .ellipse(_, center, rx, ry, rotation):
            .ellipse(id: UUID(), center: center, radiusX: rx, radiusY: ry, rotation: rotation)
        case let .polygon(_, center, radius, sides, rotation):
            .polygon(id: UUID(), center: center, radius: radius, sides: sides, rotation: rotation)
        case let .spline(_, points, closed):
            .spline(id: UUID(), points: points, closed: closed)
        }
    }
}

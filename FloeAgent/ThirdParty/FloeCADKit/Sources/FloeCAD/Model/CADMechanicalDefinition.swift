// SPDX-License-Identifier: MPL-2.0
// Bounded manufacturing intent, replayed by the existing pinned OCCT kernel.
import Foundation
import simd

nonisolated enum CADMechanicalFailure: Error, LocalizedError, Sendable {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

nonisolated struct CADSheetMetalSpec: Codable, Equatable, Sendable {
    // Both flange lengths start at the bend tangencies, not the virtual sharp corner.
    var flangeA = Expr(value: 40)
    var flangeB = Expr(value: 30)
    var width = Expr(value: 25)
    var thickness = Expr(value: 2)
    var innerRadius = Expr(value: 4)
    var bendDegrees = Expr(value: 90)
    // Explicit user/process input. No material calibration or springback is inferred.
    var kFactor = Expr(value: 0.5)
    var bendAllowance: Double { bendDegrees.value * .pi / 180 * (innerRadius.value + kFactor.value * thickness.value) }
    var blankLength: Double { flangeA.value + flangeB.value + bendAllowance }
}

nonisolated struct CADWeldmentMember: Codable, Equatable, Identifiable, Sendable {
    enum Stock: String, Codable, CaseIterable, Hashable, Sendable { case flatBar, rectangularTube, roundBar, roundTube }
    var id = UUID()
    // A separate author-owned inner boundary prevents an inner/outer wall name collision.
    var innerBoundaryID = UUID()
    var profile: Stock = .rectangularTube
    var width = Expr(value: 20) // outside diameter for round stock
    var depth = Expr(value: 10)
    var wall = Expr(value: 2)
    var length = Expr(value: 100)
    var material = "Steel"
    var placement = Transform3D.identity
    var sectionArea: Double {
        let w = width.value, d = depth.value, t = wall.value
        switch profile {
        case .flatBar: return w * d
        case .rectangularTube: return w * d - (w - 2 * t) * (d - 2 * t)
        case .roundBar: return .pi * w * w / 4
        case .roundTube: return .pi * (w * w - (w - 2 * t) * (w - 2 * t)) / 4
        }
    }
}

nonisolated struct CADMechanicalDefinition: Codable, Equatable, Sendable {
    static let supportedVersion = 1
    enum Operation: String, Codable, Hashable, Sendable { case singleBendSheet, straightWeldment, spurGear }
    var version = Self.supportedVersion
    var id = UUID()
    var operation: Operation
    var sheet: CADSheetMetalSpec?
    var gear: CADSpurGearSpec? = nil
    var members: [CADWeldmentMember]
    init(sheet: CADSheetMetalSpec) { operation = .singleBendSheet; self.sheet = sheet; members = [] }
    init(members: [CADWeldmentMember]) { operation = .straightWeldment; sheet = nil; self.members = members }
    init(gear: CADSpurGearSpec) { operation = .spurGear; sheet = nil; self.gear = gear; members = [] }
    var outputCount: Int {
        switch operation { case .singleBendSheet: return 2; case .straightWeldment: return members.count; case .spurGear: return 1 }
    }

    static func validatePlacement(_ p: Transform3D) throws {
        let q = p.rotation.vector
        guard [p.translation.x,p.translation.y,p.translation.z,q.x,q.y,q.z,q.w].allSatisfy(\.isFinite),
              abs(p.scale - 1) < 1e-12, abs(simd_length(q) - 1) < 1e-8 else {
            throw CADMechanicalFailure.invalid("Manufacturing dimensions require a finite rigid placement without scale.")
        }
    }
    func validate() throws {
        guard version == Self.supportedVersion else { throw CADMechanicalFailure.invalid("Unsupported mechanical definition version.") }
        guard expressions.allSatisfy({ $0.expr.value.isFinite }) else { throw CADMechanicalFailure.invalid("Use finite manufacturing dimensions.") }
        func dimension(_ x: Double) -> Bool { x >= 0.1 && x <= 10_000 }
        switch operation {
        case .singleBendSheet:
            guard let s = sheet, gear == nil, members.isEmpty,
                  [s.flangeA.value,s.flangeB.value,s.width.value,s.thickness.value,s.innerRadius.value].allSatisfy(dimension),
                  (5...150).contains(s.bendDegrees.value), (0...0.5).contains(s.kFactor.value),
                  s.blankLength <= 20_000 else {
                throw CADMechanicalFailure.invalid("Use one straight 5–150° bend, positive tangent flange lengths/radius/thickness, and K from 0 to 0.5.")
            }
        case .spurGear:
            guard sheet == nil, members.isEmpty, let gear else { throw CADMechanicalFailure.invalid("A gear feature must own exactly its spur definition.") }
            try gear.validate()
        case .straightWeldment:
            guard sheet == nil, gear == nil, (1...64).contains(members.count), Set(members.map(\.id)).count == members.count,
                  Set(members.flatMap { [$0.id,$0.innerBoundaryID] }).count == members.count * 2 else {
                throw CADMechanicalFailure.invalid("Use 1–64 individually identified straight members.")
            }
            for m in members {
                try Self.validatePlacement(m.placement)
                guard [m.width.value,m.depth.value,m.wall.value,m.length.value].allSatisfy(dimension),
                      !m.material.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, m.material.count <= 80 else {
                    throw CADMechanicalFailure.invalid("Use positive stock dimensions/length and a material name.")
                }
                if m.profile == .rectangularTube {
                    guard m.wall.value * 2 < min(m.width.value,m.depth.value) - 1e-6 else {
                        throw CADMechanicalFailure.invalid("Tube walls must leave a positive inner section.")
                    }
                }
                if m.profile == .roundTube, m.wall.value * 2 >= m.width.value - 1e-6 {
                    throw CADMechanicalFailure.invalid("Tube walls must leave a positive bore.")
                }
            }
        }
    }
    // Shared with DocumentSession's existing variable fan-out and rename walker.
    var expressions: [DocumentSession.FeatureExpressionSlot] {
        if let gear { return gear.expressions }
        func slot(_ name: String, _ e: Expr, _ unit: String = "mm") -> DocumentSession.FeatureExpressionSlot {
            DocumentSession.FeatureExpressionSlot(name:name,unit:unit,storedUnit:unit,expr:e)
        }
        if let s = sheet {
            return [slot("flange_a",s.flangeA),slot("flange_b",s.flangeB),slot("width",s.width),
                    slot("thickness",s.thickness),slot("inner_radius",s.innerRadius),
                    slot("bend_degrees",s.bendDegrees,"deg"),slot("k_factor",s.kFactor,"unitless")]
        }
        return members.flatMap { m in
            let p = "member." + m.id.uuidString + "."
            return [slot(p + "width",m.width),slot(p + "depth",m.depth),slot(p + "wall",m.wall),slot(p + "length",m.length)]
        }
    }
    func replacing(_ name: String, with e: Expr) -> CADMechanicalDefinition? {
        var result = self
        if let gear {
            guard let changed = gear.replacing(name, with: e) else { return nil }
            result.gear = changed; return result
        }
        if var s = sheet {
            switch name {
            case "flange_a": s.flangeA = e
            case "flange_b": s.flangeB = e
            case "width": s.width = e
            case "thickness": s.thickness = e
            case "inner_radius": s.innerRadius = e
            case "bend_degrees": s.bendDegrees = e
            case "k_factor": s.kFactor = e
            default: return nil
            }
            result.sheet = s
        } else {
            guard let index = members.firstIndex(where: { name.hasPrefix("member." + $0.id.uuidString + ".") }) else { return nil }
            switch name.components(separatedBy:".").last {
            case "width": result.members[index].width = e
            case "depth": result.members[index].depth = e
            case "wall": result.members[index].wall = e
            case "length": result.members[index].length = e
            default: return nil
            }
        }
        return result
    }
    func resolved(variables: [String:Double]) throws -> CADMechanicalDefinition {
        var result = self
        for slot in expressions {
            guard let formula = slot.expr.formula else { continue }
            guard let value = ExpressionEvaluator.evaluate(formula,variables:variables), value.isFinite else {
                throw CADMechanicalFailure.invalid("A manufacturing expression cannot be resolved.")
            }
            result = result.replacing(slot.name,with:Expr(value:value,formula:formula)) ?? result
        }
        try result.validate(); return result
    }
}

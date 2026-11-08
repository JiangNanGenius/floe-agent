// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct EDAGraphicLayerFailure: Error, LocalizedError, Codable, Hashable, Sendable {
    public let code: String
    public let index: Int
    public let layerID: String?
    public var errorDescription: String? { code + " at graphics[\(index)]" }
}
public struct EDAResolvedGraphicLayer: Codable, Hashable, Sendable {
    public let index: Int
    public let declared: EDAGraphicLayerAssignment
    public let layerID: String
    /// This is a Cu/profile subset, not a request for other layer artwork.
    public var excludedFromCopperProfile: Bool {
        [.silkscreen, .fabrication, .courtyard, .mask, .paste].contains(declared.kind)
    }
}

/// One layer resolver shared by DRC, refill, plotting and the native Inspector.
/// Known layer roles are explicit design metadata, never inferred from shape.
public enum EDAGraphicLayers {
    public static var standardAssignments: [EDAGraphicLayerAssignment] {
        var result: [EDAGraphicLayerAssignment] = []
        for side in ["F", "B"] {
            result.append(.init(layerID: side + ".Cu", kind: .copper))
            result.append(.init(layerID: side + ".SilkS", kind: .silkscreen))
            result.append(.init(layerID: side + ".Fab", kind: .fabrication))
            result.append(.init(layerID: side + ".Courtyard", kind: .courtyard))
            result.append(.init(layerID: side + ".Mask", kind: .mask))
            result.append(.init(layerID: side + ".Paste", kind: .paste))
        }
        return result
    }
    public static func validateLayout(graphics: [EDAGraphic], layers: [EDAGraphicLayerAssignment?]?) throws {
        guard let layers else { return }
        guard layers.count == graphics.count else { throw EDAError.invalid("graphic layer count") }
        for assignment in layers.compactMap({ $0 }) {
            guard !assignment.layerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  assignment.layerID.utf8.count <= 256,
                  !assignment.layerID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw EDAError.invalid("graphic layer identifier")
            }
        }
    }
    public static func resolve(_ assignment: EDAGraphicLayerAssignment?, index: Int,
                               board: EDABoard, footprintSide: String? = nil) throws -> EDAResolvedGraphicLayer {
        func failure(_ code: String) -> EDAGraphicLayerFailure { .init(code: code, index: index, layerID: assignment?.layerID) }
        guard let assignment else { throw failure("graphic_layer_unspecified") }
        if let footprintSide, footprintSide != "F.Cu" && footprintSide != "B.Cu" { throw failure("footprint_side_unsupported") }
        guard assignment.layerID != "Edge.Cuts" && assignment.layerID != "EdgeCuts" else { throw failure("graphic_profile_geometry_unsupported") }
        let known = standardAssignments + [
            .init(layerID: "F.CrtYd", kind: .courtyard), .init(layerID: "B.CrtYd", kind: .courtyard)
        ]
        if let role = known.first(where: { $0.layerID == assignment.layerID }), role.kind != assignment.kind {
            throw failure("graphic_layer_kind_conflict")
        }
        var actual = assignment.layerID
        if footprintSide == "B.Cu" {
            if actual.hasPrefix("F.") { actual = "B." + String(actual.dropFirst(2)) }
            else if actual.hasPrefix("B.") { actual = "F." + String(actual.dropFirst(2)) }
        }
        if let layer = board.layers.first(where: { $0.id == actual }) {
            guard layer.kind == assignment.kind else { throw failure("graphic_layer_kind_conflict") }
        } else {
            // Standard nonphysical Fab/courtyard layers need not be physical
            // stackup records. Actual copper always requires a real Cu layer.
            guard let role = known.first(where: { $0.layerID == actual }), role.kind == assignment.kind,
                  [.silkscreen, .fabrication, .courtyard, .mask, .paste].contains(role.kind) else {
                throw failure("graphic_layer_unsupported")
            }
        }
        guard assignment.kind != .dielectric else { throw failure("graphic_layer_kind_unsupported") }
        return .init(index: index, declared: assignment, layerID: actual)
    }
    public static func requireCopperProfileExclusion(_ resolved: EDAResolvedGraphicLayer) throws {
        guard resolved.excludedFromCopperProfile else {
            throw EDAGraphicLayerFailure(code: resolved.declared.kind == .copper ? "copper_graphic_unsupported" : "graphic_layer_kind_unsupported",
                                         index: resolved.index, layerID: resolved.layerID)
        }
    }
    public static func position(_ graphic: EDAGraphic) -> EDAPoint {
        switch graphic {
        case .line(let a, _, _), .rectangle(let a, _, _), .dimension(let a, _, _): return a
        case .circle(let p, _, _), .arc(let p, _, _, _, _), .text(_, let p, _, _): return p
        }
    }
}

/// Pure value edits used by Inspector, canvas and typed callers. One existing
/// document transaction persists both arrays; these helpers own no undo/store.
public enum EDAGraphicEditing {
    public static func assign(_ layer: EDAGraphicLayerAssignment?, at index: Int,
                              graphics: [EDAGraphic], layers: inout [EDAGraphicLayerAssignment?]?) throws {
        try EDAGraphicLayers.validateLayout(graphics: graphics, layers: layers)
        guard graphics.indices.contains(index) else { throw EDAError.invalid("graphic index") }
        if layers == nil && layer == nil { return }
        var next = layers ?? Array(repeating: nil, count: graphics.count)
        next[index] = layer
        try EDAGraphicLayers.validateLayout(graphics: graphics, layers: next)
        layers = next
    }
    public static func append(_ graphic: EDAGraphic, layer: EDAGraphicLayerAssignment? = nil,
                              graphics: inout [EDAGraphic], layers: inout [EDAGraphicLayerAssignment?]?) throws {
        try EDAGraphicLayers.validateLayout(graphics: graphics, layers: layers)
        var next = layers
        if next == nil && layer != nil { next = Array(repeating: nil, count: graphics.count) }
        next?.append(layer)
        var values = graphics; values.append(graphic)
        try EDAGraphicLayers.validateLayout(graphics: values, layers: next)
        graphics = values; layers = next
    }
    public static func remove(at index: Int, graphics: inout [EDAGraphic], layers: inout [EDAGraphicLayerAssignment?]?) throws {
        try EDAGraphicLayers.validateLayout(graphics: graphics, layers: layers)
        guard graphics.indices.contains(index) else { throw EDAError.invalid("graphic index") }
        graphics.remove(at: index); layers?.remove(at: index)
    }
    public static func duplicate(at index: Int, graphics: inout [EDAGraphic], layers: inout [EDAGraphicLayerAssignment?]?) throws {
        try EDAGraphicLayers.validateLayout(graphics: graphics, layers: layers)
        guard graphics.indices.contains(index) else { throw EDAError.invalid("graphic index") }
        let graphic = graphics[index], layer = layers?[index]
        graphics.insert(graphic, at: index + 1)
        if layers != nil { layers!.insert(layer ?? nil, at: index + 1) }
    }
    public static func move(from: Int, to: Int, graphics: inout [EDAGraphic], layers: inout [EDAGraphicLayerAssignment?]?) throws {
        try EDAGraphicLayers.validateLayout(graphics: graphics, layers: layers)
        guard graphics.indices.contains(from), graphics.indices.contains(to) else { throw EDAError.invalid("graphic index") }
        let graphic = graphics.remove(at: from); graphics.insert(graphic, at: to)
        if layers != nil { let layer = layers!.remove(at: from); layers!.insert(layer, at: to) }
    }
    public static func replace(at index: Int, with graphic: EDAGraphic,
                               graphics: inout [EDAGraphic], layers: [EDAGraphicLayerAssignment?]?) throws {
        try EDAGraphicLayers.validateLayout(graphics: graphics, layers: layers)
        guard graphics.indices.contains(index) else { throw EDAError.invalid("graphic index") }
        graphics[index] = graphic
    }
}

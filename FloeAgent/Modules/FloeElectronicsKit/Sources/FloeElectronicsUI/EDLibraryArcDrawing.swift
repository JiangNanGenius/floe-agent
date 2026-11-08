// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeElectronicsCore

/// A center, start and endpoint-direction gesture. The endpoint is projected
/// onto the radius chosen by the start; its distance never changes that radius.
/// Drafts are display-only. A finished gesture proposes one normal session edit.
struct EDLibraryArcDraft: Sendable {
    let source: EDAProject
    let context: EDADocumentContext
    private(set) var points: [EDAPoint] = []
    private(set) var isCancelled = false
    var canFinish: Bool { !isCancelled && points.count == 3 }

    init(project: EDAProject, context: EDADocumentContext) throws {
        switch context {
        case .symbol(let id): guard project.symbols.contains(where: { $0.id == id }) else { throw EDAError.missing("symbol definition") }
        case .footprint(let id): guard project.footprints.contains(where: { $0.id == id }) else { throw EDAError.missing("footprint definition") }
        default: throw EDAError.invalid("draw library arcs in a symbol or footprint definition")
        }
        source = project; self.context = context
    }
    mutating func append(_ point: EDAPoint) throws {
        guard !isCancelled else { throw EDAError.cancelled }
        guard point.isValid, points.count < 3 else { throw EDAError.invalid("arc gesture point") }
        if points.count == 1 {
            let radius = points[0].distance(to: point)
            guard radius > EDAGeometry.tolerance, radius <= 100_000 else { throw EDAError.invalid("arc radius") }
        }
        if points.count == 2 {
            _ = try Self.shape(center: points[0], start: points[1], endDirection: point, clockwise: false, width: 0.2)
        }
        points.append(point)
    }
    mutating func undoLastPoint() { if !isCancelled && !points.isEmpty { points.removeLast() } }
    mutating func cancel() { points.removeAll(); isCancelled = true }
    func preview(toward pointer: EDAPoint?, clockwise: Bool, width: Double) -> EDAGraphic? {
        guard !isCancelled, points.count >= 2, let end = points.count == 3 ? points.last : pointer else { return nil }
        return try? Self.shape(center: points[0], start: points[1], endDirection: end, clockwise: clockwise, width: width)
    }
    func plan(clockwise: Bool, width: Double, layer: EDAGraphicLayerAssignment?) throws -> EDLibraryArcPlan {
        guard !isCancelled else { throw EDAError.cancelled }
        guard canFinish else { throw EDAError.invalid("choose the arc center, start and endpoint") }
        let graphic = try Self.shape(center: points[0], start: points[1], endDirection: points[2], clockwise: clockwise, width: width)
        let edit: EDAEdit
        let index: Int
        switch context {
        case .symbol(let id):
            guard layer == nil, var value = source.symbols.first(where: { $0.id == id }) else { throw EDAError.invalid("symbol arc definition") }
            index = value.graphics.count; value.graphics.append(graphic); edit = .putSymbol(value)
        case .footprint(let id):
            guard let layer, var value = source.footprints.first(where: { $0.id == id }) else { throw EDAError.missing("explicit arc layer") }
            index = value.graphics.count
            try EDAGraphicEditing.append(graphic, layer: layer, graphics: &value.graphics, layers: &value.graphicLayers)
            edit = .putFootprintDefinition(value)
        default: throw EDAError.invalid("arc context")
        }
        // The normal session validates the complete proposed model before CAS.
        // A draft itself never creates an undo entry or changes a project.
        return .init(source: source, context: context, graphicIndex: index, graphic: graphic, edits: [edit])
    }
    private static func shape(center: EDAPoint, start: EDAPoint, endDirection: EDAPoint,
                              clockwise: Bool, width: Double) throws -> EDAGraphic {
        guard center.isValid, start.isValid, endDirection.isValid, width.isFinite, width > 0, width <= 100_000 else {
            throw EDAError.invalid("finite arc geometry and positive width required")
        }
        let a = start - center, b = endDirection - center, radius = a.length
        guard radius > EDAGeometry.tolerance, radius <= 100_000, b.length > EDAGeometry.tolerance else { throw EDAError.invalid("arc radius or endpoint") }
        let startAngle = atan2(a.y, a.x) * 180 / .pi, endAngle = atan2(b.y, b.x) * 180 / .pi
        var ccw = (endAngle - startAngle).truncatingRemainder(dividingBy: 360)
        if ccw < 0 { ccw += 360 }
        guard ccw > 1e-9 && ccw < 360 - 1e-9 else { throw EDAError.invalid("arc endpoints coincide; use the circle tool for a full circle") }
        return .arc(center: center, radius: radius, start: startAngle, sweep: clockwise ? ccw - 360 : ccw, width: width)
    }
}

struct EDLibraryArcPlan: Sendable {
    let source: EDAProject
    let context: EDADocumentContext
    let graphicIndex: Int
    let graphic: EDAGraphic
    let edits: [EDAEdit]
    func validateSource(_ current: EDAProject) throws {
        guard current.id == source.id else { throw EDAError.invalid("arc original identity changed") }
        guard current.revision == source.revision else { throw EDAError.staleRevision(expected: source.revision, actual: current.revision) }
        guard current == source else { throw EDAError.invalid("arc source changed") }
    }
    @MainActor func apply(to session: EDWorkbenchSession) async throws {
        try Task.checkCancellation(); try validateSource(session.project)
        try await session.apply(edits, expectedRevision: source.revision, cancelBeforeCommit: true)
    }
}

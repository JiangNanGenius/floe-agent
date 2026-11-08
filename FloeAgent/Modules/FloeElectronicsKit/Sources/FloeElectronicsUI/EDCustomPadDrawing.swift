// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeElectronicsCore

/// Redraw one existing pad in the same footprint canvas. Pad identity, number,
/// origin, rotation and explicit layers survive; no anchor or new net is guessed.
struct EDCustomPadDrawingDraft: Sendable {
    let source: EDAProject
    let definitionID: UUID
    let pad: EDAPad
    private(set) var points: [EDAPoint] = [] // footprint-definition coordinates
    private(set) var isCancelled = false
    var canFinish: Bool { !isCancelled && points.count >= 3 }
    init(project: EDAProject, definitionID: UUID, padID: UUID) throws {
        guard let value = project.footprints.first(where: { $0.id == definitionID })?.pads.first(where: { $0.id == padID }) else {
            throw EDAError.missing("selected footprint pad")
        }
        try EDAPolygonPadGeometry.validateSingleSurface(value)
        source = project; self.definitionID = definitionID; pad = value
    }
    mutating func append(_ point: EDAPoint) throws {
        guard !isCancelled else { throw EDAError.cancelled }
        guard point.isValid else { throw EDAError.invalid("polygon pad drawing point") }
        if let previous = points.last, previous.distance(to: point) <= EDAGeometry.tolerance { return }
        guard points.count < EDAPolygonPadGeometry.maximumVertices else { throw EDAError.invalid("polygon pad vertex budget") }
        let local = (point - pad.position).transformed(origin: .zero, angle: -pad.angle)
        guard local.isValid else { throw EDAError.invalid("polygon pad local point") }
        points.append(point)
    }
    mutating func undoLastPoint() { if !isCancelled && !points.isEmpty { points.removeLast() } }
    mutating func cancel() { points.removeAll(); isCancelled = true }
    func plan() throws -> EDCustomPadDrawingPlan {
        guard !isCancelled else { throw EDAError.cancelled }
        guard canFinish else { throw EDAError.invalid("polygon pad needs at least three points") }
        let local = points.map { ($0 - pad.position).transformed(origin: .zero, angle: -pad.angle) }
        let updated = try EDAPolygonPadGeometry.replacingOutline(of: pad, with: local)
        guard var definition = source.footprints.first(where: { $0.id == definitionID }),
              let index = definition.pads.firstIndex(where: { $0.id == pad.id }) else { throw EDAError.missing("selected pad") }
        definition.pads[index] = updated
        return .init(source: source, definitionID: definitionID, pad: updated, edits: [.putFootprintDefinition(definition)])
    }
    static func message(for error: any Error) -> String {
        if case EDAError.invalid(let reason) = error, reason == "polygon pad outline must enclose its center" {
            return edText("轮廓需围住焊盘中心。", "The outline must enclose the pad center.")
        }
        if case EDAError.invalid(let reason) = error, reason == "polygon pad vertex budget" {
            return edText("轮廓最多可有 256 个点。", "The outline can have up to 256 points.")
        }
        if case EDAError.unsupported = error {
            return edText("请选择单面无孔焊盘，开窗也需在同一面。", "Choose a single-sided, undrilled pad with openings on the same side.")
        }
        if case EDAError.staleRevision = error {
            return edText("原件已改变，请取消后重新绘制。", "The original changed. Cancel and redraw the outline.")
        }
        return edText("请绘制围住焊盘中心、不自交的闭合轮廓。", "Draw a non-self-intersecting closed outline around the pad center.")
    }
}

struct EDCustomPadDrawingPlan: Sendable {
    let source: EDAProject
    let definitionID: UUID
    let pad: EDAPad
    let edits: [EDAEdit]
    var selection: EDASelection { .init(context: .footprint(definitionID: definitionID), objectIDs: [pad.id]) }
    func validateSource(_ current: EDAProject) throws {
        guard current.id == source.id else { throw EDAError.invalid("polygon pad original identity changed") }
        guard current.revision == source.revision else { throw EDAError.staleRevision(expected: source.revision, actual: current.revision) }
        guard current == source else { throw EDAError.invalid("polygon pad source changed") }
    }
    @MainActor func apply(to session: EDWorkbenchSession) async throws {
        try Task.checkCancellation(); try validateSource(session.project)
        try await session.apply(edits, expectedRevision: source.revision, cancelBeforeCommit: true)
    }
}

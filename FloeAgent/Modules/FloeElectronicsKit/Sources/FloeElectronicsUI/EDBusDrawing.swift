// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeElectronicsCore

/// A schematic bus is an open polyline, not a scalar electrical connection.
/// Points supplied by the canvas already follow its ordinary grid setting.
/// Until Finish, this draft owns no store writes, undo entries, wires or labels.
struct EDBusDrawingDraft: Sendable {
    static let maximumPoints = 10_000
    let source: EDAProject
    let sheetID: UUID
    let busID: UUID
    private(set) var points: [EDAPoint] = []
    private(set) var isCancelled = false

    init(project: EDAProject, sheetID: UUID) throws {
        guard project.sheets.contains(where: { $0.id == sheetID }) else {
            throw EDAError.missing("schematic sheet")
        }
        source = project; self.sheetID = sheetID; busID = UUID()
    }

    mutating func append(_ point: EDAPoint) throws {
        guard !isCancelled else { throw EDAError.cancelled }
        guard point.isValid else { throw EDAError.invalid("bus point") }
        // Repeated taps on the same snapped point never create zero segments.
        if let last = points.last, last.distance(to: point) <= EDAGeometry.tolerance { return }
        guard points.count < Self.maximumPoints else { throw EDAError.invalid("bus point limit") }
        points.append(point)
    }

    mutating func undoLastPoint() {
        if !points.isEmpty { points.removeLast() }
    }

    mutating func cancel() {
        points = []; isCancelled = true
    }

    var canFinish: Bool { !isCancelled && points.count >= 2 }

    func plan() throws -> Plan {
        guard !isCancelled else { throw EDAError.cancelled }
        guard canFinish else { throw EDAError.invalid("bus needs two distinct points") }
        // Neither the bus name nor its spatial order invents member identities.
        // The existing Inspector declares literal members after this save.
        let bus = EDABus(id: busID, name: "BUS", members: [], points: points)
        return Plan(source: source, sheetID: sheetID, bus: bus)
    }

    struct Plan: Sendable {
        let source: EDAProject
        let sheetID: UUID
        let bus: EDABus
        var revision: UInt64 { source.revision }
        var edits: [EDAEdit] { [.putBus(sheet: sheetID, bus)] }
        var selection: EDASelection { .init(context: .schematic(sheetID: sheetID), objectIDs: [bus.id]) }

        func validateSource(_ project: EDAProject) throws {
            guard project.revision == revision else {
                throw EDAError.staleRevision(expected: revision, actual: project.revision)
            }
            guard project == source else { throw EDAError.invalid("bus drawing source changed") }
        }

        @MainActor func apply(to session: EDWorkbenchSession) async throws {
            try Task.checkCancellation()
            try validateSource(session.project)
            try await session.apply(edits, expectedRevision: revision, cancelBeforeCommit: true)
        }
    }
}

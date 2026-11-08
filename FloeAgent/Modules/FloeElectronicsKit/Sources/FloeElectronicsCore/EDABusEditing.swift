// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum EDABusEditing {
    public static let maximumEntries = 20_000
    /// A full bus move/rotation carries its graphical entries. It never edits
    /// their wires/labels. A detached drawing is reported by ERC, not rewired.
    public static func transformed(_ bus: EDABus, point: (EDAPoint) -> EDAPoint) -> EDABus {
        var value = bus; value.points = value.points.map(point)
        value.entries = value.entries?.map { transformed($0, point: point) }
        return value
    }
    public static func transformed(_ entry: EDABusEntry, point: (EDAPoint) -> EDAPoint) -> EDABusEntry {
        var value = entry; value.busPosition = point(value.busPosition); value.wirePosition = point(value.wirePosition); return value
    }
    public static func duplicate(_ bus: EDABus) -> EDABus {
        var value = bus; value.id = UUID(); value.entries = value.entries?.map(duplicate); return value
    }
    public static func duplicate(_ entry: EDABusEntry) -> EDABusEntry {
        var value = entry; value.id = UUID(); return value
    }
    static func objectIDs(_ project: EDAProject, includeEntries: Bool = true) -> Set<UUID> {
        var ids: Set<UUID> = [project.id]
        ids.formUnion(project.symbols.map(\.id)); ids.formUnion(project.symbols.flatMap { $0.pins.map(\.id) })
        ids.formUnion(project.footprints.map(\.id)); ids.formUnion(project.footprints.flatMap { $0.pads.map(\.id) })
        ids.formUnion(project.components.map(\.id)); ids.formUnion(project.simulations.map(\.id))
        for sheet in project.sheets {
            ids.insert(sheet.id); ids.formUnion(sheet.symbols.map(\.id)); ids.formUnion(sheet.wires.map(\.id))
            ids.formUnion(sheet.labels.map(\.id)); ids.formUnion(sheet.junctions.map(\.id)); ids.formUnion(sheet.noConnects.map(\.id))
            ids.formUnion(sheet.buses.map(\.id)); ids.formUnion(sheet.children.map(\.id)); ids.formUnion(sheet.children.flatMap { $0.ports.map(\.id) })
            if includeEntries { ids.formUnion(sheet.buses.flatMap { ($0.entries ?? []).map(\.id) }) }
        }
        for board in project.boards {
            ids.insert(board.id); ids.formUnion(board.footprints.map(\.id)); ids.formUnion(board.tracks.map(\.id))
            ids.formUnion(board.vias.map(\.id)); ids.formUnion(board.zones.map(\.id)); ids.formUnion(board.keepouts.map(\.id))
            ids.formUnion(board.holes.map(\.id)); ids.formUnion(board.netClasses.map(\.id))
        }
        return ids
    }
}

/// One ordinary edit proposal from an explicitly chosen literal member.
/// No bus-name parsing, alias expansion, automatic board rewrite or store.
public enum EDABusUnfold {
    public struct Plan: Sendable {
        public let projectID: UUID
        public let revision: UInt64
        public let edits: [EDAEdit]
        private let source: EDAProject
        fileprivate init(source: EDAProject, edits: [EDAEdit]) {
            self.source = source; projectID = source.id; revision = source.revision; self.edits = edits
        }
        public func validateSource(_ project: EDAProject) throws {
            guard project.revision == revision else { throw EDAError.staleRevision(expected: revision, actual: project.revision) }
            guard project == source else { throw EDAError.invalid("bus unfold source changed") }
        }
    }
    public static func newWire(project: EDAProject, sheetID: UUID, busID: UUID, member: String,
                               scope: EDALabelScope = .local, busPosition: EDAPoint, wirePoints: [EDAPoint],
                               cancelled: @Sendable () -> Bool = { false }) throws -> Plan {
        guard wirePoints.count >= 2, wirePoints.count <= 10_000, wirePoints.allSatisfy(\.isValid),
              let start = wirePoints.first,
              zip(wirePoints,wirePoints.dropFirst()).contains(where: { $0.0.distance(to:$0.1) > EDAGeometry.tolerance }) else { throw EDAError.invalid("bus member wire") }
        let wire = EDAWire(points: wirePoints)
        return try plan(project: project, sheetID: sheetID, busID: busID, member: member, scope: scope,
                        busPosition: busPosition, wirePosition: start, wireEdit: .putWire(sheet: sheetID, wire), cancelled: cancelled)
    }
    public static func existingWire(project: EDAProject, sheetID: UUID, busID: UUID, member: String,
                                    scope: EDALabelScope = .local, busPosition: EDAPoint,
                                    wireID: UUID, wirePosition: EDAPoint,
                                    cancelled: @Sendable () -> Bool = { false }) throws -> Plan {
        guard let wire = project.sheets.first(where: { $0.id == sheetID })?.wires.first(where: { $0.id == wireID }),
              zip(wire.points, wire.points.dropFirst()).contains(where: { EDAGeometry.onSegment(wirePosition, $0.0, $0.1) }) else {
            throw EDAError.missing("explicit bus member wire position")
        }
        return try plan(project: project, sheetID: sheetID, busID: busID, member: member, scope: scope,
                        busPosition: busPosition, wirePosition: wirePosition, wireEdit: nil, cancelled: cancelled)
    }
    private static func plan(project: EDAProject, sheetID: UUID, busID: UUID, member: String,
                             scope: EDALabelScope, busPosition: EDAPoint, wirePosition: EDAPoint, wireEdit: EDAEdit?,
                             cancelled: @Sendable () -> Bool) throws -> Plan {
        if cancelled() { throw EDAError.cancelled }
        try EDAValidation.validate(project)
        guard var bus = project.sheets.first(where: { $0.id == sheetID })?.buses.first(where: { $0.id == busID }) else { throw EDAError.missing("bus") }
        guard !member.isEmpty, member.utf8.count <= 4_096,
              bus.members.filter({ $0 == member }).count == 1 else { throw EDAError.invalid("choose one explicitly declared literal bus member") }
        guard busPosition.isValid, wirePosition.isValid,
              busPosition.distance(to: wirePosition) > EDAGeometry.tolerance,
              zip(bus.points, bus.points.dropFirst()).contains(where: { EDAGeometry.onSegment(busPosition, $0.0, $0.1) }) else {
            throw EDAError.invalid("bus entry endpoints")
        }
        var contact = try EDABusContactLookup(netlist: EDAConnectivity.derive(project, cancelled: cancelled), cancelled: cancelled)
        guard try contact.contact(wirePosition, sheet: project.sheets.first { $0.id == sheetID }!, cancelled: cancelled).netIDs.count <= 1 else {
            throw EDAError.invalid("bus member endpoint touches several scalar nets; add an explicit junction or choose one wire endpoint")
        }
        let entry = EDABusEntry(busPosition: busPosition, wirePosition: wirePosition)
        var entries = bus.entries ?? []; entries.append(entry); bus.entries = entries
        let label = EDANetLabel(name: member, position: wirePosition, scope: scope)
        var edits = wireEdit.map { [$0] } ?? []
        edits += [.putLabel(sheet: sheetID, label), .putBus(sheet: sheetID, bus)]
        // Validate the same complete transaction the caller will commit once.
        var preview = try EDAEditingSession(project: project)
        try preview.apply(edits, expectedRevision: project.revision, cancelled: cancelled)
        return .init(source: project, edits: edits)
    }
}

public extension EDAEditingSession {
    mutating func applyBusUnfold(_ plan: EDABusUnfold.Plan,
                                cancelled: @Sendable () -> Bool = { false }) throws {
        try plan.validateSource(project)
        try apply(plan.edits, expectedRevision: plan.revision, cancelled: cancelled)
    }
}

// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct EDAForwardAnnotationPlan: Sendable {
    public let projectID: UUID
    public let revision: UInt64
    public let boardID: UUID
    public let updatedBoard: EDABoard
    public let addedComponentIDs: [UUID]
    public let orphanedFootprintIDs: [UUID]
    public let missingFootprintComponentIDs: [UUID]
    public let conflictingNetIDs: [String]
    public let lockedFootprintIDs: [UUID]
    public var canApply: Bool { missingFootprintComponentIDs.isEmpty && conflictingNetIDs.isEmpty && lockedFootprintIDs.isEmpty }
}

public enum EDAForwardAnnotation {
    /// Preview a schematic-to-board update without touching either original.
    /// Routed nets that split or lose their pin mapping require a decision;
    /// they are never silently renamed, shorted or discarded.
    public static func plan(_ project: EDAProject, boardID: UUID,
                            cancelled: @Sendable () -> Bool = { false }) throws -> EDAForwardAnnotationPlan {
        let netlist = try EDAConnectivity.derive(project, cancelled: cancelled)
        guard var board = project.boards.first(where: { $0.id == boardID }) else { throw EDAError.missing("board") }
        let definitions = Dictionary(uniqueKeysWithValues: project.footprints.map { ($0.id, $0) })
        let components = Dictionary(uniqueKeysWithValues: project.components.map { ($0.id, $0) })
        let netForPin = Dictionary(uniqueKeysWithValues: netlist.nets.flatMap { net in net.pins.map { ($0, net.id) } })
        let linked = board.footprints.compactMap(\.componentID)
        guard Set(linked).count == linked.count else { throw EDAError.invalid("duplicate board component") }
        var added: [UUID] = [], missing: [UUID] = [], locked: [UUID] = []
        var mapping: [String: Set<String>] = [:], unmapped: Set<String> = []
        let orphaned = board.footprints.filter { $0.componentID.map { components[$0] == nil } ?? false }.map(\.id)
        for footprint in board.footprints where orphaned.contains(footprint.id) {
            unmapped.formUnion(footprint.padNets.values)
        }
        for component in project.components {
            if cancelled() { throw EDAError.cancelled }
            guard let definitionID = component.footprintID, let definition = definitions[definitionID] else {
                missing.append(component.id); continue
            }
            let index = board.footprints.firstIndex { $0.componentID == component.id }
            let previous = index.map { board.footprints[$0] }
            var footprint = previous ?? EDAFootprint(definitionID: definitionID, componentID: component.id)
            footprint.definitionID = definitionID; footprint.reference = component.reference; footprint.value = component.value
            footprint.padNets = Dictionary(uniqueKeysWithValues: Set(definition.pads.map(\.number)).compactMap { number in
                netForPin[EDAPinReference(componentID: component.id, number: number)].map { (number, $0) }
            })
            if let previous {
                for (number, oldNet) in previous.padNets where !oldNet.isEmpty {
                    if let next = footprint.padNets[number] { mapping[oldNet, default: []].insert(next) }
                    else { unmapped.insert(oldNet) }
                }
                if previous.locked && previous != footprint { locked.append(previous.id) }
            } else {
                // Initial placements use the board bounds as a staging grid;
                // arranging and collision clearance are explicit editor tasks.
                let bounds = EDAGeometry.bounds(board.outline)!
                let width = max(1, bounds.max.x - bounds.min.x), height = max(1, bounds.max.y - bounds.min.y)
                let n = added.count
                footprint.position = bounds.min + EDAPoint(min(width / 2, 5) + Double(n % 8) * min(10, width / 10),
                                                          min(height / 2, 5) + Double(n / 8) * min(10, height / 10))
                added.append(component.id)
            }
            if let index { board.footprints[index] = footprint } else { board.footprints.append(footprint) }
        }
        let routed = Set(board.tracks.map(\.netID) + board.vias.map(\.netID) + board.zones.map(\.netID)).subtracting([""])
        let currentNets = Set(netlist.nets.map(\.id))
        let conflicts = routed.filter { net in
            if unmapped.contains(net) { return true }
            if let candidates = mapping[net] { return candidates.count != 1 }
            return !currentNets.contains(net)
        }
        func updated(_ old: String) -> String {
            guard !conflicts.contains(old), let candidates = mapping[old], candidates.count == 1 else { return old }
            return candidates.first!
        }
        for i in board.tracks.indices { board.tracks[i].netID = updated(board.tracks[i].netID) }
        for i in board.vias.indices { board.vias[i].netID = updated(board.vias[i].netID) }
        for i in board.zones.indices {
            board.zones[i].netID = updated(board.zones[i].netID)
            board.zones[i].filledPolygons = []; board.zones[i].fillRevision = nil; board.zones[i].fillState = nil
        }
        return .init(projectID: project.id, revision: project.revision, boardID: boardID, updatedBoard: board,
                     addedComponentIDs: added, orphanedFootprintIDs: orphaned,
                     missingFootprintComponentIDs: missing, conflictingNetIDs: conflicts.sorted(),
                     lockedFootprintIDs: locked)
    }

    public static func apply(_ plan: EDAForwardAnnotationPlan, to editor: inout EDAEditingSession) throws {
        guard plan.projectID == editor.project.id, plan.revision == editor.project.revision else {
            throw EDAError.staleRevision(expected: plan.revision, actual: editor.project.revision)
        }
        guard plan.canApply else { throw EDAError.invalid("unresolved annotation conflicts") }
        try editor.apply([.putBoard(plan.updatedBoard)], expectedRevision: plan.revision)
    }
}

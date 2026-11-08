// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct EDAIssue: Codable, Hashable, Identifiable, Sendable {
    public enum Severity: String, Codable, Sendable { case error, warning, information }
    public let id: String
    public let code: String
    public let severity: Severity
    public let objectIDs: [UUID]
    public let netID: String?
    public let position: EDAPoint?
    public let details: [String: String]
    public init(code: String, severity: Severity, objectIDs: [UUID], netID: String? = nil,
                position: EDAPoint? = nil, details: [String: String] = [:]) {
        self.code = code; self.severity = severity; self.objectIDs = objectIDs
        self.netID = netID; self.position = position; self.details = details
        self.id = code + ":" + objectIDs.map(\.uuidString).sorted().joined(separator: ",") + ":" + (netID ?? "") + ":" + details.keys.sorted().map { $0 + "=" + details[$0]! }.joined(separator: ",")
    }
}

public struct EDAERCReport: Codable, Hashable, Sendable {
    public let projectID: UUID
    public let revision: UInt64
    public let netlist: EDANetlist
    public let issues: [EDAIssue]
}

public enum EDAERC {
    private struct Pin {
        let reference: EDAPinReference
        let type: EDAPinType
        let position: EDAPoint
        let sheetID: UUID
        let deliberatelyUnconnected: Bool
    }
    public static func check(_ project: EDAProject, cancelled: @Sendable () -> Bool = { false }) throws -> EDAERCReport {
        let netlist = try EDAConnectivity.derive(project, cancelled: cancelled)
        let symbols = Dictionary(uniqueKeysWithValues: project.symbols.map { ($0.id, $0) })
        let components = Dictionary(uniqueKeysWithValues: project.components.map { ($0.id, $0) })
        let placements = project.sheets.flatMap(\.symbols)
        var issues: [EDAIssue] = [], pins: [EDAPinReference: [Pin]] = [:]
        for group in Dictionary(grouping: project.components.filter { !$0.reference.isEmpty }, by: \.reference).values where group.count > 1 {
            issues.append(.init(code: "duplicate_reference", severity: .error, objectIDs: group.map(\.id), details: ["reference": group[0].reference]))
        }
        for component in project.components {
            if cancelled() { throw EDAError.cancelled }
            if component.reference.isEmpty { issues.append(.init(code: "unannotated_component", severity: .warning, objectIDs: [component.id])) }
            if symbols[component.symbolID] == nil { issues.append(.init(code: "missing_symbol", severity: .error, objectIDs: [component.id, component.symbolID])) }
            if !placements.contains(where: { $0.componentID == component.id }) {
                issues.append(.init(code: "unplaced_component", severity: .warning, objectIDs: [component.id]))
            }
            for unit in Dictionary(grouping: placements.filter { $0.componentID == component.id }, by: \.unit).values where unit.count > 1 {
                issues.append(.init(code: "duplicate_symbol_unit", severity: .error, objectIDs: unit.map(\.id)))
            }
        }
        for sheet in project.sheets {
            for placement in sheet.symbols {
                guard let component = components[placement.componentID], let symbol = symbols[component.symbolID] else { continue }
                for definition in symbol.pins where definition.unit == 0 || definition.unit == placement.unit {
                    let point = definition.position.transformed(origin: placement.position, angle: placement.angle, mirrored: placement.mirrored)
                    let pin = Pin(reference: .init(componentID: component.id, number: definition.number), type: definition.type,
                                  position: point, sheetID: sheet.id,
                                  deliberatelyUnconnected: sheet.noConnects.contains { $0.position.distance(to: point) <= EDAGeometry.tolerance })
                    pins[pin.reference, default: []].append(pin)
                }
            }
        }
        for net in netlist.nets {
            if cancelled() { throw EDAError.cancelled }
            let members = net.pins.compactMap { pins[$0]?.first }
            let connected = net.pins.count > 1 || !net.wireIDs.isEmpty || !net.labels.isEmpty
            for pin in members {
                if pin.deliberatelyUnconnected || pin.type == .noConnect {
                    if connected { issues.append(.init(code: "connected_no_connect", severity: .error, objectIDs: [pin.reference.componentID], netID: net.id, position: pin.position, details: ["pin": pin.reference.number])) }
                } else if !connected && pin.type != .unspecified {
                    issues.append(.init(code: "unconnected_pin", severity: pin.type == .powerInput ? .error : .warning,
                                        objectIDs: [pin.reference.componentID], netID: net.id, position: pin.position, details: ["pin": pin.reference.number]))
                }
            }
            let outputs = members.filter { $0.type == .output }, power = members.filter { $0.type == .powerOutput }
            if outputs.count > 1 || power.count > 1 || (!outputs.isEmpty && !power.isEmpty) {
                issues.append(.init(code: "conflicting_outputs", severity: .error, objectIDs: (outputs + power).map { $0.reference.componentID }, netID: net.id))
            }
            if members.contains(where: { $0.type == .powerInput && !$0.deliberatelyUnconnected }), power.isEmpty {
                issues.append(.init(code: "undriven_power", severity: .error, objectIDs: members.filter { $0.type == .powerInput }.map { $0.reference.componentID }, netID: net.id))
            }
            if members.contains(where: { $0.type == .input && !$0.deliberatelyUnconnected }),
               !members.contains(where: { [.output, .bidirectional, .triState, .powerOutput, .openCollector, .openEmitter, .passive].contains($0.type) }) {
                issues.append(.init(code: "undriven_input", severity: .warning, objectIDs: members.filter { $0.type == .input }.map { $0.reference.componentID }, netID: net.id))
            }
        }
        issues += try EDABusDiagnostics.issues(project, netlist: netlist, cancelled: cancelled)
        return .init(projectID: project.id, revision: project.revision, netlist: netlist, issues: issues.sorted { $0.id < $1.id })
    }
}

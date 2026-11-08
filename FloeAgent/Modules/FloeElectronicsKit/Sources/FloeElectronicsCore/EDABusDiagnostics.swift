// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Exact wire-segment contact with bounded work. Graphical entries never
/// supply graph nodes. Ambiguous contact is reported, never ordered away.
struct EDABusContactLookup {
    struct Contact { let wireIDs: [UUID]; let netIDs: [String] }
    private var wireNets: [UUID: Set<String>] = [:]
    private var steps = 0
    init(netlist: EDANetlist, cancelled: @Sendable () -> Bool) throws {
        for net in netlist.nets { for wire in net.wireIDs {
            if cancelled() { throw EDAError.cancelled }
            try tick(); wireNets[wire, default: []].insert(net.id)
        } }
    }
    mutating func tick() throws {
        steps += 1
        guard steps <= 20_000_000 else { throw EDAError.invalid("bus connectivity work budget") }
    }
    mutating func contact(_ point: EDAPoint, sheet: EDASheet, cancelled: @Sendable () -> Bool = { false }) throws -> Contact {
        var wires: Set<UUID> = [], nets: Set<String> = []
        for wire in sheet.wires {
            for (a,b) in zip(wire.points,wire.points.dropFirst()) {
                if cancelled() { throw EDAError.cancelled }
                try tick()
                if EDAGeometry.onSegment(point,a,b) { wires.insert(wire.id); nets.formUnion(wireNets[wire.id] ?? []); break }
            }
        }
        return .init(wireIDs: wires.sorted { $0.uuidString < $1.uuidString }, netIDs: nets.sorted())
    }
}

enum EDABusDiagnostics {
    static func issues(_ project: EDAProject, netlist: EDANetlist,
                       cancelled: @Sendable () -> Bool) throws -> [EDAIssue] {
        var lookup = try EDABusContactLookup(netlist: netlist, cancelled: cancelled)
        var issues: [EDAIssue] = [], memberCount = 0
        let netNames = Dictionary(grouping: netlist.nets, by: \.id)
        func add(_ code: String, _ severity: EDAIssue.Severity, sheet: EDASheet, bus: EDABus,
                 entry: EDABusEntry? = nil, wires: [UUID] = [], net: String? = nil, members: [String] = [], at position: EDAPoint? = nil) throws {
            guard issues.count < 20_000 else { throw EDAError.invalid("bus diagnostic issue budget") }
            var details = ["sheetID":sheet.id.uuidString,"busID":bus.id.uuidString,
                           "path":"sheets/\(sheet.id)/buses/\(bus.id)","memberPolicy":"explicit literal wire labels; entry is graphical only"]
            if !members.isEmpty {
                var shown: [String] = [], bytes = 0
                for member in members.prefix(16) {
                    guard bytes + member.utf8.count <= 8_192 else { break }
                    shown.append(member); bytes += member.utf8.count
                }
                details["members"] = shown.joined(separator: ", "); details["memberCount"] = String(members.count)
                details["membersTruncated"] = String(shown.count != members.count)
            }
            if wires.count > 32 { details["wireCount"] = String(wires.count); details["wireObjectsTruncated"] = "true" }
            if let entry { details["entryID"] = entry.id.uuidString; details["path"]! += "/entries/\(entry.id)" }
            issues.append(.init(code:code,severity:severity,
                objectIDs:[sheet.id,bus.id] + (entry.map { [$0.id] } ?? []) + Array(wires.prefix(32)),
                netID:net,position:position ?? entry?.wirePosition ?? bus.points.first,details:details))
        }
        for sheet in project.sheets { for bus in sheet.buses {
            if cancelled() { throw EDAError.cancelled }
            try lookup.tick(); memberCount += bus.members.count
            guard bus.members.count <= 10_000, memberCount <= 200_000 else { throw EDAError.invalid("bus member budget") }
            let members = Set(bus.members)
            if members.isEmpty { try add("bus_members_missing",.warning,sheet:sheet,bus:bus) }
            if members.count != bus.members.count || members.contains(where: { $0.isEmpty || $0.utf8.count > 4_096 }) {
                try add("bus_members_invalid",.error,sheet:sheet,bus:bus)
            }
            for entry in bus.entries ?? [] {
                if cancelled() { throw EDAError.cancelled }
                var onBus = false
                for (a,b) in zip(bus.points,bus.points.dropFirst()) {
                    if cancelled() { throw EDAError.cancelled }
                    try lookup.tick(); if EDAGeometry.onSegment(entry.busPosition,a,b) { onBus = true; break }
                }
                if !onBus { try add("bus_entry_detached",.warning,sheet:sheet,bus:bus,entry:entry,at:entry.busPosition) }
                let contact = try lookup.contact(entry.wirePosition,sheet:sheet,cancelled:cancelled)
                if contact.wireIDs.isEmpty {
                    try add("bus_entry_no_wire",.warning,sheet:sheet,bus:bus,entry:entry); continue
                }
                guard contact.netIDs.count == 1, let id = contact.netIDs.first,
                      let nets = netNames[id], nets.count == 1 else {
                    try add("bus_entry_ambiguous_nets",.error,sheet:sheet,bus:bus,entry:entry,wires:contact.wireIDs); continue
                }
                let matched = members.intersection(nets[0].labels).sorted()
                if matched.isEmpty {
                    try add("bus_entry_member_unidentified",.warning,sheet:sheet,bus:bus,entry:entry,wires:contact.wireIDs,net:id)
                } else if matched.count > 1 {
                    try add("bus_member_short",.error,sheet:sheet,bus:bus,entry:entry,wires:contact.wireIDs,net:id,members:matched)
                }
            }
        } }
        return issues
    }
}

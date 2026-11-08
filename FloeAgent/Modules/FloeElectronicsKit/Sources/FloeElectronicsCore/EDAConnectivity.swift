// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit

public struct EDAPinReference: Codable, Hashable, Sendable {
    public var componentID: UUID
    public var number: String
    public init(componentID: UUID, number: String) { self.componentID = componentID; self.number = number }
    public var key: String { componentID.uuidString + "/" + number }
}

public struct EDANet: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var pins: [EDAPinReference]
    public var wireIDs: [UUID]
    public var labels: [String]
}

public struct EDANetlist: Codable, Hashable, Sendable {
    public var projectID: UUID
    public var revision: UInt64
    public var nets: [EDANet]
    public func net(for pin: EDAPinReference) -> EDANet? { nets.first { $0.pins.contains(pin) } }
}

public enum EDAConnectivity {
    private struct NodeKey: Hashable {
        let sheet: UUID
        let x: Int64
        let y: Int64
        init(_ sheet: UUID, _ point: EDAPoint) {
            self.sheet = sheet; x = Int64((point.x * 1_000_000).rounded()); y = Int64((point.y * 1_000_000).rounded())
        }
    }
    private struct Segment { let a: EDAPoint; let b: EDAPoint; let node: Int }
    private struct Cell: Hashable { let x: Int; let y: Int }

    public static func derive(_ project: EDAProject, cancelled: @Sendable () -> Bool = { false }) throws -> EDANetlist {
        if cancelled() { throw EDAError.cancelled }
        try EDAValidation.validate(project)
        var graph = EDAUnionFind(), nodes: [NodeKey: Int] = [:]
        var nodePoints: [UUID: [(EDAPoint, Int)]] = [:]
        var pinNodes: [EDAPinReference: [Int]] = [:], wireNodes: [UUID: Int] = [:]
        var labelNodes: [(EDANetLabel, UUID, Int)] = []
        var segments: [UUID: [Segment]] = [:]
        let components = Dictionary(uniqueKeysWithValues: project.components.map { ($0.id, $0) })
        let symbols = Dictionary(uniqueKeysWithValues: project.symbols.map { ($0.id, $0) })
        func check() throws { if cancelled() { throw EDAError.cancelled } }
        func node(_ sheet: UUID, _ point: EDAPoint) -> Int {
            let key = NodeKey(sheet, point)
            if let existing = nodes[key] { return existing }
            let index = graph.add(); nodes[key] = index
            nodePoints[sheet, default: []].append((point, index)); return index
        }
        for sheet in project.sheets {
            try check()
            for placement in sheet.symbols {
                guard let component = components[placement.componentID], let symbol = symbols[component.symbolID] else { continue }
                for pin in symbol.pins where pin.unit == 0 || pin.unit == placement.unit {
                    let point = pin.position.transformed(origin: placement.position, angle: placement.angle, mirrored: placement.mirrored)
                    let index = node(sheet.id, point)
                    pinNodes[.init(componentID: component.id, number: pin.number), default: []].append(index)
                }
            }
            for wire in sheet.wires {
                guard let first = wire.points.first, let last = wire.points.last else { continue }
                let a = node(sheet.id, first), b = node(sheet.id, last)
                graph.join(a, b); wireNodes[wire.id] = a
                // Bends do not create junctions at crossings. Each polyline
                // owns one connected conductor; only explicit nodes join it.
                for (p, q) in zip(wire.points, wire.points.dropFirst()) {
                    segments[sheet.id, default: []].append(.init(a: p, b: q, node: a))
                }
            }
            for junction in sheet.junctions { _ = node(sheet.id, junction.position) }
            for label in sheet.labels { labelNodes.append((label, sheet.id, node(sheet.id, label.position))) }
            for child in sheet.children { for port in child.ports { _ = node(sheet.id, port.position) } }
        }
        for group in pinNodes.values {
            if let first = group.first { for other in group.dropFirst() { graph.join(first, other) } }
        }
        // Spatial buckets bound ordinary large-sheet work; very long segments
        // use a separate bounded list rather than allocating their whole area.
        var checks = 0
        for sheet in project.sheets {
            var buckets: [Cell: [Segment]] = [:], long: [Segment] = []
            for segment in segments[sheet.id, default: []] {
                let x0 = Int(floor(min(segment.a.x, segment.b.x) / 10)), x1 = Int(floor(max(segment.a.x, segment.b.x) / 10))
                let y0 = Int(floor(min(segment.a.y, segment.b.y) / 10)), y1 = Int(floor(max(segment.a.y, segment.b.y) / 10))
                if (x1 - x0 + 1) * (y1 - y0 + 1) > 1024 { long.append(segment); continue }
                for x in x0...x1 { for y in y0...y1 { buckets[Cell(x: x, y: y), default: []].append(segment) } }
                if buckets.count > 500_000 { throw EDAError.invalid("schematic geometry budget") }
            }
            for (point, index) in nodePoints[sheet.id, default: []] {
                try check()
                let near = buckets[Cell(x: Int(floor(point.x / 10)), y: Int(floor(point.y / 10))), default: []]
                for segment in near + long {
                    checks += 1; if checks > 20_000_000 { throw EDAError.invalid("schematic connectivity budget") }
                    if EDAGeometry.onSegment(point, segment.a, segment.b) { graph.join(index, segment.node) }
                }
            }
        }
        var names: [String: Int] = [:]
        for (label, sheet, index) in labelNodes {
            // Every label type participates in the sheet-local name first.
            // A global label additionally bridges that name across sheets;
            // it does not exclude same-named local/hierarchical labels here.
            let localKey = sheet.uuidString + ":" + label.name
            if let other = names[localKey] { graph.join(index, other) } else { names[localKey] = index }
            if label.scope == .global {
                let globalKey = "global:" + label.name
                if let other = names[globalKey] { graph.join(index, other) } else { names[globalKey] = index }
            }
        }
        for sheet in project.sheets {
            for link in sheet.children {
                for port in link.ports {
                    guard let parent = nodes[NodeKey(sheet.id, port.position)] else { continue }
                    for (label, childID, index) in labelNodes where childID == link.childSheetID && label.scope == .hierarchical && label.name == port.name {
                        graph.join(parent, index)
                    }
                }
            }
        }
        var rootPins: [Int: [EDAPinReference]] = [:], rootWires: [Int: [UUID]] = [:]
        var rootLabels: [Int: [String]] = [:]
        var rootLabelIDs: [Int: [String]] = [:]
        for (pin, indices) in pinNodes { if let first = indices.first { rootPins[graph.root(first), default: []].append(pin) } }
        for (wire, index) in wireNodes { rootWires[graph.root(index), default: []].append(wire) }
        for (label, sheet, index) in labelNodes {
            let root = graph.root(index)
            rootLabels[root, default: []].append(label.name)
            rootLabelIDs[root, default: []].append(sheet.uuidString + "/" + label.id.uuidString)
        }
        let roots = Set(rootPins.keys).union(rootWires.keys).union(rootLabels.keys)
        let nets = roots.map { root -> EDANet in
            let pins = rootPins[root, default: []].sorted { $0.key < $1.key }
            let labels = Array(Set(rootLabels[root, default: []])).sorted()
            let wires = rootWires[root, default: []].sorted { $0.uuidString < $1.uuidString }
            let identity: String
            if !pins.isEmpty { identity = "pins:" + pins.map(\.key).joined(separator: ",") }
            else if !wires.isEmpty { identity = "wires:" + wires.map(\.uuidString).joined(separator: ",") }
            else { identity = "labels:" + rootLabelIDs[root, default: []].sorted().joined(separator: ",") }
            let digest = SHA256.hash(data: Data((project.id.uuidString + ":" + identity).utf8)).map { String(format: "%02x", $0) }.joined()
            let first = pins.first.flatMap { pin in components[pin.componentID].map { "Net-(\($0.reference)-Pad\(pin.number))" } }
            return .init(id: "net-" + String(digest.prefix(24)), name: labels.first ?? first ?? "N-" + String(digest.prefix(8)),
                         pins: pins, wireIDs: wires, labels: labels)
        }.sorted { $0.id < $1.id }
        try check()
        return .init(projectID: project.id, revision: project.revision, nets: nets)
    }
}

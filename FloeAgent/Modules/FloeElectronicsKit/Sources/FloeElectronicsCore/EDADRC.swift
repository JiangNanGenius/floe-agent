// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Millimetres. Routing preferences in EDANetClass are deliberately separate.
public struct EDADRCConstraints: Codable, Hashable, Sendable {
    public var minimumCopperClearance: Double?
    public var minimumTrackWidth: Double?
    public var minimumViaDiameter: Double?
    public var minimumViaDrill: Double?
    public var minimumViaAnnularWidth: Double?
    public init(minimumCopperClearance: Double? = nil, minimumTrackWidth: Double? = nil,
                minimumViaDiameter: Double? = nil, minimumViaDrill: Double? = nil,
                minimumViaAnnularWidth: Double? = nil) {
        self.minimumCopperClearance = minimumCopperClearance; self.minimumTrackWidth = minimumTrackWidth
        self.minimumViaDiameter = minimumViaDiameter; self.minimumViaDrill = minimumViaDrill
        self.minimumViaAnnularWidth = minimumViaAnnularWidth
    }
}

public enum EDADRCRule: String, Codable, CaseIterable, Sendable {
    case geometry, copperClearance, trackWidth, viaDiameter, viaDrill, viaAnnularWidth
    case boardEdge, keepout, unconnectedNet
}

/// Pad IDs belong to library definitions: footprintID disambiguates instances.
public struct EDADRCObject: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case board, component, footprint, pad, track, via, zone, keepout }
    public let kind: Kind
    public let objectID: UUID
    public let footprintID: UUID?
    public let padNumber: String?
    public let part: Int?
    public init(kind: Kind, objectID: UUID, footprintID: UUID? = nil, padNumber: String? = nil, part: Int? = nil) {
        self.kind = kind; self.objectID = objectID; self.footprintID = footprintID
        self.padNumber = padNumber; self.part = part
    }
    var key: String {
        [kind.rawValue, objectID.uuidString, footprintID?.uuidString ?? "", padNumber ?? "", part.map(String.init) ?? ""].joined(separator: "/")
    }
}

public struct EDADRCIssue: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let rule: EDADRCRule
    public let code: String
    public let severity: EDAIssue.Severity
    public let objects: [EDADRCObject]
    public let netIDs: [String]
    public let layer: String?
    public let position: EDAPoint
    public let relatedPosition: EDAPoint?
    public let measured: Double?
    public let required: Double?
    public let ruleSourceIDs: [UUID]
    public let details: [String: String]
    init(rule: EDADRCRule, code: String, severity: EDAIssue.Severity = .error, objects: [EDADRCObject],
         netIDs: [String] = [], layer: String? = nil, position: EDAPoint, relatedPosition: EDAPoint? = nil,
         measured: Double? = nil, required: Double? = nil, ruleSourceIDs: [UUID] = [], details: [String: String] = [:]) {
        self.rule = rule; self.code = code; self.severity = severity
        self.objects = Array(Set(objects)).sorted { $0.key < $1.key }
        self.netIDs = Array(Set(netIDs)).sorted(); self.layer = layer; self.position = position
        self.relatedPosition = relatedPosition; self.measured = measured; self.required = required
        self.ruleSourceIDs = Array(Set(ruleSourceIDs)).sorted { $0.uuidString < $1.uuidString }; self.details = details
        self.id = [rule.rawValue, code, self.objects.map(\.key).joined(separator: ","), self.netIDs.joined(separator: ","),
                   layer ?? "", details.keys.sorted().map { $0 + "=" + details[$0]! }.joined(separator: ",")].joined(separator: ":")
    }
}

public struct EDADRCCoverage: Codable, Hashable, Sendable {
    public let rule: EDADRCRule
    /// Nonempty means the declared check could not be completely evaluated.
    public let limitationCodes: [String]
    public var isComplete: Bool { limitationCodes.isEmpty }
}

public struct EDADRCConnection: Codable, Hashable, Sendable {
    public let fromComponent: Int
    public let toComponent: Int
    public let fromObject: EDADRCObject
    public let toObject: EDADRCObject
    public let fromLayer: String
    public let toLayer: String
    public let fromPosition: EDAPoint
    public let toPosition: EDAPoint
    public let gap: Double
    public var requiresLayerTransition: Bool { fromLayer != toLayer }
}

public struct EDADRCRoutingStatus: Codable, Hashable, Sendable {
    public let netID: String
    public let copperComponents: [[EDADRCObject]]
    /// A minimum spanning tree of the actual disconnected copper components.
    /// These are missing connections, not a count of nets or a routed path.
    public let remainingConnections: [EDADRCConnection]
}

public struct EDADRCReport: Codable, Hashable, Sendable {
    public let projectID: UUID
    public let revision: UInt64
    public let boardID: UUID
    public let issues: [EDADRCIssue]
    public let coverage: [EDADRCCoverage]
    public let routing: [EDADRCRoutingStatus]
    /// Always separate from dynamic coverage: these checks are outside this API.
    public let excludedChecks: [String]
    public var hasErrors: Bool { issues.contains { $0.severity == .error } }
    public var isCompleteForSupportedChecks: Bool { coverage.allSatisfy(\.isComplete) }
}

public enum EDADRC {
    public static func check(_ project: EDAProject, boardID: UUID,
                             cancelled: @escaping @Sendable () -> Bool = { false }) throws -> EDADRCReport {
        if cancelled() { throw EDAError.cancelled }
        guard let board = project.boards.first(where: { $0.id == boardID }) else { throw EDAError.missing("DRC board") }
        // EDAValidation's exact simple-polygon validation is quadratic. Refuse
        // inputs above this bounded invocation budget before entering it.
        var validationWork = 0
        for b in project.boards {
            for polygon in [b.outline] + b.cutouts + b.keepouts.map(\.outline)
                + b.zones.flatMap({ [$0.outline] + $0.filledPolygons }) {
                guard polygon.count <= 20_000 else { throw EDAError.invalid("DRC polygon budget") }
                validationWork += polygon.count * polygon.count
                guard validationWork <= 20_000_000 else { throw EDAError.invalid("DRC polygon budget") }
            }
        }
        let netlist = try EDAConnectivity.derive(project, cancelled: cancelled)
        var run = Run(project: project, board: board, netlist: netlist, budget: .init(cancelled: cancelled))
        return try run.check()
    }

    private struct Copper {
        let object: EDADRCObject
        let net: String?
        let layer: String
        let shape: EDADRCShape
        let anchor: EDAPoint
        var zoneClearance: Double? = nil
        var key: String { object.key + "/" + layer }
    }
    private struct Run {
        let project: EDAProject
        let board: EDABoard
        let netlist: EDANetlist
        let budget: EDADRCBudget
        var copper: [Copper] = []
        var issues: [EDADRCIssue] = []
        var limitations: [EDADRCRule: Set<String>] = [:]
        var boardObject: EDADRCObject { .init(kind: .board, objectID: board.id) }
        var geometricRules: [EDADRCRule] { [.geometry, .copperClearance, .boardEdge, .keepout, .unconnectedNet] }

        mutating func limitation(_ code: String, rules: [EDADRCRule], objects: [EDADRCObject], position: EDAPoint,
                                 netIDs: [String] = [], severity: EDAIssue.Severity = .warning, details: [String: String] = [:]) throws {
            for rule in rules { limitations[rule, default: []].insert(code) }
            try emit(.init(rule: rules[0], code: code, severity: severity, objects: objects, netIDs: netIDs, position: position, details: details))
        }

        mutating func emit(_ issue: EDADRCIssue) throws {
            guard issues.count < 100_000 else { throw EDAError.invalid("DRC diagnostic budget") }
            issues.append(issue)
        }

        mutating func check() throws -> EDADRCReport {
            try dimensions()
            try collect()
            copper.sort { $0.key < $1.key }
            guard copper.count <= 50_000 else { throw EDAError.invalid("DRC copper budget") }
            var graph = EDAUnionFind()
            for _ in copper { _ = graph.add() }
            // The via model explicitly spans a plated barrel. Pads do not carry
            // a plating flag; their layer islands are never silently bridged.
            var viaNode: [UUID: Int] = [:]
            for i in copper.indices where copper[i].object.kind == .via {
                if let other = viaNode[copper[i].object.objectID] { graph.join(i, other) }
                else { viaNode[copper[i].object.objectID] = i }
            }
            for i in copper.indices {
                try budget.step()
                try edgeAndKeepout(copper[i])
                for j in copper.indices where j > i {
                    try budget.step()
                    let a = copper[i], b = copper[j]
                    guard a.layer == b.layer else { continue }
                    let pair = try EDADRCGeometry.distance(a.shape, b.shape, budget: budget)
                    let sameNet = a.net != nil && a.net == b.net
                    if sameNet {
                        if pair.distance <= EDAGeometry.tolerance { graph.join(i, j) }
                        continue
                    }
                    let ar = clearance(a.net), br = clearance(b.net)
                    let required = [ar.value, br.value, a.zoneClearance, b.zoneClearance].compactMap { $0 }.max()
                    if required == nil {
                        limitations[.copperClearance, default: []].insert("copper_clearance_unset")
                    }
                    if pair.distance <= EDAGeometry.tolerance || required.map({ pair.distance + EDAGeometry.tolerance < $0 }) == true {
                        try emit(.init(rule: .copperClearance, code: pair.distance <= EDAGeometry.tolerance ? "copper_contact" : "copper_clearance",
                                            objects: [a.object, b.object], netIDs: [a.net, b.net].compactMap { $0 }, layer: a.layer,
                                            position: pair.a, relatedPosition: pair.b, measured: pair.distance, required: required,
                                            ruleSourceIDs: ar.sources + br.sources + (a.zoneClearance == nil ? [] : [a.object.objectID])
                                                + (b.zoneClearance == nil ? [] : [b.object.objectID])))
                    }
                }
            }
            let routing = try routing(&graph)
            // Coverage must also be explicit when no pair happened to exercise
            // an absent clearance constraint on an otherwise empty board.
            if board.netClasses.isEmpty && board.drcConstraints?.minimumCopperClearance == nil {
                try limitation("copper_clearance_unset", rules: [.copperClearance], objects: [boardObject], position: board.outline[0], severity: .information)
            }
            let unique = Dictionary(issues.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return .init(projectID: project.id, revision: project.revision, boardID: board.id,
                         issues: unique.values.sorted { $0.id < $1.id },
                         coverage: EDADRCRule.allCases.map { .init(rule: $0, limitationCodes: limitations[$0, default: []].sorted()) },
                         routing: routing,
                         excludedChecks: ["pad_and_footprint_keepouts", "pad_annular_width", "mechanical_hole_and_hole_to_hole_clearance",
                                          "copper_to_drill_clearance", "mask_paste_silkscreen_courtyard", "differential_pairs_length_skew",
                                          "zone_refill_thermal_relief_and_neck_width", "arcs_slots_custom_padstacks_and_net_ties",
                                          "fabrication_and_physical_acceptance"])
        }

        mutating func dimensions() throws {
            let c = board.drcConstraints
            let minima: [(EDADRCRule, Double?)] = [(.trackWidth, c?.minimumTrackWidth), (.viaDiameter, c?.minimumViaDiameter),
                                                   (.viaDrill, c?.minimumViaDrill), (.viaAnnularWidth, c?.minimumViaAnnularWidth)]
            for (rule, value) in minima where value == nil {
                try limitation("minimum_constraint_unset", rules: [rule], objects: [boardObject], position: board.outline[0],
                           severity: .information, details: ["constraint": rule.rawValue])
            }
            for track in board.tracks {
                try budget.step()
                if let min = c?.minimumTrackWidth, track.width + EDAGeometry.tolerance < min {
                    try emit(.init(rule: .trackWidth, code: "track_width", objects: [.init(kind: .track, objectID: track.id)],
                                        netIDs: [track.netID], layer: track.layer, position: track.points[0], measured: track.width,
                                        required: min, ruleSourceIDs: [board.id]))
                }
            }
            for via in board.vias {
                try budget.step()
                let values: [(EDADRCRule, Double, Double?)] = [(.viaDiameter, via.diameter, c?.minimumViaDiameter),
                    (.viaDrill, via.drill, c?.minimumViaDrill), (.viaAnnularWidth, (via.diameter - via.drill) / 2, c?.minimumViaAnnularWidth)]
                for (rule, actual, min) in values {
                    if let min, actual + EDAGeometry.tolerance < min {
                        try emit(.init(rule: rule, code: rule.rawValue, objects: [.init(kind: .via, objectID: via.id)],
                                            netIDs: [via.netID], position: via.position, measured: actual, required: min, ruleSourceIDs: [board.id]))
                    }
                }
            }
        }

        func clearance(_ net: String?) -> (value: Double?, sources: [UUID]) {
            let name = netlist.nets.first { $0.id == net }?.name
            let matching = board.netClasses.filter { rule in net.map { rule.netNames.contains($0) } == true || name.map { rule.netNames.contains($0) } == true }
            // This model has no rule priorities. Multiple exact assignments use
            // the stricter clearance, not an inferred KiCad priority contract.
            let selected = matching.isEmpty ? board.netClasses.filter { $0.netNames.isEmpty } : matching
            let global = board.drcConstraints?.minimumCopperClearance
            return ((selected.map(\.clearance) + [global].compactMap { $0 }).max(), selected.map(\.id) + (global == nil ? [] : [board.id]))
        }

        mutating func collect() throws {
            let copperLayers = board.layers.filter { $0.kind == .copper }.map(\.id)
            let allLayers = Set(board.layers.map(\.id)), knownNets = Set(netlist.nets.map(\.id))
            let definitions = Dictionary(uniqueKeysWithValues: project.footprints.map { ($0.id, $0) })
            for fp in board.footprints.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                try budget.step()
                let object = EDADRCObject(kind: .footprint, objectID: fp.id)
                guard fp.side == "F.Cu" || fp.side == "B.Cu" else {
                    try limitation("footprint_side_unsupported", rules: geometricRules, objects: [object], position: fp.position); continue
                }
                guard let def = definitions[fp.definitionID] else {
                    try limitation("missing_footprint_definition", rules: geometricRules, objects: [object], position: fp.position, severity: .error); continue
                }
                for pad in def.pads.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                    try budget.step()
                    let ref = EDADRCObject(kind: .pad, objectID: pad.id, footprintID: fp.id, padNumber: pad.number)
                    let position = fp.point(pad.position)
                    guard pad.drill.map({ $0 + EDAGeometry.tolerance < min(pad.size.x, pad.size.y) }) ?? true else {
                        try limitation("pad_drill_exceeds_copper", rules: geometricRules, objects: [ref], position: position, severity: .error); continue
                    }
                    guard let shape = EDADRCGeometry.pad(pad, in: fp) else {
                        try limitation("pad_shape_unsupported", rules: geometricRules, objects: [ref], position: position,
                                   details: ["shape": pad.shape.rawValue]); continue
                    }
                    var layers: [String] = []
                    for raw in Set(pad.layers).sorted() {
                        let layer = fp.side == "B.Cu" ? (raw == "F.Cu" ? "B.Cu" : raw == "B.Cu" ? "F.Cu" : raw) : raw
                        if copperLayers.contains(layer) { layers.append(layer) }
                        else if !allLayers.contains(layer) {
                            try limitation("pad_layer_unsupported", rules: geometricRules, objects: [ref], position: position, details: ["layer": raw])
                        }
                    }
                    if pad.drill != nil && layers.count > 1 {
                        try limitation("pad_plating_unspecified", rules: [.unconnectedNet], objects: [ref], position: position)
                    }
                    let net = fp.padNets[pad.number].flatMap { $0.isEmpty ? nil : $0 }
                    for layer in layers { try append(.init(object: ref, net: net, layer: layer, shape: shape, anchor: position)) }
                }
                for number in fp.padNets.keys.sorted() where !def.pads.contains(where: { $0.number == number }) {
                    try limitation("mapped_pad_missing", rules: [.unconnectedNet], objects: [object], position: fp.position,
                               severity: .error, details: ["pad": number])
                }
            }
            for track in board.tracks {
                for i in 0..<(track.points.count - 1) {
                    try budget.step()
                    try append(.init(object: .init(kind: .track, objectID: track.id, part: i), net: nonempty(track.netID), layer: track.layer,
                                        shape: .init(outer: .capsule(track.points[i], track.points[i + 1], track.width / 2)), anchor: track.points[i]))
                }
            }
            for via in board.vias {
                guard let start = copperLayers.firstIndex(of: via.startLayer), let end = copperLayers.firstIndex(of: via.endLayer) else { continue }
                for layer in copperLayers[min(start, end)...max(start, end)] {
                    try budget.step()
                    try append(.init(object: .init(kind: .via, objectID: via.id), net: nonempty(via.netID), layer: layer,
                                        shape: .init(outer: .capsule(via.position, via.position, via.diameter / 2), hole: (via.position, via.drill / 2)), anchor: via.position))
                }
            }
            for zone in board.zones {
                try budget.step()
                let object = EDADRCObject(kind: .zone, objectID: zone.id)
                guard zone.fillRevision == project.revision && !zone.filledPolygons.isEmpty else {
                    try limitation(zone.filledPolygons.isEmpty ? "zone_fill_missing" : "zone_fill_stale", rules: geometricRules,
                               objects: [object], position: zone.outline[0]); continue
                }
                for (index, polygon) in zone.filledPolygons.enumerated() {
                    try append(.init(object: .init(kind: .zone, objectID: zone.id, part: index), net: nonempty(zone.netID), layer: zone.layer,
                                        shape: .init(outer: .polygon(polygon)), anchor: polygon[0], zoneClearance: zone.clearance))
                }
            }
            for keepout in board.keepouts {
                for layer in keepout.layers where !copperLayers.contains(layer) {
                    try limitation("keepout_layer_unsupported", rules: [.keepout], objects: [.init(kind: .keepout, objectID: keepout.id)],
                               position: keepout.outline[0], details: ["layer": layer])
                }
            }
            for item in copper {
                if clearance(item.net).value == nil && item.zoneClearance == nil {
                    try limitation("copper_clearance_unset", rules: [.copperClearance], objects: [item.object], position: item.anchor,
                               severity: .information)
                }
                if let net = item.net, !knownNets.contains(net) {
                    try limitation("unresolved_board_net", rules: [.unconnectedNet], objects: [item.object], position: item.anchor,
                               netIDs: [net], severity: .error, details: ["netID": net])
                }
            }
            // Missing schematic terminals are reported separately. We cannot
            // invent positions or count them as physical copper components.
            for net in netlist.nets {
                for pin in net.pins {
                    let fps = board.footprints.filter { $0.componentID == pin.componentID }
                    let valid = fps.contains { fp in
                        fp.padNets[pin.number] == net.id && definitions[fp.definitionID]?.pads.contains(where: { $0.number == pin.number }) == true
                    }
                    if !valid {
                        try limitation("schematic_terminal_unmapped", rules: [.unconnectedNet],
                                       objects: [boardObject, .init(kind: .component, objectID: pin.componentID)],
                                       position: fps.first?.position ?? board.outline[0], netIDs: [net.id],
                                       details: ["componentID": pin.componentID.uuidString, "pin": pin.number,
                                                 "positionKind": fps.isEmpty ? "board_anchor" : "footprint_anchor"])
                    }
                }
            }
        }

        mutating func append(_ item: Copper) throws {
            guard copper.count < 50_000 else { throw EDAError.invalid("DRC copper budget") }
            copper.append(item)
        }

        func nonempty(_ value: String) -> String? { value.isEmpty ? nil : value }

        mutating func edgeAndKeepout(_ item: Copper) throws {
            var closest: EDADRCWitness?
            for (a, b) in EDAGeometry.edges(board.outline) {
                let pair = try EDADRCGeometry.distance(item.shape, .init(outer: .capsule(a, b, 0)), budget: budget)
                if closest == nil || pair.distance < closest!.distance { closest = pair }
            }
            let outside = !EDAGeometry.contains(item.shape.outer.sample, polygon: board.outline)
            if let pair = closest, outside || pair.distance + EDAGeometry.tolerance < board.boardEdgeClearance {
                try emit(.init(rule: .boardEdge, code: outside ? "copper_outside_board" : "board_edge_clearance", objects: [item.object, boardObject],
                                    netIDs: [item.net].compactMap { $0 }, layer: item.layer, position: pair.a, relatedPosition: pair.b,
                                    measured: outside ? 0 : pair.distance, required: board.boardEdgeClearance, ruleSourceIDs: [board.id], details: ["boundary": "outline"]))
            }
            for (index, polygon) in board.cutouts.enumerated() {
                let pair = try EDADRCGeometry.distance(item.shape, .init(outer: .polygon(polygon)), budget: budget)
                if pair.distance + EDAGeometry.tolerance < board.boardEdgeClearance {
                    try emit(.init(rule: .boardEdge, code: pair.distance <= EDAGeometry.tolerance ? "copper_in_cutout" : "board_edge_clearance",
                                        objects: [item.object, boardObject], netIDs: [item.net].compactMap { $0 }, layer: item.layer,
                                        position: pair.a, relatedPosition: pair.b, measured: pair.distance, required: board.boardEdgeClearance,
                                        ruleSourceIDs: [board.id], details: ["boundary": "cutout", "cutout": String(index)]))
                }
            }
            for keepout in board.keepouts where keepout.layers.contains(item.layer) {
                let disallowed = (item.object.kind == .track && keepout.tracks) || (item.object.kind == .via && keepout.vias)
                    || (item.object.kind == .zone && keepout.copper)
                guard disallowed else { continue }
                // A via keepout excludes the complete via footprint, including
                // its drilled aperture. Copper-to-copper checks use the annulus.
                let pair = try EDADRCGeometry.distance(.init(outer: item.shape.outer), .init(outer: .polygon(keepout.outline)), budget: budget)
                if pair.distance <= EDAGeometry.tolerance {
                    try emit(.init(rule: .keepout, code: "keepout_entry", objects: [item.object, .init(kind: .keepout, objectID: keepout.id)],
                                        netIDs: [item.net].compactMap { $0 }, layer: item.layer, position: pair.midpoint, measured: 0,
                                        ruleSourceIDs: [keepout.id]))
                }
            }
        }

        mutating func routing(_ graph: inout EDAUnionFind) throws -> [EDADRCRoutingStatus] {
            var result: [EDADRCRoutingStatus] = []
            for net in Set(copper.compactMap(\.net)).sorted() {
                try budget.step()
                var components: [Int: [Int]] = [:]
                for i in copper.indices where copper[i].net == net { components[graph.root(i), default: []].append(i) }
                let groups = components.values.sorted { copper[$0[0]].key < copper[$1[0]].key }
                // Prim's tree keeps O(component count) frontier memory. Do not
                // materialize a quadratic array of candidate missing links.
                var frontier = [EDADRCConnection?](repeating: nil, count: groups.count)
                var visited: Set<Int> = [0], last = 0
                var remaining: [EDADRCConnection] = []
                while visited.count < groups.count {
                    for b in groups.indices where !visited.contains(b) {
                        for i in groups[last] { for j in groups[b] {
                            let x = copper[i], y = copper[j]
                            let pair = try EDADRCGeometry.distance(x.shape, y.shape, budget: budget)
                            let link = EDADRCConnection(fromComponent: last, toComponent: b, fromObject: x.object, toObject: y.object,
                                                      fromLayer: x.layer, toLayer: y.layer, fromPosition: pair.a, toPosition: pair.b, gap: pair.distance)
                            if frontier[b] == nil || link.gap < frontier[b]!.gap { frontier[b] = link }
                        } }
                    }
                    var chosen: EDADRCConnection?
                    for b in groups.indices where !visited.contains(b) {
                        if let link = frontier[b], chosen == nil || link.gap < chosen!.gap { chosen = link }
                    }
                    guard let link = chosen else { throw EDAError.invalid("DRC routing frontier") }
                    remaining.append(link); visited.insert(link.toComponent); last = link.toComponent
                    try emit(.init(rule: .unconnectedNet, code: "unconnected_copper", objects: [link.fromObject, link.toObject], netIDs: [net],
                                        layer: link.fromLayer == link.toLayer ? link.fromLayer : nil, position: link.fromPosition, relatedPosition: link.toPosition,
                                        measured: link.gap, details: ["fromComponent": String(link.fromComponent), "toComponent": String(link.toComponent),
                                                                   "componentCount": String(groups.count), "remainingConnections": String(groups.count - 1),
                                                                   "fromLayer": link.fromLayer, "toLayer": link.toLayer]))
                }
                result.append(.init(netID: net, copperComponents: groups.map { group in Array(Set(group.map { copper[$0].object })).sorted { $0.key < $1.key } },
                                    remainingConnections: remaining))
            }
            return result
        }
    }
}

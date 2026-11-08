// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct EDACopperFillIssue: Codable, Hashable, Sendable {
    public let code: String
    public let severity: EDAIssue.Severity
    public let boardID: UUID
    public let zoneID: UUID?
    public let objectID: UUID?
    public let position: EDAPoint?
    public let path: String
    public let details: [String: String]
}
public struct EDACopperFillFailure: Error, LocalizedError, Sendable {
    public let issues: [EDACopperFillIssue]
    public var errorDescription: String? { issues.map { $0.code + " (" + $0.path + ")" }.joined(separator: "; ") }
}
public struct EDACopperThermalConnection: Codable, Hashable, Sendable {
    public let footprintID: UUID
    public let padID: UUID
    public let connectedSpokes: Int
}
public struct EDACopperZoneFill: Codable, Hashable, Sendable {
    public let zoneID: UUID
    public let polygonCount: Int
    /// Positive native outer contours, not an electrical-net count.
    public let regionCount: Int
    public let areaSquareMillimetres: Double
    public let thermals: [EDACopperThermalConnection]
}
public struct EDACopperFillReport: Codable, Hashable, Sendable {
    public let projectID: UUID
    public let boardID: UUID
    public let sourceRevision: UInt64
    public internal(set) var resultRevision: UInt64?
    public let engineVersion: String
    public let coordinateGridMillimetres: Double
    public let roundChordErrorMillimetres: Double
    public let clearanceSafetyMillimetres: Double
    public let zones: [EDACopperZoneFill]
    public let issues: [EDACopperFillIssue]
    public let limitations: [String]
}

/// Not Codable and has no public initializer. Only the real engine produces a
/// plan; the editing session additionally compares the complete source value.
public struct EDACopperFillPlan: Sendable {
    let source: EDAProject
    let polygons: [UUID: [[EDAPoint]]]
    public let report: EDACopperFillReport
}

public enum EDACopperFill {
    /// Creates a new zone with explicit, visible Root-approved design values.
    /// EDAZone.init/decoding keep legacy thermal=true + nil unspecified.
    public static func newZone(netID: String, layer: String, outline: [EDAPoint], priority: Int = 0) -> EDAZone {
        .init(netID: netID, layer: layer, outline: outline, priority: priority,
              thermal: true, thermalRelief: .creationDefault)
    }
    public static func plan(_ project: EDAProject, boardID: UUID,
                            cancelled: @escaping @Sendable () -> Bool = { false }) throws -> EDACopperFillPlan {
        let clipper = EDACopperClipper(cancelled: cancelled)
        try clipper.step()
        // Bound the existing quadratic validation before entering it.
        var validationWork = 0
        for b in project.boards {
            for p in [b.outline] + b.cutouts + b.keepouts.map(\.outline) + b.zones.flatMap({ [$0.outline] + $0.filledPolygons }) {
                guard p.count <= 20_000 else { throw EDAError.invalid("copper fill input polygon budget") }
                validationWork += p.count * p.count
                guard validationWork <= 20_000_000 else { throw EDAError.invalid("copper fill input polygon budget") }
            }
        }
        try EDAValidation.validate(project)
        guard let board = project.boards.first(where: { $0.id == boardID }) else { throw EDAError.missing("copper fill board") }
        var worker = Worker(project: project, board: board, clipper: clipper)
        return try worker.run()
    }

    private struct Pad {
        let footprintID: UUID
        let id: UUID
        let net: String?
        let layers: Set<String>
        let shape: EDADRCShape
        let size: EDAPoint
        let position: EDAPoint
        let isPolygon: Bool
    }
    private struct Copper {
        let id: UUID
        let net: String?
        let layer: String
        let shape: EDADRCOuterShape
    }
    private struct Thermal {
        let pad: Pad
        let envelope: EDACopperClipper.Paths
        let copper: EDACopperClipper.Paths
        let corridors: [EDACopperClipper.Paths]
    }
    private struct Worker {
        let project: EDAProject
        let board: EDABoard
        let clipper: EDACopperClipper
        var pads: [Pad] = []
        var copper: [Copper] = []
        var bores: [String: EDACopperClipper.Paths] = [:]
        var borePoints = 0
        var netNames: [String: String] = [:]
        var issues: [EDACopperFillIssue] = []
        mutating func addBore(_ paths: EDACopperClipper.Paths, layer: String) throws {
            let count = paths.reduce(0) { $0 + $1.count }
            borePoints += count
            guard borePoints <= 100_000 else { throw EDAError.invalid("copper fill drill-void budget") }
            bores[layer, default: []].append(contentsOf: paths)
        }
        func appendObstacle(_ paths: EDACopperClipper.Paths, to values: inout EDACopperClipper.Paths,
                            pointCount: inout Int) throws {
            pointCount += paths.reduce(0) { $0 + $1.count }
            guard pointCount <= 20_000 else { throw EDAError.invalid("copper fill obstacle budget") }
            values.append(contentsOf: paths)
        }
        func issue(_ code: String, zone: EDAZone? = nil, object: UUID? = nil, path: String,
                   position: EDAPoint? = nil, severity: EDAIssue.Severity = .error,
                   details: [String: String] = [:]) -> EDACopperFillIssue {
            .init(code: code, severity: severity, boardID: board.id, zoneID: zone?.id,
                  objectID: object, position: position ?? zone?.outline.first,
                  path: path, details: details)
        }
        func fail(_ code: String, zone: EDAZone? = nil, object: UUID? = nil, path: String,
                  position: EDAPoint? = nil, details: [String: String] = [:]) -> EDACopperFillFailure {
            .init(issues: [issue(code, zone: zone, object: object, path: path, position: position, details: details)])
        }
        func same(_ a: String?, _ b: String?) -> Bool { a != nil && a != "" && a == b }
        func inspectGraphics(_ graphics: [EDAGraphic], layers: [EDAGraphicLayerAssignment?]?, ownerID: UUID,
                             footprint: EDAFootprint? = nil) throws {
            for index in graphics.indices {
                try clipper.step()
                do {
                    let resolved = try EDAGraphicLayers.resolve(layers?[index] ?? nil, index: index, board: board, footprintSide: footprint?.side)
                    try EDAGraphicLayers.requireCopperProfileExclusion(resolved)
                } catch let problem as EDAGraphicLayerFailure {
                    let point = EDAGraphicLayers.position(graphics[index])
                    throw fail(problem.code, object: footprint?.id ?? ownerID,
                        path: footprint == nil ? "board.graphics[\(index)]" : "footprintDefinition[\(ownerID.uuidString)].graphics[\(index)]",
                        position: footprint?.point(point) ?? point, details: ["layerID": problem.layerID ?? "unassigned"])
                }
            }
        }
        func clearance(_ net: String?) -> Double {
            let name = net.flatMap { netNames[$0] }
            let matches = board.netClasses.filter { rule in
                net.map { rule.netNames.contains($0) } == true || name.map { rule.netNames.contains($0) } == true
            }
            let rules = matches.isEmpty ? board.netClasses.filter { $0.netNames.isEmpty } : matches
            return max(rules.map(\.clearance).max() ?? 0, board.drcConstraints?.minimumCopperClearance ?? 0)
        }
        func distance(_ a: EDAZone, _ b: EDAZone) -> Double {
            max(a.clearance, b.clearance, clearance(a.netID), clearance(b.netID))
        }
        mutating func collect() throws {
            guard project.preservedSource.isEmpty else { throw fail("unmapped_preserved_source", path: "project.preservedSource") }
            try inspectGraphics(board.graphics, layers: board.graphicLayers, ownerID: board.id)
            let layers = board.layers.filter { $0.kind == .copper }.map(\.id)
            guard layers.count <= 64, board.zones.count <= 1000 else { throw EDAError.invalid("copper fill board limits") }
            let all = Set(layers)
            let definitions = Dictionary(uniqueKeysWithValues: project.footprints.map { ($0.id, $0) })
            let netlist = try EDAConnectivity.derive(project, cancelled: clipper.cancelled)
            netNames = Dictionary(uniqueKeysWithValues: netlist.nets.map { ($0.id, $0.name) })
            for area in board.keepouts where area.copper {
                guard area.layers.isSubset(of: all) else {
                    throw fail("keepout_layer_unsupported", object: area.id, path: "keepout.layers", position: area.outline.first)
                }
            }
            for fp in board.footprints.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                try clipper.step()
                guard fp.side == "F.Cu" || fp.side == "B.Cu" else { throw fail("footprint_side_unsupported", object: fp.id, path: "footprint.side", position: fp.position) }
                guard let def = definitions[fp.definitionID] else { throw fail("missing_footprint_definition", object: fp.id, path: "footprint.definitionID", position: fp.position) }
                try inspectGraphics(def.graphics, layers: def.graphicLayers, ownerID: def.id, footprint: fp)
                for pad in def.pads.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                    try clipper.step()
                    var resolved = Set<String>()
                    for raw in Set(pad.layers) {
                        if raw == "*.Cu" { resolved.formUnion(all) }
                        else if raw == "F.Cu" || raw == "B.Cu" {
                            let actual = fp.side == "B.Cu" ? (raw == "F.Cu" ? "B.Cu" : "F.Cu") : raw
                            guard all.contains(actual) else { throw fail("pad_layer_unsupported", object: pad.id, path: "pad.layers", position: fp.point(pad.position)) }
                            resolved.insert(actual)
                        } else if all.contains(raw) { resolved.insert(raw) }
                        else if !board.layers.contains(where: { $0.id == raw && $0.kind != .copper }) && !EDAGraphicLayers.standardAssignments.contains(where:{$0.layerID==raw && $0.kind != .copper}) {
                            throw fail("pad_layer_unsupported", object: pad.id, path: "pad.layers", position: fp.point(pad.position), details: ["layer": raw])
                        }
                    }
                    if let drill = pad.drill {
                        let void = try clipper.outer(.capsule(fp.point(pad.position), fp.point(pad.position), drill / 2))
                        for layer in layers { try addBore(void, layer: layer) }
                    }
                    guard !resolved.isEmpty else{continue} // Keep its real bore; do not invent copper for aperture-only pads.
                    guard pad.drill.map({ $0 + EDAGeometry.tolerance < min(pad.size.x, pad.size.y) }) ?? true,
                          let shape = EDADRCGeometry.pad(pad, in: fp) else {
                        throw fail("pad_shape_unsupported", object: pad.id, path: "pad.shape/size/drill", position: fp.point(pad.position))
                    }
                    let net = fp.padNets[pad.number].flatMap { $0.isEmpty ? nil : $0 }
                    pads.append(.init(footprintID: fp.id, id: pad.id, net: net, layers: resolved,
                                      shape: shape, size: pad.size, position: fp.point(pad.position), isPolygon: pad.shape == .polygon))
                    guard pads.count + copper.count <= 10_000 else { throw EDAError.invalid("copper fill copper-object budget") }
                }
                for key in fp.padNets.keys where !def.pads.contains(where: { $0.number == key }) {
                    throw fail("mapped_pad_missing", object: fp.id, path: "footprint.padNets", position: fp.position, details: ["pad": key])
                }
            }
            for track in board.tracks.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                for (a, b) in zip(track.points, track.points.dropFirst()) {
                    try clipper.step()
                    copper.append(.init(id: track.id, net: track.netID.isEmpty ? nil : track.netID, layer: track.layer,
                                        shape: .capsule(a, b, track.width / 2)))
                    guard pads.count + copper.count <= 10_000 else { throw EDAError.invalid("copper fill copper-object budget") }
                }
            }
            for via in board.vias.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                try clipper.step()
                guard let a = layers.firstIndex(of: via.startLayer), let b = layers.firstIndex(of: via.endLayer) else {
                    throw fail("via_span_missing", object: via.id, path: "via.layers", position: via.position)
                }
                let void = try clipper.outer(.capsule(via.position, via.position, via.drill / 2))
                for layer in layers[min(a, b)...max(a, b)] {
                    copper.append(.init(id: via.id, net: via.netID.isEmpty ? nil : via.netID, layer: layer,
                                        shape: .capsule(via.position, via.position, via.diameter / 2)))
                    try addBore(void, layer: layer)
                    guard pads.count + copper.count <= 10_000 else { throw EDAError.invalid("copper fill copper-object budget") }
                }
            }
            for hole in board.holes {
                let void = try clipper.outer(.capsule(hole.position, hole.endPosition ?? hole.position, hole.diameter / 2))
                for layer in layers { try addBore(void, layer: layer) }
            }
            guard copper.count + pads.count <= 10_000 else { throw EDAError.invalid("copper fill copper-object budget") }
        }
        mutating func run() throws -> EDACopperFillPlan {
            try collect()
            let ordered = board.zones.sorted { $0.priority == $1.priority ? $0.id.uuidString < $1.id.uuidString : $0.priority > $1.priority }
            var bases: [UUID: EDACopperClipper.Paths] = [:]
            var basePoints = 0
            let boardInterior = try clipper.offset([clipper.contour(board.outline)], -(board.boardEdgeClearance + EDACopperClipper.safety))
            var cutouts: EDACopperClipper.Paths = []
            for cutout in board.cutouts {
                cutouts.append(contentsOf: try clipper.offset([clipper.contour(cutout)], board.boardEdgeClearance + EDACopperClipper.safety))
            }
            for zone in ordered {
                try clipper.step()
                if zone.thermal {
                    guard let relief = zone.thermalRelief else { throw fail("thermal_parameters_unspecified", zone: zone, path: "zone.thermalRelief") }
                    let minimumGap = max(zone.clearance, clearance(zone.netID))
                    guard relief.gap >= minimumGap else {
                        throw fail("thermal_gap_below_clearance_floor", zone: zone, path: "zone.thermalRelief.gap", details: ["requiredMillimetres": String(minimumGap)])
                    }
                    // Conservative filler floor; net-class preferred widths
                    // remain preferences and are never treated as minima.
                    if let minimum = board.drcConstraints?.minimumTrackWidth, relief.spokeWidth < minimum {
                        throw fail("thermal_spoke_below_explicit_minimum_track_width", zone: zone, path: "zone.thermalRelief.spokeWidth", details: ["requiredMillimetres": String(minimum)])
                    }
                }
                var result = try clipper.intersection([clipper.contour(zone.outline)], boardInterior)
                result = try clipper.difference(result, cutouts)
                var obstacles = bores[zone.layer, default: []]
                var obstaclePoints = obstacles.reduce(0) { $0 + $1.count }
                guard obstaclePoints <= 20_000 else { throw EDAError.invalid("copper fill obstacle budget") }
                for area in board.keepouts where area.copper && area.layers.contains(zone.layer) {
                    try appendObstacle(clipper.offset([clipper.contour(area.outline)], EDACopperClipper.safety), to: &obstacles, pointCount: &obstaclePoints)
                }
                for pad in pads where pad.layers.contains(zone.layer) && !same(pad.net, zone.netID) {
                    try appendObstacle(clipper.outer(pad.shape.outer, inflation: max(zone.clearance, clearance(zone.netID), clearance(pad.net)) + EDACopperClipper.safety), to: &obstacles, pointCount: &obstaclePoints)
                }
                for item in copper where item.layer == zone.layer && !same(item.net, zone.netID) {
                    try appendObstacle(clipper.outer(item.shape, inflation: max(zone.clearance, clearance(zone.netID), clearance(item.net)) + EDACopperClipper.safety), to: &obstacles, pointCount: &obstaclePoints)
                }
                result = try clipper.difference(result, clipper.union(obstacles))
                basePoints += result.reduce(0) { $0 + $1.count }
                guard basePoints <= 100_000 else { throw EDAError.invalid("copper fill board intermediate budget") }
                bases[zone.id] = result
            }
            // Equal priority has no owner-selected winner. Refuse an actual
            // overlap/clearance conflict instead of inventing UUID priority.
            for a in ordered.indices {
                for b in ordered.indices where b > a {
                    try clipper.step()
                    let x = ordered[a], y = ordered[b]
                    guard x.layer == y.layer, x.priority == y.priority, !same(x.netID, y.netID) else { continue }
                    let expanded = try clipper.offset(bases[x.id]!, distance(x, y) + EDACopperClipper.safety)
                    if EDACopperClipper.area(try clipper.intersection(expanded, bases[y.id]!)) > EDAGeometry.tolerance * EDAGeometry.tolerance {
                        throw fail("ambiguous_zone_priority", zone: x, object: y.id, path: "zone.priority")
                    }
                }
            }
            var native: [UUID: EDACopperClipper.Paths] = [:], polygons: [UUID: [[EDAPoint]]] = [:]
            var reports: [EDACopperZoneFill] = []
            var outputPoints = 0, outputPolygons = 0
            for zone in ordered {
                var result = bases[zone.id]!
                for higher in ordered where higher.layer == zone.layer && higher.priority > zone.priority && !same(higher.netID, zone.netID) {
                    let obstacle = try clipper.offset(native[higher.id]!, distance(zone, higher) + EDACopperClipper.safety)
                    result = try clipper.difference(result, obstacle)
                }
                var thermals: [Thermal] = []
                if zone.thermal, let relief = zone.thermalRelief {
                    for pad in pads where pad.layers.contains(zone.layer) && same(pad.net, zone.netID) {
                        let realPad = try clipper.solid(pad.shape)
                        guard EDACopperClipper.area(try clipper.intersection(result, realPad)) > EDAGeometry.tolerance else { continue }
                        guard !pad.isPolygon else {
                            throw fail("polygon_pad_thermal_unsupported", zone: zone, object: pad.id, path: "zone.thermal/pad.polygon", position: pad.position)
                        }
                        guard relief.spokeWidth + EDACopperClipper.safety < min(pad.size.x, pad.size.y) else {
                            throw fail("thermal_spoke_too_wide_for_pad", zone: zone, object: pad.id, path: "zone.thermalRelief.spokeWidth", position: pad.position)
                        }
                        let envelope = try clipper.outer(pad.shape.outer, inflation: relief.gap + EDACopperClipper.safety)
                        let outerPad = try clipper.outer(pad.shape.outer)
                        let ring = try clipper.difference(envelope, outerPad)
                        let length = hypot(pad.size.x, pad.size.y) + relief.gap + relief.spokeWidth
                        var corridors: [EDACopperClipper.Paths] = []
                        for k in 0..<relief.spokeCount {
                            let angle = (relief.spokeAngleDegrees + Double(k) * 360 / Double(relief.spokeCount)) * .pi / 180
                            let d = EDAPoint(cos(angle), sin(angle)), n = EDAPoint(-d.y, d.x) * (relief.spokeWidth / 2)
                            corridors.append([[pad.position + n, pad.position - n,
                                               pad.position + d * length - n, pad.position + d * length + n]])
                        }
                        let knockout = try clipper.difference(ring, clipper.union(corridors.flatMap { $0 }))
                        result = try clipper.difference(result, knockout)
                        thermals.append(.init(pad: pad, envelope: envelope, copper: realPad, corridors: corridors))
                    }
                }
                var connections: [EDACopperThermalConnection] = []
                for thermal in thermals {
                    var connected = 0
                    for corridor in thermal.corridors {
                        let connection = try clipper.intersection(result, corridor)
                        for outer in connection where EDAGeometry.signedArea(outer) > 0 {
                            // Include only this connected outer and its holes.
                            let holes = connection.filter { EDAGeometry.signedArea($0) < 0 && EDAGeometry.contains($0[0], polygon: outer) }
                            let region = [outer] + holes
                            let atPad = EDACopperClipper.area(try clipper.intersection(region, thermal.copper))
                            let atZone = EDACopperClipper.area(try clipper.difference(region, thermal.envelope))
                            if atPad > EDAGeometry.tolerance && atZone > EDAGeometry.tolerance { connected += 1; break }
                        }
                    }
                    guard connected == zone.thermalRelief!.spokeCount else {
                        throw fail("thermal_connection_incomplete", zone: zone, object: thermal.pad.id, path: "zone.thermalRelief", position: thermal.pad.position,
                                   details: ["connectedSpokes": String(connected), "requiredSpokes": String(zone.thermalRelief!.spokeCount)])
                    }
                    connections.append(.init(footprintID: thermal.pad.footprintID, padID: thermal.pad.id, connectedSpokes: connected))
                }
                let solids = try clipper.simpleSolids(result)
                outputPoints += solids.reduce(0) { $0 + $1.count }; outputPolygons += solids.count
                guard outputPoints <= 100_000, outputPolygons <= 5000 else { throw EDAError.invalid("copper fill board output budget") }
                native[zone.id] = result; polygons[zone.id] = solids
                reports.append(.init(zoneID: zone.id, polygonCount: solids.count,
                                     regionCount: result.filter { EDAGeometry.signedArea($0) > 0 }.count,
                                     areaSquareMillimetres: EDACopperClipper.area(result), thermals: connections))
                if solids.isEmpty { issues.append(issue("zone_fill_empty", zone: zone, path: "zone.filledPolygons", severity: .information)) }
            }
            try clipper.step()
            let report = EDACopperFillReport(projectID: project.id, boardID: board.id, sourceRevision: project.revision,
                resultRevision: nil, engineVersion: clipper.version, coordinateGridMillimetres: EDACopperClipper.grid,
                roundChordErrorMillimetres: EDACopperClipper.chordError, clearanceSafetyMillimetres: EDACopperClipper.safety,
                zones: reports, issues: issues, limitations: [
                    "Vector clipping uses the reported integer grid and conservative polygonal round envelopes; it is not an analytic-arc or fabrication qualification.",
                    "All isolated copper regions are retained. Minimum neck width, island removal and hatch fill have no design fields and are not implemented.",
                    "Thermals apply to same-net pads; tracks and vias connect solidly. Only four explicit board-axis spokes are supported; incomplete connections refuse the entire refill.",
                    "Mechanical holes/slots and drill bores remove their real voids. A copper-to-hole clearance rule is not configured by this model and is not claimed.",
                    "Explicit silk/fabrication/courtyard graphics are non-copper design records and are retained without entering this copper-fill geometry.",
                    "Unlayered graphics, unsupported pad geometry and unmapped preserved source refuse refill. Padstack/net-tie/custom-rule and thermal override semantics are not implemented.",
                    "Native boolean calls are bounded and cancellation is checked before/after each call; an in-progress C++ call cannot be interrupted."
                ])
            return .init(source: project, polygons: polygons, report: report)
        }
    }
}

// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Missing geometry is an export failure, never a partially successful file.
public struct EDAManufacturingIssue: Codable, Hashable, Sendable {
    public let code: String
    public let path: String
    public let objectID: UUID?
}

public struct EDAManufacturingFailure: Error, LocalizedError, Sendable {
    public let issues: [EDAManufacturingIssue]
    public var errorDescription: String? { "Some board data is missing or unsupported for this manufacturing output." }
}

/// Native, deterministic RS-274X / XNC (Excellon subset) artwork writer.
/// It does not fill zones, invent layer assignments or certify fabrication.
enum EDAManufacturing {
    private struct Layer: Codable {
        let id: String
        let number: Int
        let side: String
    }
    private struct FileRecord: Codable {
        let name: String
        let mimeType: String
        let sha256: String
        let byteCount: Int
        let function: String
        let layerNumbers: [Int]
        let objectCount: Int
        let drillCount: Int
        let slotCount: Int
    }
    private struct Manifest: Encodable {
        let format = "org.floe.electronics.manufacturing"
        let version = 1
        let projectID: UUID
        let sourceRevision: String
        let boardID: UUID
        let edgePlated: Bool?
        let completeFabricationSet = false
        let output: String
        let unit = "mm"
        let coordinateResolutionMM = 0.000_001
        let coordinates = "Original board XY; viewed from top; no origin shift or whole-bottom-layer mirroring."
        let copperImage = "Phototool artwork before drilling; holes and routed slots are separate Excellon geometry."
        let copperStack: [Layer]
        let emptyCopperLayers: [Int]
        let computedEmptyZoneIDs: [UUID]
        let excludedGraphics: [ExcludedGraphic]
        let files: [FileRecord]
        let limitations: [String]
    }
    private struct ExcludedGraphic: Encodable {
        let ownerID: UUID
        let footprintID: UUID?
        let graphicIndex: Int
        let declaredLayerID: String
        let resolvedLayerID: String
        let kind: EDALayerKind
        let reason = "not_in_copper_profile_subset"
    }
    private static func recordExcludedGraphics(_ graphics: [EDAGraphic], layers: [EDAGraphicLayerAssignment?]?,
                                              board: EDABoard, ownerID: UUID, footprint: EDAFootprint? = nil,
                                              into records: inout [ExcludedGraphic], cancelled: @Sendable () -> Bool) throws {
        for index in graphics.indices {
            try check(cancelled)
            do {
                let layer = try EDAGraphicLayers.resolve(layers?[index] ?? nil, index: index, board: board, footprintSide: footprint?.side)
                try EDAGraphicLayers.requireCopperProfileExclusion(layer)
                guard records.count < 20_000 else { throw EDAError.invalid("manufacturing graphic manifest budget") }
                records.append(.init(ownerID: ownerID, footprintID: footprint?.id, graphicIndex: index,
                    declaredLayerID: layer.declared.layerID, resolvedLayerID: layer.layerID, kind: layer.declared.kind))
            } catch let problem as EDAGraphicLayerFailure {
                let path = footprint == nil ? "board.graphics[\(index)]" : "footprintDefinition[\(ownerID.uuidString)].graphics[\(index)]"
                throw failure(problem.code, path, footprint?.id ?? ownerID)
            }
        }
    }
    private enum Aperture: Hashable {
        case circle(String)
        case rectangle(String, String, String)
        case oval(String, String, String)
        var key: String {
            switch self {
            case .circle(let d): return "C/" + d
            case let .rectangle(w, h, a): return "R/" + w + "/" + h + "/" + a
            case let .oval(w, h, a): return "O/" + w + "/" + h + "/" + a
            }
        }
    }
    private enum Copper {
        case flash(Aperture, EDAPoint)
        case track(Aperture, [EDAPoint])
        case region([EDAPoint])
        var aperture: Aperture? {
            switch self { case .flash(let a, _), .track(let a, _): return a; case .region: return nil }
        }
    }
    private struct Drill {
        let id: UUID
        let start: EDAPoint
        let end: EDAPoint?
        let diameter: String
        let plated: Bool
        let from: Int
        let to: Int
        var group: String { (plated ? "PTH" : "NPTH") + "-L" + two(from) + "-L" + two(to) }
    }
    private struct Writer {
        var lines: [String] = []
        var bytes = 0
        mutating func emit(_ value: String) throws {
            bytes += value.utf8.count + 1
            guard bytes <= 32 * 1_024 * 1_024, lines.count < 1_000_000 else { throw EDAError.invalid("manufacturing file budget") }
            lines.append(value)
        }
        var data: Data { Data((lines.joined(separator: "\n") + "\n").utf8) }
    }

    static func export(_ project: EDAProject, format: EDAExportFormat, boardID: UUID?,
                       cancelled: @Sendable () -> Bool) throws -> EDAExchangeBundle {
        guard format == .gerber || format == .excellon else { throw EDAError.invalid("manufacturing format") }
        try check(cancelled)
        var work = 0
        for board in project.boards {
            for polygon in [board.outline] + board.cutouts + board.keepouts.map(\.outline)
                + board.zones.flatMap({ [$0.outline] + $0.filledPolygons }) {
                guard polygon.count <= 20_000 else { throw EDAError.invalid("manufacturing polygon budget") }
                work += polygon.count * polygon.count
                guard work <= 20_000_000 else { throw EDAError.invalid("manufacturing polygon budget") }
            }
        }
        try EDAValidation.validate(project)
        guard let board = boardID.flatMap({ id in project.boards.first { $0.id == id } }) ?? (boardID == nil ? project.boards.first : nil) else {
            throw EDAError.missing("manufacturing board")
        }
        guard project.preservedSource.isEmpty else { throw failure("unmapped_preserved_source", "project.preservedSource") }
        let copperLayers = board.layers.filter { $0.kind == .copper }
        guard (copperLayers.count == 1 && ["F.Cu", "B.Cu"].contains(copperLayers[0].id))
            || (copperLayers.first?.id == "F.Cu" && copperLayers.last?.id == "B.Cu") else {
            throw failure("copper_stack_surfaces_unspecified", "board.layers", board.id)
        }
        let layers = copperLayers.enumerated().map { index, value in
            Layer(id: value.id, number: index + 1, side: value.id == "F.Cu" ? "Top" : value.id == "B.Cu" ? "Bot" : "Inr")
        }
        guard layers.count <= 64 else { throw EDAError.invalid("manufacturing layer budget") }
        let definitions = Dictionary(uniqueKeysWithValues: project.footprints.map { ($0.id, $0) })
        var estimated = board.holes.count + board.tracks.count + board.vias.count * layers.count + board.zones.reduce(0, { $0 + $1.filledPolygons.count })
        for fp in board.footprints {
            try check(cancelled)
            if let definition = definitions[fp.definitionID] {
                estimated += definition.pads.reduce(0, { $0 + min(64, $1.layers.count) })
            }
            guard estimated <= 100_000 else { throw EDAError.invalid("manufacturing object budget") }
        }
        guard estimated <= 100_000 else { throw EDAError.invalid("manufacturing object budget") }
        var files: [EDAExchangeFile] = [], records: [FileRecord] = [], emptyLayers: [Int] = [], excludedGraphics: [ExcludedGraphic] = []
        var limitations = [
            "This export is not fabrication acceptance or a complete PCB manufacturing data set.",
            "Soldermask, solderpaste, silkscreen, assembly drawings and material/stack fabrication instructions are not generated by this model.",
            "No DRC, net connectivity, tool compensation, panelization or factory process qualification is implied."
        ]
        if board.edgePlated == nil { limitations.append("Board-edge plating is unspecified; the profile is geometry only, not a plating instruction.") }
        if format == .gerber {
            var objects: [String: [Copper]] = [:]
            try recordExcludedGraphics(board.graphics, layers: board.graphicLayers, board: board, ownerID: board.id,
                                       into: &excludedGraphics, cancelled: cancelled)
            for fp in board.footprints.sorted(by: uuidOrder) {
                try check(cancelled)
                guard fp.side == "F.Cu" || fp.side == "B.Cu" else { throw failure("footprint_side_unsupported", "footprint.side", fp.id) }
                guard let definition = definitions[fp.definitionID] else { throw failure("missing_footprint_definition", "footprint.definitionID", fp.id) }
                try recordExcludedGraphics(definition.graphics, layers: definition.graphicLayers, board: board, ownerID: definition.id,
                                           footprint: fp, into: &excludedGraphics, cancelled: cancelled)
                for pad in definition.pads.sorted(by: uuidOrder) {
                    try check(cancelled)
                    let center = fp.point(pad.position)
                    let axis = fp.point(EDAPoint(1, 0).transformed(origin: pad.position, angle: pad.angle)) - center
                    let angle = number(normalAngle(atan2(axis.y, axis.x) * 180 / .pi), decimals: 9)
                    let w = try dimension(pad.size.x, path: "pad.size.x", id: pad.id), h = try dimension(pad.size.y, path: "pad.size.y", id: pad.id)
                    let aperture: Aperture
                    switch pad.shape {
                    case .circle:
                        guard abs(pad.size.x - pad.size.y) <= EDAGeometry.tolerance else { throw failure("circle_pad_not_round", "pad.size", pad.id) }
                        aperture = .circle(w)
                    case .rectangle: aperture = .rectangle(w, h, angle)
                    case .oval: aperture = .oval(w, h, angle)
                    case .roundRectangle: throw failure("round_rectangle_radius_missing", "pad.shape", pad.id)
                    }
                    if let drill = pad.drill, drill + EDAGeometry.tolerance >= min(pad.size.x, pad.size.y) {
                        throw failure("pad_drill_exceeds_copper", "pad.drill", pad.id)
                    }
                    for rawLayer in Set(pad.layers).sorted() {
                        let layer = fp.side == "B.Cu" ? opposite(rawLayer) : rawLayer
                        guard let known = board.layers.first(where: { $0.id == layer }) else { throw failure("pad_layer_unsupported", "pad.layers", pad.id) }
                        if known.kind == .copper { objects[layer, default: []].append(.flash(aperture, center)) }
                    }
                }
            }
            for track in board.tracks.sorted(by: uuidOrder) {
                try check(cancelled)
                objects[track.layer, default: []].append(.track(.circle(try dimension(track.width, path: "track.width", id: track.id)), track.points))
            }
            for via in board.vias.sorted(by: uuidOrder) {
                try check(cancelled)
                guard let a = layers.firstIndex(where: { $0.id == via.startLayer }), let b = layers.firstIndex(where: { $0.id == via.endLayer }) else {
                    throw failure("via_span_missing", "via.layers", via.id)
                }
                for layer in layers[min(a, b)...max(a, b)] {
                    objects[layer.id, default: []].append(.flash(.circle(try dimension(via.diameter, path: "via.diameter", id: via.id)), via.position))
                }
            }
            for zone in board.zones.sorted(by: uuidOrder) {
                try check(cancelled)
                guard zone.fillRevision == project.revision && (!zone.filledPolygons.isEmpty || zone.fillState == .empty) else {
                    throw failure("zone_fill_not_current", "zone.filledPolygons", zone.id)
                }
                if zone.fillState == .empty {
                    limitations.append("Computed zone \(zone.id.uuidString) is empty at this revision; no copper image was invented for it.")
                }
                for polygon in zone.filledPolygons { objects[zone.layer, default: []].append(.region(polygon)) }
            }
            for layer in layers {
                try check(cancelled)
                let geometry = objects[layer.id, default: []]
                if geometry.isEmpty { emptyLayers.append(layer.number); continue }
                let file = EDAExchangeFile(name: "Copper-L" + two(layer.number) + ".gbr", mimeType: "application/vnd.gerber",
                    data: try gerber(geometry, function: "Copper,L\(layer.number),\(layer.side)", project: project, board: board, cancelled: cancelled))
                try add(file, to: &files); records.append(record(file, function: "copper", layers: [layer.number], objects: geometry.count))
            }
            let contours = [board.outline] + board.cutouts
            let profile = EDAExchangeFile(name: "Outline.gbr", mimeType: "application/vnd.gerber",
                data: try gerber(contours.map { .track(.circle("0.050000"), $0 + [$0[0]]) }, function: board.edgePlated.map { "Profile," + ($0 ? "P" : "NP") } ?? "Other,ProfileGeometry",
                                 project: project, board: board, cancelled: cancelled))
            try add(profile, to: &files); records.append(record(profile, function: "profileGeometry", layers: [], objects: contours.count))
            limitations.append("Gerber images are phototools before drilling; generate Excellon separately for all represented holes and slots.")
            if !excludedGraphics.isEmpty {
                limitations.append("Explicit silk/fabrication/courtyard graphics are retained in the original and listed in excludedGraphics. Those layer images are not generated by this copper/profile subset.")
            }
            if !emptyLayers.isEmpty { limitations.append("Copper layers listed as empty in the manifest have no represented copper; no blank copper files were emitted.") }
        } else {
            let drills = try drilling(board, layers: layers, definitions: definitions, cancelled: cancelled)
            guard !drills.isEmpty else { throw failure("no_drilling_geometry", "board.holes/vias/pads", board.id) }
            for key in Set(drills.map(\.group)).sorted() {
                try check(cancelled)
                let group = drills.filter { $0.group == key }
                let first = group[0]
                let viaKind = first.from == 1 && first.to == layers.count ? "PTH" : (first.from == 1 || first.to == layers.count ? "Blind" : "Buried")
                let kind = first.plated ? viaKind : "NPTH"
                let operation = group.allSatisfy { $0.end == nil } ? "Drill" : group.allSatisfy { $0.end != nil } ? "Rout" : "Mixed"
                let function = "\(first.plated ? "Plated" : "NonPlated"),\(first.from),\(first.to),\(kind),\(operation)"
                let file = EDAExchangeFile(name: "Drill-" + key + ".drl", mimeType: "application/x-excellon",
                    data: try excellon(group, function: function, project: project, board: board, cancelled: cancelled))
                try add(file, to: &files); records.append(record(file, function: function, layers: [first.from, first.to], objects: group.count,
                    drills: group.filter { $0.end == nil }.count, slots: group.filter { $0.end != nil }.count))
            }
            limitations.append("Tool diameters are modeled finished-hole/slot widths; manufacturing compensation and actual drilling-machine feeds/speeds are not generated.")
        }
        try check(cancelled)
        let manifest = Manifest(projectID: project.id, sourceRevision: String(project.revision), boardID: board.id, edgePlated: board.edgePlated, output: format.rawValue,
            copperStack: layers, emptyCopperLayers: emptyLayers,
            computedEmptyZoneIDs: board.zones.filter { $0.fillRevision == project.revision && $0.fillState == .empty }.map(\.id).sorted { $0.uuidString < $1.uuidString },
            excludedGraphics: excludedGraphics, files: records, limitations: limitations)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try add(.init(name: format == .gerber ? "Gerber-manifest.json" : "Excellon-manifest.json", mimeType: "application/json", data: try encoder.encode(manifest)), to: &files)
        guard files.count <= 500, files.reduce(0, { $0 + $1.data.count }) <= 128 * 1_024 * 1_024 else { throw EDAError.invalid("manufacturing bundle budget") }
        return .init(projectID: project.id, revision: project.revision, files: files, limitations: limitations)
    }

    private static func drilling(_ board: EDABoard, layers: [Layer], definitions: [UUID: EDAFootprintDefinition],
                                 cancelled: @Sendable () -> Bool) throws -> [Drill] {
        var result: [Drill] = []
        for hole in board.holes.sorted(by: uuidOrder) {
            try check(cancelled)
            result.append(.init(id: hole.id, start: hole.position, end: hole.endPosition, diameter: try dimension(hole.diameter, path: "hole.diameter", id: hole.id),
                                plated: hole.plated, from: 1, to: layers.count))
        }
        for via in board.vias.sorted(by: uuidOrder) {
            try check(cancelled)
            guard let start = layers.firstIndex(where: { $0.id == via.startLayer }), let end = layers.firstIndex(where: { $0.id == via.endLayer }) else {
                throw failure("via_span_missing", "via.layers", via.id)
            }
            result.append(.init(id: via.id, start: via.position, end: nil, diameter: try dimension(via.drill, path: "via.drill", id: via.id), plated: true,
                                from: min(start, end) + 1, to: max(start, end) + 1))
        }
        for fp in board.footprints.sorted(by: uuidOrder) {
            try check(cancelled)
            guard fp.side == "F.Cu" || fp.side == "B.Cu" else { throw failure("footprint_side_unsupported", "footprint.side", fp.id) }
            guard let definition = definitions[fp.definitionID] else { throw failure("missing_footprint_definition", "footprint.definitionID", fp.id) }
            for pad in definition.pads.sorted(by: uuidOrder) {
                guard let diameter = pad.drill else { continue }
                guard let plated = pad.drillPlated else { throw failure("pad_drill_plating_unspecified", "pad.drillPlated", pad.id) }
                result.append(.init(id: pad.id, start: fp.point(pad.position), end: nil, diameter: try dimension(diameter, path: "pad.drill", id: pad.id),
                                    plated: plated, from: 1, to: layers.count))
            }
        }
        guard result.count <= 100_000 else { throw EDAError.invalid("manufacturing drill budget") }
        return result
    }

    private static func gerber(_ objects: [Copper], function: String, project: EDAProject, board: EDABoard,
                              cancelled: @Sendable () -> Bool) throws -> Data {
        guard objects.count <= 100_000 else { throw EDAError.invalid("manufacturing copper budget") }
        let apertures = Set(objects.compactMap(\.aperture)).sorted { $0.key < $1.key }
        guard apertures.count <= 990 else { throw EDAError.invalid("Gerber aperture budget") }
        let codes = Dictionary(uniqueKeysWithValues: apertures.enumerated().map { ($0.element, $0.offset + 10) })
        var writer = Writer()
        try writer.emit("G04 Floe project \(project.id.uuidString) board \(board.id.uuidString) revision \(project.revision)*")
        try writer.emit("%FSLAX66Y66*%"); try writer.emit("%MOMM*%")
        try writer.emit("%TF.FileFunction,\(function)*%"); try writer.emit("%TF.FilePolarity,Positive*%")
        try writer.emit("%LPD*%")
        for aperture in apertures {
            try check(cancelled)
            let code = codes[aperture]!
            switch aperture {
            case .circle(let d): try writer.emit("%ADD\(code)C,\(d)*%")
            case let .rectangle(w, h, a):
                try writer.emit("%AMFLOE\(code)*21,1,\(w),\(h),0,0,\(a)*%")
                try writer.emit("%ADD\(code)FLOE\(code)*%")
            case let .oval(w, h, a):
                let width = Double(w)!, height = Double(h)!, angle = Double(a)!
                let radius = min(width, height) / 2, half = abs(width - height) / 2
                if half < 0.000_000_5 { try writer.emit("%ADD\(code)C,\(number(radius * 2))*%") }
                else {
                    let direction = angle + (width >= height ? 0 : 90), radians = direction * .pi / 180
                    let x = half * cos(radians), y = half * sin(radians)
                    try writer.emit("%AMFLOE\(code)*21,1,\(number(half * 2)),\(number(radius * 2)),0,0,\(number(direction, decimals: 9))*1,1,\(number(radius * 2)),\(number(-x, decimals: 9)),\(number(-y, decimals: 9)),0*1,1,\(number(radius * 2)),\(number(x, decimals: 9)),\(number(y, decimals: 9)),0*%")
                    try writer.emit("%ADD\(code)FLOE\(code)*%")
                }
            }
        }
        try writer.emit("G01*")
        for object in objects {
            try check(cancelled)
            switch object {
            case let .flash(aperture, p):
                try writer.emit("D\(codes[aperture]!)*"); try writer.emit(coordinate(p) + "D03*")
            case let .track(aperture, points):
                try writer.emit("D\(codes[aperture]!)*"); try writer.emit(coordinate(points[0]) + "D02*")
                if points.dropFirst().allSatisfy({ $0.distance(to: points[0]) < EDAGeometry.tolerance }) {
                    try writer.emit(coordinate(points[0]) + "D03*")
                } else {
                    for p in points.dropFirst() { try check(cancelled); try writer.emit(coordinate(p) + "D01*") }
                }
            case .region(let points):
                try writer.emit("G36*"); try writer.emit(coordinate(points[0]) + "D02*")
                for p in points.dropFirst() { try check(cancelled); try writer.emit(coordinate(p) + "D01*") }
                try writer.emit(coordinate(points[0]) + "D01*"); try writer.emit("G37*")
            }
        }
        try writer.emit("M02*"); return writer.data
    }

    private static func excellon(_ objects: [Drill], function: String, project: EDAProject, board: EDABoard,
                                cancelled: @Sendable () -> Bool) throws -> Data {
        let sizes = Set(objects.map(\.diameter)).sorted { Double($0)! < Double($1)! }
        guard sizes.count <= 99 else { throw EDAError.invalid("Excellon tool budget") }
        let tools = Dictionary(uniqueKeysWithValues: sizes.enumerated().map { ($0.element, $0.offset + 1) })
        var writer = Writer()
        try writer.emit("; Floe project \(project.id.uuidString) board \(board.id.uuidString) revision \(project.revision)")
        try writer.emit("; #@! TF.FileFunction,\(function)")
        try writer.emit("M48"); try writer.emit("METRIC")
        for size in sizes { try writer.emit("T" + two(tools[size]!) + "C" + size) }
        try writer.emit("%")
        for size in sizes {
            try check(cancelled)
            try writer.emit("G05"); try writer.emit("T" + two(tools[size]!))
            for object in objects.filter({ $0.diameter == size && $0.end == nil }) {
                try check(cancelled); try writer.emit(decimalCoordinate(object.start))
            }
            for object in objects.filter({ $0.diameter == size && $0.end != nil }) {
                try check(cancelled)
                try writer.emit("G00" + decimalCoordinate(object.start)); try writer.emit("T" + two(tools[size]!))
                try writer.emit("M15"); try writer.emit("G01" + decimalCoordinate(object.end!)); try writer.emit("M16")
            }
        }
        try writer.emit("M30"); return writer.data
    }

    private static func record(_ file: EDAExchangeFile, function: String, layers: [Int], objects: Int, drills: Int = 0, slots: Int = 0) -> FileRecord {
        .init(name: file.name, mimeType: file.mimeType, sha256: file.sha256, byteCount: file.data.count, function: function,
              layerNumbers: layers, objectCount: objects, drillCount: drills, slotCount: slots)
    }
    private static func add(_ file: EDAExchangeFile, to files: inout [EDAExchangeFile]) throws {
        guard files.count < 500, files.reduce(file.data.count, { $0 + $1.data.count }) <= 128 * 1_024 * 1_024 else {
            throw EDAError.invalid("manufacturing bundle budget")
        }
        files.append(file)
    }
    private static func dimension(_ value: Double, path: String, id: UUID) throws -> String {
        guard value.isFinite, value >= 0.000_001, value <= 100_000 else { throw failure("dimension_below_resolution_or_out_of_range", path, id) }
        return number(value)
    }
    private static func coordinate(_ p: EDAPoint) throws -> String {
        guard p.x.isFinite, p.y.isFinite, abs(p.x) <= 999_999.999_999, abs(p.y) <= 999_999.999_999 else {
            throw failure("coordinate_out_of_range", "geometry")
        }
        return "X\(Int64((p.x * 1_000_000).rounded()))Y\(Int64((p.y * 1_000_000).rounded()))"
    }
    private static func decimalCoordinate(_ p: EDAPoint) throws -> String { _ = try coordinate(p); return "X" + number(p.x) + "Y" + number(p.y) }
    private static func number(_ value: Double, decimals: Int = 6) -> String {
        let v = abs(value) < pow(10, -Double(decimals)) / 2 ? 0 : value
        return String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), decimals, v)
    }
    private static func two(_ value: Int) -> String { String(format: "%02d", locale: Locale(identifier: "en_US_POSIX"), value) }
    private static func normalAngle(_ value: Double) -> Double { let angle = value.truncatingRemainder(dividingBy: 360); return angle < 0 ? angle + 360 : angle }
    private static func opposite(_ layer: String) -> String {
        if layer.hasPrefix("F.") { return "B." + layer.dropFirst(2) }
        if layer.hasPrefix("B.") { return "F." + layer.dropFirst(2) }
        return layer
    }
    private static func check(_ cancelled: @Sendable () -> Bool) throws { if cancelled() { throw EDAError.cancelled } }
    private static func uuidOrder<T: Identifiable>(_ a: T, _ b: T) -> Bool where T.ID == UUID { a.id.uuidString < b.id.uuidString }
    private static func failure(_ code: String, _ path: String, _ id: UUID? = nil) -> EDAManufacturingFailure {
        .init(issues: [.init(code: code, path: path, objectID: id)])
    }
}

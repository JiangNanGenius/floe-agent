// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum EDAValidation {
    public static func validate(_ project: EDAProject) throws {
        guard project.schemaVersion == 1 else { throw EDAError.unsupported("project schema") }
        guard project.title.utf8.count <= 4096, project.sheets.count <= 1000,
              !project.sheets.isEmpty, project.boards.count <= 100,
              project.components.count <= 100_000, project.symbols.count <= 100_000,
              project.footprints.count <= 100_000 else { throw EDAError.invalid("project limits") }
        func unique<T: Hashable>(_ ids: [T], _ label: String) throws {
            guard Set(ids).count == ids.count else { throw EDAError.duplicate(label) }
        }
        func finite(_ values: Double...) throws {
            guard values.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else { throw EDAError.invalid("non-finite geometry") }
        }
        func points(_ values: [EDAPoint], min count: Int = 0) throws {
            guard values.count >= count, values.count <= 200_000, values.allSatisfy(\.isValid) else {
                throw EDAError.invalid("geometry points")
            }
        }
        func positive(_ value: Double) throws {
            guard value.isFinite, value > 0, value <= 100_000 else { throw EDAError.invalid("positive dimension") }
        }
        func graphics(_ values: [EDAGraphic]) throws {
            guard values.count <= 200_000 else { throw EDAError.invalid("graphic limits") }
            for g in values {
                switch g {
                case .line(let a, let b, let width), .rectangle(let a, let b, let width):
                    try points([a, b]); try positive(width)
                case .circle(let center, let radius, let width):
                    try points([center]); try positive(radius); try positive(width)
                case .arc(let center, let radius, let start, let sweep, let width):
                    try points([center]); try positive(radius); try positive(width); try finite(start, sweep)
                    guard abs(sweep) <= 360 else { throw EDAError.invalid("arc sweep") }
                case .text(let text, let point, let height, let angle):
                    try points([point]); try positive(height); try finite(angle)
                    guard text.utf8.count <= 1_048_576 else { throw EDAError.invalid("text limits") }
                case .dimension(let a, let b, let offset): try points([a, b]); try finite(offset)
                }
            }
        }
        try unique(project.components.map(\.id), "components")
        try unique(project.symbols.map(\.id), "symbols")
        try unique(project.footprints.map(\.id), "footprints")
        try unique(project.sheets.map(\.id), "sheets")
        try unique(project.boards.map(\.id), "boards")
        let componentIDs = Set(project.components.map(\.id)), sheetIDs = Set(project.sheets.map(\.id))
        for definition in project.symbols {
            try unique(definition.pins.map(\.id), "symbol pin IDs")
            try unique(definition.pins.map { "\($0.unit):\($0.number)" }, "symbol pin numbers")
            for pin in definition.pins {
                guard !pin.number.isEmpty, pin.unit >= 0, pin.position.isValid else { throw EDAError.invalid("symbol pin") }
            }
            try graphics(definition.graphics)
        }
        for definition in project.footprints {
            try unique(definition.pads.map(\.id), "pad IDs")
            for pad in definition.pads {
                try points([pad.position]); try finite(pad.angle); try positive(pad.size.x); try positive(pad.size.y)
                guard !pad.layers.isEmpty else { throw EDAError.invalid("pad layers") }
                if let drill = pad.drill { try positive(drill) }
                if pad.drill == nil && pad.drillPlated != nil { throw EDAError.invalid("pad plating without drill") }
            }
            try graphics(definition.graphics)
            try EDAGraphicLayers.validateLayout(graphics: definition.graphics, layers: definition.graphicLayers)
        }
        let nonEntryIDs = EDABusEditing.objectIDs(project, includeEntries: false)
        var entryIDs: Set<UUID> = []
        var parent: [UUID: UUID] = [:]
        for sheet in project.sheets {
            let ids = sheet.symbols.map(\.id) + sheet.wires.map(\.id) + sheet.junctions.map(\.id)
                + sheet.labels.map(\.id) + sheet.noConnects.map(\.id) + sheet.buses.map(\.id) + sheet.children.map(\.id)
            try unique(ids, "sheet object IDs")
            let entryCount = sheet.buses.reduce(0) { $0 + ($1.entries?.count ?? 0) }
            guard ids.count <= 200_000, entryCount <= EDABusEditing.maximumEntries,
                  ids.count + entryCount <= 200_000 else { throw EDAError.invalid("sheet limits") }
            for placement in sheet.symbols {
                guard componentIDs.contains(placement.componentID), placement.unit > 0 else { throw EDAError.missing("component") }
                try points([placement.position]); try finite(placement.angle)
            }
            for wire in sheet.wires { try points(wire.points, min: 2) }
            try points(sheet.junctions.map(\.position) + sheet.noConnects.map(\.position))
            for label in sheet.labels {
                try points([label.position]); guard !label.name.isEmpty, label.name.utf8.count <= 4096 else { throw EDAError.invalid("net label") }
            }
            for bus in sheet.buses {
                try points(bus.points, min: 2)
                for entry in bus.entries ?? [] {
                    try points([entry.busPosition, entry.wirePosition])
                    guard entry.busPosition.distance(to: entry.wirePosition) > EDAGeometry.tolerance else { throw EDAError.invalid("zero-length bus entry") }
                    guard !nonEntryIDs.contains(entry.id), entryIDs.insert(entry.id).inserted else { throw EDAError.duplicate("global bus entry ID") }
                    guard entryIDs.count <= EDABusEditing.maximumEntries else { throw EDAError.invalid("bus entry limits") }
                }
            }
            for link in sheet.children {
                guard sheetIDs.contains(link.childSheetID), parent[link.childSheetID] == nil,
                      link.childSheetID != sheet.id else { throw EDAError.invalid("sheet hierarchy") }
                parent[link.childSheetID] = sheet.id
                try unique(link.ports.map(\.name), "sheet port names")
                try points(link.ports.map(\.position))
            }
            try graphics(sheet.graphics)
        }
        for id in sheetIDs {
            var seen = Set<UUID>(), next: UUID? = id
            while let value = next {
                guard seen.insert(value).inserted else { throw EDAError.invalid("cyclic sheets") }
                next = parent[value]
            }
        }
        for board in project.boards {
            try unique(board.layers.map(\.id), "board layers")
            let copper = Set(board.layers.filter { $0.kind == .copper }.map(\.id))
            guard !copper.isEmpty else { throw EDAError.invalid("copper stackup") }
            for layer in board.layers { try finite(layer.thickness); guard layer.thickness >= 0 else { throw EDAError.invalid("layer thickness") } }
            try points(board.outline, min: 3)
            guard EDAGeometry.simplePolygon(board.outline) else { throw EDAError.invalid("board outline") }
            for cutout in board.cutouts {
                try points(cutout, min: 3)
                guard EDAGeometry.simplePolygon(cutout) else { throw EDAError.invalid("board cutout") }
            }
            try unique(board.footprints.map(\.id) + board.tracks.map(\.id) + board.vias.map(\.id)
                + board.zones.map(\.id) + board.holes.map(\.id) + board.keepouts.map(\.id), "board object IDs")
            for footprint in board.footprints { try points([footprint.position]); try finite(footprint.angle) }
            for track in board.tracks {
                try points(track.points, min: 2); try positive(track.width)
                guard copper.contains(track.layer) else { throw EDAError.invalid("track layer") }
            }
            for via in board.vias {
                try points([via.position]); try positive(via.diameter); try positive(via.drill)
                guard via.drill < via.diameter, copper.contains(via.startLayer), copper.contains(via.endLayer),
                      via.startLayer != via.endLayer else { throw EDAError.invalid("via geometry") }
            }
            for hole in board.holes {
                try points([hole.position]); try positive(hole.diameter)
                if let end = hole.endPosition {
                    try points([end])
                    guard end.distance(to: hole.position) > EDAGeometry.tolerance else { throw EDAError.invalid("slot endpoint") }
                }
            }
            for zone in board.zones {
                try points(zone.outline, min: 3); try positive(zone.clearance)
                guard copper.contains(zone.layer), EDAGeometry.simplePolygon(zone.outline) else { throw EDAError.invalid("zone") }
                if let relief = zone.thermalRelief {
                    try positive(relief.gap); try positive(relief.spokeWidth); try finite(relief.spokeAngleDegrees)
                    guard relief.spokeCount == 4 else { throw EDAError.unsupported("thermal spoke count") }
                }
                if let state = zone.fillState {
                    guard zone.fillRevision != nil,
                          (state == .empty) == zone.filledPolygons.isEmpty else { throw EDAError.invalid("zone fill state") }
                }
                for polygon in zone.filledPolygons {
                    try points(polygon, min: 3)
                    guard EDAGeometry.simplePolygon(polygon) else { throw EDAError.invalid("zone fill") }
                }
            }
            for area in board.keepouts {
                guard EDAGeometry.simplePolygon(area.outline) else { throw EDAError.invalid("keepout") }
            }
            try positive(board.boardEdgeClearance)
            if let constraints = board.drcConstraints {
                for value in [constraints.minimumCopperClearance, constraints.minimumTrackWidth, constraints.minimumViaDiameter,
                              constraints.minimumViaDrill, constraints.minimumViaAnnularWidth].compactMap({ $0 }) {
                    guard value.isFinite, value >= 0, value <= 100_000 else { throw EDAError.invalid("DRC minimum constraint") }
                }
            }
            for rule in board.netClasses {
                try positive(rule.clearance); try positive(rule.trackWidth); try positive(rule.viaDiameter)
                try positive(rule.viaDrill); try positive(rule.differentialGap)
                guard rule.viaDrill < rule.viaDiameter else { throw EDAError.invalid("via rule") }
                if let v = rule.targetLength { try positive(v) }
                if let v = rule.maxSkew { try positive(v) }
            }
            try graphics(board.graphics)
            try EDAGraphicLayers.validateLayout(graphics: board.graphics, layers: board.graphicLayers)
        }
    }
}

// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeElectronicsCore

/// Pure canvas selection/edit planning. The caller commits the returned batch
/// through the existing session/revision/CAS/undo boundary.
enum EDCanvasInteraction {
    enum Action: Hashable, CaseIterable { case rotate, flip, duplicate, delete }
    private static let duplicateOffset = EDAPoint(2.54, 2.54)

    static func hit(project: EDAProject, context: EDADocumentContext, at point: EDAPoint, tolerance: Double) -> UUID? {
        guard point.isValid, tolerance.isFinite, tolerance >= 0 else { return nil }
        var best: (distance: Double, priority: Int, id: UUID)?
        func consider(_ distance: Double, _ id: UUID, _ priority: Int = 0) {
            guard distance.isFinite, distance <= tolerance else { return }
            if let old = best {
                if distance > old.distance + 1e-9 { return }
                if abs(distance - old.distance) <= 1e-9 {
                    if priority > old.priority || (priority == old.priority && id.uuidString >= old.id.uuidString) { return }
                }
            }
            best = (distance, priority, id)
        }
        switch context {
        case .board(let id):
            guard let board = project.boards.first(where: { $0.id == id }) else { return nil }
            let definitions = Dictionary(project.footprints.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for footprint in board.footprints {
                guard let definition = definitions[footprint.definitionID] else { continue }
                let local = inverse(point, origin: footprint.position, angle: footprint.angle, mirrored: footprint.side == "B.Cu")
                for pad in definition.pads { consider(padDistance(local, pad), footprint.id) }
                for graphic in definition.graphics { consider(graphicDistance(local, graphic), footprint.id, 4) }
            }
            for via in board.vias { consider(max(0, point.distance(to: via.position) - via.diameter / 2), via.id, 1) }
            for hole in board.holes {
                consider(max(0, EDAGeometry.pointDistance(point, to: hole.position, hole.endPosition ?? hole.position) - hole.diameter / 2), hole.id, 2)
            }
            for track in board.tracks { consider(max(0, lineDistance(point, track.points) - track.width / 2), track.id, 3) }
            for zone in board.zones { consider(boundaryDistance(point, zone.outline), zone.id, 8) }
            for keepout in board.keepouts { consider(boundaryDistance(point, keepout.outline), keepout.id, 8) }
        case .schematic(let id):
            guard let sheet = project.sheets.first(where: { $0.id == id }) else { return nil }
            let components = Dictionary(project.components.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let definitions = Dictionary(project.symbols.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for placement in sheet.symbols {
                guard let component = components[placement.componentID], let definition = definitions[component.symbolID] else { continue }
                let local = inverse(point, origin: placement.position, angle: placement.angle, mirrored: placement.mirrored)
                for pin in definition.pins where pin.unit == 0 || pin.unit == placement.unit {
                    consider(max(0, local.distance(to: pin.position) - 0.2), placement.id)
                }
                for graphic in definition.graphics { consider(graphicDistance(local, graphic), placement.id, 4) }
            }
            for wire in sheet.wires { consider(lineDistance(point, wire.points), wire.id, 3) }
            for bus in sheet.buses { consider(max(0, lineDistance(point, bus.points) - 0.3), bus.id, 3) }
            for junction in sheet.junctions { consider(max(0, point.distance(to: junction.position) - 0.4), junction.id, 1) }
            for mark in sheet.noConnects {
                let a = EDAPoint(0.6, 0.6), b = EDAPoint(0.6, -0.6)
                consider(min(EDAGeometry.pointDistance(point, to: mark.position - a, mark.position + a),
                             EDAGeometry.pointDistance(point, to: mark.position - b, mark.position + b)), mark.id, 1)
            }
            // Text has no measured glyph bounds in the model; use its explicit
            // anchor, never invent a character-count rectangle.
            for label in sheet.labels { consider(point.distance(to: label.position), label.id, 2) }
            for child in sheet.children { for port in child.ports { consider(point.distance(to: port.position), child.id, 2) } }
        case .symbol(let id):
            guard let definition = project.symbols.first(where: { $0.id == id }) else { return nil }
            for pin in definition.pins { consider(max(0, point.distance(to: pin.position) - 0.2), pin.id) }
        case .footprint(let id):
            guard let definition = project.footprints.first(where: { $0.id == id }) else { return nil }
            for pad in definition.pads { consider(padDistance(point, pad), pad.id) }
        }
        // EDAGraphic has no UUID. Existing library graphic-index editing owns
        // those objects; this API does not fabricate IDs for array entries.
        return best?.id
    }

    static func availableActions(project: EDAProject, context: EDADocumentContext, objectIDs: Set<UUID>) -> Set<Action> {
        guard let items = try? selection(project, context, objectIDs), !items.isEmpty else { return [] }
        var result = Set(Action.allCases)
        for item in items {
            if item.locked { return [] }
            var allowed: Set<Action> = [.duplicate, .delete]
            if item.oriented || items.count > 1 { allowed.insert(.rotate) }
            switch context {
            case .board(let id):
                if let board = project.boards.first(where: { $0.id == id }), let reverse = try? flipped(item, board: board),
                   item.oriented || items.count > 1 || reverse != item { allowed.insert(.flip) }
            case .schematic:
                if item.oriented || items.count > 1 { allowed.insert(.flip) }
                if case .link = item { allowed.remove(.duplicate) }
            case .symbol, .footprint: break // No library-side/mirror field exists.
            }
            result.formIntersection(allowed)
        }
        return result
    }

    static func edits(for action: Action, project: EDAProject, context: EDADocumentContext, objectIDs: Set<UUID>) throws -> [EDAEdit] {
        let items = try selection(project, context, objectIDs)
        guard !items.isEmpty else { return [] }
        guard availableActions(project: project, context: context, objectIDs: objectIDs).contains(action) else {
            if items.contains(where: \.locked) { throw EDAError.readOnly }
            throw EDAError.unsupported("selected canvas action")
        }
        if action == .delete { return try removal(items, project: project, context: context) }
        let pivot = center(items.flatMap(\.points))
        var components: [UUID: EDAComponent] = [:], usedReferences = Set(project.components.map { $0.reference.uppercased() })
        for board in project.boards { usedReferences.formUnion(board.footprints.map { $0.reference.uppercased() }) }
        func copiedComponent(_ id: UUID) throws -> EDAComponent {
            if let value = components[id] { return value }
            guard var value = project.components.first(where: { $0.id == id }) else { throw EDAError.missing("selected component") }
            value.id = UUID(); value.reference = nextReference(value.reference, used: &usedReferences)
            components[id] = value; return value
        }
        var updated: [Item] = []
        for original in items {
            var value = original
            switch action {
            case .rotate: value = original.mapped(point: { rotate($0, around: pivot) }, angle: { normalized($0 + 90) })
            case .flip:
                switch context {
                case .board(let id):
                    guard let board = project.boards.first(where: { $0.id == id }) else { throw EDAError.missing("board") }
                    value = try flipped(original, board: board)
                default: break
                }
                value = value.mapped(point: { .init(2 * pivot.x - $0.x, $0.y) }, angle: { normalized(-$0) })
                if case .placement(var placed) = value { placed.mirrored.toggle(); value = .placement(placed) }
                if case .zone(var zone) = value, var relief = zone.thermalRelief {
                    relief.spokeAngleDegrees = normalized(relief.spokeAngleDegrees + 180); zone.thermalRelief = relief; value = .zone(zone)
                }
            case .duplicate:
                value = original.copy().mapped(point: { $0 + duplicateOffset }, angle: { $0 })
                if case .placement(var placed) = value { placed.componentID = try copiedComponent(placed.componentID).id; value = .placement(placed) }
                if case .footprint(var footprint) = value {
                    if let id = footprint.componentID { let component = try copiedComponent(id); footprint.componentID = component.id; footprint.reference = component.reference }
                    else { footprint.reference = nextReference(footprint.reference, used: &usedReferences) }
                    value = .footprint(footprint)
                }
            case .delete: break
            }
            updated.append(value)
        }
        let componentEdits = components.values.sorted { $0.id.uuidString < $1.id.uuidString }.map(EDAEdit.putComponent)
        return componentEdits + (try put(updated, project: project, context: context, append: action == .duplicate))
    }

    static func move(project: EDAProject, context: EDADocumentContext, objectIDs: Set<UUID>, by delta: EDAPoint) throws -> [EDAEdit] {
        guard delta.isValid else { throw EDAError.invalid("canvas displacement") }
        let items = try selection(project, context, objectIDs)
        guard !items.contains(where: \.locked) else { throw EDAError.readOnly }
        guard delta != .zero, !items.isEmpty else { return [] }
        let values = items.map { $0.mapped(point: { $0 + delta }, angle: { $0 }) }
        guard values.flatMap(\.points).allSatisfy(\.isValid) else { throw EDAError.invalid("canvas position") }
        return try put(values, project: project, context: context, append: false)
    }

    private enum Item: Equatable {
        case placement(EDASymbolPlacement), wire(EDAWire), junction(EDAJunction), label(EDANetLabel), noConnect(EDAJunction), bus(EDABus), link(EDASheetLink)
        case footprint(EDAFootprint), track(EDATrack), via(EDAVia), zone(EDAZone), keepout(EDAKeepout), hole(EDAHole)
        case pin(EDAPin), pad(EDAPad)
        var id: UUID { switch self {
        case .placement(let v): v.id; case .wire(let v): v.id; case .junction(let v): v.id; case .label(let v): v.id
        case .noConnect(let v): v.id; case .bus(let v): v.id; case .link(let v): v.id; case .footprint(let v): v.id
        case .track(let v): v.id; case .via(let v): v.id; case .zone(let v): v.id; case .keepout(let v): v.id
        case .hole(let v): v.id; case .pin(let v): v.id; case .pad(let v): v.id } }
        var locked: Bool { switch self { case .footprint(let v): v.locked; case .track(let v): v.locked; default: false } }
        var oriented: Bool { switch self {
        case .placement, .footprint, .track, .wire, .bus, .zone, .keepout, .pad: true
        case .hole(let v): v.endPosition != nil
        default: false } }
        var points: [EDAPoint] { switch self {
        case .placement(let v): [v.position]; case .wire(let v): v.points; case .junction(let v): [v.position]
        case .label(let v): [v.position]; case .noConnect(let v): [v.position]; case .bus(let v): v.points
        case .link(let v): v.ports.map(\.position); case .footprint(let v): [v.position]; case .track(let v): v.points
        case .via(let v): [v.position]; case .zone(let v): v.outline; case .keepout(let v): v.outline
        case .hole(let v): [v.position] + (v.endPosition.map { [$0] } ?? []); case .pin(let v): [v.position]; case .pad(let v): [v.position] } }
        func copy() -> Item { let id = UUID(); switch self {
        case .placement(var v): v.id = id; return .placement(v); case .wire(var v): v.id = id; return .wire(v)
        case .junction(var v): v.id = id; return .junction(v); case .label(var v): v.id = id; return .label(v)
        case .noConnect(var v): v.id = id; return .noConnect(v); case .bus(var v): v.id = id; return .bus(v)
        case .link(var v): v.id = id; return .link(v); case .footprint(var v): v.id = id; return .footprint(v)
        case .track(var v): v.id = id; return .track(v); case .via(var v): v.id = id; return .via(v)
        case .zone(var v): v.id = id; return .zone(v); case .keepout(var v): v.id = id; return .keepout(v)
        case .hole(var v): v.id = id; return .hole(v); case .pin(var v): v.id = id; return .pin(v); case .pad(var v): v.id = id; return .pad(v) } }
        func mapped(point: (EDAPoint) -> EDAPoint, angle: (Double) -> Double) -> Item { switch self {
        case .placement(var v): v.position = point(v.position); v.angle = angle(v.angle); return .placement(v)
        case .wire(var v): v.points = v.points.map(point); return .wire(v)
        case .junction(var v): v.position = point(v.position); return .junction(v)
        case .label(var v): v.position = point(v.position); return .label(v)
        case .noConnect(var v): v.position = point(v.position); return .noConnect(v)
        case .bus(var v): v.points = v.points.map(point); return .bus(v)
        case .link(var v): for i in v.ports.indices { v.ports[i].position = point(v.ports[i].position) }; return .link(v)
        case .footprint(var v): v.position = point(v.position); v.angle = angle(v.angle); return .footprint(v)
        case .track(var v): v.points = v.points.map(point); return .track(v)
        case .via(var v): v.position = point(v.position); return .via(v)
        case .zone(var v):
            v.outline = v.outline.map(point); v.filledPolygons = []; v.fillRevision = nil; v.fillState = nil
            if var relief = v.thermalRelief { relief.spokeAngleDegrees = angle(relief.spokeAngleDegrees); v.thermalRelief = relief }; return .zone(v)
        case .keepout(var v): v.outline = v.outline.map(point); return .keepout(v)
        case .hole(var v): v.position = point(v.position); v.endPosition = v.endPosition.map(point); return .hole(v)
        case .pin(var v): v.position = point(v.position); return .pin(v)
        case .pad(var v): v.position = point(v.position); v.angle = angle(v.angle); return .pad(v) } }
    }

    private static func selection(_ project: EDAProject, _ context: EDADocumentContext, _ ids: Set<UUID>) throws -> [Item] {
        var all: [Item] = []
        switch context {
        case .board(let id):
            guard let v = project.boards.first(where: { $0.id == id }) else { throw EDAError.missing("board") }
            all.append(contentsOf: v.footprints.map(Item.footprint)); all.append(contentsOf: v.tracks.map(Item.track))
            all.append(contentsOf: v.vias.map(Item.via)); all.append(contentsOf: v.zones.map(Item.zone))
            all.append(contentsOf: v.keepouts.map(Item.keepout)); all.append(contentsOf: v.holes.map(Item.hole))
        case .schematic(let id):
            guard let v = project.sheets.first(where: { $0.id == id }) else { throw EDAError.missing("sheet") }
            all.append(contentsOf: v.symbols.map(Item.placement)); all.append(contentsOf: v.wires.map(Item.wire))
            all.append(contentsOf: v.junctions.map(Item.junction)); all.append(contentsOf: v.labels.map(Item.label))
            all.append(contentsOf: v.noConnects.map(Item.noConnect)); all.append(contentsOf: v.buses.map(Item.bus))
            all.append(contentsOf: v.children.map(Item.link))
        case .symbol(let id):
            guard let v = project.symbols.first(where: { $0.id == id }) else { throw EDAError.missing("symbol") }; all = v.pins.map(Item.pin)
        case .footprint(let id):
            guard let v = project.footprints.first(where: { $0.id == id }) else { throw EDAError.missing("footprint definition") }; all = v.pads.map(Item.pad)
        }
        let selected = all.filter { ids.contains($0.id) }
        guard selected.count == ids.count else { throw EDAError.missing("selected canvas object") }
        return selected.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    private static func removal(_ values: [Item], project: EDAProject, context: EDADocumentContext) throws -> [EDAEdit] {
        switch context {
        case .board(let id): return values.map { .removeBoardObject(board: id, object: $0.id) }
        case .schematic(let id): return values.map { .removeSchematicObject(sheet: id, object: $0.id) }
        case .symbol(let id):
            guard var definition = project.symbols.first(where: { $0.id == id }) else { throw EDAError.missing("symbol") }
            let ids = Set(values.map(\.id)); definition.pins.removeAll { ids.contains($0.id) }; return [.putSymbol(definition)]
        case .footprint(let id):
            guard var definition = project.footprints.first(where: { $0.id == id }) else { throw EDAError.missing("footprint definition") }
            let ids = Set(values.map(\.id)); definition.pads.removeAll { ids.contains($0.id) }; return [.putFootprintDefinition(definition)]
        }
    }
    private static func put(_ values: [Item], project: EDAProject, context: EDADocumentContext, append: Bool) throws -> [EDAEdit] {
        switch context {
        case .board(let id): return try values.map { value in switch value {
            case .footprint(let v): .putFootprint(board: id, v); case .track(let v): .putTrack(board: id, v); case .via(let v): .putVia(board: id, v)
            case .zone(let v): .putZone(board: id, v); case .keepout(let v): .putKeepout(board: id, v); case .hole(let v): .putHole(board: id, v)
            default: throw EDAError.invalid("board canvas object") } }
        case .schematic(let id): return try values.map { value in switch value {
            case .placement(let v): .placeSymbol(sheet: id, v); case .wire(let v): .putWire(sheet: id, v); case .junction(let v): .putJunction(sheet: id, v)
            case .label(let v): .putLabel(sheet: id, v); case .noConnect(let v): .putNoConnect(sheet: id, v); case .bus(let v): .putBus(sheet: id, v)
            case .link(let v): .putSheetLink(sheet: id, v); default: throw EDAError.invalid("schematic canvas object") } }
        case .symbol(let id):
            guard var definition = project.symbols.first(where: { $0.id == id }) else { throw EDAError.missing("symbol") }
            for item in values {
                guard case .pin(var v) = item else { throw EDAError.invalid("symbol pin") }
                if append { var number = 1; let used = Set(definition.pins.filter { $0.unit == v.unit }.map(\.number)); while used.contains(String(number)) { number += 1 }; v.number = String(number); definition.pins.append(v) }
                else if let i = definition.pins.firstIndex(where: { $0.id == v.id }) { definition.pins[i] = v }
            }
            return [.putSymbol(definition)]
        case .footprint(let id):
            guard var definition = project.footprints.first(where: { $0.id == id }) else { throw EDAError.missing("footprint definition") }
            for item in values {
                guard case .pad(var v) = item else { throw EDAError.invalid("footprint pad") }
                if append { var number = 1; let used = Set(definition.pads.map(\.number)); while used.contains(String(number)) { number += 1 }; v.number = String(number); definition.pads.append(v) }
                else if let i = definition.pads.firstIndex(where: { $0.id == v.id }) { definition.pads[i] = v }
            }
            return [.putFootprintDefinition(definition)]
        }
    }
    private static func flipped(_ item: Item, board: EDABoard) throws -> Item {
        let copper = board.layers.filter { $0.kind == .copper }.map(\.id)
        func layer(_ name: String) throws -> String {
            guard let i = copper.firstIndex(of: name) else { throw EDAError.unsupported("flip requires an explicit copper layer") }
            return copper[copper.count - 1 - i]
        }
        switch item {
        case .footprint(var v):
            guard ["F.Cu", "B.Cu"].contains(v.side), copper.contains("F.Cu"), copper.contains("B.Cu") else { throw EDAError.unsupported("footprint side") }
            v.side = v.side == "F.Cu" ? "B.Cu" : "F.Cu"; return .footprint(v)
        case .track(var v): v.layer = try layer(v.layer); return .track(v)
        case .via(var v): let start = v.startLayer; v.startLayer = try layer(v.endLayer); v.endLayer = try layer(start); return .via(v)
        case .zone(var v): v.layer = try layer(v.layer); return .zone(v)
        case .keepout(var v): v.layers = Set(try v.layers.map(layer)); return .keepout(v)
        case .hole: return item
        default: throw EDAError.unsupported("board flip")
        }
    }
    private static func nextReference(_ reference: String, used: inout Set<String>) -> String {
        let trimmed = String(reference.reversed().drop(while: { $0.isNumber }).reversed())
        let prefix = trimmed.isEmpty ? "U" : trimmed
        var number = 1
        while used.contains((prefix + String(number)).uppercased()) { number += 1 }
        let result = prefix + String(number); used.insert(result.uppercased()); return result
    }
    private static func normalized(_ angle: Double) -> Double { let v = angle.truncatingRemainder(dividingBy: 360); return v < 0 ? v + 360 : v }
    private static func center(_ points: [EDAPoint]) -> EDAPoint {
        guard let bounds = EDAGeometry.bounds(points) else { return .zero }; return (bounds.min + bounds.max) * 0.5
    }
    private static func rotate(_ point: EDAPoint, around pivot: EDAPoint) -> EDAPoint { let d = point - pivot; return pivot + .init(-d.y, d.x) }
    private static func inverse(_ point: EDAPoint, origin: EDAPoint, angle: Double, mirrored: Bool = false) -> EDAPoint {
        var p = (point - origin).transformed(origin: .zero, angle: -angle)
        if mirrored { p.x = -p.x }; return p
    }
    private static func lineDistance(_ point: EDAPoint, _ points: [EDAPoint]) -> Double {
        zip(points, points.dropFirst()).map { EDAGeometry.pointDistance(point, to: $0.0, $0.1) }.min() ?? .infinity
    }
    private static func boundaryDistance(_ point: EDAPoint, _ polygon: [EDAPoint]) -> Double {
        EDAGeometry.edges(polygon).map { EDAGeometry.pointDistance(point, to: $0.0, $0.1) }.min() ?? .infinity
    }
    private static func padDistance(_ point: EDAPoint, _ pad: EDAPad) -> Double {
        let p = inverse(point, origin: pad.position, angle: pad.angle), a = pad.size.x / 2, b = pad.size.y / 2
        guard a > 0, b > 0 else { return .infinity }
        switch pad.shape {
        case .rectangle: return hypot(max(0, abs(p.x) - a), max(0, abs(p.y) - b))
        case .oval:
            let r = min(a, b), end = EDAPoint(a > b ? a - r : 0, a > b ? 0 : b - r)
            return max(0, EDAGeometry.pointDistance(p, to: end * -1, end) - r)
        case .circle:
            let x = abs(p.x), y = abs(p.y)
            if x * x / (a * a) + y * y / (b * b) <= 1 { return 0 }
            // Closest point on the actual ellipse, not its outer rectangle.
            var low = 0.0, high = max(a, b) * hypot(x, y)
            for _ in 0..<64 {
                let t = (low + high) / 2, qx = a * x / (t + a * a), qy = b * y / (t + b * b)
                if qx * qx + qy * qy > 1 { low = t } else { high = t }
            }
            return hypot(x - a * a * x / (high + a * a), y - b * b * y / (high + b * b))
        case .roundRectangle:
            // Corner radius is absent. Only the explicit anchor is known;
            // do not claim the outer rectangle is the actual rounded shape.
            return p.length
        }
    }
    private static func graphicDistance(_ point: EDAPoint, _ graphic: EDAGraphic) -> Double {
        switch graphic {
        case .line(let a, let b, let width): return max(0, EDAGeometry.pointDistance(point, to: a, b) - width / 2)
        case .rectangle(let a, let b, let width): return max(0, boundaryDistance(point, [a, .init(b.x,a.y), b, .init(a.x,b.y)]) - width / 2)
        case .circle(let center, let radius, let width): return max(0, abs(point.distance(to: center) - radius) - width / 2)
        case .arc(let center, let radius, let start, let sweep, let width):
            let d = point - center, angle = atan2(d.y, d.x) * 180 / .pi
            let offset = normalized(sweep >= 0 ? angle - start : start - angle)
            let radial = abs(d.length - radius)
            let a = EDAPoint(radius,0).transformed(origin: center, angle: start)
            let b = EDAPoint(radius,0).transformed(origin: center, angle: start + sweep)
            let distance = abs(sweep) >= 360 || offset <= abs(sweep) ? radial : min(point.distance(to: a), point.distance(to: b))
            return max(0, distance - width / 2)
        case .text(_, let position, _, _): return point.distance(to: position)
        case .dimension(let a, let b, let offset):
            let direction = b - a, n = direction.length > 0 ? EDAPoint(-direction.y, direction.x) * (offset / direction.length) : .zero
            return lineDistance(point, [a, a + n, b + n, b])
        }
    }
}

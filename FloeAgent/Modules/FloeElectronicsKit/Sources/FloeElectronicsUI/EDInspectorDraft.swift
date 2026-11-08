// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeElectronicsCore

/// A property draft is bound to the revision at which its values were read.
/// A change elsewhere never grants a dirty draft permission to overwrite it.
struct EDInspectorDraft<Value: Equatable & Sendable>: Sendable {
    var value: Value
    private(set) var baseline: Value
    private(set) var revision: UInt64
    private(set) var needsReload = false
    var isDirty: Bool { value != baseline }

    init(_ value: Value, revision: UInt64) {
        self.value = value; baseline = value; self.revision = revision
    }
    mutating func receive(_ source: Value, revision: UInt64) {
        guard self.revision != revision || baseline != source else { return }
        guard !isDirty, !needsReload else { needsReload = true; return }
        reload(source, revision: revision)
    }
    mutating func reload(_ source: Value, revision: UInt64) {
        value = source; baseline = source; self.revision = revision; needsReload = false
    }
    mutating func reject() { needsReload = true }
}

struct EDComponentInspectorValue: Equatable, Sendable {
    var placement: EDASymbolPlacement
    var component: EDAComponent
    static func read(_ project: EDAProject, sheetID: UUID, placementID: UUID) -> Self? {
        guard let placement = project.sheets.first(where: { $0.id == sheetID })?.symbols.first(where: { $0.id == placementID }),
              let component = project.components.first(where: { $0.id == placement.componentID }) else { return nil }
        return .init(placement: placement, component: component)
    }
}

/// These are ordinary edits, not a second executor. Existence checks prevent a
/// removed selection from being recreated by a delayed property submission.
enum EDInspectorEdits {
    static func board(_ value: EDABoard, project: EDAProject) throws -> [EDAEdit] {
        guard project.boards.contains(where: { $0.id == value.id }) else { throw EDAError.missing("selected board") }
        return [.putBoard(value)]
    }
    static func symbolDefinition(_ value: EDASymbolDefinition, project: EDAProject) throws -> [EDAEdit] {
        guard project.symbols.contains(where: { $0.id == value.id }) else { throw EDAError.missing("selected symbol") }
        return [.putSymbol(value)]
    }
    static func footprintDefinition(_ value: EDAFootprintDefinition, project: EDAProject) throws -> [EDAEdit] {
        guard project.footprints.contains(where: { $0.id == value.id }) else { throw EDAError.missing("selected footprint definition") }
        return [.putFootprintDefinition(value)]
    }
    static func component(_ value: EDComponentInspectorValue, sheetID: UUID, project: EDAProject) throws -> [EDAEdit] {
        guard let source = EDComponentInspectorValue.read(project, sheetID: sheetID, placementID: value.placement.id),
              source.component.id == value.component.id, value.placement.componentID == value.component.id else {
            throw EDAError.missing("selected component")
        }
        return [.putComponent(value.component), .placeSymbol(sheet: sheetID, value.placement)]
    }
    static func footprint(_ value: EDAFootprint, boardID: UUID, project: EDAProject) throws -> [EDAEdit] {
        guard project.boards.first(where: { $0.id == boardID })?.footprints.contains(where: { $0.id == value.id }) == true else { throw EDAError.missing("selected footprint") }
        return [.putFootprint(board: boardID, value)]
    }
    static func track(_ value: EDATrack, boardID: UUID, project: EDAProject) throws -> [EDAEdit] {
        guard project.boards.first(where: { $0.id == boardID })?.tracks.contains(where: { $0.id == value.id }) == true else { throw EDAError.missing("selected track") }
        return [.putTrack(board: boardID, value)]
    }
    static func via(_ value: EDAVia, boardID: UUID, project: EDAProject) throws -> [EDAEdit] {
        guard project.boards.first(where: { $0.id == boardID })?.vias.contains(where: { $0.id == value.id }) == true else { throw EDAError.missing("selected via") }
        return [.putVia(board: boardID, value)]
    }
    static func hole(_ value: EDAHole, boardID: UUID, project: EDAProject) throws -> [EDAEdit] {
        guard project.boards.first(where: { $0.id == boardID })?.holes.contains(where: { $0.id == value.id }) == true else { throw EDAError.missing("selected hole") }
        return [.putHole(board: boardID, value)]
    }
    static func deleteBoardObject(_ id: UUID, boardID: UUID, project: EDAProject) throws -> [EDAEdit] {
        guard let board = project.boards.first(where: { $0.id == boardID }) else { throw EDAError.missing("selected board") }
        if board.footprints.contains(where: { $0.id == id && $0.locked }) || board.tracks.contains(where: { $0.id == id && $0.locked }) { throw EDAError.readOnly }
        guard board.footprints.contains(where: { $0.id == id }) || board.tracks.contains(where: { $0.id == id }) || board.vias.contains(where: { $0.id == id }) || board.holes.contains(where: { $0.id == id }) else { throw EDAError.missing("selected board object") }
        return [.removeBoardObject(board: boardID, object: id)]
    }
}

/// A read-only slice for the existing EDAPlot renderer. Real geometry, sides,
/// angles, pin/pad identities and definitions are retained; no store is touched.
struct EDInspectorPreviewScene {
    var project: EDAProject
    let context: EDADocumentContext
    let bounds: CGRect

    static func component(_ value: EDComponentInspectorValue, sheetID: UUID, project: EDAProject) -> Self? {
        guard let definition = project.symbols.first(where: { $0.id == value.component.symbolID }) else { return nil }
        var copy = project
        var sheet = EDASheet(id: sheetID, name: "Preview")
        sheet.symbols = [value.placement]; copy.sheets = [sheet]; copy.components = [value.component]
        let local = graphicPoints(definition.graphics) + definition.pins.filter { $0.unit == 0 || $0.unit == value.placement.unit }.map(\.position)
        let points = local.map { $0.transformed(origin: value.placement.position, angle: value.placement.angle, mirrored: value.placement.mirrored) }
        return .init(project: copy, context: .schematic(sheetID: sheetID), bounds: fitted(points + [value.placement.position + .init(0, 6)]))
    }
    static func footprint(_ value: EDAFootprint, boardID: UUID, project: EDAProject) -> Self? {
        guard let definition = project.footprints.first(where: { $0.id == value.definitionID }) else { return nil }
        var board = emptyBoard(boardID); board.footprints = [value]
        return boardScene(board, project: project, points: (graphicPoints(definition.graphics) + padPoints(definition.pads)).map(value.point) + [value.position + .init(0, 6)])
    }
    static func track(_ value: EDATrack, boardID: UUID, project: EDAProject) -> Self {
        var board = emptyBoard(boardID); board.tracks = [value]
        return boardScene(board, project: project, points: value.points)
    }
    static func via(_ value: EDAVia, boardID: UUID, project: EDAProject) -> Self {
        var board = emptyBoard(boardID); board.vias = [value]
        let radius = value.diameter / 2
        return boardScene(board, project: project, points: [value.position - .init(radius, radius), value.position + .init(radius, radius)])
    }
    static func hole(_ value: EDAHole, boardID: UUID, project: EDAProject) -> Self {
        var board = emptyBoard(boardID); board.holes = [value]
        let radius = value.diameter / 2
        let ends = [value.position, value.endPosition ?? value.position]
        return boardScene(board, project: project, points: ends.flatMap { [$0 - .init(radius, radius), $0 + .init(radius, radius)] })
    }
    static func symbol(_ value: EDASymbolDefinition, project: EDAProject) -> Self {
        var copy = project; copy.symbols = [value]
        return .init(project: copy, context: .symbol(definitionID: value.id), bounds: fitted(graphicPoints(value.graphics) + value.pins.map(\.position)))
    }
    static func libraryFootprint(_ value: EDAFootprintDefinition, project: EDAProject) -> Self {
        var copy = project; copy.footprints = [value]
        return .init(project: copy, context: .footprint(definitionID: value.id), bounds: fitted(graphicPoints(value.graphics) + padPoints(value.pads)))
    }
    private static func emptyBoard(_ id: UUID) -> EDABoard { EDABoard(id: id, name: "Preview", outline: []) }
    private static func boardScene(_ board: EDABoard, project: EDAProject, points: [EDAPoint]) -> Self {
        var copy = project; copy.boards = [board]
        return .init(project: copy, context: .board(boardID: board.id), bounds: fitted(points))
    }
    private static func fitted(_ points: [EDAPoint]) -> CGRect {
        guard let b = EDAGeometry.bounds(points.filter(\.isValid)) else { return CGRect(x: -5, y: -5, width: 10, height: 10) }
        let margin = max(1, max(b.max.x - b.min.x, b.max.y - b.min.y) * 0.12)
        return CGRect(x: b.min.x - margin, y: b.min.y - margin, width: max(2, b.max.x - b.min.x) + margin * 2, height: max(2, b.max.y - b.min.y) + margin * 2)
    }
    private static func padPoints(_ pads: [EDAPad]) -> [EDAPoint] {
        pads.flatMap { pad in
            [EDAPoint(-pad.size.x/2, -pad.size.y/2), .init(pad.size.x/2, -pad.size.y/2), .init(pad.size.x/2, pad.size.y/2), .init(-pad.size.x/2, pad.size.y/2)].map { $0.transformed(origin: pad.position, angle: pad.angle) }
        }
    }
    private static func graphicPoints(_ values: [EDAGraphic]) -> [EDAPoint] {
        values.flatMap { graphic -> [EDAPoint] in
            switch graphic {
            case .line(let a, let b, _), .rectangle(let a, let b, _), .dimension(let a, let b, _): return [a, b, .init(a.x,b.y), .init(b.x,a.y)]
            case .circle(let c, let r, _), .arc(let c, let r, _, _, _): return [c - .init(r,r), c + .init(r,r)]
            case .text(let text, let p, let h, let angle):
                return [p, EDAPoint(Double(text.count) * h, h).transformed(origin: p, angle: angle)]
            }
        }
    }
}

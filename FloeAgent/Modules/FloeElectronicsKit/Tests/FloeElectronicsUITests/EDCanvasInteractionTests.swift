// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeElectronicsCore
@testable import FloeElectronicsUI

final class EDCanvasInteractionTests: XCTestCase {
    private func apply(_ edits: [EDAEdit], to project: EDAProject) throws -> EDAProject {
        var session = try EDAEditingSession(project: project)
        try session.apply(edits, expectedRevision: project.revision)
        return session.project
    }
    private func equal(_ a: EDAPoint, _ b: EDAPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 1e-8, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-8, file: file, line: line)
    }

    func testHitsActualSegmentsAndStrokeWidths() {
        var project = EDAProject(title: "Segments")
        let track = EDATrack(netID: "A", width: 0.6, points: [.init(0,0),.init(100,0)])
        project.boards[0].tracks = [track]
        let context = EDADocumentContext.board(boardID: project.boards[0].id)
        XCTAssertEqual(EDCanvasInteraction.hit(project: project, context: context, at: .init(2,0.29), tolerance: 0.02), track.id)
        XCTAssertNil(EDCanvasInteraction.hit(project: project, context: context, at: .init(50,5), tolerance: 0.2))
        let wire = EDAWire(points: [.init(0,10),.init(100,110)])
        project.sheets[0].wires = [wire]
        let sheet = EDADocumentContext.schematic(sheetID: project.sheets[0].id)
        XCTAssertEqual(EDCanvasInteraction.hit(project: project, context: sheet, at: .init(2,12), tolerance: 0.01), wire.id)
        XCTAssertNil(EDCanvasInteraction.hit(project: project, context: sheet, at: .init(5,100), tolerance: 0.1))
        XCTAssertNil(EDCanvasInteraction.hit(project: project, context: context, at: .zero, tolerance: .nan))
    }

    func testHitUsesTransformedPadShapesWithoutOuterRectangle() {
        var project = EDAProject(title: "Pad transform")
        let pad = EDAPad(number: "1", position: .init(4,1), size: .init(8,1), angle: 45, shape: .rectangle)
        let definition = EDAFootprintDefinition(name: "Asymmetric", pads: [pad])
        let placed = EDAFootprint(definitionID: definition.id, position: .init(30,30), angle: 30, side: "B.Cu")
        project.footprints = [definition]; project.boards[0].footprints = [placed]
        let context = EDADocumentContext.board(boardID: project.boards[0].id)
        func world(_ q: EDAPoint) -> EDAPoint { placed.point(q.transformed(origin: pad.position, angle: pad.angle)) }
        XCTAssertEqual(EDCanvasInteraction.hit(project: project, context: context, at: world(.init(3.9,0.4)), tolerance: 0.01), placed.id)
        XCTAssertNil(EDCanvasInteraction.hit(project: project, context: context, at: world(.init(3.9,0.9)), tolerance: 0.01))
        var oval = definition; oval.pads[0].shape = .oval; oval.pads[0].position = .zero; oval.pads[0].angle = 0
        project.footprints = [oval]
        let library = EDADocumentContext.footprint(definitionID: oval.id)
        XCTAssertEqual(EDCanvasInteraction.hit(project: project, context: library, at: .init(4,0), tolerance: 0.01), pad.id)
        XCTAssertNil(EDCanvasInteraction.hit(project: project, context: library, at: .init(3.95,0.49), tolerance: 0.01))
        oval.pads[0].shape = .circle; oval.pads[0].size = .init(8,2); project.footprints = [oval]
        XCTAssertNil(EDCanvasInteraction.hit(project: project, context: library, at: .init(3.8,0.8), tolerance: 0.01))
        oval.pads[0].shape = .roundRectangle; oval.pads[0].size = .init(2,2); project.footprints = [oval]
        XCTAssertNil(EDCanvasInteraction.hit(project: project, context: library, at: .init(0.99,0.99), tolerance: 0.01))
        XCTAssertEqual(EDCanvasInteraction.hit(project: project, context: library, at: .zero, tolerance: 0.01), pad.id)
    }

    func testArcSweepSymbolUnitAndInstanceTransform() {
        var project = EDAProject(title: "Symbol boundary")
        let common = EDAPin(number: "0", position: .init(-3,0), unit: 0)
        let wrongUnit = EDAPin(number: "2", position: .init(20,20), unit: 2)
        let definition = EDASymbolDefinition(name: "Arc", pins: [common,wrongUnit], graphics: [
            .arc(center: .init(10,0), radius: 5, start: 0, sweep: 90, width: 0.2),
            .rectangle(.zero,.init(4,4),width:0.2)])
        let component = EDAComponent(symbolID: definition.id, reference: "U1")
        let placed = EDASymbolPlacement(componentID: component.id, unit: 1, position: .init(30,20), angle: 90, mirrored: true)
        project.symbols = [definition]; project.components = [component]; project.sheets[0].symbols = [placed]
        let context = EDADocumentContext.schematic(sheetID: project.sheets[0].id)
        func world(_ q: EDAPoint) -> EDAPoint { q.transformed(origin: placed.position, angle: placed.angle, mirrored: placed.mirrored) }
        XCTAssertEqual(EDCanvasInteraction.hit(project: project, context: context, at: world(.init(15,0)), tolerance: 0.01), placed.id)
        XCTAssertNil(EDCanvasInteraction.hit(project: project, context: context, at: world(.init(5,0)), tolerance: 0.01))
        XCTAssertEqual(EDCanvasInteraction.hit(project: project, context: context, at: world(.init(4,2)), tolerance: 0.01), placed.id)
        XCTAssertNil(EDCanvasInteraction.hit(project: project, context: context, at: world(.init(2,2)), tolerance: 0.01))
        XCTAssertEqual(EDCanvasInteraction.hit(project: project, context: context, at: world(common.position), tolerance: 0.01), placed.id)
        XCTAssertNil(EDCanvasInteraction.hit(project: project, context: context, at: world(wrongUnit.position), tolerance: 0.01))
        project.symbols[0].graphics = [.arc(center: .init(10,0), radius: 5, start: 0, sweep: -90, width: 0.2)]
        XCTAssertEqual(EDCanvasInteraction.hit(project: project, context: context, at: world(.init(10,-5)), tolerance: 0.01), placed.id)
        XCTAssertNil(EDCanvasInteraction.hit(project: project, context: context, at: world(.init(10,5)), tolerance: 0.01))
    }

    func testHoleSlotAndConcaveZoneBoundaries() {
        var project = EDAProject(title: "Boundary")
        let hole = EDAHole(position: .init(10,10), diameter: 8)
        let slot = EDAHole(position: .init(20,5), diameter: 1, endPosition: .init(30,5))
        let zone = EDAZone(netID: "A", outline: [.init(40,0),.init(50,0),.init(50,2),.init(42,2),.init(42,10),.init(40,10)], thermal: false)
        project.boards[0].holes = [hole,slot]; project.boards[0].zones = [zone]
        let context = EDADocumentContext.board(boardID: project.boards[0].id)
        XCTAssertEqual(EDCanvasInteraction.hit(project: project, context: context, at: .init(14,10), tolerance: 0.01), hole.id)
        XCTAssertNil(EDCanvasInteraction.hit(project: project, context: context, at: .init(14.2,10), tolerance: 0.01))
        XCTAssertEqual(EDCanvasInteraction.hit(project: project, context: context, at: .init(29.9,5.49), tolerance: 0.01), slot.id)
        XCTAssertNil(EDCanvasInteraction.hit(project: project, context: context, at: .init(30.5,5.5), tolerance: 0.01))
        XCTAssertEqual(EDCanvasInteraction.hit(project: project, context: context, at: .init(42,6), tolerance: 0.01), zone.id)
        XCTAssertNil(EDCanvasInteraction.hit(project: project, context: context, at: .init(48,8), tolerance: 0.01))
        XCTAssertNil(EDCanvasInteraction.hit(project: project, context: context, at: .init(41,5), tolerance: 0.01))
    }

    func testLockedOrForeignSelectionCannotPartiallyEdit() throws {
        var project = EDAProject(title: "Locked")
        let unlocked = EDATrack(netID: "A", points: [.init(1,1),.init(3,1)])
        let locked = EDATrack(netID: "B", points: [.init(5,1),.init(7,1)], locked: true)
        project.boards[0].tracks = [unlocked,locked]
        let before = project, context = EDADocumentContext.board(boardID: project.boards[0].id), selection: Set<UUID> = [unlocked.id,locked.id]
        XCTAssertTrue(EDCanvasInteraction.availableActions(project: project, context: context, objectIDs: selection).isEmpty)
        for action in EDCanvasInteraction.Action.allCases {
            XCTAssertThrowsError(try EDCanvasInteraction.edits(for: action, project: project, context: context, objectIDs: selection)) { XCTAssertEqual($0 as? EDAError, .readOnly) }
        }
        XCTAssertThrowsError(try EDCanvasInteraction.move(project: project, context: context, objectIDs: selection, by: .init(1,1)))
        XCTAssertThrowsError(try EDCanvasInteraction.move(project: project, context: context, objectIDs: [unlocked.id,UUID()], by: .init(1,1)))
        XCTAssertThrowsError(try EDCanvasInteraction.move(project: project, context: context, objectIDs: [unlocked.id], by: .init(.nan,0)))
        XCTAssertEqual(project,before)
    }

    func testDeleteAndDuplicateKeepOtherSymbolUnitsAndPhysicalBindings() throws {
        var project = EDAProject(title: "Units")
        let definition = EDASymbolDefinition(name: "Multi-unit", pins: [.init(number: "1", position: .zero)])
        let physical = EDAFootprintDefinition(name: "Physical")
        let component = EDAComponent(symbolID: definition.id, footprintID: physical.id, reference: "U1", value: "value", fields: ["owned":"keep"])
        let first = EDASymbolPlacement(componentID: component.id, unit: 1, position: .init(5,5))
        let second = EDASymbolPlacement(componentID: component.id, unit: 2, position: .init(10,5))
        let other = EDASymbolPlacement(componentID: component.id, unit: 3, position: .init(20,20))
        project.symbols = [definition]; project.footprints = [physical]; project.components = [component]
        project.sheets[0].symbols = [first,second]; project.sheets.append(.init(symbols: [other]))
        let footprint = EDAFootprint(definitionID: physical.id, componentID: component.id, reference: "U1", padNets: ["1":"VCC"])
        project.boards[0].footprints = [footprint]
        let context = EDADocumentContext.schematic(sheetID: project.sheets[0].id)
        let removed = try apply(EDCanvasInteraction.edits(for: .delete, project: project, context: context, objectIDs: [first.id]), to: project)
        XCTAssertEqual(removed.sheets[0].symbols,[second]); XCTAssertEqual(removed.sheets[1],project.sheets[1])
        XCTAssertEqual(removed.components,project.components); XCTAssertEqual(removed.boards,project.boards)
        let duplicated = try apply(EDCanvasInteraction.edits(for: .duplicate, project: project, context: context, objectIDs: [first.id,second.id]), to: project)
        let clone = try XCTUnwrap(duplicated.components.first { $0.id != component.id })
        let placements = duplicated.sheets[0].symbols.filter { $0.componentID == clone.id }
        XCTAssertEqual(duplicated.components.count,2); XCTAssertNotEqual(clone.reference,"U1"); XCTAssertEqual(clone.fields,component.fields)
        XCTAssertEqual(Set(placements.map(\.unit)),[1,2]); XCTAssertEqual(placements.count,2)
        XCTAssertEqual(duplicated.sheets[1],project.sheets[1]); XCTAssertEqual(duplicated.boards,project.boards)
        let boardContext = EDADocumentContext.board(boardID: project.boards[0].id)
        let boardCopy = try apply(EDCanvasInteraction.edits(for: .duplicate, project: project, context: boardContext, objectIDs: [footprint.id]), to: project)
        let placedCopy = try XCTUnwrap(boardCopy.boards[0].footprints.first { $0.id != footprint.id })
        XCTAssertNotEqual(placedCopy.componentID,component.id); XCTAssertEqual(placedCopy.padNets,footprint.padNets)
        XCTAssertEqual(boardCopy.components.first { $0.id == placedCopy.componentID }?.reference,placedCopy.reference)
        XCTAssertEqual(boardCopy.sheets,project.sheets)
    }

    func testBoardFlipUsesStackAndRealFootprintTransform() throws {
        var project = EDAProject(title: "Flip")
        project.boards[0].layers = [.init("F.Cu",kind:.copper),.init("In1.Cu",kind:.copper),.init("In2.Cu",kind:.copper),.init("B.Cu",kind:.copper)]
        let pad = EDAPad(number: "1", position: .init(3,2), shape: .rectangle)
        let definition = EDAFootprintDefinition(name: "Asymmetric", pads: [pad])
        let footprint = EDAFootprint(definitionID: definition.id, position: .init(20,20), angle: 30, padNets: ["1":"A"])
        project.footprints = [definition]; project.boards[0].footprints = [footprint]
        let context = EDADocumentContext.board(boardID: project.boards[0].id)
        let reflected = try apply(EDCanvasInteraction.edits(for: .flip, project: project, context: context, objectIDs: [footprint.id]), to: project)
        let changed = reflected.boards[0].footprints[0], oldPoint = footprint.point(pad.position)
        equal(changed.point(pad.position), .init(2 * footprint.position.x - oldPoint.x,oldPoint.y))
        XCTAssertEqual(changed.side,"B.Cu"); XCTAssertEqual(changed.padNets,footprint.padNets)
        var rotated = project
        for _ in 0..<4 { rotated = try apply(EDCanvasInteraction.edits(for: .rotate, project: rotated, context: context, objectIDs: [footprint.id]), to: rotated) }
        equal(rotated.boards[0].footprints[0].point(pad.position),oldPoint)
        let via = EDAVia(netID: "VCC",position:.init(8,8),startLayer:"F.Cu",endLayer:"In1.Cu")
        let track = EDATrack(netID:"VCC",layer:"In1.Cu",points:[.init(2,2),.init(6,2)])
        let keepout = EDAKeepout(outline:[.init(1,1),.init(2,1),.init(2,2),.init(1,2)],layers:["F.Cu","In1.Cu"],tracks:false,vias:true,copper:false)
        let slot = EDAHole(position:.init(10,10),diameter:1,endPosition:.init(14,12))
        project.boards[0].vias = [via]; project.boards[0].tracks = [track]; project.boards[0].keepouts = [keepout]; project.boards[0].holes = [slot]
        let ids: Set<UUID> = [via.id,track.id,keepout.id,slot.id]
        let flipped = try apply(EDCanvasInteraction.edits(for:.flip,project:project,context:context,objectIDs:ids),to:project)
        XCTAssertEqual(flipped.boards[0].tracks[0].layer,"In2.Cu"); XCTAssertEqual(flipped.boards[0].tracks[0].netID,"VCC")
        XCTAssertEqual(flipped.boards[0].vias[0].startLayer,"In2.Cu"); XCTAssertEqual(flipped.boards[0].vias[0].endLayer,"B.Cu")
        XCTAssertEqual(flipped.boards[0].keepouts[0].layers,["B.Cu","In2.Cu"])
        XCTAssertFalse(flipped.boards[0].keepouts[0].tracks); XCTAssertFalse(flipped.boards[0].keepouts[0].copper)
        XCTAssertEqual(flipped.boards[0].holes[0].position.distance(to: try XCTUnwrap(flipped.boards[0].holes[0].endPosition)),slot.position.distance(to: try XCTUnwrap(slot.endPosition)),accuracy:1e-8)
    }

    func testLibraryEditsPreserveMetadataAndAllocateNumbers() throws {
        var project = EDAProject(title: "Library")
        let first = EDAPad(number:"1",position:.init(1,2),angle:30,shape:.rectangle)
        let second = EDAPad(number:"2",position:.init(4,2))
        let definition = EDAFootprintDefinition(name:"Pads",pads:[first,second],graphics:[.rectangle(.zero,.init(8,5),width:0.1)],graphicLayers:[.init(layerID:"F.Fab",kind:.fabrication)])
        project.footprints = [definition]
        let context = EDADocumentContext.footprint(definitionID:definition.id)
        XCTAssertFalse(EDCanvasInteraction.availableActions(project:project,context:context,objectIDs:[first.id]).contains(.flip))
        let copied = try apply(EDCanvasInteraction.edits(for:.duplicate,project:project,context:context,objectIDs:[first.id,second.id]),to:project)
        XCTAssertEqual(Set(copied.footprints[0].pads.map(\.number)),["1","2","3","4"])
        XCTAssertEqual(copied.footprints[0].graphics,definition.graphics); XCTAssertEqual(copied.footprints[0].graphicLayers,definition.graphicLayers)
        let removed = try apply(EDCanvasInteraction.edits(for:.delete,project:project,context:context,objectIDs:[first.id]),to:project)
        XCTAssertEqual(removed.footprints[0].pads,[second]); XCTAssertEqual(removed.footprints[0].graphicLayers,definition.graphicLayers)
    }

    func testMoveUsesRealTransactionRevisionUndoAndInvalidatesActualFill() throws {
        var project = EDAProject(title:"Fill movement")
        let zone = EDAZone(netID:"A",outline:[.init(5,5),.init(20,5),.init(20,20),.init(5,20)],thermal:false)
        project.boards[0].zones = [zone]
        let context = EDADocumentContext.board(boardID:project.boards[0].id)
        var session = try EDAEditingSession(project:project)
        _ = try session.refillCopper(boardID:project.boards[0].id,expectedRevision:0)
        XCTAssertEqual(session.project.boards[0].zones[0].fillState,.filled)
        let filled = session.project
        let edits = try EDCanvasInteraction.move(project:filled,context:context,objectIDs:[zone.id],by:.init(2,1))
        XCTAssertEqual(session.project,filled) // Planning itself has no side effect.
        try session.apply(edits,expectedRevision:filled.revision)
        XCTAssertEqual(session.project.boards[0].zones[0].outline[0],.init(7,6))
        XCTAssertNil(session.project.boards[0].zones[0].fillRevision); XCTAssertNil(session.project.boards[0].zones[0].fillState)
        XCTAssertTrue(session.project.boards[0].zones[0].filledPolygons.isEmpty)
        let moved = session.project
        XCTAssertThrowsError(try session.apply(edits,expectedRevision:filled.revision)); XCTAssertEqual(session.project,moved)
        try session.undo(expectedRevision:session.project.revision)
        XCTAssertEqual(session.project.boards[0].zones[0].outline,filled.boards[0].zones[0].outline)
        XCTAssertEqual(session.project.boards[0].zones[0].filledPolygons,filled.boards[0].zones[0].filledPolygons)
        XCTAssertEqual(session.project.boards[0].zones[0].fillRevision,session.project.revision)
    }
}
